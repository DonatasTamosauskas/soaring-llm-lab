extends Node3D
## Round-4 verifier XR probe (birds). Written by the verifier; public birds
## API, core Paths, the VR area's XRMirror only for the screenshot.
##
##   tools/xr.sh 45 res://tests/probes/birds/birds_r4_xr.tscn -- --xrshot=12,20,28 \
##       --xrshot_dir=birds/verify --xrshot_prefix=r4_xr
##
## 60 birds in the Meta XR Simulator, timed through BirdBatch's own hook
## (last_sync_usec, not a copy of it): 48 wheeling at 8-70 m (a third edible,
## a sixth danger), 10 perched in a row at 5 m, and two close passes the
## player lives through: an eagle (danger) circling the head at 3.5 m and a
## sparrow (edible) at 1.2 m. Writes artifacts/birds/verify/r4_xr.json each
## second (the run ends by --autoquit).

const EYE := 1.6
var _models: Array[BirdModel] = []
var _state: Array[Vector4] = []
var _eagle: BirdModel
var _prey: BirdModel
var _t := 0.0
var _sync := PackedInt32Array()
var _fps := PackedFloat32Array()
var _draws := PackedInt32Array()


func _ready() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.76, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.84, 0.92)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.2
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.58, 0.7, 0.42)
	pm.material = gm
	ground.mesh = pm
	add_child(ground)
	var origin := XROrigin3D.new()
	add_child(origin)
	var cam := XRCamera3D.new()
	cam.position = Vector3(0, EYE, 0)
	cam.near = 0.03
	cam.far = 2000.0
	origin.add_child(cam)
	cam.current = true
	var mirror := XRMirror.new()
	mirror.source = cam
	add_child(mirror)
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var ids := BirdSpecies.IDS
	for k in 48:
		var sp: StringName = ids[k % ids.size()]
		var m := _add(sp, Vector3.ZERO)
		m.highlight = [0, 1, 0, 2, 1, 0][k % 6]
		m.flap_amount = rng.randf_range(0.3, 1.0)
		_state.append(Vector4(rng.randf_range(8, 70), rng.randf_range(0, TAU), rng.randf_range(0.15, 0.5), rng.randf_range(2, 16)))
	for i in ids.size():
		var m := _add(ids[i], Vector3((i - 4.5) * 0.7, EYE - 0.7, -5.0))
		m.perched = true
		m.wing_fold = 1.0
		m.highlight = i % 3
	_eagle = _add(&"eagle", Vector3(0, EYE, -3.5))
	_eagle.highlight = 2
	_eagle.flap_amount = 0.0
	_prey = _add(&"sparrow", Vector3(0, EYE, -1.2))
	_prey.highlight = 1
	_prey.flap_amount = 1.0
	for m in _models:
		m.snap()
	print("[birds-r4] xr probe: %d birds, use_xr=%s" % [_models.size(), get_viewport().use_xr])


func _add(sp: StringName, pos: Vector3) -> BirdModel:
	var m := BirdModels.create(sp)
	m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
	m.position = pos
	add_child(m)
	_models.append(m)
	return m


func _process(dt: float) -> void:
	_t += dt
	if _t > 3.0 and BirdBatch.last_sync_usec > 0:
		_sync.append(BirdBatch.last_sync_usec)
		_fps.append(Engine.get_frames_per_second())
		_draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	for i in _state.size():
		var s := _state[i]
		var m := _models[i]
		var ang := s.y + _t * s.z
		m.position = Vector3(sin(ang) * s.x, EYE + s.w, -cos(ang) * s.x)
		m.look_at(m.position + Vector3(cos(ang), 0.0, sin(ang)), Vector3.UP)
		m.bank = 0.4
		if not m.perched:
			m.flap_phase = fposmod(m.flap_phase + 7.0 * dt, 1.0)
	# The eagle circles the head at 3.5 m, the sparrow flutters at 1.2 m.
	var ea := _t * 0.35
	_eagle.position = Vector3(sin(ea) * 3.5, EYE + 0.3, -cos(ea) * 3.5)
	_eagle.look_at(_eagle.position + Vector3(cos(ea), 0, sin(ea)), Vector3.UP)
	_eagle.bank = 0.5
	_prey.position = Vector3(0.3 * sin(_t * 1.3), EYE + 0.1 * sin(_t * 2.0), -1.2)
	_prey.flap_phase = fposmod(_prey.flap_phase + 12.0 * dt, 1.0)
	if int(_t) != int(_t - dt) and _t > 5.0:
		_write()


func _write() -> void:
	var a := Array(_sync)
	a.sort()
	if a.is_empty():
		return
	var f := Array(_fps)
	f.sort()
	var d := Array(_draws)
	d.sort()
	var rep := {"frames": a.size(), "seconds": snappedf(_t, 0.1), "use_xr": get_viewport().use_xr,
		"sync_us": {"median": a[a.size() / 2], "p95": a[int(a.size() * 0.95)], "p99": a[int(a.size() * 0.99)], "max": a.back()},
		"over_1ms_frames": a.filter(func(x): return x > 1000).size(),
		"fps_median": f[f.size() / 2], "draw_calls_median": d[d.size() / 2],
		"markers": BirdBatch.marker_total(), "renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method")}
	var fa := FileAccess.open(Paths.artifacts("birds").path_join("verify/r4_xr.json"), FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(rep, "  "))
	if int(_t) % 10 == 0:
		print("[birds-r4] xr t=%.0f s: %s" % [_t, JSON.stringify(rep)])
