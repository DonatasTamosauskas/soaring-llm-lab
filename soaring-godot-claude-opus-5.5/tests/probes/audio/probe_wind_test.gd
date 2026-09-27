extends TestCase
## Verifier probes (round 1) for AU1: try to break the wind / tuck / stall /
## clipping claims with sizes, orders and loads the builder's suite does not
## use. Measures the engine's real mix through capture taps (the audio area's
## own fixture is reused only for its mock player and taps).

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")

var fx: Fixture


func before_each() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)


func _rec_db(cap: AudioEffectCapture, settle: float, secs: float) -> Dictionary:
	await Fixture.wait(get_tree(), settle)
	var rec := await fx.record(get_tree(), cap, secs)
	rec["db"] = AudioAnalysis.db(AudioAnalysis.rms(rec["mono"]))
	return rec


## Strictly rising wind at every ladder size the player can be, spread AND
## tucked (the builder only sweeps a spread sparrow and eagle).
func test_wind_monotonic_every_size_spread_and_tucked() -> void:
	var cap := fx.tap(AudioBuses.WIND)
	var out := {}
	for sp in [&"swallow", &"pigeon", &"crow", &"hawk"]:
		var mass := float(SizeRules.species_data(sp)["mass"])
		fx.player.mass = mass
		var cruise := FlightSoundMap.cruise(mass)
		for tucked in [false, true]:
			fx.set_tel({"airspeed": 0.0, "tucked": false, "wing_extension": 1.0})
			await Fixture.wait(get_tree(), 0.6)
			var prev := -INF
			var dbs := []
			var ok := true
			for r in [0.3, 0.7, 1.0, 1.5, 2.0, 2.6]:
				fx.set_tel({"airspeed": cruise * r, "tucked": tucked, "wing_extension": 0.1 if tucked else 1.0})
				var rec := await _rec_db(cap, 0.25, 0.3)
				dbs.append(snappedf(rec["db"], 0.1))
				if rec["db"] <= prev + 0.5:
					ok = false
				prev = rec["db"]
			out["%s_%s" % [sp, "tucked" if tucked else "spread"]] = dbs
			check(ok, "%s %s: wind RMS strictly rising (>= 0.5 dB/step) %s" % [sp, "tucked" if tucked else "spread", str(dbs)])
	metric("sweeps_db", out)


## Decelerating (dive -> slow): the level must fall monotonically too, and
## settle to the same level as when approached from below (no hysteresis).
## Settle 1.5 s: the designed release (TAU_DOWN 0.18 s) plus the wind's own
## +-0.5 dB gusts left ~1.8 dB at 0.8 s, which is smoothing, not hysteresis.
func test_wind_descending_sweep_and_no_hysteresis() -> void:
	var cap := fx.tap(AudioBuses.WIND)
	var cruise := FlightSoundMap.cruise(0.03)
	var up := {}
	for r in [0.5, 1.0, 2.0]:
		fx.set_tel({"airspeed": cruise * r})
		var rec := await _rec_db(cap, 1.5, 0.8)
		up[r] = rec["db"]
	fx.set_tel({"airspeed": cruise * 2.6})
	await Fixture.wait(get_tree(), 0.8)
	var prev := INF
	var ok := true
	var down := {}
	for r in [2.0, 1.0, 0.5]:
		fx.set_tel({"airspeed": cruise * r})
		var rec := await _rec_db(cap, 1.5, 0.8)
		down[r] = rec["db"]
		if rec["db"] >= prev - 0.5:
			ok = false
		prev = rec["db"]
	check(ok, "descending sweep falls strictly (%s)" % str(down))
	for r in up:
		near(down[r], up[r], 1.0, "x%.1f: same level from above and below (%.1f vs %.1f dB)" % [r, down[r], up[r]])
	metric("up_db", up)
	metric("down_db", down)


## A smooth acceleration 0.2x -> 2.6x cruise over 4 s: 0.25 s RMS windows
## never drop (no zipper steps, no gust dips read as slowing down).
func test_wind_continuous_ramp_never_dips() -> void:
	var cap := fx.tap(AudioBuses.WIND)
	var cruise := FlightSoundMap.cruise(0.03)
	fx.set_tel({"airspeed": cruise * 0.2})
	await Fixture.wait(get_tree(), 0.6)
	cap.clear_buffer()
	var frames := PackedVector2Array()
	var t := 0.0
	var dur := 4.0
	while t < dur:
		var dt := get_process_delta_time()
		await get_tree().process_frame
		t += maxf(dt, 1.0 / 120.0)
		fx.set_tel({"airspeed": cruise * lerpf(0.2, 2.6, clampf(t / dur, 0.0, 1.0))})
		var n := cap.get_frames_available()
		if n > 0:
			frames.append_array(cap.get_buffer(n))
	var d := AudioAnalysis.split_frames(frames)
	var rate := AudioServer.get_mix_rate()
	var win := int(rate * 0.25)
	var dbs := PackedFloat32Array()
	for i in range(0, d["mono"].size() - win, win):
		dbs.append(AudioAnalysis.db(AudioAnalysis.rms(d["mono"], i, i + win)))
	var worst := 0.0
	for i in range(1, dbs.size()):
		worst = minf(worst, dbs[i] - dbs[i - 1])
	metric("ramp_windows_db", Array(dbs))
	metric("worst_step_db", worst)
	gt(worst, -0.5, "accelerating: no 0.25 s window is > 0.5 dB quieter than the one before")
	gt(dbs[dbs.size() - 1] - dbs[0], 25.0, "ramp spans > 25 dB")


## Dive >> glide and tuck brighter/thinner hold for a big bird too (eagle,
## hawk), not only a sparrow.
func test_dive_glide_and_tuck_for_big_birds() -> void:
	var cap := fx.tap(AudioBuses.WIND)
	var res := {}
	for sp in [&"hawk", &"eagle"]:
		var mass := float(SizeRules.species_data(sp)["mass"])
		fx.player.mass = mass
		var cruise := FlightSoundMap.cruise(mass)
		fx.set_tel({"airspeed": cruise, "tucked": false, "wing_extension": 1.0})
		var glide := await _rec_db(cap, 0.6, 0.5)
		fx.set_tel({"airspeed": cruise * 2.6, "tucked": true, "wing_extension": 0.1})
		var dive := await _rec_db(cap, 0.4, 0.5)
		gt(dive["db"] - glide["db"], 12.0, "%s: tucked dive >= 12 dB over glide (%.1f vs %.1f)" % [sp, dive["db"], glide["db"]])
		fx.set_tel({"airspeed": cruise * 2.0, "tucked": false, "wing_extension": 1.0})
		var spread := await _rec_db(cap, 0.6, 0.6)
		fx.set_tel({"airspeed": cruise * 2.0, "tucked": true, "wing_extension": 0.1})
		var tucked := await _rec_db(cap, 0.6, 0.6)
		var rate: float = spread["rate"]
		var ps := AudioAnalysis.mean_power(spread["mono"], 2048, 1024, -60.0)
		var pt := AudioAnalysis.mean_power(tucked["mono"], 2048, 1024, -60.0)
		var cs := AudioAnalysis.centroid(ps, rate, 20.0)
		var ct := AudioAnalysis.centroid(pt, rate, 20.0)
		var ls := AudioAnalysis.band_fraction(ps, rate, 20.0, 400.0)
		var lt_ := AudioAnalysis.band_fraction(pt, rate, 20.0, 400.0)
		gt(ct / cs, 1.5, "%s: tucked centroid >= 1.5x (%.0f -> %.0f Hz)" % [sp, cs, ct])
		lt(lt_, ls * 0.35, "%s: tucked < 400 Hz share under a third (%.2f -> %.2f)" % [sp, ls, lt_])
		res[String(sp)] = {"glide": glide["db"], "dive": dive["db"], "centroid": [cs, ct], "low": [ls, lt_]}
	metric("big_birds", res)


## Partial tuck (wing_extension between) must also sit between spread and
## tuck in brightness (no discontinuity when the wings fold gradually).
func test_partial_fold_brightness_is_monotonic() -> void:
	var cap := fx.tap(AudioBuses.WIND)
	var speed := FlightSoundMap.cruise(0.03) * 1.8
	var cents := []
	var ok := true
	var prev := 0.0
	for ext in [1.0, 0.5, 0.35, 0.2, 0.1]:
		fx.set_tel({"airspeed": speed, "tucked": false, "wing_extension": ext})
		var rec := await _rec_db(cap, 0.5, 0.5)
		var c := AudioAnalysis.centroid(AudioAnalysis.mean_power(rec["mono"], 2048, 1024, -60.0), rec["rate"], 20.0)
		cents.append(snappedf(c, 1.0))
		if c < prev * 0.98:
			ok = false
		prev = c
	check(ok, "folding the wings brightens the wind monotonically %s" % str(cents))
	metric("fold_centroids", cents)


## Stall buffet at other sizes and with only a stall warning (flight emits
## stall_warning 0..1): still periodic at 14 * flutter_pitch(mass).
func test_stall_buffet_other_sizes_and_warning() -> void:
	var cap := fx.tap(AudioBuses.BODY)
	var res := {}
	for spec in [[&"pigeon", 1.0, false], [&"hawk", 1.0, false], [&"sparrow", 0.6, true]]:
		var mass := float(SizeRules.species_data(spec[0])["mass"])
		fx.player.mass = mass
		var cruise := FlightSoundMap.cruise(mass)
		var tel := {"airspeed": cruise * 0.5, "stalled": not spec[2], "stall_warning": spec[1] if spec[2] else 0.0}
		fx.set_tel(tel)
		var rec := await _rec_db(cap, 0.4, 1.0)
		var env := AudioAnalysis.envelope(rec["mono"], rec["rate"], 0.002)
		var per := AudioAnalysis.periodicity(env, 500.0, 5.0, 40.0)
		var want := 14.0 * FlightSoundMap.flutter_pitch(mass)
		var tag := "%s%s" % [spec[0], " warning" if spec[2] else ""]
		near(per["hz"], want, want * 0.06, "%s: buffet at %.1f Hz (got %.2f)" % [tag, want, per["hz"]])
		gt(per["strength"], 0.6, "%s: periodic (strength %.2f)" % [tag, per["strength"]])
		gt(rec["db"], -60.0, "%s: audible (%.1f dBFS)" % [tag, rec["db"]])
		res[tag] = {"hz": per["hz"], "want": want, "strength": per["strength"], "db": rec["db"]}
		fx.set_tel({"stalled": false, "stall_warning": 0.0})
		await Fixture.wait(get_tree(), 0.6)
	metric("stall", res)


## Worse than the builder's "maximum load": everything flapping EVERY frame,
## 20 NPCs at 1 m all re-requesting with a big boost, fanfare + stinger +
## catches in the same frame, master_volume and every slider at 1.0, and the
## same pile-up in PAUSED (music + UI on top). Output must stay < -1 dBFS.
func test_extreme_load_never_clips_any_state() -> void:
	var saved := {}
	for k in AudioBuses.SETTING_DEFAULT:
		saved[k] = Settings.get_value(k, AudioBuses.SETTING_DEFAULT[k])
		Settings.set_value(k, 1.0)
	var marks: Array[Dictionary] = []
	for kind in ["forest", "lake", "town", "meadow", "canyon"]:
		marks.append({"name": kind, "kind": kind, "position": Vector3.ZERO, "radius": 300.0})
	marks.append({"name": "church_x", "kind": "landmark", "position": Vector3(0, 3, 0), "radius": 3.0})
	fx.add_world(marks)
	fx.listener.global_position = Vector3(0, 2, 0)
	fx.player.global_position = Vector3(0, 2, 0)
	fx.set_tel({"airspeed": 30.0, "tucked": true, "wing_extension": 0.0, "stalled": true, "in_updraft": 9.0})
	var species := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle", &"moth"]
	for i in 20:
		var a := TAU * i / 20.0
		fx.add_npc(species[i % species.size()], Vector3(cos(a), 2.0, sin(a)))
	var pred := fx.add_npc(&"eagle", Vector3(0, 2.2, -1))
	var results := {}
	for state in [Game.State.PLAYING, Game.State.PAUSED, Game.State.MENU]:
		Game.set_state(state)
		Events.threat_changed.emit(1.0, pred)
		await Fixture.wait(get_tree(), 0.7)
		var post := fx.tap(AudioBuses.MASTER)
		var pre := fx.tap(AudioBuses.MASTER, 0)
		var n := [0]
		var cb := func() -> void:
			n[0] += 1
			Events.player_flapped.emit([-1, 0, 1][n[0] % 3], 1.0)
			for b in fx.npcs:
				fx.director.voices.request_call(b, 40.0)
			Events.bird_caught.emit(fx.player, fx.npcs[n[0] % fx.npcs.size()])
			if n[0] % 5 == 0:
				Events.player_tier_changed.emit(3, 4)
				Events.player_caught.emit(pred)
				Events.player_collided.emit(20.0, Vector3.UP)
			fx.director.play_ui(&"confirm", 6.0)
		get_tree().process_frame.connect(cb)
		var recs: Array = await fx.record2(get_tree(), pre, post, 1.5)
		get_tree().process_frame.disconnect(cb)
		var pre_pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(recs[0]["l"]), AudioAnalysis.peak(recs[0]["r"])))
		var post_pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(recs[1]["l"]), AudioAnalysis.peak(recs[1]["r"])))
		var post_rms := AudioAnalysis.db(AudioAnalysis.rms(recs[1]["mono"]))
		results[Game.state_name(state)] = {"pre_peak": pre_pk, "post_peak": post_pk, "post_rms": post_rms}
		lt(post_pk, -1.0, "%s: limiter output peak < -1 dBFS under extreme load (pre %.1f, post %.2f)" % [Game.state_name(state), pre_pk, post_pk])
		if state == Game.State.PLAYING:
			AudioSynth.make_wav(recs[1]["l"], recs[1]["r"], int(recs[1]["rate"])).save_to_wav(
				Paths.artifacts("audio/verify").path_join("extreme_load_output.wav"))
		# Remove this state's taps before the next.
		for c in fx._caps.duplicate():
			if c[1] == pre or c[1] == post:
				var bi := AudioServer.get_bus_index(c[0])
				for i in range(AudioServer.get_bus_effect_count(bi) - 1, -1, -1):
					if AudioServer.get_bus_effect(bi, i) == c[1]:
						AudioServer.remove_bus_effect(bi, i)
				fx._caps.erase(c)
	metric("extreme", results)
	lt(fx.director.voices.active_count(), CallVoices.MAX_VOICES + 1, "voice cap held")
	for k in saved:
		Settings.set_value(k, saved[k])
	Events.threat_changed.emit(0.0, null)
