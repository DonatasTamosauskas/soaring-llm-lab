extends Node
## B3 in a rendered scene: 60 animated birds (6 of each species, flapping,
## gliding, banking, some tucking and perching) over a meadow in hazy light,
## one shadow-casting sun, viewed like a player would. Measured per frame
## over 3 s (216 frames at 72 Hz):
##   * the birds area's CPU cost: BirdBatch.sync_all (smoothing, transforms,
##     LOD choice, highlight markers, one MultiMesh upload per batch)
##   * draw calls and primitives with the birds minus without them
##     (RENDER_TOTAL_*_IN_FRAME: includes depth and shadow passes)
## Outputs flock.png and flock_perf.json.
##
##   tools/gd.sh birds --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/shots/birds_flock.tscn

const FRAMES := 216
const DT := 1.0 / 72.0

var vp: SubViewport
var cam: Camera3D
var holders: Array[Node3D] = []
var models: Array[BirdModel] = []


func _ready() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color("5f8fc4")
	sm.sky_horizon_color = Color("b9cfe0")
	sm.ground_horizon_color = Color("b9cfe0")
	sm.ground_bottom_color = Color("6d8a5a")
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color("b9cfe0")
	env.fog_density = 0.002
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 140, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	vp.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(800, 800)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color("86a95a")
	ground.material_override = gm
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	vp.add_child(ground)
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = 1500.0
	vp.add_child(cam)
	cam.current = true
	cam.position = Vector3(0, 5, 14)
	cam.look_at(Vector3(0, 10, -8), Vector3.UP)
	for i in 60:
		var h := Node3D.new()
		vp.add_child(h)
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		h.add_child(m)
		holders.append(h)
		models.append(m)
	# Baseline without birds.
	for h in holders:
		h.visible = false
	var base := await _count(20)
	for h in holders:
		h.visible = true
	var t := 0.0
	var sync_us := PackedFloat32Array()
	var draws := PackedFloat32Array()
	var prims := PackedFloat32Array()
	for f in FRAMES:
		t += DT
		_animate(t)
		await RenderingServer.frame_post_draw
		if f >= 20:
			sync_us.append(BirdBatch.last_sync_usec)
			draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
			prims.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	# On this Mac only Forward+ draws correctly (Mobile under MoltenVK paints
	# magenta tiles); under Mobile we still record the counts, not the image.
	var method := RenderingServer.get_current_rendering_method()
	var suffix := "" if method == "forward_plus" else "_" + method
	if suffix == "":
		var img := vp.get_texture().get_image()
		img.save_png(Paths.artifacts("birds").path_join("flock.png"))
	# LODs as drawn: each batch's mesh, counted over its instances (and the
	# models' own get_lod(), which must agree).
	var lods := [0, 0, 0]
	var tris_per_pass := 0
	for b: BirdBatch in BirdBatch.all():
		for lod in BirdModels.LOD_COUNT:
			for sp in BirdSpecies.IDS:
				if b.mesh == BirdModels.mesh(sp, lod):
					lods[lod] += b.models.size()
					tris_per_pass += b.models.size() * BirdModels.triangle_count(sp, lod)
	var disagree := 0
	for m in models:
		if m._batch == null or m._batch.mesh != BirdModels.mesh(m.species, m.get_lod()):
			disagree += 1
	var rep := {
		"birds": models.size(),
		"frames": sync_us.size(),
		"cpu_sync_us_median": _median(sync_us),
		"cpu_sync_us_p95": _pct(sync_us, 0.95),
		"cpu_budget_us": 1000,
		"draw_calls_with_birds_median": _median(draws),
		"draw_calls_without_birds": base[0],
		"bird_draw_calls": _median(draws) - base[0],
		"primitives_with_birds_median": _median(prims),
		"primitives_without_birds": base[1],
		"bird_primitives": _median(prims) - base[1],
		"batches": BirdBatch.count(),
		"lod_histogram_drawn": lods,
		"models_drawing_another_lod_than_reported": disagree,
		"bird_triangles_per_pass": tris_per_pass,
		"note": "draw calls/primitives include every pass (depth pre-pass on Forward+, shadow pass); XR multiview draws both eyes in one call",
	}
	rep["renderer"] = method
	var fa := FileAccess.open(Paths.artifacts("birds").path_join("flock_perf%s.json" % suffix), FileAccess.WRITE)
	fa.store_string(JSON.stringify(rep, "  "))
	print("[birds] flock: sync median %.0f us (p95 %.0f), bird draw calls %d, bird primitives %d, batches %d, LODs %s" % [
		rep["cpu_sync_us_median"], rep["cpu_sync_us_p95"], rep["bird_draw_calls"], rep["bird_primitives"], rep["batches"], str(lods)])
	get_tree().quit(1 if rep["cpu_sync_us_median"] > 1000 else 0)


## A loose flock over the meadow: rings of birds at different heights and
## radii, flapping or gliding, banking into the curve, a few tucked or
## perched on an invisible wire, some highlighted.
func _animate(t: float) -> void:
	for i in 60:
		var h := holders[i]
		var m := models[i]
		var ring := i % 6
		var r := 6.0 + ring * 4.0
		var w := 0.35 - ring * 0.03
		var a := t * w + i * 0.61
		if i % 13 == 0:
			h.position = Vector3(-8.0 + (i / 13) * 3.0, 3.0, 8.0)
			h.rotation = Vector3.ZERO
			m.perched = true
			m.wing_fold = 1.0
			m.flap_amount = 0.0
			continue
		h.position = Vector3(cos(a) * r, 6.0 + ring * 1.6 + sin(t * 0.8 + i) * 0.8, -8.0 + sin(a) * r)
		h.rotation = Vector3(0, -a, 0)
		m.bank = -0.5 - ring * 0.05
		m.flap_phase = fposmod(t * (3.0 + (i % 10) * 0.8) + i * 0.13, 1.0)
		m.flap_amount = clampf(0.5 + 0.5 * sin(t * 0.9 + i), 0.0, 1.0)
		m.wing_fold = 0.6 if i % 11 == 0 else 0.0
		m.highlight = 1 if i % 9 == 0 else (2 if i % 17 == 0 else 0)


func _count(frames: int) -> Array:
	var d := PackedFloat32Array()
	var p := PackedFloat32Array()
	for f in frames:
		await RenderingServer.frame_post_draw
		d.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		p.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	return [_median(d), _median(p)]


func _median(a: PackedFloat32Array) -> float:
	var s := Array(a)
	s.sort()
	return s[s.size() / 2] if not s.is_empty() else 0.0


func _pct(a: PackedFloat32Array, q: float) -> float:
	var s := Array(a)
	s.sort()
	return s[mini(int(s.size() * q), s.size() - 1)] if not s.is_empty() else 0.0
