extends TestCase
## Bad input from outside never breaks the mix. Round 4's major defect: one
## NaN wing_extension (flight's own code anticipates NaN wing states from a
## glitching tracker, and telemetry is built from the raw state) turned the
## wind layers' smoothed gains and the wind's filter state into NaN for the
## rest of the session: the wind, the main speed cue in VR, silent for good.
## A NaN lift or stall warning killed the hum or the buffet, a NaN threat
## the danger cue.
##
## Every input the audio area takes from other areas is fed NaN, +INF,
## -INF, +1e30 and -1e30 for a few frames, then normal values again:
##  * telemetry (every key), the player's mass and velocity, the threat
##    level, flap strength, collision impact, a caught prey's mass, a UI
##    sound's level, the camera (listener) position, an NPC's position,
##    every Settings volume, the World's ground height and landmarks, and
##    the frame delta;
##  * nothing the audio writes to the engine (player volumes, pitches,
##    positions, distances and shelves, bus faders, the wind's filters and
##    panner) is ever non-finite, during the bad frames or after;
##  * 0.5 s after normal input resumes, every layer, bus fader, filter and
##    duck is back within 1.5 dB of where it was before (none silenced);
##  * the second line of defence on its own: every smoothed state set to
##    NaN at once restarts from its target within a frame;
##  * on the real mixer, after a burst of every bad value at once, no
##    sample is non-finite and the wind, body, danger and ambience buses
##    play at their levels again.
## The director is stepped frame by frame (_process with a fixed 1/60 s)
## for the 120 cases, so they cost well under a second; one short stretch
## of real-time mixing checks the engine's output.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")
## Not a number, both infinities and absurd magnitudes.
const BAD := [NAN, INF, -INF, 1.0e30, -1.0e30]
const DT := 1.0 / 60.0
## "A few frames" of bad input, then 0.5 s of normal input.
const BAD_FRAMES := 4
const RECOVER_FRAMES := 30
## How close to its level before every state must be 0.5 s later (dB).
## NaN and the infinities take safe defaults and barely move anything; an
## absurd finite value is clamped to the sane range and played as that
## extreme (so is a mass the Bird itself clamps to 0.001 kg): 4 frames at
## 4x cruise lift the wind 6-10 dB, and the layers' designed 0.18 s release
## leaves up to about 1.4 dB of that after 0.5 s.
const TOL_DB := 1.5
## Normal flight: a fast glide at 1.5x cruise (every wind layer sounding:
## at 1.2x the edge layer is 36 dB down, where a dB comparison measures
## nothing audible and a 0.18 s release from a 20 dB excursion takes 0.7 s
## to come within 1.5 dB), some stall warning (buffet) and lift (hum), a
## hawk at threat 0.5 (heart and drone), low over a forest.
const GOOD_SPEED := 1.5
const GOOD_THREAT := 0.5
const GOOD_VOLUME := 0.7

var fx: Fixture
var good := {}
var hawk: Bird
var crow: Bird
var prey: Bird
var prey_mass := 0.0


func before_each() -> void:
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await get_tree().process_frame


func after_all() -> void:
	await Fixture.wait(get_tree(), 0.15)


# ------------------------------------------------------ pure functions ---

## The boundary helpers and every pure function the director feeds from
## outside return finite values for any input.
func test_pure_functions_are_total() -> void:
	var junk: Array = BAD.duplicate()
	junk.append_array([null, "0.5", Vector3.ONE, 1e300])
	var bad_out: Array[String] = []
	for v in junk:
		var n := AudioInput.num(v, 0.25, 0.0, 1.0)
		if not (is_finite(n) and n >= 0.0 and n <= 1.0):
			bad_out.append("num(%s) = %s" % [v, n])
		if AudioInput.flag(NAN):
			bad_out.append("flag(NAN) is true")
	near(AudioInput.num(NAN, 0.25, 0.0, 1.0), 0.25, 0.0, "a NaN takes the fallback")
	near(AudioInput.num(1e30, 0.25, 0.0, 1.0), 1.0, 0.0, "an absurd number is clamped")
	near(AudioInput.num(-INF, 0.25, 0.0, 1.0), 0.25, 0.0, "an infinity takes the fallback")
	check(not AudioInput.position_ok(Vector3(0, NAN, 0)) and not AudioInput.position_ok(Vector3(1e30, 0, 0))
		and AudioInput.position_ok(Vector3(500, 20, -300)), "positions: NaN and absurd ones refused, real ones kept")
	var tel := {"airspeed": 11.0, "wing_extension": 0.8, "tucked": false, "stalled": false, "stall_warning": 0.3,
		"perched": false, "in_updraft": 1.5, "world_scale": 0.3}
	var cases := 0
	for key in tel:
		for v in BAD:
			var t := tel.duplicate()
			t[key] = v
			for k2 in [0.0, 13.0]:
				var p := FlightSoundMap.compute(t, 0.03, 0.2, k2)
				cases += 1
				for pk in p:
					if not is_finite(float(p[pk])):
						bad_out.append("compute(%s=%s).%s = %s" % [key, v, pk, p[pk]])
	for v in BAD:
		for p in [FlightSoundMap.compute(tel, v, 0.0), FlightSoundMap.compute(tel, 0.03, v), FlightSoundMap.compute({}, 0.03, 0.0, v)]:
			cases += 1
			for pk in p:
				if not is_finite(float(p[pk])):
					bad_out.append("compute(mass/rel/fallback=%s).%s = %s" % [v, pk, p[pk]])
		var singles := {
			"heart_db": FlightSoundMap.heart_db(v), "drone_db": FlightSoundMap.drone_db(v),
			"heart_rate": FlightSoundMap.heart_rate(v), "heart_dub": FlightSoundMap.heart_dub(v),
			"whoosh_db": FlightSoundMap.whoosh_db(v), "whoosh_pitch": FlightSoundMap.whoosh_pitch(v),
			"catch_duck_db": FlightSoundMap.catch_duck_db(v), "body_db": FlightSoundMap.body_db(v, v),
			"cruise": FlightSoundMap.cruise(v), "flutter_pitch": FlightSoundMap.flutter_pitch(v),
			"threat_floor_db": CallVoices.threat_floor_db(v), "air_absorption_db": CallVoices.air_absorption_db(v),
			"audibility": CallVoices.audibility(&"hawk", v), "volume_to_db": AudioBuses.volume_to_db(AudioInput.num(v, 1.0, 0.0, 1.0)),
		}
		for k in singles:
			cases += 1
			if not is_finite(float(singles[k])):
				bad_out.append("%s(%s) = %s" % [k, v, singles[k]])
		var store := Fixture.MemorySettings.new()
		for key in AudioBuses.SETTING_DEFAULT:
			store.values[key] = v
		for bus in AudioBuses.SETTING:
			var sv := AudioBuses.setting_value(bus, store)
			cases += 1
			if not (is_finite(sv) and sv >= 0.0 and sv <= 1.0):
				bad_out.append("setting_value(%s = %s) = %s" % [bus, v, sv])
	metric("cases", cases)
	eq(bad_out.size(), 0, "every pure function returns finite values for any input (%d cases): %s" % [cases, bad_out.slice(0, 6)])
	# A corrupted volume reads as its shipped default, not as full volume.
	var store2 := Fixture.MemorySettings.new()
	store2.values["music_volume"] = NAN
	near(AudioBuses.setting_value(AudioBuses.MUSIC, store2), AudioBuses.SETTING_DEFAULT["music_volume"], 1e-6,
		"a NaN music_volume reads as its default (0.5), not as 1.0")


# ------------------------------------------------------ the director ---

## Builds the stage: low over a forest (every ambience bed has a weight,
## the church bell a position), a threatening hawk, a crow calling nearby,
## a moth at the ear, a far prey to catch, normal flight, all five volume
## sliders at 0.7. Landmarks with a NaN position, a NaN radius and an
## infinite position sit among the real ones (they must be skipped).
func _stage() -> void:
	var marks: Array[Dictionary] = [
		{"name": "wood", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 80.0},
		{"name": "church", "kind": "tower", "position": Vector3(40, 0, 30), "radius": 5.0},
		{"name": "pond", "kind": "lake", "position": Vector3(60, 0, 0), "radius": 50.0},
		{"name": "bad_pos", "kind": "town", "position": Vector3(NAN, 0, 0), "radius": 60.0},
		{"name": "bad_radius", "kind": "meadow", "position": Vector3(-40, 0, 0), "radius": NAN},
		{"name": "church_far", "kind": "field", "position": Vector3(INF, 0, 0), "radius": 60.0},
	]
	fx.add_world(marks)
	fx.listener.global_position = Vector3(0, 4, 0)
	fx.player.global_position = Vector3(0, 4, 0)
	var cruise := FlightSoundMap.cruise(0.03)
	good = {"airspeed": cruise * GOOD_SPEED, "wing_extension": 1.0, "tucked": false, "stalled": false, "stall_warning": 0.5,
		"in_updraft": 2.5, "perched": false, "world_scale": 1.0}
	fx.set_tel(good)
	hawk = fx.add_npc(&"hawk", Vector3(0, 30, -60))
	crow = fx.add_npc(&"crow", Vector3(8, 6, -6))
	fx.add_npc(&"moth", Vector3(0.3, 4, 0))
	prey = fx.add_npc(&"wren", Vector3(5000, 4, 0))
	prey_mass = prey.mass
	for key in AudioBuses.SETTING_DEFAULT:
		fx.settings.set_value(key, GOOD_VOLUME)
	Events.threat_changed.emit(GOOD_THREAT, hawk)


## One frame of the director at a fixed step (the test drives it; the tree
## does not).
func _frames(n: int, dt: float = DT, each: Callable = Callable()) -> void:
	for i in n:
		if each.is_valid():
			each.call()
		fx.director._process(dt)


static func _db(g: float) -> float:
	return linear_to_db(maxf(g, 1e-5))


## The director's levels, filters and ducks, in dB (filters as 20 log10 Hz,
## the pan scaled so 1.5 is 0.075): what must come back to where it was.
func _levels() -> Dictionary:
	var d := fx.director
	var out := {}
	for l in d._layers:
		out["layer." + String(l.key)] = _db(l.gain)
	for bus in [AudioBuses.MASTER, AudioBuses.MUSIC, AudioBuses.SFX, AudioBuses.AMBIENCE, AudioBuses.UI]:
		out["bus." + String(bus)] = AudioServer.get_bus_volume_db(AudioBuses.index(bus))
	out["wind.lowpass"] = 20.0 * log(maxf(d._lp_wind.cutoff_hz, 1e-3)) / log(10.0)
	out["wind.highpass"] = 20.0 * log(maxf(d._hp_wind.cutoff_hz, 1e-3)) / log(10.0)
	out["wind.pan"] = 20.0 * d._panner.pan
	out["duck.sfx"] = d._duck_db
	out["duck.ambience"] = d._amb_duck_db
	out["duck.world"] = d._world_duck_db
	out["music"] = d._music_db
	out["threat"] = 20.0 * d.threat_level
	out["calls.speed_duck"] = d.voices.speed_duck_db
	out["calls.cue_duck"] = d.voices.cue_duck_db
	out["ambience.speed_duck"] = d.ambience.duck_db
	for key in d.ambience._players:
		out["bed." + String(key)] = _db(float(d.ambience._players[key]["gain"]))
	return out


## Every value the audio area hands the engine, by name: finite or not.
func _non_finite() -> Array[String]:
	var d := fx.director
	var bad: Array[String] = []
	var vals := {}
	for l in d._layers:
		vals["layer.%s.volume_db" % l.key] = l.player.volume_db
		vals["layer.%s.pitch" % l.key] = l.player.pitch_scale
		vals["layer.%s.gain" % l.key] = l.gain
	for i in d._whoosh.size():
		var w: AudioStreamPlayer3D = d._whoosh[i]
		vals["whoosh%d.volume_db" % i] = w.volume_db
		vals["whoosh%d.pitch" % i] = w.pitch_scale
		vals["whoosh%d.position" % i] = w.global_position
	for i in d.voices.voices.size():
		var p: AudioStreamPlayer3D = d.voices.voices[i].player
		vals["voice%d.volume_db" % i] = p.volume_db
		vals["voice%d.max_db" % i] = p.max_db
		vals["voice%d.unit_size" % i] = p.unit_size
		vals["voice%d.max_distance" % i] = p.max_distance
		vals["voice%d.shelf_db" % i] = p.attenuation_filter_db
		vals["voice%d.pitch" % i] = p.pitch_scale
		vals["voice%d.position" % i] = p.global_position
	var bell: AudioStreamPlayer3D = d.ambience._bell
	vals["bell.volume_db"] = bell.volume_db
	vals["bell.max_db"] = bell.max_db
	vals["bell.unit_size"] = bell.unit_size
	vals["bell.max_distance"] = bell.max_distance
	vals["bell.shelf_db"] = bell.attenuation_filter_db
	vals["bell.position"] = bell.global_position
	for key in d.ambience._players:
		vals["bed.%s.volume_db" % key] = (d.ambience._players[key]["player"] as AudioStreamPlayer).volume_db
	for i in AudioServer.bus_count:
		vals["bus.%s" % AudioServer.get_bus_name(i)] = AudioServer.get_bus_volume_db(i)
	vals["wind.lowpass"] = d._lp_wind.cutoff_hz
	vals["wind.highpass"] = d._hp_wind.cutoff_hz
	vals["wind.pan"] = d._panner.pan
	vals["music.volume_db"] = (d.get_node("Music") as AudioStreamPlayer).volume_db
	for k in vals:
		var v: Variant = vals[k]
		var ok: bool = v.is_finite() if v is Vector3 else is_finite(float(v))
		if not ok:
			bad.append("%s=%s" % [k, v])
	return bad


func _flap_both(v: float) -> void:
	Events.player_flapped.emit(0, v)
	Events.player_flapped.emit(-1, v)


func _catch_with_mass(v: float) -> void:
	prey.mass = v
	Events.bird_caught.emit(fx.player, prey)


## (The ambience reads the ground 4 times a second: forced every frame.)
func _ground(v: float) -> void:
	fx.world.ground = v
	fx.director.ambience._acc = 1.0


## [name, apply one bad value (called every bad frame), restore]. `v` is
## the bad value.
func _cases(v: float) -> Array:
	var out := []
	for key in ["airspeed", "wing_extension", "stall_warning", "in_updraft", "world_scale", "tucked", "stalled", "perched"]:
		out.append(["telemetry." + key, func() -> void: fx.player.tel[key] = v, func() -> void: fx.player.tel[key] = good[key]])
	out.append(["player.mass", func() -> void: fx.player.mass = v, func() -> void: fx.player.mass = 0.03])
	out.append(["player.velocity", func() -> void: fx.player.velocity = Vector3(v, v, v),
		func() -> void: fx.player.velocity = Vector3(0, 0, -9)])
	out.append(["threat_level", func() -> void: Events.threat_changed.emit(v, hawk),
		func() -> void: Events.threat_changed.emit(GOOD_THREAT, hawk)])
	out.append(["flap_strength", func() -> void: _flap_both(v), func() -> void: pass])
	out.append(["collision", func() -> void: Events.player_collided.emit(v, Vector3(v, v, v)), func() -> void: pass])
	out.append(["ui_sound_volume", func() -> void: fx.director.play_ui(&"click", v), func() -> void: pass])
	out.append(["caught_prey_mass", func() -> void: _catch_with_mass(v), func() -> void: prey.mass = prey_mass])
	out.append(["listener_position", func() -> void: fx.listener.global_position = Vector3(v, v, v),
		func() -> void: fx.listener.global_position = Vector3(0, 4, 0)])
	out.append(["npc_position", func() -> void: crow.global_position = Vector3(v, v, v),
		func() -> void: crow.global_position = Vector3(8, 6, -6)])
	for key in AudioBuses.SETTING_DEFAULT:
		out.append(["settings." + key, func() -> void: fx.settings.set_value(key, v),
			func() -> void: fx.settings.set_value(key, GOOD_VOLUME)])
	out.append(["world.ground_height", func() -> void: _ground(v), func() -> void: fx.world.ground = 0.0])
	out.append(["frame_delta", func() -> void: pass, func() -> void: pass])
	return out


## Every input, every bad value, frame by frame: finite throughout, and
## back within TOL_DB of the levels before 0.5 s after normal input resumes.
func test_bad_inputs_recover_within_half_a_second() -> void:
	var errs := ErrorLog.install()
	_stage()
	await wait_frames(2)
	fx.director.set_process(false)
	# 10 s of normal flight: every smoothed state settles (the slowest, the
	# ambience's 1.2 s crossfade, to 0.03%).
	_frames(600)
	fx.director.ambience.settle(fx.listener.global_position)
	_frames(60)
	var ref := _levels()
	var stage_bad := _non_finite()
	eq(stage_bad.size(), 0, "normal flight: every value handed to the engine is finite: %s" % [stage_bad])
	check(float(ref["layer.wind_body"]) > -30.0 and float(ref["layer.stall_flutter"]) > -40.0 and float(ref["layer.updraft_hum"]) > -40.0
		and float(ref["layer.heartbeat"]) > -40.0 and float(ref["layer.drone"]) > -40.0,
		"every flight and danger layer is sounding before the bad frames (%s)" % [ref])
	check(float(ref["bed.amb_leaves"]) > -40.0 and fx.director.ambience._bell_pos.is_finite(),
		"the forest bed is heard and the bell has a place: the bad landmarks were skipped")
	var worst := {}
	var failures: Array[String] = []
	var n_cases := 0
	for v: float in BAD:
		for c: Array in _cases(v):
			var name: String = c[0]
			var dt := DT
			if name == "frame_delta":
				dt = v
			var during: Array[String] = []
			for f in BAD_FRAMES:
				(c[1] as Callable).call()
				fx.director._process(dt)
				during.append_array(_non_finite())
			(c[2] as Callable).call()
			_frames(RECOVER_FRAMES)
			n_cases += 1
			var after := _non_finite()
			var now := _levels()
			var dev := 0.0
			var dev_key := ""
			for k in ref:
				var x: float = now[k]
				var e := absf(x - float(ref[k])) if is_finite(x) else INF
				if e > dev:
					dev = e
					dev_key = k
			var label := "%s=%s" % [name, v]
			worst[label] = [snappedf(dev, 0.01), dev_key]
			if not during.is_empty() or not after.is_empty():
				failures.append("%s: non-finite %s" % [label, (during + after).slice(0, 3)])
			if dev > TOL_DB:
				failures.append("%s: %s is %.2f dB off 0.5 s later (%.2f vs %.2f)" % [label, dev_key, dev, now[dev_key], ref[dev_key]])
			# Half a second more before the next case, so each starts from
			# (nearly) the reference state rather than from the last one's
			# residue.
			_frames(30)
	# The second line of defence on its own: every smoothed state poisoned
	# at once (as a NaN that slipped past the boundary would leave it) must
	# restart from its target, not stay stuck.
	var d := fx.director
	for l in d._layers:
		l.gain = NAN
	d._cut = NAN
	d._hp = NAN
	d._pan = NAN
	d._world_duck_db = NAN
	d.voices.crowd_db = NAN
	d.voices.speed_duck_db = NAN
	d.ambience.duck_db = NAN
	for key in d.ambience._players:
		d.ambience._players[key]["gain"] = NAN
	_frames(1)
	var poisoned_after := _non_finite()
	_frames(RECOVER_FRAMES - 1)
	var healed := _levels()
	var poison_dev := 0.0
	var poison_key := ""
	for k in ref:
		var x: float = healed[k]
		var e := absf(x - float(ref[k])) if is_finite(x) else INF
		if e > poison_dev:
			poison_dev = e
			poison_key = k
	metric("poisoned_state_worst_db", [poison_dev, poison_key])
	eq(poisoned_after.size(), 0, "every smoothed state poisoned with NaN: nothing non-finite reaches the engine one frame later: %s" % [poisoned_after.slice(0, 6)])
	lt(poison_dev, TOL_DB, "and 0.5 s later every level is back (worst %s, %.2f dB off)" % [poison_key, poison_dev])
	errs.uninstall()
	var max_dev := 0.0
	for k in worst:
		max_dev = maxf(max_dev, float(worst[k][0]))
	metric("cases", n_cases)
	metric("max_deviation_db_after_0_5s", max_dev)
	metric("worst_by_case", worst)
	Fixture.save_measure("bad_input_recovery", {"tol_db": TOL_DB, "bad_frames": BAD_FRAMES, "recover_s": RECOVER_FRAMES * DT,
		"cases": n_cases, "worst_by_case": worst})
	gt(n_cases, 100.0, "every input with every bad value (%d cases)" % n_cases)
	eq(failures.size(), 0, "every value stays finite and every level is back within %.1f dB after 0.5 s: %s" % [TOL_DB, failures.slice(0, 8)])
	eq(errs.errors, 0, "no engine or script errors: %s" % [errs.samples])
	fx.director.set_process(true)


## On the real mixer: normal flight, then one frame each of NaN, +INF,
## -INF, +1e30 and -1e30 in every input at once, then normal flight again.
## No captured sample is non-finite, and 0.5 s later the wind, body (the
## buffet) and danger buses play within 3 dB of their levels before (their
## RMS moves about 1 dB from one window to the next; a poisoned layer is
## 80 dB down), the ambience within 10 (see below). Every window is one
## heartbeat period (at threat 1), so the danger bus reads the same
## wherever the window starts.
func test_bad_frames_on_the_mixer() -> void:
	var errs := ErrorLog.install()
	_stage()
	# At threat 1 the heart beats fastest: its period (the danger window)
	# is 0.54 s.
	Events.threat_changed.emit(1.0, hawk)
	fx.set_tel({"in_updraft": 0.0})  # the hum beats at 0.25 Hz: kept out of the Body window
	good["in_updraft"] = 0.0
	var names := ["wind", "body", "danger", "ambience", "master"]
	var caps := [fx.tap(AudioBuses.WIND), fx.tap(AudioBuses.BODY), fx.tap(AudioBuses.DANGER), fx.tap(AudioBuses.AMBIENCE),
		fx.tap(AudioBuses.MASTER)]
	# The director finds the world and computes the flight first, then the
	# beds jump to their zone and speed duck.
	await wait_frames(3)
	fx.director.ambience.settle(fx.listener.global_position)
	await Fixture.wait(get_tree(), 0.3)
	var period := 1.0 / FlightSoundMap.heart_rate(1.0)
	var before := await fx.record_many(get_tree(), caps, period)
	for v: float in BAD:
		for c: Array in _cases(v):
			(c[1] as Callable).call()
		await get_tree().process_frame
	for c: Array in _cases(0.0):
		(c[2] as Callable).call()
	Events.threat_changed.emit(1.0, hawk)
	await Fixture.wait(get_tree(), 0.5)
	var after := await fx.record_many(get_tree(), caps, period)
	errs.uninstall()
	var res := {}
	for i in names.size():
		var nan_seen := false
		for x in (after[i]["mono"] as PackedFloat32Array):
			if not is_finite(x):
				nan_seen = true
				break
		var b0 := AudioAnalysis.db(AudioAnalysis.rms(before[i]["mono"]))
		var b1 := AudioAnalysis.db(AudioAnalysis.rms(after[i]["mono"]))
		res[names[i]] = {"before_dbfs": b0, "after_dbfs": b1}
		check(not nan_seen, "%s: every sample finite after the bad frames" % names[i])
		if names[i] == "master":
			continue  # (the one-shots of the burst ring on in the master)
		gt(b0, -70.0, "%s: sounding before (%.1f dBFS)" % [names[i], b0])
		# The forest bed carries a recorded bird chorus whose loudness moves
		# by a few dB from one half second to the next: there the mixer
		# check is "sounding, not silenced" (10 dB); the bed gains and the
		# ambience duck are held to 1.5 dB by the frame-stepped test.
		var tol := 10.0 if names[i] == "ambience" else 3.0
		near(b1, b0, tol, "%s: back at its level 0.5 s after the bad frames (%.1f -> %.1f dBFS)" % [names[i], b0, b1])
	metric("mixer", res)
	eq(errs.errors, 0, "no engine or script errors: %s" % [errs.samples])
