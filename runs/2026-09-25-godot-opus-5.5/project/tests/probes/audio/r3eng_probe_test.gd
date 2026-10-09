extends TestCase
## Round-3 engineering verifier probes (not part of the audio suite).
##
##   tools/gd.sh audio_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=r3eng
##
## 1. Call balance measured on the engine's mixer, not on a model of it.
##    audio_calls_test.test_calls_are_balanced_by_loudness computes each
##    clip's level at 25 perceived m from Godot's distance law (_heard_at),
##    leaving out AudioStreamPlayer3D's air-absorption shelf (attenuation
##    filter: 5 kHz, up to -24 dB, on by default). This probe plays every
##    clip through the real voice path (CallVoices._request -> _start) at 25 m
##    and at the unit distance, records the Calls bus and measures the same
##    A-weighted loudness (loudest 0.4 s), with the filter as shipped and
##    with it disabled, then applies the suite's own balance thresholds.
## 2. A second catch within CUE_STACK_S is 6 dB lower on the mix.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const SMALL: Array[StringName] = [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon"]
const OTHERS: Array[StringName] = [&"crow", &"gull", &"hawk", &"eagle"]

var fx: Fixture


func before_each() -> void:
	Fixture.restore_default_settings()
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	Fixture.restore_default_settings()
	await Fixture.wait(get_tree(), 0.05)


func after_all() -> void:
	await Fixture.wait(get_tree(), 0.3)


## Plays `st` from bird b through the pool at its designed gain (no random
## offset, pitch 1) and returns the Calls bus loudness (A-weighted, loudest
## 0.4 s, mono) over the clip.
func _measure(b: Bird, sp: StringName, st: AudioStream, cap: AudioEffectCapture, filter_on: bool) -> float:
	var voices := fx.director.voices
	for v in voices.voices:
		v.player.attenuation_filter_db = -24.0 if filter_on else 0.0
	var ok := voices._request(b, {"species": sp, "stream": st, "kind": &"call", "prio": 100.0,
		"db": CallVoices.clip_gain_db(sp, st), "pitch": 1.0, "urgent": false})
	if not ok:
		return -INF
	var rec := await fx.record(get_tree(), cap, st.get_length() + 0.15)
	voices.stop_all()
	await wait_frames(3)
	return AudioAnalysis.loudness_aw(rec["mono"], rec["rate"], 0.4)["max"]


## The suite's model of the same level (audio_calls_test._heard_at).
static func _model(sp: StringName, clip_loud: float, d: float) -> float:
	var v: Dictionary = CallVoices.VOICE[sp]
	var vol := float(v["loud"]) - clip_loud
	var att := minf(vol + 20.0 * log(float(v["unit"]) / d) / log(10.0), minf(vol + CallVoices.NEAR_BOOST_DB, 0.0))
	return clip_loud + att + 20.0 * log(maxf(1.0 - d / float(v["reach"]), 1e-5)) / log(10.0)


func test_call_balance_on_the_mixer() -> void:
	Game.set_state(Game.State.PLAYING)
	fx.set_tel({"airspeed": 0.0, "world_scale": 1.0})
	var voices := fx.director.voices
	voices.scheduling = false
	var cap := fx.tap(AudioBuses.CALLS)
	await Fixture.wait(get_tree(), 0.4)
	var bank := fx.director.bank
	var rows := {}
	var med_on := {}
	var med_off := {}
	var med_model := {}
	for sp in SMALL + OTHERS:
		var b := fx.add_npc(sp, Vector3(0, 100, -25))
		await wait_frames(2)
		var on := PackedFloat32Array()
		var off := PackedFloat32Array()
		var mod := PackedFloat32Array()
		for st: AudioStream in bank.calls_for(sp):
			var clip: StringName = st.get_meta(&"clip", &"")
			var m_on := await _measure(b, sp, st, cap, true)
			var m_off := await _measure(b, sp, st, cap, false) if sp in SMALL else NAN
			var model := _model(sp, float(CallVoices.CALL_LOUDNESS[clip]), 25.0)
			on.append(m_on)
			if not is_nan(m_off):
				off.append(m_off)
			mod.append(model)
			rows[String(clip)] = {"mixer_filter_on": snappedf(m_on, 0.01), "mixer_filter_off": snappedf(m_off, 0.01) if not is_nan(m_off) else null,
				"model": snappedf(model, 0.01)}
			print("[audio-verify] %s at 25 m: mixer %.1f (filter off %s), model %.1f dB A" % [clip, m_on, "%.1f" % m_off if not is_nan(m_off) else "-", model])
		med_on[sp] = AudioAnalysis.median(on)
		med_model[sp] = AudioAnalysis.median(mod)
		if not off.is_empty():
			med_off[sp] = AudioAnalysis.median(off)
		fx.npcs.erase(b)
		b.queue_free()
		await wait_frames(2)
	# The 3D panning law costs every voice the same constant: compare the
	# mixer to the model after removing the median offset of the filter-off pass.
	var offs := PackedFloat32Array()
	for sp in med_off:
		offs.append(float(med_off[sp]) - float(med_model[sp]))
	var pan_offset := AudioAnalysis.median(offs)
	var spread := func(m: Dictionary) -> float:
		var lo := INF
		var hi := -INF
		for sp in SMALL:
			lo = minf(lo, m[sp])
			hi = maxf(hi, m[sp])
		return hi - lo
	var starling_over := func(m: Dictionary) -> float:
		return float(m[&"starling"]) - maxf(maxf(m[&"wren"], m[&"sparrow"]), m[&"swallow"])
	var out := {"clips": rows, "median_mixer_filter_on": med_on, "median_mixer_filter_off": med_off, "median_model": med_model,
		"panning_offset_db": pan_offset,
		"small_spread_db": {"mixer_filter_on": spread.call(med_on), "mixer_filter_off": spread.call(med_off), "model": spread.call(med_model)},
		"starling_over_recorded_db": {"mixer_filter_on": starling_over.call(med_on), "mixer_filter_off": starling_over.call(med_off),
			"model": starling_over.call(med_model)}}
	var loss := {}
	for sp in SMALL + OTHERS:
		loss[sp] = snappedf(float(med_on[sp]) - float(med_model[sp]) - pan_offset, 0.1)
	out["air_absorption_loss_db"] = loss
	metric("balance", out)
	var f := FileAccess.open(Paths.artifacts("audio/verify/r3eng").path_join("call_balance_on_mixer.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	print("[audio-verify] spread wren..pigeon: mixer %.1f (filter off %.1f), model %.1f dB; starling over recorded: mixer %.1f (off %.1f), model %.1f" % [
		spread.call(med_on), spread.call(med_off), spread.call(med_model), starling_over.call(med_on), starling_over.call(med_off), starling_over.call(med_model)])
	print("[audio-verify] air-absorption loss by species at 25 m (dB): %s" % [loss])
	# The suite's thresholds, applied to what the mixer actually plays.
	lt(spread.call(med_on), 6.0, "mixer (as shipped): wren..pigeon within 6 dB at 25 m (%.1f)" % spread.call(med_on))
	lt(starling_over.call(med_on), 2.0, "mixer (as shipped): starling <= recorded songbirds + 2 dB (%.1f)" % starling_over.call(med_on))
	lt(spread.call(med_off), 6.0, "mixer, air absorption off: wren..pigeon within 6 dB (%.1f)" % spread.call(med_off))
	var mid := minf(med_on[&"crow"], med_on[&"gull"])
	var s_hi := -INF
	for sp in SMALL:
		s_hi = maxf(s_hi, med_on[sp])
	gt(mid - s_hi, 3.0, "mixer: crows and gulls carry over the small birds (%.1f vs %.1f)" % [mid, s_hi])


## A second catch within CUE_STACK_S (two prey in one sweep) plays 6 dB lower.
func test_second_quick_catch_is_lower() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.SFX)
	await Fixture.wait(get_tree(), 0.4)
	var peaks := {}
	for gap in [0.05, 0.6]:
		var a := fx.add_npc(&"wren", Vector3(0, 100, -1))
		var b := fx.add_npc(&"wren", Vector3(0, 100, -1.2))
		var stacks: Array = []
		var cb := func(n: StringName, i: Dictionary) -> void:
			if n == &"catch":
				stacks.append(i.get("stack_db", 0.0))
		fx.director.cue.connect(cb)
		Events.bird_caught.emit(fx.player, a)
		await Fixture.wait(get_tree(), gap)
		Events.bird_caught.emit(fx.player, b)
		await Fixture.wait(get_tree(), 0.8)
		fx.director.cue.disconnect(cb)
		peaks[gap] = stacks
	metric("stack_db", peaks)
	eq(peaks[0.05], [0.0, -6.0], "two catches 50 ms apart: the second plays 6 dB lower")
	eq(peaks[0.6], [0.0, 0.0], "two catches 0.6 s apart: both at full level")


## The same effect at each small species' unit distance (where VOICE.loud is
## its designed level) and at 12 m, next to the sparrow's own wind at cruise,
## all measured on the mixer in one stage (mono, A-weighted: calls by their
## loudest 0.4 s, the wind by its mean).
func test_small_birds_against_the_cruise_wind() -> void:
	Game.set_state(Game.State.PLAYING)
	fx.set_tel({"airspeed": FlightSoundMap.cruise(0.03), "world_scale": 1.0})
	var voices := fx.director.voices
	voices.scheduling = false
	var calls := fx.tap(AudioBuses.CALLS)
	var wind := fx.tap(AudioBuses.WIND)
	await Fixture.wait(get_tree(), 0.5)
	var wrec := await fx.record(get_tree(), wind, 1.0)
	var wind_aw: float = AudioAnalysis.loudness_aw(wrec["mono"], wrec["rate"], 0.4)["mean"]
	var bank := fx.director.bank
	var out := {"sparrow_cruise_wind_aw_mean": wind_aw}
	for sp in SMALL:
		var unit := float(CallVoices.VOICE[sp]["unit"])
		var st: AudioStream = bank.calls_for(sp)[0]
		var row := {"designed_at_unit": float(CallVoices.VOICE[sp]["loud"])}
		for d in [unit, 12.0]:
			var b := fx.add_npc(sp, Vector3(0, 100, -d))
			await wait_frames(2)
			row["%.0fm_filter_on" % d] = snappedf(await _measure(b, sp, st, calls, true), 0.1)
			row["%.0fm_filter_off" % d] = snappedf(await _measure(b, sp, st, calls, false), 0.1)
			fx.npcs.erase(b)
			b.queue_free()
			await wait_frames(2)
		out[String(sp)] = row
		print("[audio-verify] %s %s" % [sp, row])
	print("[audio-verify] sparrow cruise wind %.1f dB A (mean)" % wind_aw)
	metric("small_birds_vs_wind", out)
	var f := FileAccess.open(Paths.artifacts("audio/verify/r3eng").path_join("small_birds_vs_wind.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	check(true, "measured")


## The player's own wingbeats are AudioStreamPlayer3D too (attenuation
## disabled, at arm's length). Godot's air-absorption shelf still follows
## their volume_db: compare the rendered high band (> 4 kHz share) of a full
## and a soft flap with the shelf as shipped and disabled.
func test_wingbeat_high_band_vs_air_absorption() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.BODY)
	await Fixture.wait(get_tree(), 0.4)
	var out := {}
	for filter_on in [true, false]:
		for strength in [1.0, 0.3]:
			for w in fx.director._whoosh:
				w.attenuation_filter_db = -24.0 if filter_on else 0.0
			cap.clear_buffer()
			Events.player_flapped.emit(-1, strength)
			var rec := await fx.record(get_tree(), cap, 0.35)
			var p := AudioAnalysis.mean_power(rec["mono"], 1024, 512, -60.0)
			out["%s_%.1f" % ["on" if filter_on else "off", strength]] = {
				"hi_share_4k": snappedf(AudioAnalysis.band_fraction(p, rec["rate"], 4000.0, 16000.0), 0.0001),
				"centroid": snappedf(AudioAnalysis.centroid(p, rec["rate"]), 1.0),
				"rms_db": snappedf(AudioAnalysis.db(AudioAnalysis.rms(rec["mono"])), 0.1)}
			await Fixture.wait(get_tree(), 0.15)
	print("[audio-verify] wingbeat vs air absorption: %s" % [out])
	metric("wingbeat_air_absorption", out)
	check(true, "measured")
