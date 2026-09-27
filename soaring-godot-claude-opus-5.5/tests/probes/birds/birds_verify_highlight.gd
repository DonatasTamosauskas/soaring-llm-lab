extends Node
## Verifier render probe (birds, round 1): B4 for the species the builder's
## highlight shot leaves out (moth, wren, swallow; sparrow as a reference),
## in the WORLD's day lighting (values mirrored from Palette.LIGHT.day and
## WorldSky: filmic white 6.0, ambient 0.65, fog 0.00042) instead of the
## builder's stage, and over more backgrounds than sky + meadow: forest
## canopy, conifers, lake water and red roofs.
##
## Method copied from tests/shots/birds_highlight.gd (Quest Pro density
## 20 px/deg, 40 m, each bird rendered alone, colour = mean of its core
## pixels, worst of three pulse phases, Oklab) with the builder's
## thresholds: state 0.12, edible/danger 0.15, background 0.15.
##
##   tools/gd.sh birds_verify --rendering-method forward_plus --resolution 1600x900 \
##       res://tests/probes/birds/birds_verify_highlight.tscn
## Outputs: artifacts/birds/verify/highlight_small_*.png, highlight_small.json

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const W := 1600
const H := 900
var DIST := 40.0
var SPECIES := [&"moth", &"wren", &"swallow", &"sparrow"]
var TAG := ""
const STATES := ["none", "edible", "danger"]
const MIN_DE_STATE := 0.12
const MIN_DE_PAIR := 0.15
const MIN_DE_BG := 0.15
## Backgrounds (world Palette colours): "sky" looks up at the birds; the
## others look down on them over a plane of that colour.
var SETTINGS := {
	"sky": Color(0, 0, 0, 0),
	"meadow": Color("7fa65a"),
	"forest": Color("4d7e3b"),
	"conifer": Color("3f6c47"),
	"water": Color("41849c"),
	"roof_red": Color("b1543f"),
}

var vp: SubViewport
var cam: Camera3D
var ground: MeshInstance3D
var ground_mat: StandardMaterial3D
var birds := []
var out_dir := ""


func _ready() -> void:
	# Optional: -- --dist=16 --species=moth,swallow --settings=sky,meadow
	var args := Paths.user_args()
	if args.has("dist"):
		DIST = float(args["dist"])
		TAG = "_%dm" % int(DIST)
	if args.has("species"):
		SPECIES = []
		for x in String(args["species"]).split(","):
			SPECIES.append(StringName(x))
	if args.has("settings"):
		var keep := {}
		for x in String(args["settings"]).split(","):
			keep[x] = SETTINGS[x]
		SETTINGS = keep
	out_dir = Paths.artifacts("birds").path_join("verify")
	DirAccess.make_dir_recursive_absolute(out_dir)
	vp = SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	_environment()
	cam = Camera3D.new()
	cam.fov = 45.0
	cam.near = 0.1
	cam.far = 3000.0
	vp.add_child(cam)
	cam.current = true
	var report := {"distance_m": DIST, "px_per_degree": H / 45.0, "thresholds": {"state": MIN_DE_STATE, "pair": MIN_DE_PAIR, "background": MIN_DE_BG}}
	var fails := 0
	var fail_list := []
	for setting in SETTINGS:
		var res: Dictionary = await _measure(setting)
		report[setting] = res["numbers"]
		fails += int(res["fails"])
		fail_list.append_array(res["fail_list"])
		(res["frame"] as Image).save_png(out_dir.path_join("highlight_small%s_%s.png" % [TAG, setting]))
		(res["zoom"] as Image).save_png(out_dir.path_join("highlight_small%s_%s_zoom.png" % [TAG, setting]))
	report["failures"] = fails
	report["fail_list"] = fail_list
	var f := FileAccess.open(out_dir.path_join("highlight_small%s.json" % TAG), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("[birds-verify] highlight small birds at %.0f m: %d failures %s" % [DIST, fails, str(fail_list)])
	get_tree().quit(0)


func _environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color("5a95d4")
	mat.sky_horizon_color = Color("bcd6e6")
	mat.sky_curve = 0.12
	mat.ground_horizon_color = Color("a9b8a6")
	mat.ground_bottom_color = Color("6f7f6c")
	mat.ground_curve = 0.05
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color("b6c8dc")
	env.ambient_light_sky_contribution = 0.55
	env.ambient_light_energy = 0.65
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color("c4d8e3")
	env.fog_density = 0.00042
	env.fog_sky_affect = 0.2
	env.fog_aerial_perspective = 0.25
	env.fog_sun_scatter = 0.12
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color("fff0d4")
	sun.light_energy = 1.25
	# Palette day: elevation 47 deg, azimuth -38 deg.
	var el := deg_to_rad(47.0)
	var az := deg_to_rad(-38.0)
	var to_sun := Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az)).normalized()
	vp.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)
	ground = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(3000, 3000)
	ground.mesh = pm
	ground_mat = StandardMaterial3D.new()
	ground_mat.roughness = 1.0
	ground.material_override = ground_mat
	vp.add_child(ground)


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


func _measure(setting: String) -> Dictionary:
	for b in birds:
		b.queue_free()
	birds.clear()
	var col: Color = SETTINGS[setting]
	ground.visible = setting != "sky"
	ground_mat.albedo_color = col if setting != "sky" else Color("7fa65a")
	var eye := Vector3(0, 2, 0) if setting == "sky" else Vector3(0, 30, 0)
	var pitch := deg_to_rad(8.0) if setting == "sky" else deg_to_rad(-35.0)
	cam.position = eye
	cam.rotation = Vector3(pitch, 0, 0)
	var n := SPECIES.size() * STATES.size()
	var hfov := rad_to_deg(2.0 * atan(tan(deg_to_rad(45.0) * 0.5) * float(W) / H))
	var spread := hfov * 0.9
	for i in n:
		var sp: StringName = SPECIES[i / 3]
		var st := i % 3
		var yaw := deg_to_rad(spread * 0.5 - spread * (i + 0.5) / n)
		var dir := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		vp.add_child(m)
		m.global_position = eye + dir * DIST
		m.look_at(m.global_position + Vector3(1, 0, -0.3), Vector3.UP)
		m.bank = deg_to_rad(15.0)
		m.highlight = st
		m.snap()
		birds.append(m)
	for j in 5:
		await get_tree().process_frame
	var frame: Image = await _grab()
	for b in birds:
		b.visible = false
	var bg: Image = await _grab()
	var cols := {}
	var zoom_cells := []
	for i in birds.size():
		var b: BirdModel = birds[i]
		b.visible = true
		var sp2 := cam.unproject_position(b.global_position)
		# The drawn size may be inflated to 0.7 deg when highlighted.
		var drawn_span := maxf(float(SizeRules.species_data(b.species)["span"]), DIST * BirdModel.MIN_HIGHLIGHT_ANGLE)
		var r := int(ceil(drawn_span / DIST * (H / deg_to_rad(45.0)) * 0.75)) + 3
		var rect := Rect2i(Vector2i(sp2) - Vector2i(r, r), Vector2i(r * 2 + 1, r * 2 + 1)).intersection(Rect2i(0, 0, W, H))
		var best := {}
		for k in 3:
			for j in 3 + k * 4:
				await get_tree().process_frame
			var img: Image = await _grab()
			var px := []
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					var c: Color = img.get_pixel(x, y)
					var cb: Color = bg.get_pixel(x, y)
					var dd := absf(c.r - cb.r) + absf(c.g - cb.g) + absf(c.b - cb.b)
					if dd > 0.06:
						px.append([dd, c, cb])
			if px.is_empty():
				continue
			px.sort_custom(func(p1, p2): return p1[0] > p2[0])
			var sum := Color(0, 0, 0, 0)
			var bsum := Color(0, 0, 0, 0)
			var cnt := 0
			for q in px.slice(0, maxi(1, (px.size() + 1) / 2)):
				sum += (q[1] as Color).srgb_to_linear()
				bsum += (q[2] as Color).srgb_to_linear()
				cnt += 1
			var ok := Geo.oklab(sum / cnt)
			var okb := Geo.oklab(bsum / cnt)
			var de_bg := ok.distance_to(okb)
			if best.is_empty() or de_bg < best["de_bg"]:
				best = {"lab": ok, "de_bg": de_bg, "px": px.size()}
			if k == 0:
				zoom_cells.append(img.get_region(rect))
		b.visible = false
		cols[i] = best
	for b in birds:
		b.visible = true
	var numbers := {}
	var fails := 0
	var fail_list := []
	for si in SPECIES.size():
		var none: Dictionary = cols[si * 3]
		var ed: Dictionary = cols[si * 3 + 1]
		var dg: Dictionary = cols[si * 3 + 2]
		var sp := String(SPECIES[si])
		if ed.is_empty() or dg.is_empty():
			fails += 1
			fail_list.append("%s %s: highlighted bird not visible" % [setting, sp])
			numbers[sp] = "highlighted not visible"
			continue
		var none_lab: Vector3 = none["lab"] if not none.is_empty() else Vector3.INF
		var de_e: float = (ed["lab"] as Vector3).distance_to(none_lab) if not none.is_empty() else 1.0
		var de_d: float = (dg["lab"] as Vector3).distance_to(none_lab) if not none.is_empty() else 1.0
		var de_ed: float = (ed["lab"] as Vector3).distance_to(dg["lab"])
		var row := {"pixels_none": none.get("px", 0), "pixels_edible": ed["px"], "edible_vs_none": snappedf(de_e, 0.001),
			"danger_vs_none": snappedf(de_d, 0.001), "edible_vs_danger": snappedf(de_ed, 0.001),
			"none_vs_bg": snappedf(float(none.get("de_bg", 0.0)), 0.001),
			"edible_vs_bg": snappedf(ed["de_bg"], 0.001), "danger_vs_bg": snappedf(dg["de_bg"], 0.001)}
		var bad := []
		if de_e < MIN_DE_STATE:
			bad.append("edible~none")
		if de_d < MIN_DE_STATE:
			bad.append("danger~none")
		if de_ed < MIN_DE_PAIR:
			bad.append("edible~danger")
		if ed["de_bg"] < MIN_DE_BG:
			bad.append("edible~background")
		if dg["de_bg"] < MIN_DE_BG:
			bad.append("danger~background")
		row["fail"] = bad
		fails += bad.size()
		for x in bad:
			fail_list.append("%s %s %s" % [setting, sp, x])
		numbers[sp] = row
		print("[birds-verify] %-8s %-8s px %3d/%3d  e/n %.3f  d/n %.3f  e/d %.3f  bg n %.3f e %.3f d %.3f %s" % [setting, sp,
			none.get("px", 0), ed["px"], de_e, de_d, de_ed, float(none.get("de_bg", 0.0)), ed["de_bg"], dg["de_bg"], "" if bad.is_empty() else str(bad)])
	# Zoom sheet: every bird x6, nearest neighbour.
	var cell := 120
	var sheet := Image.create(cell * zoom_cells.size(), cell, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.12, 0.12, 0.14))
	for i in zoom_cells.size():
		var reg: Image = zoom_cells[i]
		reg.convert(Image.FORMAT_RGBA8)
		var w := mini(reg.get_width() * 6, cell - 4)
		var h := mini(reg.get_height() * 6, cell - 4)
		reg.resize(w, h, Image.INTERPOLATE_NEAREST)
		sheet.blit_rect(reg, Rect2i(0, 0, w, h), Vector2i(i * cell + (cell - w) / 2, (cell - h) / 2))
	return {"numbers": numbers, "fails": fails, "fail_list": fail_list, "frame": frame, "zoom": sheet}
