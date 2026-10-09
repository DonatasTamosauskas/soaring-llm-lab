extends Node
## Proves the vertex shader and BirdPose (the CPU maths every animation test
## uses) pose the birds identically: each case is rendered twice with the
## same camera - the real BirdModel (GPU, batched MultiMesh) and a mesh
## posed on the CPU by BirdPose - and compared twice:
##   1. Silhouettes, with the real material: the robust mismatch (pixels of
##      one silhouette with no pixel of the other within 1 px, as a share of
##      the union; antialiasing on 2-px-thin edge-on wings dominates raw IoU).
##      Every case must stay below MAX_MISMATCH.
##   2. Positions: a copy of the real shader code whose fragment writes the
##      posed model-space position as the colour, against the CPU mesh with
##      BirdPose's positions as vertex colours. Inside both silhouettes every
##      pixel must agree within MAX_POS_ERROR (span units, one step of the
##      8-bit encoding): any posing difference moves the colour of every
##      pixel it touches, even where the silhouettes overlap (an 8 deg change
##      of one fold angle moves the wing by 0.02-0.05).
##   gpu_vs_cpu.png    silhouette overlays (red = GPU only, blue = CPU only)
##                     and, below, position error maps (black = 0, white >=
##                     2 x MAX_POS_ERROR)
##   gpu_vs_cpu.json   per case: IoU, mismatch, worst and 99th-percentile
##                     position error
##
##   tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 \
##       res://tests/shots/birds_gpu_check.tscn

const Stage := preload("res://tests/shots/birds_stage.gd")
const CELL := 200
const MAX_MISMATCH := 0.005
## Posed position agreement inside the silhouettes, span units. The colour
## is 8-bit sRGB, so a position reads to within one byte: 0.001 span at the
## dark end of the encoding, 0.0075 at mid-grey, 0.011 at the bright end.
## The limit is just over one byte anywhere: the two paths must agree to the
## encoding's own resolution (a GPU that rounds a step differently passes; a
## posing difference of two steps or more fails).
const MAX_POS_ERROR := 0.012
## Share of interior pixels allowed over it (surfaces in contact).
const MAX_POS_SHARE := 0.02
const BG := Color(1.0, 0.0, 1.0)
## Position -> colour: c = p * POS_K + 0.5 (linear), covering |p| < 0.6.
const POS_K := 0.8

var _cpu_mat := StandardMaterial3D.new()


func _ready() -> void:
	_cpu_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cpu_mat.albedo_color = Color(0.1, 0.4, 0.9)
	# Back faces culled, as the bird material does (same triangles, same
	# winding: like is compared with like).
	_cpu_mat.cull_mode = BaseMaterial3D.CULL_BACK
	BirdModels.material().set_shader_parameter("head_look_amount", 0.0)
	BirdPose.head_look_amount = 0.0
	var cases := []
	for sp in [&"sparrow", &"swallow", &"gull", &"crow", &"eagle", &"moth", &"wren"]:
		for inst in [Vector4(0.0, 1.0, 0.0, 0.0), Vector4(0.2, 1.0, 0.0, 0.0), Vector4(0.42, 1.0, 0.0, 0.0),
				Vector4(0.65, 1.0, 0.0, 0.0), Vector4(0.85, 1.0, 0.0, 0.0), Vector4(0.3, 0.0, 0.5, 0.0),
				Vector4(0.7, 1.0, 0.45, 0.6), Vector4(0.3, 0.0, 0.85, 0.5),
				Vector4(0.3, 0.0, 1.0, 0.0), Vector4(0.3, 0.0, 1.0, 1.0)]:
			cases.append([sp, inst, "three_q" if inst.x < 0.5 or inst.y == 0.0 else "three_q_below"])
		cases.append([sp, Vector4(0.1, 1.0, 0.0, 0.0), "front"])
		cases.append([sp, Vector4(0.3, 0.0, 1.0, 1.0), "side"])
	var vp := Stage.make(self, Vector2i(CELL, CELL), BG, 1.2)
	var env: Environment = (vp.get_child(0) as WorldEnvironment).environment
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var cols := 12
	var rows := int(ceil(cases.size() / float(cols)))
	var sheet := Image.create(CELL * cols, CELL * rows * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(1, 1, 1))
	var report := {}
	var worst := 0.0
	var worst_pos := 0.0
	var failed := 0
	# Pass 1: silhouettes with the real material.
	for ci in cases.size():
		var c: Array = cases[ci]
		var a: Image = await _gpu(vp, c)
		var b: Image = await _cpu(vp, c, false)
		var r := _silhouette_diff(a, b)
		var key := "%s %s %s" % [c[0], c[2], c[1]]
		report[key] = {"iou": snappedf(r[0], 0.0001), "mismatch": snappedf(r[1], 0.00001)}
		worst = maxf(worst, r[1])
		if r[1] > MAX_MISMATCH:
			failed += 1
		sheet.blit_rect(r[2], Rect2i(0, 0, CELL, CELL), Vector2i((ci % cols) * CELL, (ci / cols) * CELL))
	# Pass 2: posed positions, through a copy of the real shader code.
	var dbg := _position_shader()
	if dbg == null:
		print("[birds] gpu/cpu: could not build the position shader from bird.gdshader")
		get_tree().quit(1)
		return
	var real_shader := BirdModels.material().shader
	BirdModels.material().shader = dbg
	for ci in cases.size():
		var c: Array = cases[ci]
		var a: Image = await _gpu(vp, c)
		var b: Image = await _cpu(vp, c, true)
		var r := _position_diff(a, b)
		var key := "%s %s %s" % [c[0], c[2], c[1]]
		report[key]["pos_err_max"] = snappedf(r[0], 0.0001)
		report[key]["pos_err_p99"] = snappedf(r[1], 0.0001)
		report[key]["pos_share_over"] = snappedf(r[2], 0.0001)
		worst_pos = maxf(worst_pos, r[1])
		# A posing difference moves a whole region; a few pixels where two
		# surfaces touch (a folded wing on the back: equal depth to float
		# precision) may show the other surface on each path.
		if r[1] > MAX_POS_ERROR or r[2] > MAX_POS_SHARE:
			failed += 1
		print("[birds] gpu/cpu %-9s %-13s %s IoU %.4f mismatch %.5f  pos err p99 %.4f max %.4f (%.2f%% over)" % [c[0], c[2], c[1],
			report[key]["iou"], report[key]["mismatch"], r[1], r[0], r[2] * 100.0])
		sheet.blit_rect(r[3], Rect2i(0, 0, CELL, CELL), Vector2i((ci % cols) * CELL, (rows + ci / cols) * CELL))
	BirdModels.material().shader = real_shader
	BirdModels.material().set_shader_parameter("head_look_amount", 1.0)
	BirdPose.head_look_amount = 1.0
	Stage.save(sheet, "gpu_vs_cpu.png")
	var out := {"max_mismatch_allowed": MAX_MISMATCH, "max_pos_error_allowed": MAX_POS_ERROR, "max_pos_share_over": MAX_POS_SHARE,
		"worst_mismatch": snappedf(worst, 0.00001), "worst_pos_err_p99": snappedf(worst_pos, 0.0001),
		"cases": report.size(), "failed": failed, "per_case": report}
	var f := FileAccess.open(Paths.artifacts("birds").path_join("gpu_vs_cpu.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	print("[birds] gpu/cpu worst mismatch %.5f, worst position error (p99) %.4f over %d cases, %d failed" % [worst, worst_pos, report.size(), failed])
	get_tree().quit(1 if failed > 0 else 0)


## The real BirdModel (GPU), posed by its fields.
func _gpu(vp: SubViewport, c: Array) -> Image:
	var inst: Vector4 = c[1]
	Stage.aim(vp, c[2], Vector3.ZERO, 4.0)
	var m := BirdModels.create(c[0])
	m.lod_override = 0
	vp.add_child(m)
	m.flap_phase = inst.x
	m.flap_amount = inst.y
	m.wing_fold = inst.z
	m.perched = inst.w > 0.5
	m.snap()
	# Show exactly this pose (including blends such as perch 0.6, which no
	# field can hold): let the first sync take the fields, then freeze the
	# model (no smoothing) and set the displayed pose.
	m.process_mode = Node.PROCESS_MODE_DISABLED
	await RenderingServer.frame_post_draw
	m._phase_s = inst.x
	m._amount_s = inst.y
	m._fold_s = inst.z
	m._perch_s = inst.w
	var img: Image = await Stage.grab(vp)
	m.queue_free()
	img.convert(Image.FORMAT_RGBA8)
	return img


## The same pose from BirdPose on the CPU (positions as colours if `pos`).
func _cpu(vp: SubViewport, c: Array, pos: bool) -> Image:
	Stage.aim(vp, c[2], Vector3.ZERO, 4.0)
	var mi := MeshInstance3D.new()
	mi.mesh = _cpu_mesh(c[0], c[1])
	if pos:
		# The same position encoding as the GPU copy, from the CPU-posed
		# vertices (a float varying: no 8-bit vertex colours in between).
		var pm := ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = "shader_type spatial;\nrender_mode cull_back, depth_draw_opaque, unshaded;\nvarying vec3 v_pos;\nvoid vertex() {\n\tv_pos = VERTEX;\n}\nvoid fragment() {\n\tALBEDO = v_pos * %f + 0.5;\n}\n" % POS_K
		pm.shader = sh
		mi.material_override = pm
	else:
		mi.material_override = _cpu_mat
	vp.add_child(mi)
	var img: Image = await Stage.grab(vp)
	mi.queue_free()
	img.convert(Image.FORMAT_RGBA8)
	return img


## [IoU, robust mismatch, overlay cell].
func _silhouette_diff(a: Image, b: Image) -> Array:
	var ma := PackedByteArray()
	var mb := PackedByteArray()
	ma.resize(CELL * CELL)
	mb.resize(CELL * CELL)
	for y in CELL:
		for x in CELL:
			ma[y * CELL + x] = 1 if _is_bird(a.get_pixel(x, y)) else 0
			mb[y * CELL + x] = 1 if _is_bird(b.get_pixel(x, y)) else 0
	var inter := 0
	var uni := 0
	var off := 0
	var cell := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
	for y in CELL:
		for x in CELL:
			var ia := ma[y * CELL + x] == 1
			var ib := mb[y * CELL + x] == 1
			var col := Color(1, 1, 1)
			if ia and ib:
				inter += 1
				col = Color(0.15, 0.15, 0.2)
			elif ia:
				col = Color(0.95, 0.1, 0.1)
				if not _near(mb, x, y):
					off += 1
					col = Color(1.0, 0.6, 0.0)
			elif ib:
				col = Color(0.1, 0.3, 1.0)
				if not _near(ma, x, y):
					off += 1
					col = Color(0.0, 0.9, 0.9)
			if ia or ib:
				uni += 1
			cell.set_pixel(x, y, col)
	return [float(inter) / maxf(uni, 1.0), float(off) / maxf(uni, 1.0), cell]


## [max error, 99th percentile error, share of pixels over MAX_POS_ERROR,
## error map] over pixels well inside both silhouettes.
func _position_diff(a: Image, b: Image) -> Array:
	var errs := PackedFloat32Array()
	var over := 0
	var cell := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
	cell.fill(Color(0.35, 0.55, 0.35))
	for y in range(1, CELL - 1):
		for x in range(1, CELL - 1):
			var inside := true
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if not _is_bird(a.get_pixel(x + dx, y + dy)) or not _is_bird(b.get_pixel(x + dx, y + dy)):
						inside = false
			if not inside:
				continue
			var pa := _decode(a.get_pixel(x, y))
			var pb := _decode(b.get_pixel(x, y))
			var e := maxf(absf(pa.x - pb.x), maxf(absf(pa.y - pb.y), absf(pa.z - pb.z)))
			errs.append(e)
			if e > MAX_POS_ERROR:
				over += 1
			var g := clampf(e / (2.0 * MAX_POS_ERROR), 0.0, 1.0)
			cell.set_pixel(x, y, Color(g, g, g) if e <= MAX_POS_ERROR else Color(1.0, g * 0.3, 0.1))
	if errs.is_empty():
		return [0.0, 0.0, 0.0, cell]
	var sorted := Array(errs)
	sorted.sort()
	return [sorted[sorted.size() - 1], sorted[int(sorted.size() * 0.99)], float(over) / errs.size(), cell]


func _decode(c: Color) -> Vector3:
	var l := c.srgb_to_linear()
	return (Vector3(l.r, l.g, l.b) - Vector3(0.5, 0.5, 0.5)) / POS_K


## bird.gdshader with its fragment replaced: the posed model-space position
## as an unlit colour. The vertex code (the thing under test) is untouched.
static func _position_shader() -> Shader:
	var code := BirdModels.SHADER.code
	var mode := "render_mode cull_back, depth_draw_opaque, diffuse_lambert, specular_schlick_ggx;"
	var at := code.find("void fragment()")
	if not code.contains(mode) or not code.contains("\tVERTEX = q;") or at < 0:
		return null
	code = code.substr(0, at) + "void fragment() {\n\tALBEDO = v_pos * %f + 0.5;\n}\n" % POS_K
	code = code.replace(mode, "render_mode cull_back, depth_draw_opaque, unshaded;\nvarying vec3 v_pos;")
	code = code.replace("\tVERTEX = q;", "\tVERTEX = q;\n\tv_pos = q;")
	var sh := Shader.new()
	sh.code = code
	return sh


func _near(m: PackedByteArray, x: int, y: int) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var xx := x + dx
			var yy := y + dy
			if xx >= 0 and yy >= 0 and xx < CELL and yy < CELL and m[yy * CELL + xx] == 1:
				return true
	return false


func _is_bird(c: Color) -> bool:
	return absf(c.r - BG.r) + absf(c.g - BG.g) + absf(c.b - BG.b) > 0.35


func _cpu_mesh(sp: StringName, inst: Vector4) -> ArrayMesh:
	var arr := BirdModels.mesh(sp, 0).surface_get_arrays(0)
	var v := BirdPose.pose_arrays(arr, inst)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = v
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	return am
