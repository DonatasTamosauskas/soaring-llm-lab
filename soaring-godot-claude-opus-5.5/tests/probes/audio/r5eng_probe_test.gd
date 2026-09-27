extends TestCase
## Round-5 engineering verifier probes for the audio area (not part of the
## suite). Each probe checks a claim the builder makes that the suite does
## not pin, or pins only in a narrower form:
##  * the rig path: in the game the world scale comes from the XROrigin3D in
##    group player_rig and wingbeats play at its LeftHand/RightHand; no suite
##    test builds a rig;
##  * the per-frame cost with the flight changing on every call (the suite's
##    tight loop repeats one frozen state);
##  * silent layers and beds are paused (the Quest mixing-cost claim);
##  * the contract surface: group, process mode, API, shipped bus layout;
##  * the director keeps processing while the tree is paused;
##  * shutdown() stops everything and leaves no errors.
##
##   tools/gd.sh audio_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=r5eng

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")

var fx: Fixture
## Buses as Godot loaded them before any director ran ensure() (the
## shipped default_bus_layout.tres).
var _boot_buses := {}


func before_all() -> void:
	for i in AudioServer.bus_count:
		var effects: Array[String] = []
		for e in AudioServer.get_bus_effect_count(i):
			effects.append(AudioServer.get_bus_effect(i, e).get_class())
		_boot_buses[String(AudioServer.get_bus_name(i))] = {"send": String(AudioServer.get_bus_send(i)), "effects": effects}


func before_each() -> void:
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.05)


func after_all() -> void:
	await Fixture.wait(get_tree(), 0.15)


# --------------------------------------------------------------- contract ---

func test_contract_surface() -> void:
	# The shipped layout is what Godot loads at startup (before any ensure()).
	var want := {"Master": ["", ["AudioEffectHardLimiter"]], "Music": ["Master", []], "SFX": ["Master", ["AudioEffectLowPassFilter"]],
		"Wind": ["SFX", ["AudioEffectHighPassFilter", "AudioEffectLowPassFilter", "AudioEffectPanner"]], "Body": ["SFX", []],
		"Calls": ["SFX", []], "Danger": ["SFX", []], "Ambience": ["Master", ["AudioEffectLowPassFilter"]], "UI": ["Master", []]}
	metric("boot_buses", _boot_buses)
	eq(_boot_buses.size(), 9, "default_bus_layout.tres gives 9 buses at startup (%s)" % [_boot_buses.keys()])
	for b in want:
		check(_boot_buses.has(b), "bus %s exists at startup" % b)
		if not _boot_buses.has(b):
			continue
		if b != "Master":
			eq(_boot_buses[b]["send"], want[b][0], "%s sends to %s" % [b, want[b][0]])
		eq(_boot_buses[b]["effects"], want[b][1], "%s effects as documented" % b)
	var lim := AudioServer.get_bus_effect(0, 0) as AudioEffectHardLimiter
	check(lim != null and is_equal_approx(lim.ceiling_db, -1.5), "Master limiter ceiling -1.5 dB")
	# The scene root: group and process mode come from the scene itself.
	var packed := load(Fixture.DIRECTOR) as PackedScene
	var inst := packed.instantiate()
	eq(inst.process_mode, Node.PROCESS_MODE_ALWAYS, "audio_director.tscn root is PROCESS_MODE_ALWAYS")
	check(inst.is_in_group(&"audio_director"), "audio_director.tscn root is in group audio_director")
	check(inst is AudioDirector, "the root is an AudioDirector")
	inst.free()
	var d := fx.director
	eq(get_tree().get_first_node_in_group(&"audio_director"), d, "found through its group")
	# API documented in ARCHITECTURE (audio contract notes).
	var methods := {}
	for m in d.get_method_list():
		methods[m["name"]] = m["args"].size()
	for m in ["play_ui", "shutdown", "debug_snapshot", "perf_stats"]:
		check(methods.has(m), "API %s() exists" % m)
	eq(methods.get("play_ui", -1), 2, "play_ui(kind, volume_db = NAN)")
	var has_cue := false
	for s in d.get_signal_list():
		if s["name"] == "cue":
			has_cue = s["args"].size() == 2
	check(has_cue, "signal cue(name, info)")
	var snap := d.debug_snapshot()
	for k in ["amb_speed_duck_db", "cue_duck_db", "voices", "threat", "duck_db"]:
		check(snap.has(k), "debug_snapshot() has %s" % k)
	check(d.perf_stats().has("p25"), "perf_stats() has p25")
	check("settings" in d, "AudioDirector.settings exists")
	# Audio never emits on the Events bus (facts come from other areas).
	var emitters := []
	for f in DirAccess.get_files_at("res://scripts/audio"):
		if f.ends_with(".gd"):
			var src := FileAccess.get_file_as_string("res://scripts/audio/" + f)
			if RegEx.create_from_string("Events\\.[a-z_]+\\.emit").search(src) != null:
				emitters.append(f)
	eq(emitters.size(), 0, "no audio script emits on Events (%s)" % [emitters])


## Pause freezes gameplay, not the director: it and every player under it
## keep processing (a paused AudioStreamPlayer would cut the music and UI).
func test_director_keeps_running_while_tree_paused() -> void:
	fx.set_tel({"airspeed": 12.0})
	await Fixture.wait(get_tree(), 0.2)
	Game.set_state(Game.State.PAUSED)
	check(get_tree().paused, "Game PAUSED pauses the tree")
	var f0 := fx.director.perf_frames
	await wait_frames(5)
	gt(float(fx.director.perf_frames - f0), 3.0, "the director's _process runs while the tree is paused")
	var cannot: Array[String] = []
	for n in fx.director.find_children("*", "", true, false):
		if (n is AudioStreamPlayer or n is AudioStreamPlayer3D) and not n.can_process():
			cannot.append(String(n.name))
	eq(cannot.size(), 0, "every player under the director keeps processing while paused (%s)" % [cannot])
	check(fx.director._wind_body.player.playing and not fx.director._wind_body.player.stream_paused, "the wind keeps playing (ducked) in pause")
	Game.set_state(Game.State.PLAYING)


## As in the game: the director under a PAUSABLE parent (Main is
## pausable; the test runner is PROCESS_MODE_ALWAYS, so every suite test
## inherits ALWAYS and cannot tell). Paused, the director must still run
## its ducks, play the music and the pause-menu UI sounds.
func test_pause_under_a_pausable_parent() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.05)
	var game := Node.new()
	game.name = "PausableMain"
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(game)
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(game)
	await wait_frames(2)
	fx.set_tel({"airspeed": 12.0})
	var ui := fx.tap(AudioBuses.UI)
	var music := fx.tap(AudioBuses.MUSIC)
	await Fixture.wait(get_tree(), 0.2)
	Game.set_state(Game.State.PAUSED)
	var f0 := fx.director.perf_frames
	await Fixture.wait(get_tree(), 0.6)
	gt(float(fx.director.perf_frames - f0), 5.0, "pausable parent: the director keeps processing in pause")
	near(fx.director._duck_db, -20.0, 0.5, "pausable parent: the pause duck ramps to -20 dB (%.1f)" % fx.director._duck_db)
	ui.clear_buffer()
	fx.director.play_ui(&"select", 0.0)
	var rec := await fx.record(get_tree(), ui, 0.25)
	gt(AudioAnalysis.peak(rec["mono"]), 0.05, "pausable parent: a UI sound plays in the pause menu")
	var m := await fx.record(get_tree(), music, 0.3)
	gt(AudioAnalysis.db(AudioAnalysis.rms(m["mono"])), -45.0, "pausable parent: the music plays in the pause menu")
	Game.set_state(Game.State.PLAYING)
	fx.teardown()
	game.queue_free()


# --------------------------------------------------------------- rig path ---

func _rig(ws: float) -> XROrigin3D:
	var rig := XROrigin3D.new()
	rig.name = "Rig"
	rig.add_to_group(&"player_rig")
	fx.root.add_child(rig)
	rig.global_position = Vector3(0, 100, 0)
	rig.world_scale = ws
	for side in [["LeftHand", -1.0], ["RightHand", 1.0]]:
		var h := Node3D.new()
		h.name = side[0]
		rig.add_child(h)
		h.position = Vector3(0.3 * side[1], -0.1, -0.2)
	return rig


## In the game the rig's world_scale rules (the telemetry's copy is only the
## fallback), and each wingbeat plays at its own hand.
func test_rig_world_scale_and_hands() -> void:
	fx.set_tel({"airspeed": 9.0, "world_scale": 1.0})
	var rig := _rig(0.14)
	# The director looks the rig up twice a second.
	fx.director._rig_check = 0
	await wait_frames(3)
	near(fx.director.voices.world_scale, 0.14, 1e-4, "the voices use the rig's world_scale (not telemetry's 1.0)")
	near(fx.director._last_ws, 0.14, 1e-4, "the director's world scale is the rig's")
	var lh := rig.get_node("LeftHand") as Node3D
	var rh := rig.get_node("RightHand") as Node3D
	var pos := {}
	for side in [-1, 1]:
		var before := fx.director._whoosh_i
		Events.player_flapped.emit(side, 1.0)
		var w: AudioStreamPlayer3D = fx.director._whoosh[before]
		pos[side] = w.global_position
		check(w.playing, "flap %d: a whoosh voice plays" % side)
	vnear(pos[-1], lh.global_position, 1e-4, "a left flap plays at the LeftHand")
	vnear(pos[1], rh.global_position, 1e-4, "a right flap plays at the RightHand")
	# Growth mid-flight: the rig's scale changes, the voices follow within
	# half a second.
	rig.world_scale = 1.3
	await Fixture.wait(get_tree(), 0.6)
	near(fx.director.voices.world_scale, 1.3, 1e-4, "the voices follow the rig's world_scale as the player grows")


# ------------------------------------------------------------------- cost ---

## Per-call CPU cost of _process when the flight changes on every call (as
## in a real frame) against the suite's tight loop, which repeats one frozen
## state. Best-of-5 blocks of 200 calls both; only _process is timed.
func test_cost_with_flight_changing_every_call() -> void:
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
	var species := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var birds: Array[Bird] = []
	for i in 60:
		var a := rng.randf() * TAU
		var dd := 2.0 + 2.2 * i
		birds.append(fx.add_npc(species[i % species.size()], Vector3(cos(a) * dd, 100.0, sin(a) * dd)))
	var hawk: Bird = birds[7]
	var t_setup := Time.get_ticks_usec()
	await Fixture.wait(get_tree(), 0.2)
	var wall := {"settle_0.2s": (Time.get_ticks_usec() - t_setup) / 1000.0}
	fx.director.set_process(false)
	var frame := [0]
	var change := func() -> void:
		var t: float = frame[0] / 24.0
		fx.set_tel({"airspeed": 9.0 + 8.0 * sin(t), "tucked": sin(t) > 0.5, "wing_extension": 0.5 + 0.5 * cos(t),
			"stalled": frame[0] % 40 < 6, "in_updraft": maxf(0.0, 3.0 * sin(t * 0.7))})
		fx.player.velocity = Vector3(sin(t), 0, -cos(t)) * 9.0
		fx.listener.rotation.y = 0.3 * sin(t * 0.5)
		if frame[0] % 18 == 0:
			Events.threat_changed.emit(absf(sin(t)), hawk)
		for b in birds:
			b.global_position += Vector3(0.05, 0, 0).rotated(Vector3.UP, t)
		frame[0] += 1
	var res := {}
	for mode in ["frozen", "changing", "frozen_again", "changing_again"]:
		var t_mode := Time.get_ticks_usec()
		var best := INF
		var all := PackedFloat32Array()
		for block in 5:
			var sum := 0
			for i in 200:
				if mode.begins_with("changing"):
					change.call()
				var t0 := Time.get_ticks_usec()
				fx.director._process(1.0 / 72.0)
				var us := Time.get_ticks_usec() - t0
				sum += us
				all.append(us / 1000.0)
			best = minf(best, sum / 200.0 / 1000.0)
		res[mode] = {"best_block_mean_ms": best, "median_ms": AudioAnalysis.median(all)}
		wall[mode] = (Time.get_ticks_usec() - t_mode) / 1000.0
	fx.director.set_process(true)
	metric("cost", res)
	print("[audio] r5eng cost: %s" % [res])
	print("[audio] r5eng cost wall ms: %s" % [wall])
	metric("wall_ms", wall)
	var changing := minf(res["changing"]["best_block_mean_ms"], res["changing_again"]["best_block_mean_ms"])
	var frozen := minf(res["frozen"]["best_block_mean_ms"], res["frozen_again"]["best_block_mean_ms"])
	metric("changing_over_frozen", changing / maxf(frozen, 1e-6))
	# The brief's bar on the Mac and a Quest-extrapolated one (3-4x slower).
	lt(changing, 1.0, "AU5: mean cost with flight changing every call under 1 ms (%.3f ms)" % changing)
	lt(changing * 4.0, 1.0, "extrapolated to a Quest (4x): under 1 ms (%.3f ms here)" % changing)
	var t_end := Time.get_ticks_usec()
	Events.threat_changed.emit(0.0, null)
	await wait_frames(1)
	wall["threat_clear_and_frame"] = (Time.get_ticks_usec() - t_end) / 1000.0
	t_end = Time.get_ticks_usec()
	fx.teardown()
	wall["teardown"] = (Time.get_ticks_usec() - t_end) / 1000.0
	print("[audio] r5eng cost tail ms: %s" % [wall])


# ----------------------------------------------------------- idle pausing ---

## "Silent ones paused": a layer or bed with nothing to play costs no mixing.
func test_silent_layers_and_beds_are_paused() -> void:
	# Cruise, no stall, no lift, no threat: the buffet, hum, heart and drone
	# have nothing to play. 100 m up (fixture): every bed is silent.
	fx.set_tel({"airspeed": 9.0, "stalled": false, "in_updraft": 0.0})
	fx.add_world([{"name": "wood", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 80.0}])
	await Fixture.wait(get_tree(), 1.6)
	var d := fx.director
	var st := {}
	for l in d._layers:
		st[String(l.key)] = {"gain": l.gain, "stream_paused": l.player.stream_paused, "playing": l.player.playing}
	for key in d.ambience._players:
		var p: AudioStreamPlayer = d.ambience._players[key]["player"]
		st["bed." + String(key)] = {"gain": d.ambience._players[key]["gain"], "stream_paused": p.stream_paused, "playing": p.playing}
	metric("idle_states", st)
	for k in ["stall_flutter", "updraft_hum", "drone", "heartbeat"]:
		check(bool(st[k]["stream_paused"]) or not bool(st[k]["playing"]), "%s is silent and paused (%s)" % [k, st[k]])
	check(not bool(st["wind_body"]["stream_paused"]), "the wind body plays at cruise")
	for key in d.ambience._players:
		var e: Dictionary = st["bed." + String(key)]
		check(float(e["gain"]) > 0.0 or bool(e["stream_paused"]) or not bool(e["playing"]), "bed %s: silent 100 m up and not mixing (%s)" % [key, e])


# --------------------------------------------------------------- shutdown ---

func test_shutdown_stops_everything_cleanly() -> void:
	var log := ErrorLog.install()
	fx.set_tel({"airspeed": 20.0, "stalled": true, "in_updraft": 3.0})
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, -20))
	fx.add_npc(&"moth", Vector3(0.3, 100, 0))
	Events.threat_changed.emit(0.9, hawk)
	Events.player_flapped.emit(0, 1.0)
	Events.bird_caught.emit(fx.player, fx.add_npc(&"wren", Vector3(0, 100, -1)))
	fx.director.play_ui(&"click")
	await Fixture.wait(get_tree(), 0.4)
	await fx.director.shutdown()
	var still: Array[String] = []
	for n in fx.director.find_children("*", "", true, false):
		if (n is AudioStreamPlayer or n is AudioStreamPlayer3D) and n.playing:
			still.append(String(n.name))
	eq(still.size(), 0, "shutdown() stops every player (%s)" % [still])
	log.uninstall()
	eq(log.errors, 0, "no errors (%s)" % [log.samples])
