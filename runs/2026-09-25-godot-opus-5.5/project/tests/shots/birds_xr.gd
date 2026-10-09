extends Node3D
## B3 in a real XR session: 60 birds drawn through the Meta XR Simulator
## (Mobile renderer, multiview shaders, 72 Hz), and where the birds' CPU time
## goes when it spikes.
##
##   tools/xr.sh 26 res://tests/shots/birds_xr.tscn -- --xrshot=12 --xrshot_dir=birds --xrshot_prefix=xr_birds
##   (desktop baseline, same scene: tools/gd.sh birds --rendering-method mobile
##    --resolution 1280x960 res://tests/shots/birds_xr.tscn -- --desktop_quit=14)
##
## The scene: every species close up flapping (3-6 m), every species at 40 m
## edible and danger (markers), every species perched at 5 m, and 20 birds
## wheeling 15-70 m away (LOD changes while flying) - the round-3 verifier's
## layout. From 2 s on, every frame records:
##   * the birds' sync (BirdBatch.sync_all at frame_pre_draw) and its phases;
##   * the same fixed pure-GDScript workload timed right BEFORE and right
##     AFTER the sync (connected around it on frame_pre_draw): if the machine
##     slows the main thread (the simulator's own threads, the core it runs
##     on), the canary right before the sync is slow in the same frames;
##   * each bird's own tick (a timed copy of the tick loop, the same calls in
##     the same order, run by this script instead of BirdBatch's hook): a
##     spike spread evenly over all 60 birds is the thread running slower, a
##     spike in a few birds is their own work.
## Writes artifacts/birds/xr_perf_<xr|desktop>.json. Gate (printed, and the
## exit code of a desktop run): sync p95 under 1000 us.

const EYE := 1.6
const WARMUP := 2.0
const P95_LIMIT := 1000.0

var _models: Array[BirdModel] = []
var _flock: Array[BirdModel] = []
var _flock_state: Array[Vector4] = []
var _t := 0.0
var _quit_at := -1.0
var _cam: XRCamera3D
var _sync := PackedInt32Array()
var _ph0 := PackedInt32Array()
var _ph1 := PackedInt32Array()
var _ph2 := PackedInt32Array()
var _before := PackedInt32Array()
var _after := PackedInt32Array()
## Per frame: the median and the largest of the 60 birds' own ticks (us x 10).
var _bird_med := PackedInt32Array()
var _bird_max := PackedInt32Array()
var _fps := PackedFloat32Array()
var _draws := PackedInt32Array()
var _prims := PackedInt32Array()
var _bad_lod := 0
var _frames := 0
var _pending_before := 0


func _ready() -> void:
	var args := Paths.user_args()
	_quit_at = float(args.get("desktop_quit", "-1"))
	# The canary before the sync must run first on frame_pre_draw: connect it
	# before any bird exists (BirdBatch hooks itself on its first batch).
	RenderingServer.frame_pre_draw.connect(_canary_before)
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
	for i in ids.size():
		var sp: StringName = ids[i]
		var span: float = SizeRules.species_data(sp).get("span", 0.3)
		var x := (i - 4.5)
		var a := _add(sp, span, Vector3(x * 0.55, EYE + 0.3, -4.0))
		a.flap_amount = 1.0
		_add(sp, span, Vector3(x * 3.2, EYE + 6.0, -40.0)).highlight = 1
		_add(sp, span, Vector3(x * 3.2, EYE + 1.0, -40.0)).highlight = 2
		var d := _add(sp, span, Vector3(x * 0.6, EYE - 0.6, -5.0))
		d.perched = true
		d.wing_fold = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 33
	for k in 20:
		var sp: StringName = ids[rng.randi() % ids.size()]
		var m := _add(sp, SizeRules.species_data(sp).get("span", 0.3), Vector3.ZERO)
		m.flap_amount = 0.6
		m.highlight = rng.randi() % 3
		_flock.append(m)
		_flock_state.append(Vector4(rng.randf_range(15, 70), rng.randf_range(0, TAU), rng.randf_range(0.2, 0.6), rng.randf_range(2, 14)))
	for m in _models:
		m.snap()
	# Replace BirdBatch's hook with the timed copy below, then the canary
	# after it.
	for c in RenderingServer.frame_pre_draw.get_connections():
		var cb: Callable = c["callable"]
		if cb.get_method() == &"_on_frame_pre_draw":
			RenderingServer.frame_pre_draw.disconnect(cb)
	RenderingServer.frame_pre_draw.connect(_timed_sync)
	RenderingServer.frame_pre_draw.connect(_canary_after)
	print("[birds] xr shot: %d birds, use_xr=%s, renderer %s" % [_models.size(), get_viewport().use_xr,
		ProjectSettings.get_setting("rendering/renderer/rendering_method")])


func _add(sp: StringName, span: float, pos: Vector3) -> BirdModel:
	var m := BirdModels.create(sp)
	m.scale = Vector3.ONE * span
	m.position = pos
	add_child(m)
	_models.append(m)
	return m


## A fixed pure-GDScript workload (~100 us on an M1 P-core).
static func _canary() -> int:
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	var v := Vector3(0.3, 0.2, 0.1)
	for k in 1500:
		v = Basis(Vector3.UP, 0.001 * k) * v
		acc += v.x * 0.5 + sin(acc * 0.001)
	var us := Time.get_ticks_usec() - t0
	return us if acc != 12345.678 else us + 1


func _canary_before() -> void:
	_pending_before = _canary()


func _canary_after() -> void:
	if _t > WARMUP:
		_before.append(_pending_before)
		_after.append(_canary())


## BirdBatch.sync_all, with each bird's tick timed (the same calls in the
## same order as BirdBatch._sync / sync_all).
func _timed_sync() -> void:
	var dt := get_tree().root.get_process_delta_time()
	var t0 := Time.get_ticks_usec()
	var moves: Array[BirdModel] = []
	var per := PackedInt32Array()
	BirdBatch._mark_changes.clear()
	for b: BirdBatch in BirdBatch.all():
		if b.models.is_empty():
			continue
		b._lod_moves.clear()
		var cam := BirdModels.camera_position(b.models[0].get_viewport())
		for i in b.models.size():
			var m := b.models[i]
			var a := Time.get_ticks_usec()
			if m._tick(dt, cam):
				b._lod_moves.append(m)
			b.write(i, m._xf, m._inst)
			if m._hl_on != (m._mark != null):
				BirdBatch._mark_changes.append(m)
			per.append(Time.get_ticks_usec() - a)
		moves.append_array(b._lod_moves)
	var t1 := Time.get_ticks_usec()
	for m in moves:
		if is_instance_valid(m):
			m._reattach()
	for m in BirdBatch._mark_changes:
		if is_instance_valid(m):
			m._sync_mark()
	BirdBatch._mark_changes.clear()
	for b: BirdBatch in BirdBatch.markers():
		b._write_marks()
	var t2 := Time.get_ticks_usec()
	for b: BirdBatch in BirdBatch.all():
		if not b.models.is_empty():
			b.upload()
	for b: BirdBatch in BirdBatch.markers():
		b.upload()
	var t3 := Time.get_ticks_usec()
	BirdBatch.last_phases = Vector3i(t1 - t0, t2 - t1, t3 - t2)
	BirdBatch.last_lod_moves = moves.size()
	BirdBatch.last_sync_usec = t3 - t0
	BirdBatch.syncs += 1
	if _t > WARMUP:
		_sync.append(t3 - t0)
		_ph0.append(t1 - t0)
		_ph1.append(t2 - t1)
		_ph2.append(t3 - t2)
		var s := Array(per)
		s.sort()
		_bird_med.append(int(s[s.size() / 2]) if not s.is_empty() else 0)
		_bird_max.append(int(s[s.size() - 1]) if not s.is_empty() else 0)


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
	if _t > WARMUP:
		_fps.append(Engine.get_frames_per_second())
		_draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		_prims.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
		for m in _models:
			if m._batch == null or m._batch.mesh != BirdModels.mesh(m.species, m.get_lod()):
				_bad_lod += 1
				break
	if int(_t) != int(_t - delta) and _t > WARMUP + 2.0:
		# The simulator run ends by VR's --autoquit: keep the report current.
		_report()
	if _quit_at > 0.0 and _t >= _quit_at:
		var ok := _report()
		get_tree().quit(0 if ok else 1)


static func _q(a: PackedInt32Array, q: float) -> float:
	if a.is_empty():
		return -1.0
	var s := Array(a)
	s.sort()
	return float(s[mini(int(s.size() * q), s.size() - 1)])


func _report() -> bool:
	var med := _q(_sync, 0.5)
	# Slow frames: the sync over 1.8 x its median. In them, how slow were the
	# canary right before the sync, the canary right after, and the birds'
	# typical (median) tick, each against its own median.
	var slow := 0
	var r_before := PackedFloat32Array()
	var r_after := PackedFloat32Array()
	var r_bird := PackedFloat32Array()
	var mb := maxf(_q(_before, 0.5), 1.0)
	var ma := maxf(_q(_after, 0.5), 1.0)
	var mm := maxf(_q(_bird_med, 0.5), 1.0)
	var n := mini(_sync.size(), mini(_before.size(), _bird_med.size()))
	for i in n:
		if _sync[i] > 1.8 * med:
			slow += 1
			r_before.append(_before[i] / mb)
			r_after.append(_after[i] / ma)
			r_bird.append(_bird_med[i] / mm)
	var fs := Array(_fps)
	fs.sort()
	var hist := [0, 0, 0]
	for m in _models:
		hist[m.get_lod()] += 1
	var mean := func(a: PackedFloat32Array) -> float:
		var t := 0.0
		for x in a:
			t += x
		return snappedf(t / maxf(a.size(), 1), 0.01)
	var p95 := _q(_sync, 0.95)
	var rep := {
		"mode": "xr" if get_viewport().use_xr else "desktop",
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"seconds": snappedf(_t, 0.1), "frames_measured": _sync.size(), "birds": _models.size(),
		"fps_median": fs[fs.size() / 2] if not fs.is_empty() else -1.0,
		"draw_calls_median": _q(_draws, 0.5), "primitives_median": _q(_prims, 0.5),
		"lod_histogram": hist, "frames_with_a_model_in_the_wrong_batch": _bad_lod,
		"sync_us": {"median": med, "p95": p95, "p99": _q(_sync, 0.99), "max": _q(_sync, 1.0)},
		"phases_us_median_p95": {"ticks_and_writes": [_q(_ph0, 0.5), _q(_ph0, 0.95)],
			"lod_moves_and_markers": [_q(_ph1, 0.5), _q(_ph1, 0.95)], "uploads": [_q(_ph2, 0.5), _q(_ph2, 0.95)]},
		"one_bird_tick_us": {"median_of_frame_medians": _q(_bird_med, 0.5), "p95_of_frame_medians": _q(_bird_med, 0.95),
			"largest": _q(_bird_max, 1.0)},
		"canary_before_us": [_q(_before, 0.5), _q(_before, 0.95)], "canary_after_us": [_q(_after, 0.5), _q(_after, 0.95)],
		"slow_frames": {"count": slow, "of": n, "canary_before_x_median": mean.call(r_before),
			"canary_after_x_median": mean.call(r_after), "bird_tick_x_median": mean.call(r_bird)},
		"p95_limit_us": P95_LIMIT, "pass": p95 < P95_LIMIT and _bad_lod == 0,
	}
	var f := FileAccess.open(Paths.artifacts("birds").path_join("xr_perf_%s.json" % rep["mode"]), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rep, "  "))
	print("[birds] xr perf (%s): sync median %d us, p95 %d, p99 %d, max %d; slow frames %d/%d: canary before x%.2f, after x%.2f, bird tick x%.2f; %s" % [
		rep["mode"], med, p95, rep["sync_us"]["p99"], rep["sync_us"]["max"], slow, n, rep["slow_frames"]["canary_before_x_median"],
		rep["slow_frames"]["canary_after_x_median"], rep["slow_frames"]["bird_tick_x_median"], "PASS" if rep["pass"] else "FAIL"])
	return rep["pass"]
