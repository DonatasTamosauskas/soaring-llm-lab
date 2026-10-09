extends TestCase
## Verifier probes (round 1) for AU1 (tuck loudness claim), AU3 (wingbeats
## at every size, with an XR rig), AU4 (danger release), AU5 (voices under a
## realistic scheduler with despawns, cost), AU6 (every game state, rapid
## pause toggles, slider edge values) and first-launch main-thread cost.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")

var fx: Fixture
var _saved := {}


func before_all() -> void:
	for k in AudioBuses.SETTING_DEFAULT:
		_saved[k] = Settings.get_value(k, AudioBuses.SETTING_DEFAULT[k])


func after_all() -> void:
	for k in _saved:
		Settings.set_value(k, _saved[k])


func before_each() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)


## A-weighting gain (linear power) at f Hz (IEC 61672).
static func _a_pow(f: float) -> float:
	if f < 10.0:
		return 0.0
	var f2 := f * f
	var ra := (12194.0 * 12194.0 * f2 * f2) / ((f2 + 20.6 * 20.6) * sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * (f2 + 12194.0 * 12194.0))
	var g := ra * 1.2589  # +2.0 dB normalisation at 1 kHz
	return g * g


static func _a_db(power: PackedFloat32Array, rate: float) -> float:
	var n := (power.size() - 1) * 2
	var s := 0.0
	for i in power.size():
		s += power[i] * _a_pow(i * rate / n)
	return 10.0 * log(maxf(s, 1e-30)) / log(10.0)


static func _z_db(power: PackedFloat32Array) -> float:
	var s := 0.0
	for i in range(1, power.size()):
		s += power[i]
	return 10.0 * log(maxf(s, 1e-30)) / log(10.0)


## AUDIO.md: "a tucked dive is brighter, thinner AND louder". Same speed,
## spread vs tucked, unweighted and A-weighted (closer to what ears hear).
func test_tuck_loudness_same_speed() -> void:
	var cap := fx.tap(AudioBuses.WIND)
	var cruise := FlightSoundMap.cruise(0.03)
	var res := {}
	for r in [1.0, 1.5, 2.6]:
		var row := {}
		for tucked in [false, true]:
			fx.set_tel({"airspeed": cruise * r, "tucked": tucked, "wing_extension": 0.1 if tucked else 1.0})
			await Fixture.wait(get_tree(), 0.6)
			var rec := await fx.record(get_tree(), cap, 0.8)
			var p := AudioAnalysis.mean_power(rec["mono"], 2048, 1024, -80.0)
			row["tucked" if tucked else "spread"] = {"rms_db": AudioAnalysis.db(AudioAnalysis.rms(rec["mono"])), "z_rel": _z_db(p), "a_rel": _a_db(p, rec["rate"])}
			AudioSynth.make_wav(rec["l"], rec["r"], int(rec["rate"])).save_to_wav(
				Paths.artifacts("audio/verify").path_join("wind_%.1fx_%s.wav" % [r, "tucked" if tucked else "spread"]))
		var da: float = row["tucked"]["a_rel"] - row["spread"]["a_rel"]
		var dz: float = row["tucked"]["rms_db"] - row["spread"]["rms_db"]
		row["delta_rms_db"] = dz
		row["delta_a_db"] = da
		res["%.1fx" % r] = row
		if r == 2.6:
			gt(da, 0.0, "2.6x: tucked dive A-weighted louder than spread at the same speed (dA %.1f dB, dRMS %.1f dB)" % [da, dz])
	metric("tuck_loudness", res)


## AU3 at every whoosh size, heaviest birds of each class (lowest pitch:
## slowest decay), several variants each: rendered decay < 300 ms.
func test_wingbeat_decay_every_size() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.BODY)
	var worst := {}
	for sp in [&"wren", &"swallow", &"starling", &"crow", &"gull", &"eagle"]:
		fx.player.mass = float(SizeRules.species_data(sp)["mass"])
		var w := 0.0
		for k in 3:
			cap.clear_buffer()
			Events.player_flapped.emit(-1, 1.0)
			var rec := await fx.record(get_tree(), cap, 0.6)
			var env := AudioAnalysis.envelope(rec["mono"], rec["rate"], 0.005)
			var pk := 0.0
			for e in env:
				pk = maxf(pk, e)
			var on := 0
			while on < env.size() and env[on] < pk * 0.1:
				on += 1
			var last := on
			for i in range(on, env.size()):
				if env[i] >= pk * 0.1:
					last = i
			var dec := (last - on + 1) * 0.005
			w = maxf(w, dec)
			lt(dec, 0.3, "%s flap %d: rendered envelope < 10%% of peak within 300 ms (%.3f s)" % [sp, k, dec])
			await Fixture.wait(get_tree(), 0.15)
		worst[String(sp)] = w
	metric("worst_decay_s", worst)


## Wingbeats with a real rig (group player_rig, LeftHand/RightHand) at a
## sparrow's world_scale: the whoosh follows the hand, left is left.
func test_wingbeat_follows_hands_with_rig() -> void:
	Game.set_state(Game.State.PLAYING)
	var rig := XROrigin3D.new()
	rig.name = "Rig"
	rig.add_to_group(&"player_rig")
	fx.root.add_child(rig)
	rig.global_position = Vector3(0, 100, 0)
	rig.world_scale = 0.15
	var lh := Node3D.new()
	lh.name = "LeftHand"
	rig.add_child(lh)
	lh.position = Vector3(-0.12, -0.03, -0.02)
	var rh := Node3D.new()
	rh.name = "RightHand"
	rig.add_child(rh)
	rh.position = Vector3(0.12, -0.03, -0.02)
	await wait_frames(2)
	var cap := fx.tap(AudioBuses.BODY)
	var res := {}
	for side in [-1, 1, 0]:
		cap.clear_buffer()
		Events.player_flapped.emit(side, 1.0)
		var rec := await fx.record(get_tree(), cap, 0.5)
		var l := AudioAnalysis.db(AudioAnalysis.rms(rec["l"]))
		var r := AudioAnalysis.db(AudioAnalysis.rms(rec["r"]))
		res[str(side)] = [l, r]
		await Fixture.wait(get_tree(), 0.2)
	var lft: Array = res["-1"]
	var rgt: Array = res["1"]
	var both: Array = res["0"]
	between(lft[0] - lft[1], 6.0, 20.0, "rig: left flap 6-20 dB louder on the left (%.1f)" % (lft[0] - lft[1]))
	between(rgt[1] - rgt[0], 6.0, 20.0, "rig: right flap 6-20 dB louder on the right (%.1f)" % (rgt[1] - rgt[0]))
	lt(absf(both[0] - both[1]), 3.0, "rig: both-wing flap centred within 3 dB (%.1f)" % (both[0] - both[1]))
	metric("rig_lr_db", res)


## AU4 continued: threat released to 0 -> the danger bus is silent soon
## after (no stuck heartbeat), and a different predator species works.
func test_danger_release_and_other_predator() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.DANGER)
	var gull := fx.add_npc(&"gull", Vector3(0, 100, 20))
	var dbs := []
	for lv in [0.1, 0.5, 0.9]:
		Events.threat_changed.emit(lv, gull)
		await Fixture.wait(get_tree(), 0.25)
		var rec := await fx.record(get_tree(), cap, 1.0 / FlightSoundMap.heart_rate(lv))
		dbs.append(AudioAnalysis.db(AudioAnalysis.rms(rec["mono"])))
	check(dbs[0] < dbs[1] and dbs[1] < dbs[2], "gull predator: danger rises with threat %s" % str(dbs))
	Events.threat_changed.emit(0.0, null)
	await Fixture.wait(get_tree(), 1.5)
	var after := await fx.record(get_tree(), cap, 0.5)
	var a_db := AudioAnalysis.db(AudioAnalysis.rms(after["mono"]))
	lt(a_db, -70.0, "threat cleared: danger silent 1.5 s later (%.1f dBFS)" % a_db)
	# Predator freed while the threat is still high, and GameLoop then clears.
	Events.threat_changed.emit(0.8, gull)
	await Fixture.wait(get_tree(), 0.3)
	fx.npcs.erase(gull)
	gull.queue_free()
	await wait_frames(3)
	Events.threat_changed.emit(0.0, null)
	await Fixture.wait(get_tree(), 1.5)
	var after2 := await fx.record(get_tree(), cap, 0.5)
	lt(AudioAnalysis.db(AudioAnalysis.rms(after2["mono"])), -70.0, "predator freed then cleared: silent")
	metric("danger_db", dbs)
	metric("released_db", a_db)


## AU5 with the director's own scheduler: 60 birds incl. moths spread over
## 250 m, all moving, world_scale 1.3 (a hawk-sized player), 12 s of play
## with birds despawning mid-call, then 3 s of pause (no new calls).
func test_voices_realistic_scheduler_with_despawns() -> void:
	Game.set_state(Game.State.PLAYING)
	var rig := XROrigin3D.new()
	rig.add_to_group(&"player_rig")
	fx.root.add_child(rig)
	rig.world_scale = 1.3
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var ladder := [&"moth", &"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var birds: Array[Bird] = []
	for i in 60:
		var sp: StringName = ladder[i % ladder.size()]
		var a := rng.randf() * TAU
		var d := rng.randf_range(3.0, 250.0)
		var b := fx.add_npc(sp, Vector3(cos(a) * d, 100.0 + rng.randf_range(-40.0, 30.0), sin(a) * d))
		if i % 7 == 0:
			b.state_str = "flee"
		elif i % 5 == 0:
			b.perched = true
		birds.append(b)
	var voices := fx.director.voices
	var children := voices.get_child_count()
	await wait_frames(2)
	fx.director.reset_perf()
	var busy_hist := {}
	var max_busy := 0
	var frames := 0
	var t := 0.0
	var removed := 0
	var stale_frames := 0
	while t < 12.0:
		var dt := get_process_delta_time()
		for b in birds:
			if is_instance_valid(b):
				b.global_position += Vector3(0.08, 0.0, 0.0).rotated(Vector3.UP, t * 0.3 + b.get_instance_id() % 7)
		# Every ~1 s one bird that is speaking right now leaves the game.
		# Removed the way Ecosystem._remove does it: alive = false, out of the
		# tree, queue_free (Birds.unregister emits bird_removed on exit).
		if frames % 60 == 30:
			for v in voices.voices:
				if not v.player.playing or v.fading or not is_instance_valid(v.bird):
					continue
				var vb: Bird = v.bird
				if vb.species != &"moth":
					birds.erase(vb)
					fx.npcs.erase(vb)
					vb.alive = false
					vb.get_parent().remove_child(vb)
					vb.queue_free()
					removed += 1
					break
		for v in voices.voices:
			if v.player.playing and not v.fading and typeof(v.bird) == TYPE_OBJECT and not is_instance_valid(v.bird):
				stale_frames += 1
		await get_tree().process_frame
		t += maxf(dt, 1.0 / 120.0)
		frames += 1
		var n := voices.active_count()
		max_busy = maxi(max_busy, n)
		busy_hist[n] = int(busy_hist.get(n, 0)) + 1
	var started_play: int = voices.stats["started"]
	var st := fx.director.perf_stats()
	Game.set_state(Game.State.PAUSED)
	await Fixture.wait(get_tree(), 3.0)
	var started_pause: int = voices.stats["started"] - started_play
	Game.set_state(Game.State.PLAYING)
	metric("busy_histogram", busy_hist)
	metric("stats", voices.stats)
	metric("removed_mid_call", removed)
	metric("voice_frames_holding_freed_bird", stale_frames)
	metric("perf", st)
	lt(max_busy, CallVoices.MAX_VOICES + 1, "never more than 8 voices (max %d)" % max_busy)
	eq(voices.get_child_count(), children, "pool unchanged (no players created or freed)")
	gt(started_play, 10.0, "the scheduler really called (%d starts in 12 s)" % started_play)
	gt(removed, 5.0, "birds despawned mid-call (%d)" % removed)
	# Moths only hold a voice within reach (5 perceived m); pause stops new calls.
	lt(started_pause, 1.0, "no new NPC calls start while paused (%d)" % started_pause)
	lt(st["median"], 0.2, "median director cost under 0.2 ms with a live scheduler (%.3f)" % st["median"])
	lt(st["mean"], 1.0, "raw mean director cost under 1 ms (%.3f)" % st["mean"])


## AU6 in every state: duck of SFX/Ambience relative to Settings, UI never
## ducked, muffle only in PAUSED; rapid pause toggling settles correctly.
func test_every_state_mix_and_rapid_toggles() -> void:
	Settings.set_value("sfx_volume", 1.0)
	Settings.set_value("ambience_volume", 1.0)
	Settings.set_value("ui_volume", 1.0)
	var sfx_i := AudioBuses.index(AudioBuses.SFX)
	var amb_i := AudioBuses.index(AudioBuses.AMBIENCE)
	var ui_i := AudioBuses.index(AudioBuses.UI)
	var mi := AudioBuses.effect_index(AudioBuses.SFX, "AudioEffectLowPassFilter")
	var res := {}
	for s in [Game.State.PLAYING, Game.State.MENU, Game.State.PAUSED, Game.State.CAUGHT, Game.State.ENDED]:
		Game.set_state(s)
		await Fixture.wait(get_tree(), 0.8)
		var row := {"sfx": AudioServer.get_bus_volume_db(sfx_i), "amb": AudioServer.get_bus_volume_db(amb_i),
			"ui": AudioServer.get_bus_volume_db(ui_i), "muffle": AudioServer.is_bus_effect_enabled(sfx_i, mi)}
		res[Game.state_name(s)] = row
		near(row["ui"], 0.0, 0.01, "%s: UI bus never ducked" % Game.state_name(s))
		var mix: Dictionary = AudioDirector.STATE_MIX[s]
		near(row["sfx"], mix["sfx"], 0.1, "%s: SFX at its state duck" % Game.state_name(s))
		eq(row["muffle"], s == Game.State.PAUSED, "%s: muffle only when paused" % Game.state_name(s))
	metric("state_mix", res)
	# Rapid toggles (a jittery menu button), ending in PLAYING.
	for i in 12:
		Game.set_state(Game.State.PAUSED if i % 2 == 0 else Game.State.PLAYING)
		await wait_frames(2)
	Game.set_state(Game.State.PLAYING)
	await Fixture.wait(get_tree(), 0.8)
	near(AudioServer.get_bus_volume_db(sfx_i), 0.0, 0.05, "after rapid toggles: SFX fully restored")
	eq(AudioServer.is_bus_effect_enabled(sfx_i, mi), false, "after rapid toggles: muffle off")
	# Slider edge values: > 1 clamps to 0 dB, < 0 mutes, master change in pause keeps the duck.
	Settings.set_value("sfx_volume", 1.7)
	await wait_frames(1)
	near(AudioServer.get_bus_volume_db(sfx_i), 0.0, 0.05, "sfx_volume 1.7 clamps to 0 dB")
	Settings.set_value("sfx_volume", -0.3)
	await wait_frames(1)
	check(AudioServer.is_bus_mute(sfx_i), "sfx_volume < 0 mutes")
	Settings.set_value("sfx_volume", 1.0)
	Game.set_state(Game.State.PAUSED)
	await Fixture.wait(get_tree(), 0.8)
	Settings.set_value("master_volume", 0.5)
	await wait_frames(1)
	near(AudioServer.get_bus_volume_db(sfx_i), -20.0, 0.1, "master change while paused keeps the SFX duck")
	near(AudioServer.get_bus_volume_db(AudioBuses.index(AudioBuses.MASTER)), -12.04, 0.05, "master 0.5 -> -12 dB")
	Game.set_state(Game.State.PLAYING)


## First launch: poll() writes each freshly synthesized clip to the disk
## cache on the MAIN thread. How long does one such save take? (Written to
## a private user:// folder; the shared cache is untouched.)
func test_first_launch_cache_save_cost() -> void:
	var bank := fx.director.bank
	var dir := "user://audio_verify_tmp"
	DirAccess.make_dir_recursive_absolute(dir)
	var costs := {}
	var worst := 0.0
	var worst_key := ""
	for job in bank.jobs():
		var key: StringName = job[0]
		var st := bank.get_stream(key)
		if st == null:
			continue
		var t0 := Time.get_ticks_usec()
		ResourceSaver.save(st, dir.path_join(String(key) + ".res"), ResourceSaver.FLAG_COMPRESS)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		costs[String(key)] = snappedf(ms, 0.01)
		if ms > worst:
			worst = ms
			worst_key = String(key)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	metric("save_ms", costs)
	metric("worst_save_ms", worst)
	metric("worst_save_key", worst_key)
	# Informational bound: one save should not blow a 72 Hz VR frame (13.9 ms).
	lt(worst, 13.9, "worst single cache save on the main thread (%s %.1f ms) fits in one 72 Hz frame" % [worst_key, worst])


## What a voice does when its bird is removed mid-sound, the Ecosystem's way
## (alive = false, removed from the tree, queue_free, all before the
## director's _process that frame), and when a moth is freed outright.
func test_voice_when_its_bird_is_despawned() -> void:
	Game.set_state(Game.State.PLAYING)
	var voices := fx.director.voices
	var hawk := fx.add_npc(&"hawk", Vector3(40, 100, 0))
	var moth := fx.add_npc(&"moth", Vector3(0.5, 100, 0))
	var moth2 := fx.add_npc(&"moth", Vector3(-0.5, 100, 0.3))
	await Fixture.wait(get_tree(), 0.5)
	check(voices.request_call(hawk, 30.0), "hawk call started")
	await wait_frames(3)
	var hv: CallVoices.Voice = null
	var mv: CallVoices.Voice = null
	var mv2: CallVoices.Voice = null
	for v in voices.voices:
		if v.bird == hawk and v.player.playing:
			hv = v
		if v.bird == moth and v.player.playing:
			mv = v
		if v.bird == moth2 and v.player.playing:
			mv2 = v
	check(hv != null, "hawk has a voice")
	check(mv != null and mv2 != null, "both moths have their flutter loops (in reach)")
	if hv == null or mv == null or mv2 == null:
		return
	var pos_before := hv.player.global_position
	# Ecosystem-style removal of the hawk and the first moth, at the start of
	# a frame (before any node's _process).
	await get_tree().process_frame
	for b in [hawk, moth]:
		fx.npcs.erase(b)
		b.alive = false
		b.get_parent().remove_child(b)
		b.queue_free()
	await wait_frames(4)
	var pos_after := hv.player.global_position
	metric("hawk_voice_pos_before", str(pos_before))
	metric("hawk_voice_pos_after", str(pos_after))
	lt(pos_after.distance_to(pos_before), 1.0, "a despawned bird's call stays where the bird was (moved %.1f m to %s)" % [pos_after.distance_to(pos_before), str(pos_after)])
	await Fixture.wait(get_tree(), 0.3)
	check(not mv.player.playing, "Ecosystem-removed moth: its flutter loop stopped")
	# The second moth is freed outright (a scene/ecosystem teardown).
	fx.npcs.erase(moth2)
	moth2.free()
	await Fixture.wait(get_tree(), 2.0)
	var still := mv2.player.playing and not mv2.fading
	metric("freed_moth_loop_still_playing_after_2s", still)
	check(not still, "a freed moth's flutter loop does not keep looping (still playing after 2 s: %s)" % still)


## STATE_MIX gives each state its own Ambience duck, but transitions between
## states with the SAME SFX duck (PLAYING <-> CAUGHT, MENU <-> PAUSED) must
## still land on the new state's Ambience level.
func test_ambience_duck_follows_every_transition() -> void:
	Settings.set_value("ambience_volume", 1.0)
	var amb_i := AudioBuses.index(AudioBuses.AMBIENCE)
	var got := {}
	for path in [[Game.State.PLAYING, Game.State.CAUGHT], [Game.State.CAUGHT, Game.State.PLAYING],
			[Game.State.PLAYING, Game.State.PAUSED], [Game.State.PAUSED, Game.State.MENU], [Game.State.MENU, Game.State.PAUSED]]:
		Game.set_state(path[0])
		await Fixture.wait(get_tree(), 0.8)
		Game.set_state(path[1])
		await Fixture.wait(get_tree(), 0.8)
		var want: float = AudioDirector.STATE_MIX[path[1]]["amb"]
		var have := AudioServer.get_bus_volume_db(amb_i)
		var tag := "%s->%s" % [Game.state_name(path[0]), Game.state_name(path[1])]
		got[tag] = [have, want]
		near(have, want, 0.1, "%s: Ambience bus at the new state's duck (%.1f, want %.1f)" % [tag, have, want])
	metric("ambience_after_transition", got)
	Game.set_state(Game.State.PLAYING)
