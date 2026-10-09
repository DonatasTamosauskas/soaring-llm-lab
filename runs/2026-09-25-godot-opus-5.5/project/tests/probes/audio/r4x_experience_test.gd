extends TestCase
## Round-4 verifier probes (experience & requirements lens) for the audio
## area. Everything is measured on the engine's own mix (capture taps) with
## the shipped Settings, and targets what earlier rounds did not cover:
##  * the danger cue and the predator's scream while the player flees in a
##    SPREAD (untucked) dive, where the wind keeps its low end and the
##    calls bus is speed-ducked (round 3 only measured 1.5x and a tucked dive);
##  * loop seams of the shipped menu music and the recorded forest chorus,
##    rendered through the mixer (the suite's seam test covers synthesized
##    clips only);
##  * the updraft hum while actually thermalling (0.8x cruise, 1-3 m/s);
##  * the moth's "soft flutter" hovering next to it and chasing it at cruise;
##  * one bad telemetry / threat frame (NaN, INF) must not break the mix;
##  * a 40 s soak: bounded bookkeeping, stable cost, no errors, clean release.
## Run: tools/gd.sh audio_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=r4x
## Outputs: artifacts/audio/verify/r4x/.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")
const SPARROW_WS := 0.24 / 1.7
const OCT: Array[float] = [63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0]

var fx: Fixture
var _out := {}


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("audio/verify/r4x"))
	Fixture.restore_default_settings()


func after_all() -> void:
	Fixture.restore_default_settings()
	var path := Paths.artifacts("audio/verify/r4x").path_join("measurements.json")
	var data := {}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			data = parsed
	for k in _out:
		data[k] = _out[k]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  ", true))
	f.close()
	await Fixture.wait(get_tree(), 0.3)


func before_each() -> void:
	Fixture.restore_default_settings()
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	Fixture.restore_default_settings()
	await Fixture.wait(get_tree(), 0.1)


# ------------------------------------------------------------ helpers ---

static func _db(x: float) -> float:
	return AudioAnalysis.db(x)


static func _fader(bus: StringName) -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus))


## Octave-band levels (dB RMS-referenced) of a buffer's mean power, over
## samples [from, to).
static func _octaves(buf: PackedFloat32Array, rate: float, from: int = 0, to: int = -1) -> PackedFloat32Array:
	var b := buf if (from == 0 and to < 0) else buf.slice(from, to)
	var frames := AudioAnalysis.stft(b, 2048, 1024)
	var p := PackedFloat32Array()
	p.resize(1025)
	p.fill(0.0)
	for fr in frames:
		for i in fr.size():
			p[i] += fr[i] * fr[i]
	for i in p.size():
		p[i] /= maxf(1.0, frames.size())
	var out := PackedFloat32Array()
	for f in OCT:
		out.append(AudioAnalysis.band_db(p, rate, f / sqrt(2.0), f * sqrt(2.0)))
	return out


static func _oct_dict(v: PackedFloat32Array, add_db: float = 0.0) -> Dictionary:
	var d := {}
	for i in OCT.size():
		d["%d" % int(OCT[i])] = snappedf(v[i] + add_db, 0.1)
	return d


static func _has_nan(buf: PackedFloat32Array) -> bool:
	for x in buf:
		if is_nan(x) or is_inf(x):
			return true
	return false


# ------------------------------------------- danger while fleeing fast ---

## A small bird fleeing a hawk dives. Round 3 measured the danger cue at
## cruise, 1.5x and in a TUCKED 2.4x dive (whose wind is high-passed at
## 350 Hz, so the heart and drone sit in an empty band). A SPREAD dive keeps
## the wind's whole low end, and the Calls bus (the scream) is speed-ducked
## up to 6 dB there. The danger must still be heard: heart+drone at least
## at the wind's level in the 125/250 Hz speaker bands at threat 0.5 and
## 6 dB over it at threat 1 (round 3's own bar); the predator's scream,
## at the ThreatWatch distance (45 m at sparrow scale) and closing (15 m),
## at least at the wind's level in its strongest octave band (2/4 kHz).
func test_danger_and_scream_heard_while_fleeing_in_a_dive() -> void:
	var cruise := FlightSoundMap.cruise(0.03)
	fx.set_tel({"world_scale": SPARROW_WS})
	var wind := fx.tap(AudioBuses.WIND)
	var danger := fx.tap(AudioBuses.DANGER)
	var calls := fx.tap(AudioBuses.CALLS)
	# Behind and above the fleeing player (it dives away along -Z).
	var hawk := fx.add_npc(&"hawk", Vector3(0, 108, 44.3))
	var voices := fx.director.voices
	var res := {}
	# spread_2.6x is reported only: 2.6x is the TUCK-dive maximum (FlightParams
	# v_max), a spread bird rarely gets there.
	var plot := {"danger_0.5": PackedFloat32Array(), "danger_1.0": PackedFloat32Array(), "scream_45m": PackedFloat32Array(), "scream_15m": PackedFloat32Array()}
	var xs := PackedFloat32Array()
	var xi := 0
	for fl in [["spread_1.5x", 1.5, false], ["spread_2.0x", 2.0, false], ["spread_2.6x", 2.6, false], ["tucked_2.6x", 2.6, true]]:
		var assert_it: bool = fl[0] != "spread_2.6x"
		xi += 1
		xs.append(float(xi))
		fx.set_tel({"airspeed": cruise * float(fl[1]), "tucked": fl[2], "wing_extension": 0.1 if fl[2] else 1.0})
		hawk.global_position = Vector3(0, 108, 44.3)
		var r := {}
		# Heart + drone.
		for lvl in [0.5, 1.0]:
			Events.threat_changed.emit(lvl, hawk)
			await Fixture.wait(get_tree(), 0.9)
			var pair := await fx.record2(get_tree(), wind, danger, 1.3)
			var rate: float = pair[0]["rate"]
			var wo := _octaves(pair[0]["mono"], rate)
			var do_ := _octaves(pair[1]["mono"], rate)
			var spk := maxf(do_[1] - wo[1], do_[2] - wo[2])
			var d_aw: float = AudioAnalysis.loudness_aw(pair[1]["mono"], rate, 0.1)["max"]
			var w_aw: float = AudioAnalysis.loudness_aw(pair[0]["mono"], rate, 0.4)["mean"]
			r["danger@%.1f" % lvl] = {"band_125_250_margin_db": snappedf(spk, 0.1), "beat_minus_wind_dba": snappedf(d_aw - w_aw, 0.1),
				"danger_oct": _oct_dict(do_), "wind_oct": _oct_dict(wo)}
			print("[audio-verify-r4] %s danger@%.1f: 125/250 Hz margin %+.1f dB, beat %+.1f dB A vs wind" % [fl[0], lvl, spk, d_aw - w_aw])
			plot["danger_%.1f" % lvl].append(spk)
			if not assert_it:
				continue
			if lvl >= 1.0:
				gt(spk, 6.0, "%s: at threat 1 heart+drone beat the wind by >= 6 dB at 125 or 250 Hz (%+.1f)" % [fl[0], spk])
			else:
				gt(spk, 0.0, "%s: at threat 0.5 heart+drone reach the wind's level at 125 or 250 Hz (%+.1f)" % [fl[0], spk])
		# The scream, at 45 m then with the hawk closing to 15 m.
		for dist in [45.0, 15.0]:
			voices.stop_all()
			Events.threat_changed.emit(0.0, null)
			fx.director._screech_cool = 0.0
			hawk.global_position = Vector3(0, 100.0 + dist * 0.18, dist * 0.984)
			await Fixture.wait(get_tree(), 0.35)
			Events.threat_changed.emit(0.3, hawk)
			await wait_frames(1)
			var cues: Array = []
			var cb := func(n: StringName, _i: Dictionary) -> void: cues.append(n)
			fx.director.cue.connect(cb)
			Events.threat_changed.emit(0.7, hawk)
			await wait_frames(1)
			fx.director.cue.disconnect(cb)
			var calls_fader := _fader(AudioBuses.CALLS)
			var recs := await fx.record_many(get_tree(), [calls, wind], 1.2)
			var calls_fader2 := _fader(AudioBuses.CALLS)
			var rate2: float = recs[0]["rate"]
			var fad := 0.5 * (calls_fader + calls_fader2)
			var s_aw: float = AudioAnalysis.loudness_aw(recs[0]["mono"], rate2, 0.4)["max"] + fad
			var w_aw2: float = AudioAnalysis.loudness_aw(recs[1]["mono"], rate2, 0.4)["mean"]
			var so := _octaves(recs[0]["mono"], rate2)
			var wo2 := _octaves(recs[1]["mono"], rate2)
			var band := maxf(so[5] - wo2[5], so[6] - wo2[6])
			var key := "scream_%dm" % int(dist)
			r[key] = {"screamed": cues.has(&"screech"), "calls_fader_db": snappedf(fad, 0.1), "scream_dba": snappedf(s_aw, 0.1),
				"wind_dba": snappedf(w_aw2, 0.1), "scream_minus_wind_dba": snappedf(s_aw - w_aw2, 0.1),
				"best_2k_4k_band_margin_db": snappedf(band + fad, 0.1), "scream_oct": _oct_dict(so, fad), "wind_oct": _oct_dict(wo2)}
			print("[audio-verify-r4] %s %s: screamed %s, calls fader %.1f dB, scream %+.1f dB A vs wind, best 2k/4k band %+.1f dB" % [
				fl[0], key, cues.has(&"screech"), fad, s_aw - w_aw2, band + fad])
			plot[key].append(band + fad)
			check(cues.has(&"screech"), "%s: the hawk screams at the 0.6 crossing from %d m" % [fl[0], int(dist)])
			if assert_it:
				gt(band + fad, 0.0, "%s: the scream from %d m reaches the wind's level in its 2k/4k band (%+.1f dB)" % [fl[0], int(dist), band + fad])
		Events.threat_changed.emit(0.0, null)
		voices.stop_all()
		res[fl[0]] = r
		await Fixture.wait(get_tree(), 0.2)
	_out["danger_in_dive"] = res
	metric("danger_in_dive", res)
	var series := []
	for k in ["danger_0.5", "danger_1.0", "scream_45m", "scream_15m"]:
		series.append({"name": k.to_upper().replace("_", " "), "x": xs, "y": plot[k], "dots": true, "line": true})
	var img := AudioPlot.chart("R4 VERIFY: DANGER AND HAWK SCREAM VS WIND, FLEEING SPARROW", series,
		{"x_label": "1 SPREAD 1.5X   2 SPREAD 2.0X   3 SPREAD 2.6X   4 TUCKED 2.6X (CRUISE MULTIPLES)", "y_label": "DB OVER THE WIND",
		"hlines": [{"y": 0.0, "label": "WIND LEVEL"}],
		"note": "DANGER: HEART+DRONE, BEST OF 125/250 HZ OCTAVES. SCREAM: HAWK AT 45/15 M, BEST OF 2K/4K OCTAVES, CALLS FADER INCLUDED."})
	img.save_png(Paths.artifacts("audio/verify/r4x").path_join("danger_scream_in_dive.png"))


## "Predator screech getting louder" (DESIGN, Audio). A hawk hunting a
## sparrow-sized player calls again and again as it closes in (the scream at
## the 0.6 crossing, hunting calls, the stoop scream). Each NEW call should
## start louder the closer the hawk is. Measured: the voice's gain at its
## start (Godot's distance law with the voice's own settings, the model the
## suite checks against the mixer within 0.7 dB), hawk at 60/40/20/10/5 m.
## Reported, and asserted only as "some growth from 60 m to 10 m".
func test_successive_screams_grow_as_the_hawk_closes() -> void:
	fx.set_tel({"world_scale": SPARROW_WS, "airspeed": FlightSoundMap.cruise(0.03)})
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, 60))
	var voices := fx.director.voices
	await wait_frames(2)
	var res := {}
	var gains := []
	for dist in [60.0, 40.0, 20.0, 10.0, 5.0]:
		voices.stop_all()
		hawk.global_position = Vector3(0, 100, dist)
		Events.threat_changed.emit(0.8, hawk)
		await wait_frames(2)
		var ok := voices.request_call(hawk, 20.0, true)
		await wait_frames(2)
		var g := -INF
		for v in voices.voices:
			if v.follows and v.bird == hawk and v.player.playing:
				g = voices.voice_gain_db(v) - v.base_db
		gains.append(g)
		res["%dm" % int(dist)] = {"started": ok, "gain_rel_unit_level_db": snappedf(g, 0.1)}
		print("[audio-verify-r4] new hawk call at %d m (%.0f perceived): %+.1f dB relative to its unit level" % [int(dist), dist / SPARROW_WS, g])
	Events.threat_changed.emit(0.0, null)
	voices.stop_all()
	_out["successive_screams"] = res
	metric("successive_screams", res)
	gt(float(gains[3]) - float(gains[0]), 3.0, "a new call from 10 m is louder than one from 60 m (%+.1f dB)" % (float(gains[3]) - float(gains[0])))


# --------------------------------------------------------- loop seams ---

## The menu music loops every 33.7 s and the forest chorus every 34 s. A gap
## or click at the wrap would be heard on every loop in the menu / a wood.
## Rendered through the mixer across the wrap and, as a control, across a
## stretch in the middle of the loop (same length). Skipping the playback's
## own onset (first 30 ms): the wrap's deepest 10 ms dip under the median
## may be at most 4 dB deeper than the control's, and its largest sample
## step at most 1.5x the control's.
func test_loop_seams_are_clean_on_the_mixer() -> void:
	var caps := fx.tap_buses("R4Seam", 1, AudioBuses.MASTER)
	var p := AudioStreamPlayer.new()
	p.bus = &"R4Seam0"
	fx.root.add_child(p)
	var bank := fx.director.bank
	var res := {}
	for key: StringName in [&"music_menu", &"amb_forest_birds"]:
		var st := bank.get_stream(key)
		check(st != null, "%s in the bank" % key)
		if st == null:
			continue
		var length := st.get_length()
		p.stream = st
		var r := {"length_s": snappedf(length, 0.01)}
		for part in [["wrap", maxf(0.0, length - 0.6)], ["control", length * 0.5]]:
			p.play(float(part[1]))
			var rec := await fx.record(get_tree(), caps[0], 1.4)
			p.stop()
			await wait_frames(2)
			var rate: float = rec["rate"]
			var m: PackedFloat32Array = rec["mono"].slice(int(0.03 * rate))
			var env := AudioAnalysis.envelope(m, rate, 0.01)
			var sorted := env.duplicate()
			sorted.sort()
			var med := sorted[sorted.size() / 2]
			var mn := sorted[0]
			var mx := 0.0
			var mx_at := 0
			for i in range(1, m.size()):
				var d := absf(m[i] - m[i - 1])
				if d > mx:
					mx = d
					mx_at = i
			r[part[0]] = {"dip_db": snappedf(_db(mn) - _db(med), 0.1), "dip_at_s": snappedf(env.find(mn) * 0.01 + 0.03, 0.01),
				"median_dbfs": snappedf(_db(med), 0.1), "max_step": snappedf(mx, 0.0001), "max_step_at_s": snappedf(mx_at / rate + 0.03, 0.001),
				"after_wrap_dbfs": snappedf(_db(AudioAnalysis.rms(m, int(0.8 * rate), int(1.3 * rate))), 0.1)}
			AudioSynth.make_wav(rec["l"], rec["r"], int(rate)).save_to_wav(Paths.artifacts("audio/verify/r4x").path_join("seam_%s_%s.wav" % [key, part[0]]))
		gt(float(r["wrap"]["after_wrap_dbfs"]), -60.0, "%s keeps playing after its end (loops)" % key)
		if key == &"amb_forest_birds":
			# A sparse chorus: chirps make the mixer stretches non-stationary,
			# so check the (crossfaded) source instead: the wrap's sample jump
			# against the clip's steps, and the noise floor either side.
			var pcm := AudioAnalysis.clip_pcm(st)
			var x: PackedFloat32Array = pcm["mono"]
			var sr: float = pcm["rate"]
			var steps := PackedFloat32Array()
			for i in range(1, x.size(), 3):
				steps.append(absf(x[i] - x[i - 1]))
			var jump := absf(x[0] - x[x.size() - 1])
			var p99 := AudioAnalysis.percentile(steps, 0.99)
			var tail := AudioAnalysis.envelope(x.slice(x.size() - int(sr)), sr, 0.01)
			var head := AudioAnalysis.envelope(x.slice(0, int(sr)), sr, 0.01)
			var ft := _db(AudioAnalysis.percentile(tail, 0.2))
			var fh := _db(AudioAnalysis.percentile(head, 0.2))
			r["source"] = {"jump": snappedf(jump, 0.0001), "p99_step": snappedf(p99, 0.0001), "floor_last_1s_dbfs": snappedf(ft, 0.1), "floor_first_1s_dbfs": snappedf(fh, 0.1)}
			res[String(key)] = r
			print("[audio-verify-r4] seam %s: %s" % [key, r])
			lt(jump, p99, "%s: the wrap's sample jump (%.4f) is within the clip's p99 step (%.4f)" % [key, jump, p99])
			lt(absf(ft - fh), 3.0, "%s: the noise floor is continuous across the wrap (%.1f vs %.1f dBFS)" % [key, ft, fh])
			continue
		res[String(key)] = r
		print("[audio-verify-r4] seam %s: %s" % [key, r])
		gt(float(r["wrap"]["dip_db"]), float(r["control"]["dip_db"]) - 4.0,
			"%s: no gap at the wrap (dip %.1f dB vs %.1f in the middle of the loop)" % [key, float(r["wrap"]["dip_db"]), float(r["control"]["dip_db"])])
		lt(float(r["wrap"]["max_step"]), 1.5 * float(r["control"]["max_step"]) + 1e-4,
			"%s: no click at the wrap (max step %.4f vs %.4f in the middle)" % [key, float(r["wrap"]["max_step"]), float(r["control"]["max_step"])])
	_out["loop_seams"] = res
	metric("loop_seams", res)


# ------------------------------------------------ updraft while soaring ---

## Thermalling is slow gliding (about 0.8x cruise) in 1-4 m/s of lift (the
## world's thermal cores are 3.8-4.4 m/s, ridges 2.8-3.4). The hum is the
## audio cue for rising air: it must be audible over that wind in its own
## bands (125/250 Hz) from 2 m/s, and clearly (3 dB) at 3 m/s.
func test_updraft_hum_audible_while_thermalling() -> void:
	var cruise := FlightSoundMap.cruise(0.03)
	var wind := fx.tap(AudioBuses.WIND)
	var body := fx.tap(AudioBuses.BODY)
	var res := {}
	for lift in [1.0, 2.0, 3.0]:
		fx.set_tel({"airspeed": cruise * 0.8, "in_updraft": lift, "wing_extension": 1.0, "tucked": false})
		await Fixture.wait(get_tree(), 0.8)
		var pair := await fx.record2(get_tree(), wind, body, 1.2)
		var rate: float = pair[0]["rate"]
		var wo := _octaves(pair[0]["mono"], rate)
		var bo := _octaves(pair[1]["mono"], rate)
		var m := maxf(bo[1] - wo[1], bo[2] - wo[2])
		var aw: float = AudioAnalysis.loudness_aw(pair[1]["mono"], rate, 0.4)["mean"] - AudioAnalysis.loudness_aw(pair[0]["mono"], rate, 0.4)["mean"]
		res["lift_%.0f" % lift] = {"band_margin_db": snappedf(m, 0.1), "aw_margin_db": snappedf(aw, 0.1), "hum_oct": _oct_dict(bo), "wind_oct": _oct_dict(wo)}
		print("[audio-verify-r4] hum at %.0f m/s, 0.8x cruise: best 125/250 Hz band %+.1f dB, A-weighted %+.1f dB vs wind" % [lift, m, aw])
		if lift >= 3.0:
			gt(m, 3.0, "hum at 3 m/s: >= 3 dB over the wind in its band (%+.1f)" % m)
		elif lift >= 2.0:
			gt(m, 0.0, "hum at 2 m/s: at least the wind's level in its band (%+.1f)" % m)
	_out["hum_thermalling"] = res
	metric("hum_thermalling", res)


# ------------------------------------------------------------- moth ---

## "moth = soft flutter": a small bird hovering next to a moth should hear
## it (soft, but there); chasing it at cruise is reported, not asserted.
func test_moth_flutter_is_heard_close_up() -> void:
	var cruise := FlightSoundMap.cruise(0.03)
	fx.set_tel({"world_scale": SPARROW_WS})
	var calls := fx.tap(AudioBuses.CALLS)
	var wind := fx.tap(AudioBuses.WIND)
	var res := {}
	for case in [["hover_0.25m", 0.15, 0.25], ["hover_0.5m", 0.15, 0.5], ["cruise_0.25m", 1.0, 0.25]]:
		fx.set_tel({"airspeed": cruise * float(case[1])})
		var moth := fx.add_npc(&"moth", Vector3(0, 100, -float(case[2])))
		await Fixture.wait(get_tree(), 0.8)
		var recs := await fx.record_many(get_tree(), [calls, wind], 1.0)
		var rate: float = recs[0]["rate"]
		var fad := _fader(AudioBuses.CALLS)
		var m_aw: float = AudioAnalysis.loudness_aw(recs[0]["mono"], rate, 0.4)["mean"] + fad
		var w_aw: float = AudioAnalysis.loudness_aw(recs[1]["mono"], rate, 0.4)["mean"]
		var voiced := false
		for v in fx.director.voices.voices:
			if v.bird == moth and v.player.playing:
				voiced = true
		res[case[0]] = {"voiced": voiced, "moth_dba": snappedf(m_aw, 0.1), "wind_dba": snappedf(w_aw, 0.1), "margin_db": snappedf(m_aw - w_aw, 0.1)}
		print("[audio-verify-r4] moth %s: voiced %s, %.1f dB A vs wind %.1f (%+.1f)" % [case[0], voiced, m_aw, w_aw, m_aw - w_aw])
		if String(case[0]).begins_with("hover"):
			check(voiced, "%s: the moth near a hovering bird gets a voice" % case[0])
			gt(m_aw - w_aw, 0.0, "%s: its flutter is over the (quiet) wind (%+.1f dB A)" % [case[0], m_aw - w_aw])
		fx.npcs.erase(moth)
		moth.get_parent().remove_child(moth)
		moth.queue_free()
		await Fixture.wait(get_tree(), 0.3)
	_out["moth"] = res
	metric("moth", res)


# ------------------------------------------------- robustness to NaN ---

## One frame of NaN telemetry (a flight-model hiccup, a tracking dropout
## feeding wing_extension) or a NaN threat level must not poison a smoothed
## layer forever: 0.8 s later the wind, the hum and the danger cue are back
## at their levels (within 3 dB; the Body bus within 6 dB, since the hum's
## 0.25 Hz beating moves a 2.1 s RMS by about 3 dB; a poisoned layer is
## 80+ dB off), nothing captured is NaN.
func test_one_bad_frame_does_not_break_the_mix() -> void:
	var log := ErrorLog.install()
	var cruise := FlightSoundMap.cruise(0.03)
	var good := {"airspeed": cruise * 1.2, "wing_extension": 1.0, "tucked": false, "in_updraft": 2.5, "stalled": false, "stall_warning": 0.0}
	var res := {}
	for bad in [["wing_extension_nan", {"wing_extension": NAN}], ["in_updraft_nan", {"in_updraft": NAN}],
			["stall_warning_nan", {"stall_warning": NAN}], ["airspeed_inf", {"airspeed": INF}], ["airspeed_nan", {"airspeed": NAN}],
			["threat_nan", {}]]:
		# A fresh director for every case: each is measured on its own.
		fx.teardown()
		await Fixture.wait(get_tree(), 0.05)
		Game.set_state(Game.State.PLAYING)
		fx = Fixture.new()
		fx.build(self)
		await wait_frames(2)
		var wind := fx.tap(AudioBuses.WIND)
		var body := fx.tap(AudioBuses.BODY)
		var danger := fx.tap(AudioBuses.DANGER)
		var hawk := fx.add_npc(&"hawk", Vector3(0, 100, -60))
		fx.set_tel(good)
		Events.threat_changed.emit(0.5, hawk)
		await Fixture.wait(get_tree(), 1.0)
		var before := await fx.record_many(get_tree(), [wind, body, danger], 2.1)
		if String(bad[0]) == "threat_nan":
			Events.threat_changed.emit(NAN, hawk)
		else:
			fx.set_tel(bad[1])
		await wait_frames(2)
		fx.set_tel(good)
		Events.threat_changed.emit(0.5, hawk)
		await Fixture.wait(get_tree(), 0.8)
		var after := await fx.record_many(get_tree(), [wind, body, danger], 2.1)
		var d := {}
		var nan_seen := false
		for i in 3:
			var b0 := _db(AudioAnalysis.rms(before[i]["mono"]))
			var b1 := _db(AudioAnalysis.rms(after[i]["mono"]))
			nan_seen = nan_seen or _has_nan(after[i]["mono"])
			d[["wind", "body", "danger"][i]] = snappedf(b1 - b0, 0.1)
		var gains_ok := true
		var bad_layers: Array[String] = []
		for l in fx.director._layers:
			if not is_finite(l.gain):
				gains_ok = false
				bad_layers.append(String(l.key))
		d["nan_in_mix"] = nan_seen
		d["non_finite_layers"] = bad_layers
		d["cutoff_finite"] = is_finite(fx.director._cut)
		res[bad[0]] = d
		print("[audio-verify-r4] bad frame %s: %s" % [bad[0], d])
		check(not nan_seen, "%s: no NaN reaches the mix" % bad[0])
		check(gains_ok, "%s: every layer's smoothed gain is finite again (broken: %s)" % [bad[0], bad_layers])
		check(is_finite(fx.director._cut), "%s: the wind cut-off is finite again" % bad[0])
		for k in ["wind", "body", "danger"]:
			var tol := 6.0 if k == "body" else 3.0
			lt(absf(float(d[k])), tol, "%s: the %s level recovers within %.0f dB (%+.1f)" % [bad[0], k, tol, float(d[k])])
		Events.threat_changed.emit(0.0, null)
	log.uninstall()
	res["errors"] = log.errors
	res["error_samples"] = log.samples
	_out["bad_frames"] = res
	metric("bad_frames", res)
	eq(log.errors, 0, "no engine or script errors: %s" % [log.samples])


# ------------------------------------------------------------- soak ---

## 40 s of a busy sky at the pace of real play (not chaos): 40 NPCs moving,
## churn every second, flaps at 2 Hz, the threat rising and falling, a catch
## every 4 s, a pause every 12 s, the player growing (world_scale 0.14 ->
## 0.6). Bookkeeping stays bounded by the live birds, the cost does not
## creep (second half vs first half), the heart keeps its tempo (beats
## counted vs expected), no errors, and everything releases at the end.
func test_soak_40s_busy_sky() -> void:
	var log := ErrorLog.install()
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var cruise := FlightSoundMap.cruise(0.03)
	var species: Array[StringName] = [&"moth", &"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var at := Vector3(0, 100, 0)
	var alive: Array[Bird] = []
	for i in 40:
		alive.append(fx.add_npc(species[rng.randi() % species.size()], at + Vector3(rng.randf_range(-40, 40), rng.randf_range(-8, 12), rng.randf_range(-40, 40))))
	var post := fx.tap(AudioBuses.MASTER)
	var voices := fx.director.voices
	fx.director.reset_perf()
	var beats0 := fx.director.beats
	var state := {"t": 0.0, "max_voices": 0, "max_next": 0, "max_connected": 0, "removed": 0, "catches": 0, "pauses": 0,
		"perf_first": {}, "expected_beats": 0.0, "peak": 0.0, "ws": SPARROW_WS, "threat": 0.0}
	var hawk: Bird = fx.add_npc(&"hawk", at + Vector3(0, 20, 60))
	var dt := 0.1
	var driver := Timer.new()
	driver.wait_time = dt
	driver.process_mode = Node.PROCESS_MODE_ALWAYS
	fx.root.add_child(driver)
	driver.timeout.connect(func() -> void:
		state["t"] += dt
		var t: float = state["t"]
		state["max_voices"] = maxi(state["max_voices"], voices.active_count())
		state["max_next"] = maxi(state["max_next"], voices._next.size())
		state["max_connected"] = maxi(state["max_connected"], voices._connected.size())
		# Flight: glide, dive, climb in a thermal, repeat every 10 s.
		var ph := fmod(t, 10.0)
		var x := 1.0 if ph < 4.0 else (2.2 if ph < 6.0 else 0.8)
		state["ws"] = lerpf(SPARROW_WS, 0.6, clampf(t / 40.0, 0.0, 1.0))
		fx.set_tel({"airspeed": cruise * x, "tucked": ph >= 4.0 and ph < 6.0, "in_updraft": 3.0 if ph >= 6.0 else 0.0,
			"world_scale": state["ws"]})
		if int(round(t / dt)) % 5 == 0:
			Events.player_flapped.emit(rng.randi_range(-1, 1), rng.randf_range(0.3, 1.0))
		for b in alive:
			if is_instance_valid(b) and b.is_inside_tree():
				b.global_position += Vector3(rng.randf_range(-0.8, 0.8), rng.randf_range(-0.3, 0.3), rng.randf_range(-0.8, 0.8))
		# Churn: one bird leaves and one arrives every second.
		if int(round(t / dt)) % 10 == 0 and alive.size() > 5:
			var v: Bird = alive.pop_at(rng.randi() % alive.size())
			if is_instance_valid(v):
				fx.npcs.erase(v)
				v.alive = false
				v.get_parent().remove_child(v)
				v.queue_free()
				state["removed"] += 1
			alive.append(fx.add_npc(species[rng.randi() % species.size()], at + Vector3(rng.randf_range(-40, 40), rng.randf_range(-8, 12), rng.randf_range(-40, 40))))
		# The threat rises over 5 s and falls, every 10 s.
		var th := clampf(sin(t * TAU / 10.0) * 1.2, 0.0, 1.0)
		state["threat"] = th
		Events.threat_changed.emit(th, hawk if th > 0.0 else null)
		state["expected_beats"] += dt * FlightSoundMap.heart_rate(th)
		if int(round(t / dt)) % 40 == 20 and alive.size() > 5:
			var q: Bird = alive.pop_at(rng.randi() % alive.size())
			if is_instance_valid(q):
				Events.bird_caught.emit(fx.player, q)
				fx.npcs.erase(q)
				q.alive = false
				q.queue_free()
				state["catches"] += 1
		var tick := int(round(t / dt))
		if tick % 120 == 60:
			Game.set_state(Game.State.PAUSED)
			state["pauses"] += 1
		elif tick % 120 == 70:
			Game.set_state(Game.State.PLAYING)
		if tick == 200:
			state["perf_first"] = fx.director.perf_stats()
			fx.director.reset_perf())
	driver.start()
	var rec := await fx.record(get_tree(), post, 40.0)
	driver.stop()
	driver.queue_free()
	var perf2 := fx.director.perf_stats()
	var beats := fx.director.beats - beats0
	var pk := _db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"])))
	var live := 0
	for b in alive:
		if is_instance_valid(b) and b.is_inside_tree():
			live += 1
	# Release.
	Game.set_state(Game.State.PLAYING)
	Events.threat_changed.emit(0.0, null)
	for b in fx.npcs.duplicate():
		if is_instance_valid(b):
			if b.is_inside_tree():
				b.get_parent().remove_child(b)
			b.queue_free()
	fx.npcs.clear()
	alive.clear()
	fx.set_tel({"airspeed": 0.0, "perched": true, "in_updraft": 0.0, "world_scale": 1.0, "tucked": false})
	await Fixture.wait(get_tree(), 1.2)
	var t0 := Time.get_ticks_msec()
	while _fader(AudioBuses.CALLS) < -0.05 and Time.get_ticks_msec() - t0 < 4000:
		await get_tree().process_frame
	log.uninstall()
	var r := {"live_birds_end": live, "max_voices": state["max_voices"], "max_next": state["max_next"], "max_connected": state["max_connected"],
		"removed": state["removed"], "catches": state["catches"], "pauses": state["pauses"], "beats": beats,
		"beats_expected_approx": snappedf(state["expected_beats"], 0.1), "output_peak_dbfs": snappedf(pk, 0.01),
		"perf_first_20s": state["perf_first"], "perf_last_20s": perf2, "voices_after": voices.active_count(),
		"calls_fader_after": _fader(AudioBuses.CALLS), "errors": log.errors, "error_samples": log.samples, "vstats": voices.stats,
		"next_after": voices._next.size(), "connected_after": voices._connected.size()}
	_out["soak"] = r
	metric("soak", r)
	print("[audio-verify-r4] soak: %s" % [r])
	eq(log.errors, 0, "no errors in 40 s: %s" % [log.samples])
	lt(float(state["max_voices"]), 8.5, "never more than 8 voices (%d)" % state["max_voices"])
	lt(float(state["max_next"]), 60.0, "call timers bounded by the live birds (%d)" % state["max_next"])
	lt(float(state["max_connected"]), 60.0, "behaviour hooks bounded by the live birds (%d)" % state["max_connected"])
	lt(pk, -1.0, "output under -1 dBFS for 40 s (%.2f)" % pk)
	var m1: float = float(state["perf_first"].get("median", 0.0))
	var m2: float = float(perf2["median"])
	lt(m2, 0.2, "median cost < 0.2 ms in the last 20 s (%.3f)" % m2)
	lt(m2, m1 * 1.5 + 0.02, "cost does not creep (%.3f -> %.3f ms)" % [m1, m2])
	eq(voices.active_count(), 0, "no voice left once the sky is clear")
	gt(_fader(AudioBuses.CALLS), -0.05, "Calls bus back to 0 dB (%.2f)" % _fader(AudioBuses.CALLS))
	lt(float(voices._next.size()), 1.0, "no call timers left for gone birds (%d)" % voices._next.size())
