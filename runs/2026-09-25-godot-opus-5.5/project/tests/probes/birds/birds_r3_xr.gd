extends Node3D
## Round-3 verifier probe (birds): the bird material in a real XR session.
## The builder only ever drew birds on desktop Forward+/Mobile; the project
## ships with xr/shaders/enabled (multiview variants), so this checks that
## the bird shader compiles and draws under the Meta XR Simulator, and what
## 60 birds cost there at the headset's frame rate.
##
##   tools/xr.sh 20 res://tests/probes/birds/birds_r3_xr.tscn -- --xrshot=8,14 --xrshot_dir=birds/verify --xrshot_prefix=r3_xr
##
## Desktop baseline (no XR): tools/gd.sh birds_verify --rendering-method mobile
##   --resolution 1280x960 res://tests/probes/birds/birds_r3_xr.tscn -- --desktop_quit=6
##
## Writes artifacts/birds/verify/r3_xr_<mode>.json.

const EYE := 1.6

var _models: Array[BirdModel] = []
var _flock: Array[BirdModel] = []
var _flock_state: Array[Vector4] = []
var _t := 0.0
var _sync := PackedInt32Array()
var _fps := PackedFloat32Array()
var _draws := PackedInt32Array()
var _prims := PackedInt32Array()
var _moves := PackedInt32Array()
var _bcount := PackedInt32Array()
## A dummy MultiMesh of the same size as a bird batch, uploaded at the same
## point of the frame (frame_pre_draw, right after BirdBatch.sync_all): if it
## spikes as the birds' sync does, the spikes are the engine's buffer upload,
## not the birds' own code.
var _dummy_mm := RID()
var _dummy_buf := PackedFloat32Array()
var _dummy_us := PackedInt32Array()
## A fixed CPU workload (pure GDScript maths, ~bird-sync sized) timed at the
## same point: if it is bimodal like the sync, the tail is the machine
## (scheduler / core type under the simulator), not the birds' code.
var _canary_us := PackedInt32Array()
## --phase_timing: the probe swaps BirdBatch's frame_pre_draw hook for a copy
## of sync_all (same calls, same order) that times its three phases.
var _ph_tick := PackedInt32Array()
var _ph_reattach := PackedInt32Array()
var _ph_upload := PackedInt32Array()
var _bad_lod_frames := 0
var _frames := 0
var _cam: XRCamera3D
var _quit_at := -1.0


func _ready() -> void:
	var args := Paths.user_args()
	_quit_at = float(args.get("desktop_quit", "-1"))
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.76, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.82, 0.9)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.55, 0.72, 0.45)
	pm.material = gm
	ground.mesh = pm
	add_child(ground)
	var origin := XROrigin3D.new()
	add_child(origin)
	_cam = XRCamera3D.new()
	_cam.position = Vector3(0, EYE, 0)
	_cam.near = 0.03
	_cam.far = 2000.0
	origin.add_child(_cam)
	_cam.current = true
	var mirror := XRMirror.new()
	mirror.source = _cam
	add_child(mirror)
	var ids := BirdSpecies.IDS
	# Row A: every species close (3-6 m), flapping, plain: the plumage.
	# Row B / C: every species at 40 m, edible / danger: the markers.
	# Row D: every species perched on an invisible rail at 5 m.
	# Flock: 20 birds wheeling 15-70 m away (LOD changes while flying).
	for i in ids.size():
		var sp: StringName = ids[i]
		var span: float = SizeRules.species_data(sp).get("span", 0.3)
		var x := (i - 4.5)
		var a := _add(sp, span, Vector3(x * 0.55, EYE + 0.3, -4.0))
		a.flap_amount = 1.0
		var b := _add(sp, span, Vector3(x * 3.2, EYE + 6.0, -40.0))
		b.highlight = 1
		var c := _add(sp, span, Vector3(x * 3.2, EYE + 1.0, -40.0))
		c.highlight = 2
		var d := _add(sp, span, Vector3(x * 0.6, EYE - 0.6, -5.0))
		d.perched = true
		d.wing_fold = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 33
	for k in 20:
		var sp: StringName = ids[rng.randi() % ids.size()]
		var span: float = SizeRules.species_data(sp).get("span", 0.3)
		var m := _add(sp, span, Vector3.ZERO)
		m.flap_amount = 0.6
		m.highlight = rng.randi() % 3
		_flock.append(m)
		_flock_state.append(Vector4(rng.randf_range(15, 70), rng.randf_range(0, TAU), rng.randf_range(0.2, 0.6), rng.randf_range(2, 14)))
	for m in _models:
		m.snap()
	if args.has("phase_timing"):
		for c in RenderingServer.frame_pre_draw.get_connections():
			var cb: Callable = c["callable"]
			if cb.get_method() == &"_on_frame_pre_draw":
				RenderingServer.frame_pre_draw.disconnect(cb)
		RenderingServer.frame_pre_draw.connect(_timed_sync)
	_dummy_mm = RenderingServer.multimesh_create()
	RenderingServer.multimesh_allocate_data(_dummy_mm, 64, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true)
	_dummy_buf.resize(64 * 16)
	RenderingServer.frame_pre_draw.connect(_dummy_upload)
	print("[birds] r3 xr probe: %d birds, use_xr=%s" % [_models.size(), get_viewport().use_xr])


## BirdBatch.sync_all, phase by phase (tick+write, LOD reattach, upload).
func _timed_sync() -> void:
	var dt := get_tree().root.get_process_delta_time()
	var t0 := Time.get_ticks_usec()
	var moves: Array[BirdModel] = []
	var n := 0
	for b: BirdBatch in BirdBatch.all():
		if b.models.is_empty():
			continue
		b._sync(dt)
		n += b.models.size()
		moves.append_array(b._lod_moves)
	var t1 := Time.get_ticks_usec()
	for m in moves:
		if is_instance_valid(m):
			m._reattach()
	var t2 := Time.get_ticks_usec()
	for b: BirdBatch in BirdBatch.all():
		if not b.models.is_empty():
			b.upload()
	var t3 := Time.get_ticks_usec()
	BirdBatch.last_lod_moves = moves.size()
	BirdBatch.last_sync_usec = t3 - t0
	BirdBatch.last_sync_models = n
	BirdBatch.syncs += 1
	if _t > 1.0:
		_ph_tick.append(t1 - t0)
		_ph_reattach.append(t2 - t1)
		_ph_upload.append(t3 - t2)


func _dummy_upload() -> void:
	for k in 22:
		_dummy_buf[k] = randf()
	var t0 := Time.get_ticks_usec()
	for k in 20:
		RenderingServer.multimesh_set_buffer(_dummy_mm, _dummy_buf)
	if _t > 1.0:
		_dummy_us.append(Time.get_ticks_usec() - t0)
	var t1 := Time.get_ticks_usec()
	var acc := 0.0
	var v := Vector3(0.3, 0.2, 0.1)
	for k in 6000:
		v = Basis(Vector3.UP, 0.001 * k) * v
		acc += v.x * 0.5 + sin(acc * 0.001)
	if _t > 1.0:
		_canary_us.append(Time.get_ticks_usec() - t1)
	if acc == 12345.678:
		print("[birds] never")


func _exit_tree() -> void:
	if _dummy_mm.is_valid():
		RenderingServer.free_rid(_dummy_mm)


func _add(sp: StringName, span: float, pos: Vector3) -> BirdModel:
	var m := BirdModels.create(sp)
	m.scale = Vector3.ONE * span
	m.position = pos
	add_child(m)
	_models.append(m)
	return m


func _process(delta: float) -> void:
	_t += delta
	_frames += 1
	for i in _models.size():
		var m := _models[i]
		if not m.perched:
			m.flap_phase = fposmod(m.flap_phase + delta * (9.0 if i % 2 == 0 else 4.0), 1.0)
	for k in _flock.size():
		var s := _flock_state[k]
		var ang := s.y + _t * s.z
		var m := _flock[k]
		m.position = Vector3(cos(ang) * s.x, EYE + s.w, -sin(ang) * s.x - 20.0)
		m.bank = 0.4
		m.look_at(m.position + Vector3(-sin(ang), 0, -cos(ang)), Vector3.UP)
	# Skip the first second (shader compiles, session start).
	if _t > 1.0:
		_sync.append(BirdBatch.last_sync_usec)
		_moves.append(BirdBatch.last_lod_moves)
		_bcount.append(BirdBatch.count())
		_fps.append(Engine.get_frames_per_second())
		_draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		_prims.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
		for m in _models:
			var want := BirdModels.mesh(m.species, m.get_lod())
			if m._batch == null or m._batch.mesh != want:
				_bad_lod_frames += 1
				break
	if int(_t) != int(_t - delta):
		print("[birds] r3 xr t=%d fps=%.0f sync_us=%d draws=%d" % [int(_t), Engine.get_frames_per_second(), BirdBatch.last_sync_usec,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
		# The simulator run ends by VR's --autoquit: keep the report current.
		if _t > 4.0:
			_write_report()
	if _quit_at > 0.0 and _t >= _quit_at:
		_write_report()
		get_tree().quit()


func _median(a: PackedInt32Array) -> float:
	if a.is_empty():
		return -1.0
	var s := Array(a)
	s.sort()
	return float(s[s.size() / 2])


func _p95(a: PackedInt32Array) -> float:
	if a.is_empty():
		return -1.0
	var s := Array(a)
	s.sort()
	return float(s[int(s.size() * 0.95)])


func _pct(a: PackedInt32Array, q: float) -> float:
	if a.is_empty():
		return -1.0
	var s := Array(a)
	s.sort()
	return float(s[mini(int(s.size() * q), s.size() - 1)])


## Sync time split by what happened in that sync: no LOD move, LOD moves
## without a batch created/freed, and syncs where the batch count changed.
func _split() -> Dictionary:
	var calm := PackedInt32Array()
	var moved := PackedInt32Array()
	var churn := PackedInt32Array()
	for i in _sync.size():
		var changed := i > 0 and _bcount[i] != _bcount[i - 1]
		if changed:
			churn.append(_sync[i])
		elif _moves[i] > 0:
			moved.append(_sync[i])
		else:
			calm.append(_sync[i])
	var over := 0
	for v in _sync:
		if v > 1000:
			over += 1
	return {
		"sync_us_p99": _pct(_sync, 0.99), "sync_us_max": _pct(_sync, 1.0), "syncs_over_1000us": over,
		"calm_n": calm.size(), "calm_median": _pct(calm, 0.5), "calm_p95": _pct(calm, 0.95), "calm_max": _pct(calm, 1.0),
		"lod_move_n": moved.size(), "lod_move_median": _pct(moved, 0.5), "lod_move_max": _pct(moved, 1.0),
		"batch_churn_n": churn.size(), "batch_churn_median": _pct(churn, 0.5), "batch_churn_max": _pct(churn, 1.0),
	}


func _write_report() -> void:
	var fs := Array(_fps)
	fs.sort()
	var hist := [0, 0, 0]
	for m in _models:
		hist[m.get_lod()] += 1
	var rep := {
		"mode": "xr" if get_viewport().use_xr else "desktop",
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"seconds": _t,
		"frames": _frames,
		"birds": _models.size(),
		"batches": BirdBatch.count(),
		"sync_us_median": _median(_sync),
		"sync_us_p95": _p95(_sync),
		"fps_median": fs[fs.size() / 2] if not fs.is_empty() else -1.0,
		"draw_calls_median": _median(_draws),
		"primitives_median": _median(_prims),
		"lod_histogram": hist,
		"frames_with_a_model_in_the_wrong_batch": _bad_lod_frames,
		"split": _split(),
		"dummy_20_uploads_us_median": _pct(_dummy_us, 0.5),
		"dummy_20_uploads_us_p95": _pct(_dummy_us, 0.95),
		"dummy_20_uploads_us_max": _pct(_dummy_us, 1.0),
		"phase_tick_us": [_pct(_ph_tick, 0.5), _pct(_ph_tick, 0.95), _pct(_ph_tick, 1.0)],
		"phase_reattach_us": [_pct(_ph_reattach, 0.5), _pct(_ph_reattach, 0.95), _pct(_ph_reattach, 1.0)],
		"phase_upload_us": [_pct(_ph_upload, 0.5), _pct(_ph_upload, 0.95), _pct(_ph_upload, 1.0)],
		"cpu_canary_us_median": _pct(_canary_us, 0.5),
		"cpu_canary_us_p95": _pct(_canary_us, 0.95),
		"cpu_canary_us_max": _pct(_canary_us, 1.0),
	}
	var path := Paths.artifacts("birds/verify").path_join("r3_xr_%s.json" % rep["mode"])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rep, "  "))
	print("[birds] r3 xr report: ", JSON.stringify(rep))
