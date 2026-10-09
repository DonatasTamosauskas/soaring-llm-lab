extends TestCase
## Round-5 engineering verifier diagnostic (not part of the suite): where the
## wall time goes around a 60-bird director stage. Finding: thousands of
## back-to-back _process calls inside ONE engine frame (as a test's tight
## loop does), with the danger layers changing level, leave a stall of
## 0.1-5 s in the following engine frames, outside every node's _process
## (the stamps show the gap after process ends, before the next physics
## step), and it scales with the number of player volume writes queued in
## that frame (dropping either danger layer shrinks it). That points at the
## engine's per-frame AudioServer bookkeeping of replaced playback bus
## details, not at audio's code: at one _process per frame (the game) the
## frames stay fast. test_engine_volume_writes_in_one_frame reproduces it
## with no director at all (one bare player: 2000 / 8000 / 16000 volume_db
## writes in a frame -> the next frames take 36 ms / 0.54 s / 2.0 s, i.e.
## quadratic). Flags: --calls=N --threat=0|1 --no_haptics=1
## --no_heart=1 --no_screech=1 --no_listener=1 --keep=level|bird
## --drop=heart|drone.
##
##   tools/gd.sh audio_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=r5eng_diag

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")


## Stamps the start (priority -1000) or end (+1000) of process, or the
## physics step, into a shared log.
class Stamp:
	extends Node
	var tag := ""
	var log: Array = []
	var physics := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		set_physics_process(physics)
		set_process(not physics)

	func _process(_d: float) -> void:
		log.append([tag, Time.get_ticks_usec()])

	func _physics_process(_d: float) -> void:
		log.append([tag, Time.get_ticks_usec()])

var fx: Fixture


func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


func test_phases() -> void:
	Game.set_state(Game.State.PLAYING)
	var t := Time.get_ticks_usec()
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	var phases := {"build": _ms(t)}
	t = Time.get_ticks_usec()
	var birds: Array[Bird] = []
	for i in 60:
		birds.append(fx.add_npc([&"wren", &"crow", &"hawk"][i % 3], Vector3(i * 2.0, 100, -5)))
	phases["add_60"] = _ms(t)
	t = Time.get_ticks_usec()
	fx.director.set_process(false)
	for i in 1000:
		fx.director._process(1.0 / 72.0)
	phases["process_1000_frozen"] = _ms(t)
	t = Time.get_ticks_usec()
	for i in 1000:
		for b in birds:
			b.global_position += Vector3(0.01, 0, 0)
	phases["move_60_birds_1000x"] = _ms(t)
	t = Time.get_ticks_usec()
	for i in 1000:
		fx.set_tel({"airspeed": 9.0 + (i % 10)})
	phases["set_tel_1000x"] = _ms(t)
	t = Time.get_ticks_usec()
	var arr := PackedFloat32Array()
	for i in 1000:
		arr.append(fmod(i * 0.618, 1.0))
	var t2 := Time.get_ticks_usec()
	AudioAnalysis.median(arr)
	phases["median_1000"] = _ms(t2)
	fx.director.set_process(true)
	t = Time.get_ticks_usec()
	await wait_frames(10)
	phases["10_frames_after"] = _ms(t)
	t = Time.get_ticks_usec()
	fx.teardown()
	phases["teardown"] = _ms(t)
	t = Time.get_ticks_usec()
	await wait_frames(10)
	phases["10_frames_after_teardown"] = _ms(t)
	metric("phases_ms", phases)
	print("[audio] r5eng diag phases: %s" % [phases])
	check(true, "diagnostic only")


## The cost probe's exact stage, each phase timed.
func test_cost_stage_phases() -> void:
	Game.set_state(Game.State.PLAYING)
	var ph := {}
	var t := Time.get_ticks_usec()
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	ph["build"] = _ms(t)
	t = Time.get_ticks_usec()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var marks: Array[Dictionary] = []
	var kinds := ["forest", "lake", "town", "meadow", "field", "orchard", "farm", "hedge"]
	for i in 40:
		marks.append({"name": "m%d" % i, "kind": kinds[i % kinds.size()], "radius": rng.randf_range(20, 150),
			"position": Vector3(rng.randf_range(-400, 400), 0, rng.randf_range(-400, 400))})
	fx.add_world(marks)
	fx.player.global_position = Vector3(0, 10, 0)
	fx.listener.global_position = Vector3(0, 10, 0)
	ph["world"] = _ms(t)
	t = Time.get_ticks_usec()
	var species := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	for i in 60:
		var a := rng.randf() * TAU
		var dd := 2.0 + 2.2 * i
		fx.add_npc(species[i % species.size()], Vector3(cos(a) * dd, 100.0, sin(a) * dd))
	ph["birds"] = _ms(t)
	t = Time.get_ticks_usec()
	await wait_frames(1)
	ph["frame1"] = _ms(t)
	t = Time.get_ticks_usec()
	await Fixture.wait(get_tree(), 0.2)
	ph["wait_0.2"] = _ms(t)
	t = Time.get_ticks_usec()
	for i in 30:
		await get_tree().process_frame
	ph["30_frames"] = _ms(t)
	ph["director_perf"] = fx.director.perf_stats()
	t = Time.get_ticks_usec()
	fx.teardown()
	ph["teardown"] = _ms(t)
	t = Time.get_ticks_usec()
	await wait_frames(5)
	ph["5_frames_after"] = _ms(t)
	metric("cost_stage_phases_ms", ph)
	print("[audio] r5eng cost-stage phases: %s" % [ph])
	check(true, "diagnostic only")


## The cost probe's 4000 back-to-back _process calls, then each part of the
## next _process timed on its own, then the next real frame.
func test_stall_after_burst() -> void:
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var species := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var birds: Array[Bird] = []
	for i in 60:
		var a := rng.randf() * TAU
		var dd := 2.0 + 2.2 * i
		birds.append(fx.add_npc(species[i % species.size()], Vector3(cos(a) * dd, 100.0, sin(a) * dd)))
	var hawk: Bird = birds[7]
	await Fixture.wait(get_tree(), 0.2)
	var d := fx.director
	d.set_process(false)
	# --no_haptics=1: take VR's haptics off the threat event (another
	# area's listener) to see whose frame stalls.
	if Paths.arg("no_haptics", "0") == "1":
		var hp: Node = VR.get("haptics")
		if hp and Events.threat_changed.is_connected(Callable(hp, "_on_threat_changed")):
			Events.threat_changed.disconnect(Callable(hp, "_on_threat_changed"))
	# --no_listener=1: the director does not hear the threat either.
	if Paths.arg("no_listener", "0") == "1":
		Events.threat_changed.disconnect(d._on_threat_changed)
	var ev := {}
	var conns := []
	for c in Events.threat_changed.get_connections():
		var cb: Callable = c["callable"]
		conns.append("%s.%s" % [cb.get_object().get_class() if cb.get_object() else "?", cb.get_method()])
	ev["threat_listeners"] = conns
	var n_calls := int(Paths.arg("calls", "4000"))
	var with_threat := Paths.arg("threat", "1") == "1"
	# --no_heart=1: the heartbeat generator is not fed during the burst.
	if Paths.arg("no_heart", "0") == "1":
		d._heart_pb = null
	# --drop=heart|drone: that layer's player is removed from the director's
	# layer list before the burst (never touched again).
	var drop := Paths.arg("drop", "")
	if drop == "heart":
		d._layers.erase(d._heart)
		d._heart.player.stop()
		d._heart_pb = null
		d._heart = d.Layer.new()
		d._heart.player = AudioStreamPlayer.new()
		d.add_child(d._heart.player)
	elif drop == "drone":
		d._layers.erase(d._drone)
		d._drone.player.stop()
		d._drone = d.Layer.new()
		d._drone.player = AudioStreamPlayer.new()
		d.add_child(d._drone.player)
	# --no_screech=1: no screech (a cooldown that never runs out).
	var no_screech := Paths.arg("no_screech", "0") == "1"
	var t := Time.get_ticks_usec()
	for i in n_calls:
		if no_screech:
			d._screech_cool = 1e9
		if with_threat and i % 18 == 0:
			Events.threat_changed.emit(absf(sin(i / 24.0)), hawk)
			# --keep=level: the danger layers only; --keep=bird: the voices' threat only.
			if Paths.arg("keep", "") == "level":
				d.threat_bird = null
				d._threat_has_bird = false
			elif Paths.arg("keep", "") == "bird":
				d.threat_level = 0.0
		d._process(1.0 / 72.0)
	ev["burst_ms"] = _ms(t)
	ev["voices_stats"] = d.voices.stats.duplicate()
	var parts := {}
	t = Time.get_ticks_usec()
	d.bank.poll()
	parts["bank_poll"] = _ms(t)
	t = Time.get_ticks_usec()
	d._attach_streams()
	parts["attach"] = _ms(t)
	t = Time.get_ticks_usec()
	d._apply_state_mix(false, 0.016)
	parts["state_mix"] = _ms(t)
	t = Time.get_ticks_usec()
	var lst: Transform3D = d._listener_transform()
	parts["listener"] = _ms(t)
	t = Time.get_ticks_usec()
	d._update_flight(0.016, Birds.player(), lst)
	parts["flight"] = _ms(t)
	t = Time.get_ticks_usec()
	d._update_danger(0.016)
	parts["danger"] = _ms(t)
	t = Time.get_ticks_usec()
	d.voices.tick(0.016, lst.origin, 1.0)
	parts["voices"] = _ms(t)
	t = Time.get_ticks_usec()
	d.ambience.tick(0.016, lst.origin, 1.0, 0.0)
	parts["ambience"] = _ms(t)
	ev["parts_ms"] = parts
	var stamps: Array = []
	for spec in [["first", -1000, false], ["last", 1000, false], ["phys", 0, true]]:
		var st := Stamp.new()
		st.tag = spec[0]
		st.process_priority = spec[1]
		st.process_physics_priority = spec[1]
		st.physics = spec[2]
		st.log = stamps
		add_child(st)
	var pf0 := Engine.get_physics_frames()
	t = Time.get_ticks_usec()
	await get_tree().process_frame
	ev["next_frame_director_off_ms"] = _ms(t)
	ev["physics_frames_in_it"] = Engine.get_physics_frames() - pf0
	ev["perf_process_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	ev["perf_physics_ms"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	ev["audio_latency_ms"] = Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY) * 1000.0
	t = Time.get_ticks_usec()
	await get_tree().process_frame
	ev["frame2_director_off_ms"] = _ms(t)
	d.set_process(true)
	t = Time.get_ticks_usec()
	await get_tree().process_frame
	ev["frame_director_on_ms"] = _ms(t)
	t = Time.get_ticks_usec()
	await get_tree().process_frame
	ev["frame2_director_on_ms"] = _ms(t)
	var t_base: int = stamps[0][1] if not stamps.is_empty() else 0
	var trace := []
	for e in stamps:
		trace.append("%s@%.1f" % [e[0], (e[1] - t_base) / 1000.0])
	ev["trace_ms"] = trace
	metric("stall", ev)
	print("[audio] r5eng stall: %s" % [ev])
	fx.teardown()
	check(true, "diagnostic only")


## Engine only, no director: N volume writes to one playing player inside
## one frame, then the next frames timed (--writes=N).
func test_engine_volume_writes_in_one_frame() -> void:
	var p := AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	p.stream = gen
	add_child(p)
	p.play()
	await wait_frames(3)
	var n := int(Paths.arg("writes", "8000"))
	var t := Time.get_ticks_usec()
	for i in n:
		p.volume_db = -10.0 - float(i % 7)
	var ev := {"writes": n, "write_ms": _ms(t)}
	t = Time.get_ticks_usec()
	await get_tree().process_frame
	ev["next_frame_ms"] = _ms(t)
	t = Time.get_ticks_usec()
	await get_tree().process_frame
	ev["frame2_ms"] = _ms(t)
	print("[audio] r5eng engine writes: %s" % [ev])
	metric("engine_writes", ev)
	p.stop()
	p.queue_free()
	check(true, "diagnostic only")
