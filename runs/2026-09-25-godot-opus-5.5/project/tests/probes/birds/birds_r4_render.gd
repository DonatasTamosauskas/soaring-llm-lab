extends Node3D
## Round-4 verifier shot (birds, experience lens). Written by the verifier.
## Uses only the birds area's public factory/fields and core Capture/Paths;
## its own sky, sun and ground (no other area's code).
##
##   tools/gd.sh birds_verify --rendering-method forward_plus --resolution 1600x900 \
##       res://tests/probes/birds/birds_r4_render.tscn
##
## 1. murmuration: what a crow-sized player sees when GameLoop highlights a
##    starling murmuration (edible), a few pigeons (edible) and two hawks
##    (danger) at 10-80 m, with unhighlighted gulls and sparrows around; at
##    Quest Pro density (20 px/deg). Same frame with no highlights for
##    comparison. Measures the share of the view the markers cover and how
##    many markers overlap another.
## 2. triangle_tip: a danger hawk at 10 and 25 deg across, seen from above,
##    turned 0 / 30 deg in the view (the triangle is view-aligned, apex up):
##    does the triangle's line clear the wingtip? 4x crops.
## 3. density: every species at 40 m, edible and danger, at 20 px/deg and at
##    10 px/deg (a foveated periphery; the XR mirror is ~8): do the ring and
##    the triangle keep their shape?
## Writes artifacts/birds/verify/r4_*.png and r4_render.json.

const EYE := Vector3(0, 30, 0)
var _out := ""
var _cam: Camera3D
var _birds: Array[BirdModel] = []
var _hz: Array[float] = []
var _t := 0.0
var _animate := true
var _report := {}


func _ready() -> void:
	_out = Paths.artifacts("birds").path_join("verify")
	DirAccess.make_dir_recursive_absolute(_out)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.76, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.84, 0.92)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.2
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2000, 2000)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.58, 0.7, 0.42)
	pm.material = gm
	ground.mesh = pm
	add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 45.0  # vertical: 900 px / 45 deg = 20 px/deg (Quest Pro)
	_cam.far = 3000.0
	add_child(_cam)
	_cam.make_current()
	BirdModels.prewarm()
	var mat := BirdModels.material()
	mat.set_shader_parameter("pulse_test", 0.5)
	var only := Paths.arg("only", "")
	if only == "" or only == "murmuration":
		await _murmuration()
	if only == "" or only == "triangle":
		await _triangle_tip()
	if only == "" or only == "density":
		await _density()
	if only == "" or only == "perched":
		await _perched_rows()
	var f := FileAccess.open(_out.path_join("r4_render%s.json" % ("" if only == "" else "_" + only)), FileAccess.WRITE)
	f.store_string(JSON.stringify(_report, "  "))
	print("[birds-r4] render report: ", JSON.stringify(_report))
	mat.set_shader_parameter("pulse_test", -1.0)
	get_tree().quit(0)


func _process(dt: float) -> void:
	if not _animate:
		return
	_t += dt
	for i in _birds.size():
		var m := _birds[i]
		if is_instance_valid(m) and not m.perched:
			m.flap_phase = fposmod(m.flap_phase + _hz[i] * dt, 1.0)


func _add(sp: StringName, pos: Vector3, yaw_deg: float, bank_deg: float, hl: int, span: float, amount: float, rng: RandomNumberGenerator) -> BirdModel:
	var m := BirdModels.create(sp)
	m.scale = Vector3.ONE * span
	m.position = pos
	m.rotation_degrees = Vector3(0, yaw_deg, 0)
	m.bank = deg_to_rad(bank_deg)
	m.highlight = hl
	m.flap_amount = amount
	m.flap_phase = rng.randf()
	add_child(m)
	m.snap()
	_birds.append(m)
	_hz.append(lerpf(3.0, 12.0, clampf(1.0 - span, 0.0, 1.0)))
	return m


func _clear() -> void:
	for m in _birds:
		if is_instance_valid(m):
			m.free()
	_birds.clear()
	_hz.clear()


func _span(sp: StringName) -> float:
	return SizeRules.species_data(sp)["span"]


func _capture(vp: Viewport, file: String) -> Image:
	await Capture.save_viewport(vp, _out.path_join(file))
	return vp.get_texture().get_image()


# --- 1 ----------------------------------------------------------------------

func _murmuration() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	_cam.position = EYE
	_cam.rotation_degrees = Vector3(4, 0, 0)
	var centre := EYE + Vector3(4, 4, -34)
	for i in 30:
		var p := centre + Vector3(rng.randf_range(-11, 11), rng.randf_range(-4, 4), rng.randf_range(-9, 9))
		_add(&"starling", p, 90.0 + rng.randf_range(-35, 35), rng.randf_range(-30, 30), 1, _span(&"starling"), rng.randf_range(0.5, 1.0), rng)
	for i in 6:
		var p := EYE + Vector3(rng.randf_range(-22, -6), rng.randf_range(-3, 6), rng.randf_range(-30, -12))
		_add(&"pigeon", p, rng.randf_range(0, 360), rng.randf_range(-20, 20), 1, _span(&"pigeon"), rng.randf_range(0.3, 1.0), rng)
	_add(&"hawk", EYE + Vector3(-18, 9, -48), 40.0, 25.0, 2, _span(&"hawk"), 0.0, rng)
	_add(&"hawk", EYE + Vector3(22, 3, -72), -60.0, -15.0, 2, _span(&"hawk"), 0.4, rng)
	for i in 5:
		var p := EYE + Vector3(rng.randf_range(-40, 40), rng.randf_range(4, 18), rng.randf_range(-80, -40))
		_add(&"gull", p, rng.randf_range(0, 360), rng.randf_range(-20, 20), 0, _span(&"gull"), 0.0, rng)
	for i in 6:
		var p := EYE + Vector3(rng.randf_range(4, 14), rng.randf_range(-4, 2), rng.randf_range(-24, -14))
		_add(&"sparrow", p, rng.randf_range(0, 360), rng.randf_range(-20, 20), 0, _span(&"sparrow"), 1.0, rng)
	await _frames(70)
	# Freeze the beat for an exact A/B: highlighted vs plain, same frame.
	_animate = false
	await _frames(2)
	var hl_img := await _capture(get_viewport(), "r4_murmuration.png")
	var saved: Array[int] = []
	for m in _birds:
		saved.append(m.highlight)
		m.highlight = 0
		m.snap()
	await _frames(2)
	var plain_img := await _capture(get_viewport(), "r4_murmuration_plain.png")
	# Marker coverage: pixels that changed a lot between the two frames and
	# are strongly violet/magenta (the markers and the few tinted birds).
	var w := hl_img.get_width()
	var h := hl_img.get_height()
	var changed := 0
	for y in h:
		for x in w:
			var a := hl_img.get_pixel(x, y)
			var b := plain_img.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.25:
				changed += 1
	var hl_count := 0
	for s in saved:
		if s != 0:
			hl_count += 1
	_report["murmuration"] = {"highlighted_birds": hl_count, "birds": _birds.size(),
		"marker_pixels": changed, "marker_share_of_view": snappedf(float(changed) / float(w * h), 0.0001)}
	print("[birds-r4] murmuration: %d of %d birds highlighted; markers change %d px (%.2f%% of the view)" % [
		hl_count, _birds.size(), changed, 100.0 * changed / float(w * h)])
	_animate = true
	_clear()


# --- 2 ----------------------------------------------------------------------

func _triangle_tip() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var vp := SubViewport.new()
	vp.size = Vector2i(700, 700)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	add_child(vp)
	var c2 := Camera3D.new()
	c2.fov = 35.0  # 20 px/deg on 700 px
	vp.add_child(c2)
	c2.make_current()
	var sheet := Image.create(4 * 280, 2 * 280, false, Image.FORMAT_RGBA8)
	var col := 0
	var cases := [[10.0, 0.0], [10.0, 30.0], [25.0, 0.0], [25.0, 30.0]]
	for cs in cases:
		var deg: float = cs[0]
		var yaw: float = cs[1]
		# Hawk span 1.6 m, seen from straight above: distance for `deg` across.
		var span := _span(&"hawk")
		var d := 0.5 * span / tan(deg_to_rad(deg) * 0.5)
		var m := _add(&"hawk", Vector3(0, 5, 0), yaw, 0.0, 2, span, 0.0, rng)
		m.flap_phase = 0.25
		m.snap()
		# Camera above, looking down, beak towards the top of the frame.
		var cpos := Vector3(0, 5 + d, 0)
		c2.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), cpos)
		_cam.transform = c2.transform
		await _frames(3)
		var img := await _capture(vp, "r4_triangle_tip_%d_%d.png" % [int(deg), int(yaw)])
		# Crop the right wingtip's neighbourhood (the tip sits at +/-0.5 span
		# from the centre, rotated by the yaw in the view) at 4x.
		var px_per_rad := 700.0 / deg_to_rad(35.0)
		var tip_ang := deg_to_rad(deg) * 0.5
		# Positive yaw turns the right wingtip (+X) towards -Z: up-right in view.
		var a := deg_to_rad(yaw)
		var tip := Vector2(350, 350) + Vector2(cos(a), -sin(a)) * tip_ang * px_per_rad
		var crop := img.get_region(Rect2i(int(tip.x) - 35, int(tip.y) - 35, 70, 70))
		crop.resize(280, 280, Image.INTERPOLATE_NEAREST)
		crop.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(crop, Rect2i(0, 0, 280, 280), Vector2i(col * 280, 0))
		var whole := img.duplicate() as Image
		whole.resize(280, 280, Image.INTERPOLATE_BILINEAR)
		whole.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(whole, Rect2i(0, 0, 280, 280), Vector2i(col * 280, 280))
		col += 1
		_clear()
	sheet.save_png(_out.path_join("r4_triangle_tip_sheet.png"))
	print("[birds-r4] triangle tip sheet written (top: 4x crops at the right wingtip; bottom: whole view)")
	_cam.make_current()
	vp.queue_free()
	await _frames(2)


# --- 3 ----------------------------------------------------------------------

func _density() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var lo := SubViewport.new()
	lo.size = Vector2i(800, 450)
	lo.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	lo.msaa_3d = Viewport.MSAA_4X
	add_child(lo)
	var c_lo := Camera3D.new()
	c_lo.fov = 45.0  # 10 px/deg
	lo.add_child(c_lo)
	c_lo.make_current()
	var hi := SubViewport.new()
	hi.size = Vector2i(1600, 900)
	hi.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	hi.msaa_3d = Viewport.MSAA_4X
	add_child(hi)
	var c_hi := Camera3D.new()
	c_hi.fov = 45.0  # 20 px/deg
	hi.add_child(c_hi)
	c_hi.make_current()
	var eye := Vector3(0, 30, 0)
	for c: Camera3D in [c_lo, c_hi, _cam]:
		c.transform = Transform3D(Basis(), eye)
		c.rotation_degrees = Vector3(0, 0, 0)
	# Two rows at 40 m: edible above, danger below, against the sky.
	var ids := BirdSpecies.IDS
	for i in ids.size():
		var ang := deg_to_rad(-13.5 + 3.0 * i)
		for r in 2:
			var el := deg_to_rad(4.0 - 5.0 * r)
			var dir := Vector3(sin(ang) * cos(el), sin(el), -cos(ang) * cos(el))
			_add(ids[i], eye + dir * 40.0, rng.randf_range(0, 360), rng.randf_range(-20, 20), 1 + r, _span(ids[i]), 1.0, rng)
	await _frames(40)
	_animate = false
	await _frames(2)
	var img_lo := await _capture(lo, "r4_density_10ppd.png")
	var img_hi := await _capture(hi, "r4_density_20ppd.png")
	# Side by side crops of the band at the same angular window, both at 4 px
	# per 1 px of the 20 px/deg view (lo x8, hi x4).
	var band_lo := img_lo.get_region(Rect2i(400 - 160, 225 - 30, 320, 60))
	band_lo.resize(1280, 240, Image.INTERPOLATE_NEAREST)
	var band_hi := img_hi.get_region(Rect2i(800 - 320, 450 - 60, 640, 120))
	band_hi.resize(1280, 240, Image.INTERPOLATE_NEAREST)
	var sheet := Image.create(1280, 480, false, Image.FORMAT_RGBA8)
	band_hi.convert(Image.FORMAT_RGBA8)
	band_lo.convert(Image.FORMAT_RGBA8)
	sheet.blit_rect(band_hi, Rect2i(0, 0, 1280, 240), Vector2i(0, 0))
	sheet.blit_rect(band_lo, Rect2i(0, 0, 1280, 240), Vector2i(0, 240))
	sheet.save_png(_out.path_join("r4_density_sheet.png"))
	print("[birds-r4] density sheet written (top 20 px/deg, bottom 10 px/deg)")
	_animate = true
	_clear()
	_cam.make_current()
	lo.queue_free()
	hi.queue_free()
	await _frames(2)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


# --- 4 ----------------------------------------------------------------------

## Perched rows at natural spacing, seen from a perch nearby: sparrows on a
## wire 0.2 m apart (about one body length) and pigeons on a roof ridge
## 0.45 m apart, highlights mixed (edible / none / danger). Markers are sized
## by the wingspan, and a perched bird's wings are folded: which bird does
## each marker belong to?
func _perched_rows() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var eye := Vector3(0, 6.0, 0)
	_cam.transform = Transform3D(Basis(), eye)
	_cam.fov = 45.0
	var wire_y := 6.3
	var hl_pattern := [1, 0, 2, 1, 1, 0, 2, 0]
	var report := []
	for row in 2:
		var sp: StringName = [&"sparrow", &"pigeon"][row]
		var gap: float = [0.2, 0.45][row]
		var dist: float = [2.5, 6.0][row]
		var x0 := -gap * 3.5 + (-1.4 if row == 0 else 1.9)
		var span := _span(sp)
		for i in 8:
			var p := Vector3(x0 + i * gap, wire_y - 0.9 * row, -dist)
			var m := _add(sp, p, rng.randf_range(-20, 20) + (90.0 if i % 2 == 0 else -90.0), 0.0, hl_pattern[i], span, 0.0, rng)
			m.perched = true
			m.wing_fold = 1.0
			m.snap()
		# The ring's radius in metres at this distance vs half the gap.
		var ang := span / dist
		var r_m := maxf(0.0056, 0.62 * ang) * dist
		report.append({"species": sp, "gap_m": gap, "distance_m": dist, "ring_radius_m": snappedf(r_m, 0.001),
			"triangle_edge_distance_m": snappedf(r_m * 1.65 * 0.5, 0.001), "neighbours_inside_ring": int(floor(r_m / gap))})
	await _frames(30)
	_animate = false
	await _frames(2)
	await _capture(get_viewport(), "r4_perched_rows.png")
	for m in _birds:
		m.highlight = 0
		m.snap()
	await _frames(2)
	await _capture(get_viewport(), "r4_perched_rows_plain.png")
	_report["perched_rows"] = report
	print("[birds-r4] perched rows: ", JSON.stringify(report))
	_animate = true
	_clear()
