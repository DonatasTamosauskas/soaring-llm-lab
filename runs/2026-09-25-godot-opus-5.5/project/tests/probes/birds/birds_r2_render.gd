extends Node
## Round-2 verifier render probe for the birds area (experience lens).
## Written by the verifier. Quits itself; outputs go to artifacts/birds/verify/.
##
##   tools/gd.sh birds_verify --rendering-method forward_plus --resolution 1600x900 \
##       res://tests/probes/birds/birds_r2_render.tscn
##
## 1. r2_world_40m_*.png / r2_world_40m.json: highlighted birds 40 m away in
##    the REAL world (SoaringWorld: its terrain, roofs, trees, water, fog,
##    sun), 15 birds per view over whatever is behind them, 4 views. The same
##    Oklab measurement as the builder's shot (core pixels, pulse pinned at
##    its dimmest and brightest), but over real, cluttered backgrounds.
## 2. r2_size_cue.png / r2_size_cue.json: a sparrow player's view: an edible
##    moth and an edible wren next to an ordinary sparrow at 40/20/10/5 m.
##    Does the prey read smaller than the player's own species, and does it
##    grow as you close in?
## 3. r2_perched.png: perched close-ups (side and from above-behind).
## 4. r2_bad_input.png / r2_bad_input.json: one bird with degenerate input
##    (highlighted at scale 0; one frame of NaN flap_phase) among 4 others.

const W := 1600
const H := 900
const FOV := 45.0
const OUT_SUB := "birds/verify"

var vp: SubViewport
var cam: Camera3D
var report := {}


func _ready() -> void:
	var only := String(Paths.user_args().get("only", "world,size,perched,bad")).split(",")
	var rp := Paths.artifacts(OUT_SUB).path_join("r2_render.json")
	if FileAccess.file_exists(rp):
		var prev: Variant = JSON.parse_string(FileAccess.get_file_as_string(rp))
		if prev is Dictionary:
			report = prev
	if only.has("world"):
		await _world_views()
	if only.has("size"):
		await _size_cue()
	if only.has("perched"):
		await _perched()
	if only.has("bad"):
		await _bad_input()
	var f := FileAccess.open(rp, FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	print("[birds-r2] wrote r2_render.json")
	get_tree().quit()


# --- helpers ------------------------------------------------------------------

func _grab(v: SubViewport) -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := v.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img


func _save(img: Image, name: String) -> void:
	var p := Paths.artifacts(OUT_SUB).path_join(name)
	img.save_png(p)
	print("[birds-r2] wrote ", p)


func _annotate(img: Image, labels: Array) -> Image:
	var v := SubViewport.new()
	v.size = img.get_size()
	v.disable_3d = true
	v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(v)
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.size = Vector2(img.get_size())
	v.add_child(tr)
	for l in labels:
		var lb := Label.new()
		lb.text = l[0]
		lb.position = l[1]
		lb.add_theme_font_size_override("font_size", l[2])
		lb.add_theme_color_override("font_color", l[3])
		lb.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		lb.add_theme_constant_override("outline_size", 5)
		v.add_child(lb)
	var out: Image = await _grab(v)
	v.queue_free()
	return out


static func _lin(x: float) -> float:
	return x / 12.92 if x <= 0.04045 else pow((x + 0.055) / 1.055, 2.4)


static func oklab(c: Color) -> Vector3:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var l := pow(maxf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 0.0), 1.0 / 3.0)
	var m := pow(maxf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 0.0), 1.0 / 3.0)
	var s := pow(maxf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 0.0), 1.0 / 3.0)
	return Vector3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


## Bird pixels near `c` (where `img` differs from `bg`): {n, core (Color),
## behind (Color), bbox (Rect2i)}. Core = the half that differs most.
static func bird_pixels(img: Image, bg: Image, c: Vector2, half: int) -> Dictionary:
	var px := []
	var x0 := clampi(int(c.x) - half, 0, img.get_width() - 1)
	var x1 := clampi(int(c.x) + half, 0, img.get_width() - 1)
	var y0 := clampi(int(c.y) - half, 0, img.get_height() - 1)
	var y1 := clampi(int(c.y) + half, 0, img.get_height() - 1)
	var minx := 99999
	var maxx := -1
	var miny := 99999
	var maxy := -1
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var a := img.get_pixel(x, y)
			var b := bg.get_pixel(x, y)
			var d := maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))
			if d > 0.035:
				px.append([d, a, b])
				minx = mini(minx, x)
				maxx = maxi(maxx, x)
				miny = mini(miny, y)
				maxy = maxi(maxy, y)
	if px.is_empty():
		return {"n": 0}
	px.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
	var k := maxi(1, px.size() / 2)
	var core := Color(0, 0, 0)
	var behind := Color(0, 0, 0)
	for i in k:
		core += px[i][1]
	for p in px:
		behind += p[2]
	core = Color(core.r / k, core.g / k, core.b / k)
	behind = Color(behind.r / px.size(), behind.g / px.size(), behind.b / px.size())
	return {"n": px.size(), "core": core, "behind": behind, "bbox": Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)}


# --- 1 + 2: the real world ------------------------------------------------------

func _world_views() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var scene := load("res://scenes/world/world.tscn") as PackedScene
	if scene == null:
		print("[birds-r2] world scene unavailable: skipping world views")
		report["world"] = "unavailable"
		return
	var world: Node = scene.instantiate()
	vp.add_child(world)
	if not world.get("is_generated"):
		await world.generated
	cam = Camera3D.new()
	cam.fov = FOV
	cam.near = 0.05
	cam.far = 3000.0
	vp.add_child(cam)
	cam.current = true
	for j in 4:
		await get_tree().process_frame
	var views := [
		["village", Vector3(-40, 20, 62), Vector3(-95, 4, 30)],
		["forest", Vector3(-200, 32, -205), Vector3(-262, 6, -258)],
		["lake", Vector3(150, 10, 150), Vector3(228, -0.6, 228)],
		["spawn_level", Vector3(-31.5, 12.5, 39.0), Vector3(-31.5, 14.0, -40.0)],
	]
	var mat := BirdModels.material()
	var all := {}
	var fails := []
	var worst := {"state": [INF, ""], "pair": [INF, ""], "background": [INF, ""]}
	var sheet_rows := []
	for vi in views.size():
		var v: Array = views[vi]
		cam.global_position = v[1]
		cam.look_at(v[2], Vector3.UP)
		# The world swaps terrain LOD from the camera; let it settle.
		for j in 6:
			await get_tree().process_frame
		var bg: Image = await _grab(vp)
		var birds: Array[BirdModel] = []
		var dirs := []
		for yi in 5:
			for pi_ in 3:
				var yaw := deg_to_rad(-18.0 + 9.0 * yi)
				var pitch := deg_to_rad(-8.0 + 6.0 * pi_)
				var fwd := -cam.global_basis.z
				var dir := fwd.rotated(cam.global_basis.x, pitch).rotated(Vector3.UP, -yaw).normalized()
				dirs.append(dir)
				var sp: StringName = BirdSpecies.IDS[(yi * 3 + pi_ + vi * 3) % 10]
				var m := BirdModels.create(sp)
				m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
				m.cast_shadows = false
				vp.add_child(m)
				m.global_position = cam.global_position + dir * 40.0
				m.look_at(m.global_position + cam.global_basis.x - fwd * 0.3, Vector3.UP)
				m.bank = deg_to_rad(15.0)
				m.flap_phase = 0.25
				birds.append(m)
		var frames := {}
		for st in [0, 1, 2]:
			for pulse in ([0.0, 1.0] if st > 0 else [0.0]):
				mat.set_shader_parameter("pulse_test", pulse)
				for m in birds:
					m.highlight = st
					m.snap()
				frames["%d_%d" % [st, int(pulse)]] = await _grab(vp)
		mat.set_shader_parameter("pulse_test", -1.0)
		var rows := []
		var rad_px := deg_to_rad(FOV) / H
		for i in birds.size():
			var m := birds[i]
			var c := cam.unproject_position(m.global_position)
			var span_px := BirdModels.min_highlight_angle(m.species) / rad_px
			var half := clampi(int(span_px * 0.9) + 6, 8, 90)
			var none: Dictionary = bird_pixels(frames["0_0"], bg, c, half)
			var none_col: Color = none["core"] if int(none["n"]) >= 3 else (bird_pixels(frames["1_0"], bg, c, half).get("behind", bg.get_pixel(int(c.x), int(c.y))))
			var worst_bird := {"state": INF, "pair": INF, "background": INF}
			for pulse in [0, 1]:
				var e: Dictionary = bird_pixels(frames["1_%d" % pulse], bg, c, half)
				var d: Dictionary = bird_pixels(frames["2_%d" % pulse], bg, c, half)
				if int(e["n"]) == 0 or int(d["n"]) == 0:
					fails.append("%s %s: highlighted bird not visible" % [v[0], m.species])
					continue
				var le := oklab(e["core"])
				var ld := oklab(d["core"])
				var ln := oklab(none_col)
				worst_bird["state"] = minf(worst_bird["state"], minf(le.distance_to(ln), ld.distance_to(ln)))
				worst_bird["pair"] = minf(worst_bird["pair"], le.distance_to(ld))
				worst_bird["background"] = minf(worst_bird["background"], minf(le.distance_to(oklab(e["behind"])), ld.distance_to(oklab(d["behind"]))))
			var tag := "%s %s (%d,%d)" % [v[0], m.species, int(c.x), int(c.y)]
			var behind_desc: Color = bird_pixels(frames["1_0"], bg, c, half).get("behind", Color(0, 0, 0))
			rows.append({"bird": tag, "behind": behind_desc.to_html(false), "state": snappedf(worst_bird["state"], 0.001),
				"pair": snappedf(worst_bird["pair"], 0.001), "background": snappedf(worst_bird["background"], 0.001)})
			for k in worst:
				if float(worst_bird[k]) < float(worst[k][0]):
					worst[k] = [snappedf(worst_bird[k], 0.001), tag]
			if worst_bird["state"] < 0.12:
				fails.append("%s: state %.3f < 0.12" % [tag, worst_bird["state"]])
			if worst_bird["pair"] < 0.15:
				fails.append("%s: edible/danger %.3f < 0.15" % [tag, worst_bird["pair"]])
			if worst_bird["background"] < 0.15:
				fails.append("%s: vs background %.3f < 0.15 (behind #%s)" % [tag, worst_bird["background"], behind_desc.to_html(false)])
		all[v[0]] = rows
		# Evidence: the edible (dimmest pulse) frame and the danger frame.
		var e_img: Image = frames["1_0"]
		var d_img: Image = frames["2_0"]
		var both := Image.create(W, H / 2, false, Image.FORMAT_RGBA8)
		var e_half := e_img.duplicate() as Image
		e_half.resize(W / 2, H / 2, Image.INTERPOLATE_BILINEAR)
		var d_half := d_img.duplicate() as Image
		d_half.resize(W / 2, H / 2, Image.INTERPOLATE_BILINEAR)
		both.blit_rect(e_half, Rect2i(0, 0, W / 2, H / 2), Vector2i(0, 0))
		both.blit_rect(d_half, Rect2i(0, 0, W / 2, H / 2), Vector2i(W / 2, 0))
		_save(await _annotate(both, [["%s: edible (left) / danger (right), 15 birds at 40 m, pulse at its dimmest" % v[0], Vector2(8, 4), 16, Color(1, 1, 0.8)]]), "r2_world_40m_%s.png" % v[0])
		_save(e_img, "r2_world_40m_%s_edible_full.png" % v[0])
		# Zoom sheet: each bird none / edible / danger at 4x.
		var z := 4
		var cell := 36
		var zs := Image.create(3 * cell * z, birds.size() * cell * z / 3 + 0, false, Image.FORMAT_RGBA8)
		zs = Image.create(5 * 3 * cell * z / 2, 3 * cell * z / 2, false, Image.FORMAT_RGBA8)
		for i in birds.size():
			var c := cam.unproject_position(birds[i].global_position)
			var col := i / 3
			var row := i % 3
			for st in 3:
				var src: Image = frames["%d_0" % st]
				var rect := Rect2i(Vector2i(c) - Vector2i(cell / 2, cell / 2), Vector2i(cell, cell))
				rect = rect.intersection(Rect2i(0, 0, W, H))
				var reg := src.get_region(rect)
				reg.resize(cell * z / 2, cell * z / 2, Image.INTERPOLATE_NEAREST)
				zs.blit_rect(reg, Rect2i(0, 0, reg.get_width(), reg.get_height()), Vector2i((col * 3 + st) * cell * z / 2, row * cell * z / 2))
		_save(zs, "r2_world_40m_%s_zoom.png" % v[0])
		for m in birds:
			m.free()
		sheet_rows.append(v[0])
	report["world_40m"] = {"thresholds": {"state": 0.12, "pair": 0.15, "background": 0.15}, "worst": worst,
		"failures": fails.size(), "fail_list": fails, "per_view": all}
	print("[birds-r2] real-world 40 m: worst state %s, pair %s, background %s; %d failures" % [str(worst["state"]), str(worst["pair"]), str(worst["background"]), fails.size()])
	for x in fails.slice(0, 30):
		print("[birds-r2]   fail ", x)
	world.queue_free()
	vp.queue_free()
	await get_tree().process_frame


## A sparrow player's view up at birds flying away overhead (plain sky, 20
## px/deg like a Quest Pro): an edible wren and an edible moth next to an
## ordinary sparrow (the player's own species), at 40/20/10/5 m. Their drawn
## widths in pixels: does prey read smaller than you, and does it grow as you
## close in?
func _size_cue() -> void:
	var sv := _stage(Vector2i(W, H))
	var sc := sv.get_node("Cam") as Camera3D
	sc.fov = FOV
	sc.far = 500.0
	sc.global_position = Vector3.ZERO
	sc.rotation = Vector3(deg_to_rad(20.0), 0.0, 0.0)
	var bg: Image = await _grab(sv)
	var res := {}
	var cells := []
	for d: float in [40.0, 20.0, 10.0, 5.0]:
		var trio := [[&"wren", 1, -8.0], [&"moth", 1, 0.0], [&"sparrow", 0, 8.0]]
		var ms: Array[BirdModel] = []
		for t in trio:
			var m := BirdModels.create(t[0])
			m.scale = Vector3.ONE * float(SizeRules.species_data(t[0])["span"])
			m.cast_shadows = false
			sv.add_child(m)
			var dir := (-sc.global_basis.z).rotated(Vector3.UP, deg_to_rad(-float(t[2])))
			m.global_position = dir * d
			# Flying away, level: seen from 20 deg below, span across the view.
			m.look_at(m.global_position + Vector3(0, 0, -1), Vector3.UP)
			m.flap_phase = 0.25
			m.highlight = t[1]
			m.snap()
			ms.append(m)
		var img: Image = await _grab(sv)
		var row := {}
		for i in ms.size():
			var c := sc.unproject_position(ms[i].global_position)
			var bp: Dictionary = bird_pixels(img, bg, c, 70)
			var wpx: int = (bp["bbox"] as Rect2i).size.x if int(bp["n"]) > 0 else 0
			row[String(ms[i].species) + ("_edible" if ms[i].highlight == 1 else "")] = wpx
		res["%dm" % int(d)] = row
		var cc := sc.unproject_position(ms[1].global_position)
		var cw := 520
		var ch := 120
		var rect := Rect2i(Vector2i(int(cc.x) - cw / 2, int(cc.y) - ch / 2), Vector2i(cw, ch)).intersection(Rect2i(0, 0, W, H))
		cells.append([d, img.get_region(rect)])
		for m in ms:
			m.free()
	var sheet := Image.create(520, 4 * 120 + 30, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	var labels := [["sparrow player (1:1 at 20 px/deg): edible wren | edible moth | ordinary sparrow", Vector2(6, 6), 13, Color(1, 1, 0.8)]]
	for i in cells.size():
		var reg: Image = cells[i][1]
		sheet.blit_rect(reg, Rect2i(0, 0, reg.get_width(), reg.get_height()), Vector2i(0, 30 + i * 120))
		var r: Dictionary = res["%dm" % int(cells[i][0])]
		labels.append(["%d m: drawn width px  wren %d | moth %d | sparrow %d" % [int(cells[i][0]), int(r.get("wren_edible", 0)), int(r.get("moth_edible", 0)), int(r.get("sparrow", 0))],
			Vector2(6, 32 + i * 120), 13, Color(1, 1, 1)])
	_save(await _annotate(sheet, labels), "r2_size_cue.png")
	report["size_cue_px"] = res
	print("[birds-r2] size cue (px widths): ", res)
	sv.queue_free()


# --- 3: perched close-ups ---------------------------------------------------------

func _stage(size: Vector2i) -> SubViewport:
	var v := SubViewport.new()
	v.size = size
	v.own_world_3d = true
	v.msaa_3d = Viewport.MSAA_4X
	v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(v)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.84, 0.88, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.82, 0.9)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	v.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.2
	sun.rotation_degrees = Vector3(-50, -30, 0)
	v.add_child(sun)
	var c := Camera3D.new()
	c.name = "Cam"
	c.fov = 30.0
	c.near = 0.01
	c.far = 200.0
	v.add_child(c)
	c.current = true
	return v


func _perched() -> void:
	var cell := Vector2i(360, 260)
	var v := _stage(cell)
	var c := v.get_node("Cam") as Camera3D
	var species := [&"wren", &"sparrow", &"swallow", &"starling", &"crow", &"gull", &"hawk", &"eagle", &"moth"]
	var views := [["side", Vector3(1, 0.05, 0)], ["above-behind", Vector3(0.45, 0.8, 0.8)], ["front-below", Vector3(0.3, -0.25, -1)],
		["top (straight down)", Vector3(0.0, 1.0, 0.02)], ["behind", Vector3(0.0, 0.12, 1.0)]]
	var sheet := Image.create(cell.x * species.size(), cell.y * views.size() + 26, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.97, 0.97, 0.96))
	var labels := []
	HeadLook.freeze(BirdModels.material())
	for si in species.size():
		var m := BirdModels.create(species[si])
		v.add_child(m)
		m.perched = true
		m.wing_fold = 1.0
		m.lod_override = 0
		m.snap()
		labels.append([String(species[si]), Vector2(si * cell.x + 8, 4), 16, Color(0.1, 0.1, 0.1)])
		for vi in views.size():
			c.global_position = (views[vi][1] as Vector3).normalized() * 1.25
			c.look_at(Vector3(0, -0.05, 0), Vector3.UP)
			var img: Image = await _grab(v)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i(si * cell.x, 26 + vi * cell.y))
		m.free()
	for vi in views.size():
		labels.append([views[vi][0], Vector2(8, 26 + vi * cell.y + 6), 14, Color(0.2, 0.2, 0.6)])
	BirdModels.material().set_shader_parameter("head_look_amount", 1.0)
	_save(await _annotate(sheet, labels), "r2_perched.png")
	v.queue_free()


# --- 4: degenerate input among neighbours ----------------------------------------

func _bad_input() -> void:
	var v := _stage(Vector2i(900, 300))
	var c := v.get_node("Cam") as Camera3D
	c.global_position = Vector3(0, 0, 9)
	c.look_at(Vector3.ZERO, Vector3.UP)
	var crows: Array[BirdModel] = []
	for i in 5:
		var m := BirdModels.create(&"crow")
		m.lod_override = 0
		v.add_child(m)
		m.global_position = Vector3(-3.2 + 1.6 * i, 0, 0)
		m.scale = Vector3.ONE * 0.95
		m.rotation = Vector3(0.5, 0.3, 0)
		m.snap()
		crows.append(m)
	var bg_v := _stage(Vector2i(900, 300))
	var bgc := bg_v.get_node("Cam") as Camera3D
	bgc.global_transform = c.global_transform
	var bg: Image = await _grab(bg_v)
	bg_v.queue_free()
	var counts := func(img: Image) -> Array:
		var out := []
		for m in crows:
			var p := c.unproject_position(m.global_position)
			out.append(int(bird_pixels(img, bg, p, 80)["n"]))
		return out
	var a: Image = await _grab(v)
	var base: Array = counts.call(a)
	# Crow 1: highlighted and scaled to zero (e.g. a "gulp" shrink).
	crows[1].scale = Vector3.ZERO
	crows[1].highlight = 1
	var b: Image = await _grab(v)
	var zero_scale: Array = counts.call(b)
	crows[1].scale = Vector3.ONE * 0.95
	crows[1].highlight = 0
	# Crow 3: one frame of NaN flap_phase, then sane values again.
	crows[3].flap_phase = NAN
	await RenderingServer.frame_post_draw
	crows[3].flap_phase = 0.3
	for j in 30:
		await RenderingServer.frame_post_draw
	var cimg: Image = await _grab(v)
	var nan_phase: Array = counts.call(cimg)
	report["bad_input_pixels"] = {"baseline": base, "crow1_highlighted_scale0": zero_scale, "crow3_after_one_nan_phase_frame": nan_phase}
	print("[birds-r2] bad input pixel counts per crow: baseline %s | crow1 scale 0 + highlight %s | 30 frames after one NaN phase on crow3 %s" % [base, zero_scale, nan_phase])
	var sheet := Image.create(900, 900 + 30, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	sheet.blit_rect(a, Rect2i(0, 0, 900, 300), Vector2i(0, 30))
	sheet.blit_rect(b, Rect2i(0, 0, 900, 300), Vector2i(0, 330))
	sheet.blit_rect(cimg, Rect2i(0, 0, 900, 300), Vector2i(0, 630))
	_save(await _annotate(sheet, [["baseline | crow 2 highlighted at scale 0 | 30 frames after one NaN flap_phase frame on crow 4", Vector2(6, 4), 14, Color(1, 1, 0.8)]]), "r2_bad_input.png")
	v.queue_free()


class HeadLook:
	static func freeze(mat: ShaderMaterial) -> void:
		mat.set_shader_parameter("head_look_amount", 0.0)
