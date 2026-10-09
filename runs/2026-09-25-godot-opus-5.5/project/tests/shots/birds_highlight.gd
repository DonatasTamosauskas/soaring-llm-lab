extends Node
## B4: highlight states (none / edible / danger) read at gameplay distances,
## and highlighted birds keep their own colours once they are big enough to
## show them.
##
## A camera with a Quest Pro's pixel density (~20 px per degree: 900 px over
## a 45 deg vertical field) in the world's own daylight (WorldSky and the
## Palette's "day" light, loaded at run time; a mirrored copy if the world
## scripts are unavailable). Passes (--passes=dist,band,identity,close):
##
##   dist      every species in every state at 40 m (the brief's distance)
##             and 16 m (a sparrow player's 70-span range), against the sky
##             (looking up 8 deg: wings nearly edge-on, the hardest view) and
##             from 35 deg above against every large surface of the world:
##             grass, meadow, crops, ploughland, forest canopy, conifers,
##             water, the village's red/terracotta/barn/slate roofs, rock,
##             sandstone, white walls.
##   band      every species at 1.0 / 1.2 / 1.4 / 1.8 / 2.5 x its own
##             readable angle (BirdModels.min_highlight_angle: the tint eases
##             out from 1.0 to bird.gdshader's tint_end, 1.8) over six
##             backgrounds, so no distance between the fixed ones hides a
##             weak spot.
##   identity  one bird at a time over the meadow at 0.8 x and 1.5 x its
##             readable angle and at 3, 10 and 25 deg across: the marker
##             must be there (its extent where the shader puts it, highlighted
##             only) and clearly coloured, and from 3 deg on the highlighted
##             bird's own pixels (marker hidden) must keep the plain bird's
##             colours (the species' identity, B1).
##   close     the look at ~12 deg (evidence image).
##
## dist/band: each bird's pixels are where the frame differs from the same
## frame without birds; its colour is the mean of its core pixels (the half
## that differs most from the background: antialiased edges are mostly
## background), in Oklab, marker included. The highlight pulse is pinned to
## its dimmest and to its brightest (the shader's pulse_test) and the worse
## of the two counts. Every bird must show:
##   * highlighted vs the same bird unhighlighted: dE >= MIN_DE_STATE,
##   * edible vs danger: dE >= MIN_DE_PAIR,
##   * highlighted vs what is behind it: dE >= MIN_DE_BG.
## Outputs (artifacts/birds/):
##   highlight_40m.png, highlight_40m_roofs.png   full frames, all 30 birds
##   highlight_zoom_40m.png, highlight_zoom_16m.png, highlight_zoom_band.png
##                                                every bird x3 per background
##   highlight_identity.png                       plain / edible / danger, 5 sizes
##   highlight_close.png                          ~12 deg
##   highlight.json                               the numbers; exit 1 on failure
##
##   tools/gd.sh birds --rendering-method forward_plus --resolution 1600x900 \
##       res://tests/shots/birds_highlight.tscn [-- --passes=identity --dist=40
##       --bg=sky,roof_red --species=moth,crow --edible=6b4cff --danger=ff4000
##       --u_rim_glow=0.8 --tag=try]

const Stage := preload("res://tests/shots/birds_stage.gd")
const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const W := 1600
const H := 900
const FOV := 45.0
const STATES := ["none", "edible", "danger"]
const MIN_DE_STATE := 0.12
const MIN_DE_PAIR := 0.15
const MIN_DE_BG := 0.15
## From 3 deg across, a highlighted bird's own pixels (marker hidden) keep
## the plain bird's mean colour within this (Oklab; 0.02 is about one
## just-noticeable difference): its plumage, not the tint, says what it is.
const MAX_DE_IDENTITY := 0.02
## The marker's own pixels are clearly coloured (the hues are ~0.3).
const MIN_MARK_CHROMA := 0.12
## ...and there are enough of them to see (a far ring is ~80 px).
const MIN_MARK_PX := 24
## The marker is drawn where the shader puts it: its measured extent within
## this many px of the expected (antialiasing, the pixel grid).
const MARK_EXTENT_TOL := 3.0
## The band: multiples of each species' readable angle, and its backgrounds.
const BAND := [1.0, 1.2, 1.4, 1.8, 2.5]
const BAND_BGS := ["sky", "wall_white", "meadow", "water_deep", "roof_red", "leaf_dark"]
## Identity sizes: x the readable angle (the marker carries the state) and
## wingspans across (deg; the plumage must show).
const ID_SIZES := [["0.8x", 0.8, true], ["1.5x", 1.5, true], ["3deg", 3.0, false], ["10deg", 10.0, false], ["25deg", 25.0, false]]
## Large surfaces a bird is seen against (Palette keys; fallback colours).
const GROUNDS := {
	&"grass": "7fa65a", &"meadow": "9fbb62", &"wheat": "d6b865", &"ploughed": "8b6a4c",
	&"leaf": "6c9f48", &"leaf_dark": "4d7e3b", &"conifer": "3f6c47", &"water": "41849c",
	&"water_deep": "2e6682", &"roof_red": "b1543f", &"roof_terracotta": "c46b45",
	&"barn_red": "a4473b", &"roof_slate": "5f6774", &"rock": "9a9086", &"sandstone": "c39a72",
	&"wall_white": "eae3d3",
}

var vp: SubViewport
var cam: Camera3D
var ground: MeshInstance3D
var ground_mat: StandardMaterial3D
var light_source := "mirrored"
var distances: Array[float] = [40.0, 16.0]
var species: Array = BirdSpecies.IDS.duplicate()
var backgrounds: Array = []
var tag := ""


func _ready() -> void:
	var args := Paths.user_args()
	if args.has("dist"):
		distances.clear()
		for d in String(args["dist"]).split(","):
			distances.append(float(d))
	if args.has("species"):
		species = Array(String(args["species"]).split(",")).map(func(x: String) -> StringName: return StringName(x))
	backgrounds = ["sky"]
	backgrounds.append_array(GROUNDS.keys())
	if args.has("bg"):
		backgrounds = Array(String(args["bg"]).split(","))
	tag = String(args.get("tag", ""))
	var passes := Array(String(args.get("passes", "dist,band,identity,close")).split(","))
	var mat := BirdModels.material()
	if args.has("edible"):
		mat.set_shader_parameter("prey_color", Color(String(args["edible"])))
	if args.has("danger"):
		mat.set_shader_parameter("threat_color", Color(String(args["danger"])))
	# Trial overrides of the highlight's float uniforms (--u_rim_glow=0.5).
	for k: String in args:
		if k.begins_with("u_"):
			mat.set_shader_parameter(k.substr(2), float(args[k]))
	# Glances frozen: the identity pass compares frames of one bird.
	mat.set_shader_parameter("head_look_amount", 0.0)
	_stage()
	var report := {"px_per_degree": H / FOV, "light": light_source, "distances_m": distances, "passes": passes,
		"thresholds": {"state": MIN_DE_STATE, "pair": MIN_DE_PAIR, "background": MIN_DE_BG,
			"identity": MAX_DE_IDENTITY, "marker_chroma": MIN_MARK_CHROMA, "marker_extent_px": MARK_EXTENT_TOL},
		"edible": _param(mat, &"prey_color").to_html(false),
		"danger": _param(mat, &"threat_color").to_html(false),
		"tint_end": _fparam(mat, &"tint_end")}
	var fails := []
	var worst := {"state": [INF, ""], "pair": [INF, ""], "background": [INF, ""],
		"marker_state": [INF, ""], "marker_pair": [INF, ""], "marker_background": [INF, ""]}
	if passes.has("dist"):
		for dist in distances:
			var per_bg := {}
			var zoom_rows := []
			for bg in backgrounds:
				var res: Dictionary = await _measure(StringName(bg), dist)
				per_bg[bg] = res["numbers"]
				zoom_rows.append([bg, res["cells"]])
				_collect(res, "%dm" % dist, fails, worst)
			report["%dm" % dist] = per_bg
			var sheet: Image = await _zoom_sheet(zoom_rows, "%d m" % dist)
			Stage.save(sheet, "highlight_zoom_%dm%s.png" % [dist, _suffix()])
	if passes.has("band"):
		var band := {}
		var zoom_rows := []
		for k: float in BAND:
			var per_bg := {}
			for bg: String in BAND_BGS:
				if args.has("bg") and not backgrounds.has(bg):
					continue
				var res: Dictionary = await _measure(StringName(bg), func(sp: StringName) -> float:
					return float(SizeRules.species_data(sp)["span"]) / (BirdModels.min_highlight_angle(sp) * k))
				per_bg[bg] = res["numbers"]
				if bg in ["sky", "meadow"]:
					zoom_rows.append(["%s %.1fx" % [bg, k], res["cells"]])
				_collect(res, "band %.1fx" % k, fails, worst)
			band["%.1fx" % k] = per_bg
		report["band"] = band
		var sheet: Image = await _zoom_sheet(zoom_rows, "band (x readable angle)")
		Stage.save(sheet, "highlight_zoom_band%s.png" % _suffix())
	for k in worst:
		worst[k] = [snappedf(float(worst[k][0]), 0.001), worst[k][1]]
	report["worst"] = worst
	if passes.has("identity"):
		var idr: Dictionary = await _identity()
		report["identity"] = idr["numbers"]
		report["identity_worst"] = idr["worst"]
		fails.append_array(idr["fails"])
		Stage.save(idr["sheet"], "highlight_identity%s.png" % _suffix())
	if passes.has("close"):
		Stage.save(await _close_frame(), "highlight_close%s.png" % _suffix())
	if tag == "" and passes.has("dist") and distances.has(40.0):
		for bg in ["sky", "roof_red"]:
			var img: Image = await _evidence_frame(StringName(bg), 40.0)
			Stage.save(img, "highlight_40m.png" if bg == "sky" else "highlight_40m_roofs.png")
	report["failures"] = fails.size()
	report["fail_list"] = fails
	mat.set_shader_parameter("pulse_test", -1.0)
	mat.set_shader_parameter("head_look_amount", 1.0)
	var f := FileAccess.open(Paths.artifacts("birds").path_join("highlight%s.json" % _suffix()), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	print("[birds] highlight (%s light): marker: state %.3f (%s), pair %.3f (%s), background %.3f (%s); tinted birds: state %.3f (%s), pair %.3f (%s), background %.3f (%s); identity %s; %d failures" % [light_source,
		worst["marker_state"][0], worst["marker_state"][1], worst["marker_pair"][0], worst["marker_pair"][1], worst["marker_background"][0], worst["marker_background"][1],
		worst["state"][0], worst["state"][1], worst["pair"][0], worst["pair"][1], worst["background"][0], worst["background"][1],
		str(report.get("identity_worst", "-")), fails.size()])
	for x in fails.slice(0, 40):
		print("[birds]   fail ", x)
	get_tree().quit(1 if not fails.is_empty() else 0)


func _suffix() -> String:
	return "" if tag == "" else "_" + tag


func _collect(res: Dictionary, where: String, fails: Array, worst: Dictionary) -> void:
	for f in res["fails"]:
		fails.append("%s %s" % [where, f])
	for k in worst:
		var w: Array = res["worst"][k]
		if float(w[0]) < float(worst[k][0]):
			worst[k] = [w[0], "%s %s" % [where, w[1]]]


static func _fparam(mat: ShaderMaterial, name: StringName) -> float:
	var v: Variant = mat.get_shader_parameter(name)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), name)
	return float(v)


## A colour uniform of the bird material (its shader default when unset).
static func _param(mat: ShaderMaterial, name: StringName) -> Color:
	var v: Variant = mat.get_shader_parameter(name)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), name)
	return v if v is Color else Color(v.x, v.y, v.z)


## The world's daylight: WorldSky/Palette when they load, else a copy.
func _stage() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var we := WorldEnvironment.new()
	var sun: DirectionalLight3D = null
	var ws := load("res://scripts/world/world_sky.gd") as GDScript
	if ws != null and ws.can_instantiate():
		we.environment = ws.call("make_environment", &"day")
		sun = ws.call("make_sun", &"day")
		light_source = "WorldSky day"
	else:
		we.environment = _mirrored_environment()
		sun = DirectionalLight3D.new()
		sun.light_color = Color("fff0d4")
		sun.light_energy = 1.25
		var el := deg_to_rad(47.0)
		var az := deg_to_rad(-38.0)
		var to_sun := Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az)).normalized()
		sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	vp.add_child(we)
	vp.add_child(sun)
	cam = Camera3D.new()
	cam.fov = FOV
	cam.near = 0.1
	cam.far = 3000.0
	vp.add_child(cam)
	cam.current = true
	ground = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4000, 4000)
	ground.mesh = pm
	# Like the world's shared solid material (Palette.solid_material).
	ground_mat = StandardMaterial3D.new()
	ground_mat.roughness = 0.92
	ground_mat.metallic_specular = 0.25
	ground.material_override = ground_mat
	vp.add_child(ground)


func _mirrored_environment() -> Environment:
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color("5a95d4")
	sm.sky_horizon_color = Color("bcd6e6")
	sm.sky_curve = 0.12
	sm.ground_horizon_color = Color("a9b8a6")
	sm.ground_bottom_color = Color("6f7f6c")
	sm.ground_curve = 0.05
	sky.sky_material = sm
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color("b6c8dc")
	env.ambient_light_sky_contribution = 0.55
	env.ambient_light_energy = 0.65
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_light_color = Color("c4d8e3")
	env.fog_density = 0.00042
	env.fog_sky_affect = 0.2
	env.fog_aerial_perspective = 0.25
	env.fog_sun_scatter = 0.12
	return env


func _ground_color(bg: StringName) -> Color:
	var pal := load("res://scripts/world/palette.gd") as GDScript
	if pal != null and pal.can_instantiate():
		var c: Dictionary = pal.get_script_constant_map().get("C", {})
		if c.has(bg):
			return c[bg]
	return Color(String(GROUNDS.get(bg, "808080")))


## Camera pose for a background: up at the sky, or down onto the ground.
func _aim(bg: StringName) -> float:
	var pitch := deg_to_rad(8.0) if bg == &"sky" else deg_to_rad(-35.0)
	cam.position = Vector3(0, 2, 0) if bg == &"sky" else Vector3(0, 60, 0)
	cam.rotation = Vector3(pitch, 0, 0)
	ground.visible = bg != &"sky"
	if bg != &"sky":
		ground_mat.albedo_color = _ground_color(bg)
	return pitch


## A bird crossing the view `dist` away in direction (yaw, pitch offsets from
## the camera's centre), banked a little: wings visible as a passing bird.
func _bird(sp: StringName, st: int, dist: float, yaw: float, pitch: float) -> BirdModel:
	var m := BirdModels.create(sp)
	m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
	# Measured alone: no shadow of it may land on another bird's pixels.
	m.cast_shadows = false
	vp.add_child(m)
	var dir := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	m.global_position = cam.global_position + dir * dist
	m.look_at(m.global_position + Vector3(1, 0, -0.3), Vector3.UP)
	m.bank = deg_to_rad(15.0)
	m.highlight = st
	m.snap()
	return m


func _grab() -> Image:
	var img: Image = await Stage.grab(vp)
	img.convert(Image.FORMAT_RGBA8)
	return img


## Measures every species in every state over one background, each at
## `dist` metres: a number, or a Callable(species) -> metres.
func _measure(bg: StringName, dist: Variant) -> Dictionary:
	var dist_of: Callable = dist if dist is Callable else func(_sp: StringName) -> float: return float(dist)
	var pitch := _aim(bg)
	var mat := BirdModels.material()
	for j in 3:
		await get_tree().process_frame
	var bg_img := await _grab()
	var bgd := bg_img.get_data()
	var numbers := {}
	var fails := []
	var cells := []
	var worst := {"state": [INF, ""], "pair": [INF, ""], "background": [INF, ""],
		"marker_state": [INF, ""], "marker_pair": [INF, ""], "marker_background": [INF, ""]}
	for sp in species:
		var d_m: float = dist_of.call(sp)
		# Highlighted birds are drawn at their true size.
		var drawn_span := float(SizeRules.species_data(sp)["span"])
		var px_span := drawn_span / d_m * _focal_px()
		# The highlight marker around the bird (the danger triangle's corners
		# reach furthest): see bird.gdshader.
		var px_mark := _mark_px(drawn_span / d_m, true)
		# Three birds side by side, far enough apart that their pixel boxes
		# (markers included) never overlap.
		var gap := maxf(deg_to_rad(6.0), 2.0 * (maxf(px_span * 0.8, px_mark) + 12.0) / _focal_px())
		var birds := []
		for st in 3:
			birds.append(_bird(sp, st, d_m, (st - 1) * gap, pitch))
		var labs := [[], [], []]
		var marks := [[], [], []]
		var pxn := [0, 0, 0]
		for pulse in [0.0, 1.0]:
			mat.set_shader_parameter("pulse_test", pulse)
			for j in 2:
				await get_tree().process_frame
			_markers_visible(true)
			var img := await _grab()
			var d := img.get_data()
			# The same frame without the markers: the marker's own pixels are
			# where the two differ.
			_markers_visible(false)
			var bd := (await _grab()).get_data()
			_markers_visible(true)
			for st in 3:
				var b: BirdModel = birds[st]
				var c := cam.unproject_position(b.global_position)
				var r := int(ceil(maxf(px_span * 0.75, px_mark))) + 3
				var rect := Rect2i(Vector2i(c) - Vector2i(r, r), Vector2i(r * 2 + 1, r * 2 + 1)).intersection(Rect2i(0, 0, W, H))
				var m := _core_colour(d, bgd, rect)
				labs[st].append(m)
				pxn[st] = maxi(pxn[st], int(m["px"]))
				if st > 0:
					marks[st].append(_marker_colour(d, bd, rect))
				if pulse == 0.0:
					cells.append(img.get_region(rect))
		for b in birds:
			b.queue_free()
		# Worst case over the pulse extremes (and their combinations).
		var row := {"pixels": pxn, "tinted": drawn_span / d_m <= BirdModels.min_highlight_angle(sp)}
		var bad := []
		var vis := true
		for st in [1, 2]:
			for m in labs[st]:
				if int(m["px"]) == 0:
					vis = false
		# An unhighlighted bird too small to see (a moth at 40 m) blends into
		# the background: a highlighted one then differs from "none" by as
		# much as it differs from the background.
		var none_seen := int(labs[0][0]["px"]) > 0
		if not none_seen:
			row["none"] = "not visible unhighlighted"
		var none_lab: Vector3 = labs[0][0]["lab"]
		if not vis:
			bad.append("highlighted bird not visible")
		else:
			# 1. The marker, at every size: present, off the background, the
			# two states apart, and unlike the plain bird.
			var mk := {"px": 1 << 30, "state": INF, "pair": INF, "background": INF}
			for st in [1, 2]:
				for mm in marks[st]:
					mk["px"] = mini(mk["px"], int(mm["px"]))
					mk["background"] = minf(mk["background"], float(mm["de_bg"]))
					var vs_none: float = (mm["lab"] as Vector3).distance_to(none_lab) if none_seen else float(mm["de_bg"])
					mk["state"] = minf(mk["state"], vs_none)
			for me in marks[1]:
				for md in marks[2]:
					mk["pair"] = minf(mk["pair"], (me["lab"] as Vector3).distance_to(md["lab"]))
			row["marker"] = {"px": mk["px"], "vs_none": snappedf(mk["state"], 0.001), "edible_vs_danger": snappedf(mk["pair"], 0.001),
				"vs_bg": snappedf(mk["background"], 0.001)}
			if int(mk["px"]) < MIN_MARK_PX:
				bad.append("marker %d px" % mk["px"])
			if mk["state"] < MIN_DE_STATE:
				bad.append("marker~none %.3f" % mk["state"])
			if mk["pair"] < MIN_DE_PAIR:
				bad.append("marker edible~danger %.3f" % mk["pair"])
			if mk["background"] < MIN_DE_BG:
				bad.append("marker~background %.3f" % mk["background"])
			var where := "%s %s" % [bg, sp]
			for k in ["state", "pair", "background"]:
				if float(mk[k]) < float(worst["marker_" + k][0]):
					worst["marker_" + k] = [mk[k], where]
			# 2. The whole bird box (bird + marker), as the eye averages a
			# small blob: required where the bird itself is tinted (at or
			# under its readable angle), reported above it (there the bird
			# wears its own plumage by design, and its dark or pale plumage
			# can out-contrast the thin marker in the "core" half).
			var de_bg := [INF, INF, INF]
			for st in 3:
				for m in labs[st]:
					de_bg[st] = minf(de_bg[st], float(m["de_bg"]))
			var st_e := INF
			var st_d := INF
			var pair := INF
			for me in labs[1]:
				st_e = minf(st_e, (me["lab"] as Vector3).distance_to(none_lab) if none_seen else float(me["de_bg"]))
				for md in labs[2]:
					pair = minf(pair, (me["lab"] as Vector3).distance_to(md["lab"]))
			for md in labs[2]:
				st_d = minf(st_d, (md["lab"] as Vector3).distance_to(none_lab) if none_seen else float(md["de_bg"]))
			row["edible_vs_none"] = snappedf(st_e, 0.001)
			row["danger_vs_none"] = snappedf(st_d, 0.001)
			row["edible_vs_danger"] = snappedf(pair, 0.001)
			row["none_vs_bg"] = snappedf(de_bg[0], 0.001) if none_seen else 0.0
			row["edible_vs_bg"] = snappedf(de_bg[1], 0.001)
			row["danger_vs_bg"] = snappedf(de_bg[2], 0.001)
			if row["tinted"]:
				if st_e < MIN_DE_STATE:
					bad.append("edible~none %.3f" % st_e)
				if st_d < MIN_DE_STATE:
					bad.append("danger~none %.3f" % st_d)
				if pair < MIN_DE_PAIR:
					bad.append("edible~danger %.3f" % pair)
				if de_bg[1] < MIN_DE_BG:
					bad.append("edible~background %.3f" % de_bg[1])
				if de_bg[2] < MIN_DE_BG:
					bad.append("danger~background %.3f" % de_bg[2])
				for k in [["state", minf(st_e, st_d)], ["pair", pair], ["background", minf(de_bg[1], de_bg[2])]]:
					if float(k[1]) < float(worst[k[0]][0]):
						worst[k[0]] = [k[1], where]
		row["fail"] = bad
		row["dist_m"] = snappedf(d_m, 0.01)
		numbers[String(sp)] = row
		for x in bad:
			fails.append("%s %s %s" % [bg, sp, x])
	print("[birds] %s %-15s %d failures" % ["%dm" % int(dist) if not dist is Callable else "band", bg, fails.size()])
	return {"numbers": numbers, "fails": fails, "cells": cells, "worst": worst}


## The marker's pixels in `rect` (the frame with markers `d` against the same
## frame without them `bd`): {px, lab: mean Oklab colour of its core half
## (the pixels it changes most: antialiased edges are mostly what is behind),
## de_bg: against what is behind those pixels}.
func _marker_colour(d: PackedByteArray, bd: PackedByteArray, rect: Rect2i) -> Dictionary:
	var px := []
	for y in range(rect.position.y, rect.end.y):
		var o := (y * W + rect.position.x) * 4
		for x in rect.size.x:
			var i := o + x * 4
			var dd := (absi(d[i] - bd[i]) + absi(d[i + 1] - bd[i + 1]) + absi(d[i + 2] - bd[i + 2])) / 255.0
			if dd > 0.06:
				px.append([dd, i])
	if px.is_empty():
		return {"px": 0, "lab": Vector3.ZERO, "de_bg": 0.0}
	px.sort_custom(func(p1: Array, p2: Array) -> bool: return p1[0] > p2[0])
	var sum := Color(0, 0, 0, 0)
	var bsum := Color(0, 0, 0, 0)
	var cnt := 0
	for q in px.slice(0, maxi(1, (px.size() + 1) / 2)):
		var i: int = q[1]
		sum += Color8(d[i], d[i + 1], d[i + 2]).srgb_to_linear()
		bsum += Color8(bd[i], bd[i + 1], bd[i + 2]).srgb_to_linear()
		cnt += 1
	var lab := Geo.oklab(sum / cnt)
	return {"px": px.size(), "lab": lab, "de_bg": lab.distance_to(Geo.oklab(bsum / cnt))}


## Mean Oklab colour of a bird's core pixels in `rect` (the half of the
## pixels differing from the background that differ most) and of the
## background behind the same pixels.
func _core_colour(d: PackedByteArray, bgd: PackedByteArray, rect: Rect2i) -> Dictionary:
	var px := []
	for y in range(rect.position.y, rect.end.y):
		var o := (y * W + rect.position.x) * 4
		for x in rect.size.x:
			var i := o + x * 4
			var dd := (absi(d[i] - bgd[i]) + absi(d[i + 1] - bgd[i + 1]) + absi(d[i + 2] - bgd[i + 2])) / 255.0
			if dd > 0.06:
				px.append([dd, i])
	if px.is_empty():
		return {"px": 0, "lab": Vector3.ZERO, "de_bg": 0.0}
	px.sort_custom(func(p1: Array, p2: Array) -> bool: return p1[0] > p2[0])
	var sum := Color(0, 0, 0, 0)
	var bsum := Color(0, 0, 0, 0)
	var cnt := 0
	for q in px.slice(0, maxi(1, (px.size() + 1) / 2)):
		var i: int = q[1]
		sum += Color8(d[i], d[i + 1], d[i + 2]).srgb_to_linear()
		bsum += Color8(bgd[i], bgd[i + 1], bgd[i + 2]).srgb_to_linear()
		cnt += 1
	var lab := Geo.oklab(sum / cnt)
	return {"px": px.size(), "lab": lab, "de_bg": lab.distance_to(Geo.oklab(bsum / cnt))}


## The frame as the headset would see it: all 30 birds at `dist` over `bg`
## (species across, none / edible / danger down), pulse animated.
func _evidence_frame(bg: StringName, dist: float) -> Image:
	var pitch := _aim(bg)
	BirdModels.material().set_shader_parameter("pulse_test", -1.0)
	var hfov := 2.0 * atan(tan(deg_to_rad(FOV) * 0.5) * float(W) / H)
	var birds := []
	for i in species.size():
		for st in 3:
			var yaw := hfov * 0.45 - hfov * 0.9 * (i + 0.5) / species.size()
			birds.append(_bird(species[i], st, dist, -yaw, pitch + deg_to_rad(6.0 * (1 - st))))
	for j in 4:
		await get_tree().process_frame
	var img := await _grab()
	for b in birds:
		b.queue_free()
	return img


## Close up (each bird 8 deg across, as prey is a few spans away) over the
## meadow, pulse at its brightest: plain / edible / danger (rows) for four
## species, each with room for its marker.
func _close_frame() -> Image:
	_aim(&"meadow")
	BirdModels.material().set_shader_parameter("pulse_test", 1.0)
	var picks := [&"sparrow", &"starling", &"gull", &"eagle"]
	var birds := []
	for i in picks.size():
		var sp: StringName = picks[i]
		var d := float(SizeRules.species_data(sp)["span"]) / deg_to_rad(8.0)
		for st in 3:
			birds.append(_bird(sp, st, d, deg_to_rad(25.5 - 17.0 * i), deg_to_rad(-35.0 + 14.0 * (1 - st))))
	for j in 4:
		await get_tree().process_frame
	var img := await _grab()
	for b in birds:
		b.queue_free()
	return img


## The marker's outer radius (px) around a bird whose wingspan covers `ang`
## radians (bird.gdshader: mark_radius, mark_bird_scale, mark_tri_scale).
func _mark_px(ang: float, tri: bool) -> float:
	var mat := BirdModels.material()
	var r := maxf(_fparam(mat, &"mark_radius"), _fparam(mat, &"mark_bird_scale") * ang)
	return r * (_fparam(mat, &"mark_tri_scale") if tri else 1.0) * _focal_px()


## Pixels per radian at the centre of the view (perspective: the focal
## length in pixels, not H / FOV).
static func _focal_px() -> float:
	return H * 0.5 / tan(deg_to_rad(FOV) * 0.5)


## Hides (or shows) every marker batch (the identity measurement looks at
## the bird's own pixels).
static func _markers_visible(on: bool) -> void:
	for b: BirdBatch in BirdBatch.markers():
		RenderingServer.instance_set_visible(b.inst, on)


## One bird at a time over the meadow at each of ID_SIZES, in each state:
##   * with the marker, pulse at its dimmest: how far from the bird's centre
##     the frame changes (the marker's extent: as the shader places it when
##     highlighted, just the bird when not) and the chroma of the marker's
##     own pixels;
##   * marker hidden, pulse at its brightest (the most tint glow): the mean
##     colour of the bird's own pixels, against the plain bird's.
func _identity() -> Dictionary:
	var pitch := _aim(&"meadow")
	# High enough that the farthest bird (an eagle at 0.8 x its readable
	# angle, 120 m) is well above the ground.
	cam.position.y = 200.0
	var mat := BirdModels.material()
	for j in 3:
		await get_tree().process_frame
	var bgd := (await _grab()).get_data()
	var ppr := _focal_px()
	var numbers := {}
	var fails := []
	var worst := {"identity_de": [0.0, ""], "marker_chroma": [INF, ""], "marker_extent_err_px": [0.0, ""]}
	var cell := 150
	var sheet := Image.create(cell * species.size(), cell * ID_SIZES.size() * 3 + 30, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.12, 0.12, 0.14))
	var labels := []
	for si in ID_SIZES.size():
		var size_def: Array = ID_SIZES[si]
		var row := {}
		for ci in species.size():
			var sp: StringName = species[ci]
			var span := float(SizeRules.species_data(sp)["span"])
			var ang: float = BirdModels.min_highlight_angle(sp) * float(size_def[1]) if size_def[2] else deg_to_rad(float(size_def[1]))
			var d := span / ang
			var m := _bird(sp, 0, d, 0.0, pitch)
			var c := cam.unproject_position(m.global_position)
			var half := int(ceil(_mark_px(ang, true))) + 6
			var rect := Rect2i(Vector2i(c) - Vector2i(half, half), Vector2i(half * 2 + 1, half * 2 + 1)).intersection(Rect2i(0, 0, W, H))
			var rec := {"deg": snappedf(rad_to_deg(ang), 0.01), "dist_m": snappedf(d, 0.01)}
			var own := {}
			for st in 3:
				m.highlight = st
				m.snap()
				mat.set_shader_parameter("pulse_test", 0.0)
				await RenderingServer.frame_post_draw
				_markers_visible(true)
				var with_mark := await _grab()
				var wd := with_mark.get_data()
				mat.set_shader_parameter("pulse_test", 1.0)
				await RenderingServer.frame_post_draw
				_markers_visible(false)
				var bare := await _grab()
				_markers_visible(true)
				var bd := bare.get_data()
				var ext := _extent(wd, bgd, rect, c)
				rec[STATES[st] + "_extent_px"] = snappedf(ext, 0.1)
				own[st] = bd
				if st > 0:
					# The marker: where it is and how coloured, from the pixels
					# the marker changes (with it vs without it).
					var expect := _mark_px(ang, st == 2)
					var err := absf(ext - expect)
					rec[STATES[st] + "_extent_expected_px"] = snappedf(expect, 0.1)
					var ch := _marker_chroma(wd, bd, rect)
					rec[STATES[st] + "_marker_px"] = ch[0]
					rec[STATES[st] + "_marker_chroma"] = snappedf(ch[1], 0.001)
					var where := "%s %s %s" % [size_def[0], sp, STATES[st]]
					if err > MARK_EXTENT_TOL:
						fails.append("identity %s: marker extent %.1f px, expected %.1f" % [where, ext, expect])
					if int(ch[0]) < 12 or float(ch[1]) < MIN_MARK_CHROMA:
						fails.append("identity %s: marker %d px, chroma %.3f" % [where, ch[0], ch[1]])
					if err > float(worst["marker_extent_err_px"][0]):
						worst["marker_extent_err_px"] = [snappedf(err, 0.1), where]
					if float(ch[1]) < float(worst["marker_chroma"][0]):
						worst["marker_chroma"] = [snappedf(ch[1], 0.001), where]
				elif ext > span / d * ppr * 0.5 + MARK_EXTENT_TOL:
					fails.append("identity %s %s: an unhighlighted bird drew beyond itself (%.1f px)" % [size_def[0], sp, ext])
				var crop := with_mark.get_region(rect)
				crop.resize(cell - 4, cell - 4, Image.INTERPOLATE_BILINEAR if crop.get_width() > cell else Image.INTERPOLATE_NEAREST)
				sheet.blit_rect(crop, Rect2i(0, 0, cell - 4, cell - 4), Vector2i(ci * cell + 2, 30 + (si * 3 + st) * cell + 2))
			# The bird's own colours, marker hidden: highlighted vs plain over
			# the pixels any of the three changes.
			var labs := _own_colours(own, bgd, rect)
			rec["own_px"] = labs[3]
			for st in [1, 2]:
				var de: float = (labs[st] as Vector3).distance_to(labs[0])
				rec[STATES[st] + "_vs_none_own_de"] = snappedf(de, 0.001)
				if not size_def[2]:
					var where := "%s %s %s" % [size_def[0], sp, STATES[st]]
					if de > MAX_DE_IDENTITY:
						fails.append("identity %s: own colours %.3f from the plain bird's" % [where, de])
					if de > float(worst["identity_de"][0]):
						worst["identity_de"] = [snappedf(de, 0.001), where]
			rec["none_oklab"] = [snappedf(labs[0].x, 0.001), snappedf(labs[0].y, 0.001), snappedf(labs[0].z, 0.001)]
			row[String(sp)] = rec
			m.queue_free()
			await get_tree().process_frame
		numbers[size_def[0]] = row
		for st in 3:
			labels.append(["%s %s" % [size_def[0], STATES[st]], Vector2(4, 30 + (si * 3 + st) * cell + 4), 12, Color(1, 1, 1)])
	for ci in species.size():
		labels.append([String(species[ci]), Vector2(ci * cell + 6, 6), 14, Color(1, 0.85, 0.4)])
	mat.set_shader_parameter("pulse_test", -1.0)
	return {"numbers": numbers, "fails": fails, "worst": worst, "sheet": await Stage.annotate(self, sheet, labels)}


## Pixel stride for a box: every pixel up to ~250 px across, sparser above
## (means and extents of big close-up birds do not need every pixel).
static func _stride(rect: Rect2i) -> int:
	return maxi(1, rect.size.x / 250)


## How far (px) from `c` the frame differs from the background within rect.
func _extent(d: PackedByteArray, bgd: PackedByteArray, rect: Rect2i, c: Vector2) -> float:
	var mx := 0.0
	var st := _stride(rect)
	for y in range(rect.position.y, rect.end.y, st):
		for x in range(rect.position.x, rect.end.x, st):
			var i := (y * W + x) * 4
			if (absi(d[i] - bgd[i]) + absi(d[i + 1] - bgd[i + 1]) + absi(d[i + 2] - bgd[i + 2])) / 255.0 > 0.06:
				mx = maxf(mx, Vector2(x + 0.5, y + 0.5).distance_to(c))
	return mx


## [pixel count, mean Oklab chroma] of the pixels the marker changes (the
## frame with it against the same frame without it).
func _marker_chroma(with_mark: PackedByteArray, bare: PackedByteArray, rect: Rect2i) -> Array:
	var sum := Color(0, 0, 0, 0)
	var n := 0
	var st := _stride(rect)
	for y in range(rect.position.y, rect.end.y, st):
		for x in range(rect.position.x, rect.end.x, st):
			var i := (y * W + x) * 4
			if (absi(with_mark[i] - bare[i]) + absi(with_mark[i + 1] - bare[i + 1]) + absi(with_mark[i + 2] - bare[i + 2])) / 255.0 > 0.3:
				sum += Color8(with_mark[i], with_mark[i + 1], with_mark[i + 2]).srgb_to_linear()
				n += 1
	if n == 0:
		return [0, 0.0]
	var lab := Geo.oklab(sum / n)
	return [n, Vector2(lab.y, lab.z).length()]


## Mean Oklab colour of each state's frame (marker hidden) over the pixels
## any of them changes: [none, edible, danger, pixel count].
func _own_colours(own: Dictionary, bgd: PackedByteArray, rect: Rect2i) -> Array:
	var idx := PackedInt32Array()
	var sd := _stride(rect)
	for y in range(rect.position.y, rect.end.y, sd):
		for x in range(rect.position.x, rect.end.x, sd):
			var i := (y * W + x) * 4
			for st in 3:
				var d: PackedByteArray = own[st]
				if (absi(d[i] - bgd[i]) + absi(d[i + 1] - bgd[i + 1]) + absi(d[i + 2] - bgd[i + 2])) / 255.0 > 0.06:
					idx.append(i)
					break
	var out := []
	for st in 3:
		var d: PackedByteArray = own[st]
		var sum := Color(0, 0, 0, 0)
		for i in idx:
			sum += Color8(d[i], d[i + 1], d[i + 2]).srgb_to_linear()
		out.append(Geo.oklab(sum / maxf(idx.size(), 1)))
	out.append(idx.size())
	return out


func _zoom_sheet(rows: Array, what: Variant) -> Image:
	var z := 3
	var cell := 0
	for r in rows:
		for c: Image in r[1]:
			cell = maxi(cell, maxi(c.get_width(), c.get_height()) * z + 4)
	cell = clampi(cell, 40, 140)
	var label_w := 120
	var cols := species.size() * 3
	var top := 44
	var sheet := Image.create(label_w + cols * cell, top + rows.size() * cell, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.12, 0.12, 0.14))
	var labels := []
	for i in species.size():
		labels.append([String(species[i]), Vector2(label_w + i * 3 * cell + 4, 22), 13, Color(0.9, 0.9, 0.9)])
	for r in rows.size():
		var row: Array = rows[r]
		labels.append([String(row[0]), Vector2(4, top + r * cell + cell * 0.4), 13, Color(0.9, 0.9, 0.9)])
		var cs: Array = row[1]
		for i in cs.size():
			var reg: Image = cs[i]
			var w := mini(reg.get_width() * z, cell - 4)
			var h := mini(reg.get_height() * z, cell - 4)
			reg.resize(w, h, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(reg, Rect2i(0, 0, w, h), Vector2i(label_w + i * cell + (cell - w) / 2, top + r * cell + (cell - h) / 2))
	var title: String = what if what is String else "%d m" % int(what)
	labels.append(["%s: none / edible / danger per species (x%d)" % [title, z], Vector2(4, 2), 13, Color(1, 0.85, 0.4)])
	return await Stage.annotate(self, sheet, labels)
