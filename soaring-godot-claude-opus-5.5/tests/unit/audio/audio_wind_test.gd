extends TestCase
## AU1 and AU4: the wind and the danger cue, rendered by the engine's mixer
## (not a model of it) and measured offline:
##  * RMS rises strictly with airspeed (sparrow and eagle), a dive is far
##    louder than a glide;
##  * a tucked dive is spectrally brighter (centroid, roll-off) and thinner
##    (less low end) than the same speed with wings spread, and louder to
##    the ear;
##  * the wind follows the head (turned away from the flight, the ear
##    facing the airflow hears it louder);
##  * a stall buffets periodically at the size's buffet rate (and not
##    otherwise); the updraft hum follows the lift;
##  * the danger cue gets strictly louder with the threat level, its heart
##    faster at a fixed pitch, and it stands over the wind where the wind is
##    strongest (at 1.5x cruise and in a spread 2.6x dive);
##  * at maximum load (everything at once) the output never clips: peak
##    below -1 dBFS; realistic heavy play never reaches the limiter;
##  * the living sky: the Ecosystem's birds heard over the wind at every
##    player size.
## Renders land in artifacts/audio/renders/, numbers in measurements.json.
##
## The flight tests read one flight session per size, recorded once in
## before_all: the headless mixer runs in real time, and the wind (Wind
## bus), the buffet and hum (Body bus), the danger cue (Danger bus) and the
## NPC calls (Calls bus) are separate layers on separate buses, so one sweep
## measures them all. What a step adds besides speed (lift, a stall, the
## head turned, a threat) drives only its own layer: lift and stall only
## the Body layers, the head only the wind's pan, which keeps the mono sum
## (Godot's panner moves one channel into the other), a threat only the
## Danger bus (a threat level with no predator: no scream, no voice). The
## Danger and Calls buses are recorded without a break through the
## sparrow's session (the heart's tempo needs beats in a row), each step's
## own stretch cut from it where it was recorded alongside the wind. The
## sparrow's session flies through the Ecosystem's sky (60 NPCs round it)
## up to cruise.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")

var fx: Fixture
## Size -> steps [{ratio, tel, label, threat, wind: {l, r, mono, rate},
## body: {...}, danger_from, danger_to (frames into `danger`)}].
var session := {}
## The sparrow session's whole Danger bus {l, r, mono, rate}, and where each
## threat level was set in it: [[level, frame], ...].
var danger := {}
var threat_marks := []
## The heartbeat player's pitch_scale through the session (must stay 1).
var heart_pitches := PackedFloat32Array()


## One step per row: [airspeed / cruise, extra telemetry, settle s, record s,
## threat level set as the step begins (null: unchanged), label ("": part
## of the speed sweep)]. Speeds rise through the sweep (the wind's attack is
## 0.06 s; a release would need longer settles); the thermal steps come
## early and the stall last, so a hum or a buffet never rings into another
## Body measurement. The glide and the dive are recorded 0.4 s or more
## (gusty low-frequency noise: 0.2 s of it reads within about 0.5 dB, 0.4 s
## within 0.3).
## The tuck is judged at 2.6x cruise, spread against tucked (the dive's own
## steps).
## The danger cue rides along: threat 0 first (silence), 0.25 for three
## steps (2.2 beat periods for the resting heart's tempo after 0.18 s for
## the new level: the heart's generator buffers 0.15 s), 0.5 from 1.5x
## cruise (one period, over the 1.5x wind) on, over a spread 2.6x dive (one
## period), then 1 (two periods over it: the wind's low octaves move by a
## dB or two from one beat to the next; and on without a break into the
## tucked dive for the racing heart's tempo and rhythm), and 0.75 at the
## stall. Every level's loudness is taken where the drone's make-up for a
## fast spread dive is 0 (at or under 1.5x cruise, or tucked:
## FlightSoundMap.danger_makeup_db), so it is the threat's alone; a falling
## level gets 0.5 s to settle (the layers' release is 0.18 s).
const SPARROW_PLAN := [
	[0.15, {}, 0.2, 0.2, 0.0, ""],
	[0.4, {"in_updraft": 1.0}, 0.2, 0.35, 0.25, ""],
	[0.7, {"in_updraft": 4.0}, 0.2, 0.35, null, ""],
	[1.0, {}, 0.6, 0.4, null, ""],
	[1.5, {}, 0.2, 0.75, 0.5, ""],
	[1.8, {}, 0.2, 0.2, null, ""],
	[2.2, {}, 0.25, 0.4, null, ""],
	[2.6, {}, 0.2, 0.75, null, "danger_0.5"],
	[2.6, {}, 0.2, 1.1, 1.0, "danger_1"],
	[2.6, {"tucked": true, "wing_extension": 0.1}, 0.5, 0.55, null, ""],
	[0.5, {"stalled": true}, 0.5, 0.65, 0.75, ""],
]
## The eagle flies with its head turned 90 degrees left from the start
## (the pan follows over 0.3 s; it is full from cruise up).
const EAGLE_PLAN := [
	[0.15, {}, 0.2, 0.2, null, ""],
	[1.3, {}, 0.2, 0.2, null, ""],
	[2.6, {}, 0.2, 0.3, null, ""],
	[0.5, {"stalled": true}, 0.2, 0.6, null, ""],
]
## World scale by size (span / (1.6 m arms + 0.2): WorldScaleDriver).
const SPARROW_WS := 0.24 / 1.8
const EAGLE_WS := 2.1 / 1.8
## The sparrow's session has the Ecosystem's sky round it up to this step
## (cruise), recorded on the Calls bus (the living-sky test).
const SKY_UNTIL := 1.0
## Sky details from the session: {calls: {l, r, mono, rate} over the slow
## steps, started, stats}.
var sky := {}


func before_all() -> void:
	Game.set_state(Game.State.PLAYING)
	for spec in [[&"sparrow", 0.03, SPARROW_PLAN, SPARROW_WS], [&"eagle", 3.0, EAGLE_PLAN, EAGLE_WS]]:
		# A fresh, silent stage per size.
		var st := Fixture.new()
		st.build(self)
		await wait_frames(2)
		st.player.mass = spec[1]
		st.player.species = spec[0]
		if spec[0] == &"eagle":
			st.listener.rotation = Vector3(0.0, PI * 0.5, 0.0)
		var wind := st.tap(AudioBuses.WIND)
		var body := st.tap(AudioBuses.BODY)
		var dtap := st.tap(AudioBuses.DANGER, -1, 12.0)
		var calls := st.tap(AudioBuses.CALLS)
		var voices := st.director.voices
		var heart: AudioStreamPlayer = st.director.get_node("Heartbeat")
		var sky_birds: Array = []
		var started0: int = voices.stats["started"]
		var rate := AudioServer.get_mix_rate()
		if spec[0] == &"sparrow":
			var rng := RandomNumberGenerator.new()
			rng.seed = 505
			sky_birds = st.add_sky(st.listener.global_position, rng)
			calls.clear_buffer()
			dtap.clear_buffer()
		var cruise := FlightSoundMap.cruise(spec[1])
		var steps := []
		for row: Array in spec[2]:
			var tel := {"airspeed": cruise * float(row[0]), "tucked": false, "wing_extension": 1.0, "stalled": false,
				"in_updraft": 0.0, "world_scale": spec[3]}
			tel.merge(row[1], true)
			st.set_tel(tel)
			if row[4] != null:
				threat_marks.append([float(row[4]), dtap.get_frames_available()])
				Events.threat_changed.emit(float(row[4]), null)
			await Fixture.wait(get_tree(), row[2])
			# The wind and body taps start where the danger tap stands (the
			# mixer locked: no block falls between the two).
			AudioServer.lock()
			var from := dtap.get_frames_available()
			wind.clear_buffer()
			body.clear_buffer()
			AudioServer.unlock()
			var need := int(float(row[3]) * rate)
			var fw := PackedVector2Array()
			var fb := PackedVector2Array()
			while fw.size() < need or fb.size() < need:
				await get_tree().process_frame
				fw.append_array(wind.get_buffer(wind.get_frames_available()))
				fb.append_array(body.get_buffer(body.get_frames_available()))
			var rw := AudioAnalysis.split_frames(fw.slice(0, need))
			var rb := AudioAnalysis.split_frames(fb.slice(0, need))
			rw["rate"] = rate
			rb["rate"] = rate
			heart_pitches.append(heart.pitch_scale)
			steps.append({"ratio": row[0], "tel": row[1], "label": row[5], "wind": rw, "body": rb,
				"threat": st.director.threat_level, "danger_from": from, "danger_to": from + need})
			if not sky_birds.is_empty() and is_equal_approx(float(row[0]), SKY_UNTIL) and (row[1] as Dictionary).is_empty():
				# The sky's calls up to cruise, then the sky goes (the rest of
				# the session measures other layers).
				var frames := calls.get_buffer(calls.get_frames_available())
				var d := AudioAnalysis.split_frames(frames)
				d["rate"] = rate
				sky = {"calls": d, "started": int(voices.stats["started"]) - started0, "stats": voices.stats.duplicate(),
					"birds": sky_birds.size()}
				voices.scheduling = false
				voices.stop_all()
				for b in sky_birds:
					st.npcs.erase(b)
					b.get_parent().remove_child(b)
					b.queue_free()
				sky_birds.clear()
		if spec[0] == &"sparrow":
			# Every frame the Danger bus mixed since the session began.
			await get_tree().process_frame
			danger = AudioAnalysis.split_frames(dtap.get_buffer(dtap.get_frames_available()))
			danger["rate"] = rate
		session[spec[0]] = steps
		Events.threat_changed.emit(0.0, null)
		st.teardown()
		await Fixture.wait(get_tree(), 0.025)


## The Danger bus from frame a to b of the sparrow's session: {l, r, mono, rate}.
func _danger(a: int, b: int) -> Dictionary:
	var out := {"rate": danger["rate"]}
	for ch in ["l", "r", "mono"]:
		var buf: PackedFloat32Array = danger[ch]
		out[ch] = buf.slice(clampi(a, 0, buf.size()), clampi(b, 0, buf.size()))
	return out


## The Danger bus recorded alongside a session step's wind.
func _danger_of(stp: Dictionary) -> Dictionary:
	return _danger(int(stp["danger_from"]), int(stp["danger_to"]))


func before_each() -> void:
	# The director starts in play: no test waits out a menu duck.
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


## Before the suite ends (the runner may quit next): give the mixer time to
## drop every stopped playback, or the engine reports them as leaked.
func after_all() -> void:
	await Fixture.wait(get_tree(), 0.15)


func after_each() -> void:
	fx.teardown()
	# A frame: the mixer drops the freed players' playbacks in its next
	# block, while the next test builds its stage and settles (after_all
	# waits longer before the runner may quit).
	await get_tree().process_frame


## The session's step at `ratio` whose extra telemetry has `key` (or none).
func _step(size: StringName, ratio: float, key: String = "") -> Dictionary:
	for st: Dictionary in session[size]:
		if is_equal_approx(float(st["ratio"]), ratio) and (key.is_empty() == (st["tel"] as Dictionary).is_empty()) \
				and (key.is_empty() or (st["tel"] as Dictionary).has(key)):
			return st
	return {}


## The sweep: the steps with wings spread and no stall, in flight order
## (a step repeated for the danger cue at the same speed is not a new one).
func _sweep(size: StringName) -> Array:
	var out := []
	for st: Dictionary in session[size]:
		var t: Dictionary = st["tel"]
		if not t.get("tucked", false) and not t.get("stalled", false) and String(st["label"]) in ["", "danger_0.5"]:
			out.append(st)
	return out


## The session step with this label.
func _labelled(size: StringName, label: String) -> Dictionary:
	for st: Dictionary in session[size]:
		if String(st["label"]) == label:
			return st
	return {}


func test_wind_rms_rises_strictly_with_airspeed() -> void:
	var results := {}
	for size: StringName in [&"sparrow", &"eagle"]:
		var cruise := FlightSoundMap.cruise(0.03 if size == &"sparrow" else 3.0)
		var xs := PackedFloat32Array()
		var dbs := PackedFloat32Array()
		var prev := -INF
		var ok := true
		var at_cruise := NAN
		for st: Dictionary in _sweep(size):
			# 0.2 s settles the level (3 time constants of its 0.06 s attack)
			# and the filter; 0.2 s of noise gives its RMS within ~0.4 dB,
			# against steps of 2.3 dB or more.
			var d := AudioAnalysis.db(AudioAnalysis.rms(st["wind"]["mono"]))
			xs.append(cruise * float(st["ratio"]))
			dbs.append(d)
			if d <= prev + 0.5:
				ok = false
				fail("%s: wind RMS not rising at %.1f m/s (%.2f dB after %.2f dB)" % [size, cruise * float(st["ratio"]), d, prev])
			prev = d
			if is_equal_approx(float(st["ratio"]), 1.0):
				at_cruise = d
		check(ok, "%s wind RMS strictly increasing over %d airspeeds" % [size, dbs.size()])
		results[String(size)] = {"airspeed": Array(xs), "rms_db": Array(dbs)}
		metric("%s_rms_db" % size, Array(dbs))
		# Silence when stopped, clearly audible at cruise.
		if size == &"sparrow":
			lt(dbs[0], at_cruise - 25.0, "sparrow: nearly silent at 0.15x cruise vs cruise")
			# A tucked dive (2.6x cruise) against a glide at cruise.
			var glide := _step(size, 1.0)
			var dive := _step(size, 2.6, "tucked")
			var dv := AudioAnalysis.db(AudioAnalysis.rms(dive["wind"]["mono"]))
			metric("glide_db", at_cruise)
			metric("dive_db", dv)
			gt(dv - at_cruise, 12.0, "tucked dive (2.6x cruise) at least 12 dB louder than a glide at cruise (+%.1f)" % (dv - at_cruise))
			Fixture.save_render(glide["wind"], "wind_glide_sparrow")
			Fixture.save_render(dive["wind"], "wind_dive_tucked_sparrow")
			Fixture.save_measure("dive_vs_glide", {"glide_db": at_cruise, "dive_db": dv})
		else:
			lt(dbs[0], dbs[1] - 25.0, "eagle: nearly silent at 0.15x cruise vs 1.3x")
	Fixture.save_measure("wind_rms", results)


func test_tuck_is_brighter_and_thinner() -> void:
	var spread: Dictionary = _step(&"sparrow", 2.6)["wind"]
	var tucked: Dictionary = _step(&"sparrow", 2.6, "tucked")["wind"]
	var rate: float = spread["rate"]
	var ps := AudioAnalysis.mean_power(spread["mono"], 2048, 1024, -60.0)
	var pt := AudioAnalysis.mean_power(tucked["mono"], 2048, 1024, -60.0)
	var c_s := AudioAnalysis.centroid(ps, rate, 20.0)
	var c_t := AudioAnalysis.centroid(pt, rate, 20.0)
	var r_s := AudioAnalysis.rolloff(ps, rate, 0.85)
	var r_t := AudioAnalysis.rolloff(pt, rate, 0.85)
	var low_s := AudioAnalysis.band_fraction(ps, rate, 20.0, 400.0)
	var low_t := AudioAnalysis.band_fraction(pt, rate, 20.0, 400.0)
	var hi_s := AudioAnalysis.band_fraction(ps, rate, 3000.0, 20000.0)
	var hi_t := AudioAnalysis.band_fraction(pt, rate, 3000.0, 20000.0)
	metric("centroid_spread", c_s)
	metric("centroid_tucked", c_t)
	metric("rolloff_spread", r_s)
	metric("rolloff_tucked", r_t)
	metric("low_frac_spread", low_s)
	metric("low_frac_tucked", low_t)
	metric("high_frac_spread", hi_s)
	metric("high_frac_tucked", hi_t)
	gt(c_t / c_s, 1.5, "tucked: spectral centroid at least 1.5x higher (brighter)")
	gt(r_t / r_s, 1.4, "tucked: 85% roll-off at least 1.4x higher")
	lt(low_t, low_s * 0.35, "tucked: under a third of the < 400 Hz share (thinner)")
	gt(hi_t, hi_s * 2.0, "tucked: at least twice the > 3 kHz share")
	# Thinner is not quieter: the tuck's high-pass removes low-end energy
	# (plain RMS drops) but TUCK_DB and the edge layer put it back where the
	# ear listens, so to the ear (A-weighted) a tucked dive is louder:
	# clearly, 3 dB, a step anyone hears (the tuck's own 2.5 dB of level,
	# TUCK_DB, is part of it; the edge layer and the open low-pass bring the
	# rest).
	var aw_s := AudioAnalysis.a_weighted_db(ps, rate)
	var aw_t := AudioAnalysis.a_weighted_db(pt, rate)
	metric("a_weighted_gain_db", aw_t - aw_s)
	gt(aw_t - aw_s, 3.0, "tucked: clearly louder to the ear (A-weighted) at the same speed (+%.1f dB)" % (aw_t - aw_s))
	Fixture.save_render(spread, "wind_2.6x_spread")
	Fixture.save_render(tucked, "wind_2.6x_tucked")
	Fixture.save_measure("tuck", {"centroid": [c_s, c_t], "rolloff": [r_s, r_t], "low_frac": [low_s, low_t],
		"high_frac": [hi_s, hi_t], "spread_power": Array(ps), "tucked_power": Array(pt), "rate": rate})


## The wind is placed by the head (a VR direction cue): flying along -Z
## with the head turned 90 degrees left, the air arrives from the head's
## right, and the right ear hears it louder (the eagle's session). Head
## straight (the sparrow's), both ears hear it alike.
func test_wind_follows_the_head() -> void:
	var straight := PackedFloat32Array()
	for r in [1.5, 1.8, 2.6]:
		var w: Dictionary = _step(&"sparrow", r)["wind"]
		straight.append(AudioAnalysis.db(AudioAnalysis.rms(w["r"])) - AudioAnalysis.db(AudioAnalysis.rms(w["l"])))
	var t: Dictionary = _step(&"eagle", 2.6)["wind"]
	var turned := AudioAnalysis.db(AudioAnalysis.rms(t["r"])) - AudioAnalysis.db(AudioAnalysis.rms(t["l"]))
	metric("wind_right_minus_left_db", {"straight": Array(straight), "head_turned_left": turned})
	for x in straight:
		lt(absf(x), 1.5, "head straight: the wind is centred (R - L %+.1f dB)" % x)
	gt(turned, 4.0, "head turned left: the air arrives at the right ear, louder there (R - L %+.1f dB)" % turned)


func test_stall_buffets_periodically() -> void:
	var out := {}
	for size: StringName in [&"sparrow", &"eagle"]:
		# No stall, no buffet (the first step, before any stall has played).
		var calm_db := AudioAnalysis.db(AudioAnalysis.rms(_step(size, 0.15)["body"]["mono"]))
		metric("%s_unstalled_db" % size, calm_db)
		lt(calm_db, -70.0, "%s: no buffet without a stall" % size)
		var stall: Dictionary = _step(size, 0.5, "stalled")["body"]
		var rate: float = stall["rate"]
		var env := AudioAnalysis.envelope(stall["mono"], rate, 0.002)
		var per := AudioAnalysis.periodicity(env, 500.0, 5.0, 40.0)
		var want := 14.0 * FlightSoundMap.flutter_pitch(0.03 if size == &"sparrow" else 3.0)
		metric("%s_buffet_hz" % size, per["hz"])
		metric("%s_periodicity" % size, per["strength"])
		near(per["hz"], want, want * 0.06, "%s: buffet at %.1f Hz" % [size, want])
		gt(per["strength"], 0.6, "%s: buffet strongly periodic (normalised autocorrelation)" % size)
		Fixture.save_render(stall, "stall_buffet_%s" % size)
		out[String(size)] = {"hz": per["hz"], "strength": per["strength"], "want": want,
			"env": Array(env.slice(0, 500))}
	# The size scaling, pinned on the measured rates (not on flutter_pitch,
	# the code under test): a small bird's feathers buffet fast, an eagle's
	# big flight feathers clearly slower.
	var sp_hz: float = out["sparrow"]["hz"]
	var ea_hz: float = out["eagle"]["hz"]
	between(sp_hz, 12.0, 16.0, "sparrow buffets at 12-16 Hz")
	between(ea_hz, 8.0, 12.0, "eagle buffets at 8-12 Hz")
	lt(ea_hz, sp_hz * 0.8, "an eagle buffets at most 0.8x a sparrow's rate")
	Fixture.save_measure("stall", out)


## The updraft hum, a variometer-like cue on the Body bus in slow flight
## (no buffet, no wingbeats): silent without lift, audible in a 1 m/s
## thermal, clearly louder and higher in strong (4 m/s) lift.
func test_updraft_hum_follows_lift() -> void:
	var out := {}
	for row in [[0.0, 0.15, ""], [1.0, 0.4, "in_updraft"], [4.0, 0.7, "in_updraft"]]:
		var rec: Dictionary = _step(&"sparrow", row[1], row[2])["body"]
		var pw := AudioAnalysis.mean_power(rec["mono"], 4096, 2048, -80.0)
		out[row[0]] = {"db": AudioAnalysis.db(AudioAnalysis.rms(rec["mono"])), "centroid": AudioAnalysis.centroid(pw, rec["rate"], 60.0, 600.0)}
	metric("hum", out)
	lt(out[0.0]["db"], -70.0, "no lift: no hum (%.1f dBFS)" % out[0.0]["db"])
	gt(out[1.0]["db"], -60.0, "1 m/s of lift: the hum sounds (%.1f dBFS)" % out[1.0]["db"])
	gt(out[4.0]["db"] - out[1.0]["db"], 6.0, "4 m/s: clearly louder (+%.1f dB)" % (out[4.0]["db"] - out[1.0]["db"]))
	gt(out[4.0]["centroid"] / out[1.0]["centroid"], 1.03, "and higher (centroid %.0f -> %.0f Hz)" % [out[1.0]["centroid"], out[4.0]["centroid"]])
	Fixture.save_measure("hum", {"lift": [0.0, 1.0, 4.0], "db": [out[0.0]["db"], out[1.0]["db"], out[4.0]["db"]],
		"centroid": [out[0.0]["centroid"], out[1.0]["centroid"], out[4.0]["centroid"]]})


## Octave bands for the comparisons over the wind (Hz, centre).
const OCTAVES: Array[float] = [125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0]


static func _octaves(p: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	for fc in OCTAVES:
		o.append(AudioAnalysis.band_db(p, rate, fc / sqrt(2.0), fc * sqrt(2.0)))
	return o


## Octave-band levels of a stereo recording, both ears' power summed (the
## measure CallVoices levels calls in: a voice straight ahead splits its
## power between the ears).
static func _ear_bands(rec: Dictionary) -> PackedFloat32Array:
	var rate: float = rec["rate"]
	var bl := _octaves(AudioAnalysis.mean_power(rec["l"], 2048, 1024, -90.0), rate)
	var br := _octaves(AudioAnalysis.mean_power(rec["r"], 2048, 1024, -90.0), rate)
	var o := PackedFloat32Array()
	for k in bl.size():
		o.append(10.0 * log(pow(10.0, bl[k] / 10.0) + pow(10.0, br[k] / 10.0)) / log(10.0))
	return o


## How far a sound stands over the wind in its own band (dB): the best
## octave among those within 10 dB of its strongest.
static func _over_in_own_band(snd: PackedFloat32Array, wind: PackedFloat32Array) -> float:
	var top := -INF
	for x in snd:
		top = maxf(top, x)
	var best := -INF
	for k in snd.size():
		if snd[k] >= top - 10.0:
			best = maxf(best, snd[k] - wind[k])
	return best


## Onsets (s) of the heartbeat in a Danger-bus recording: rising crossings
## of half the top of its low band (< 120 Hz; the drone's lowest partial is
## 165 Hz), re-armed below a quarter. 20 ms windows: longer than one cycle
## of the 58 Hz lub, so the envelope does not ripple with the waveform.
static func _heart_onsets(rec: Dictionary) -> PackedFloat32Array:
	var rate: float = rec["rate"]
	var low := AudioSynth.filter(rec["mono"], [AudioSynth.lp(120.0, 0.707, rate), AudioSynth.lp(120.0, 0.707, rate)])
	var env := AudioAnalysis.envelope(low, rate, 0.02)
	var top := 0.0
	for e in env:
		top = maxf(top, e)
	var onsets := PackedFloat32Array()
	var armed := env.size() > 0 and env[0] < 0.25 * top  # not a beat already sounding
	for i in env.size():
		if armed and env[i] >= 0.5 * top:
			onsets.append(i * 0.02)
			armed = false
		elif env[i] < 0.25 * top:
			armed = true
	return onsets


## The strongest partial between 40 and 150 Hz of a recording's mean power
## spectrum (parabolic interpolation between bins). Every beat has one lub
## and one dub whatever the tempo, so this picks the same partial at any
## threat level unless the heart is resampled.
static func _low_peak_hz(rec: Dictionary) -> float:
	var rate: float = rec["rate"]
	var p := AudioAnalysis.mean_power(rec["mono"], 4096, 4096, -40.0)
	var n := 4096
	var best := 0
	for i in range(int(40.0 * n / rate), int(150.0 * n / rate) + 1):
		if best == 0 or p[i] > p[best]:
			best = i
	var a := sqrt(p[best - 1])
	var b := sqrt(p[best])
	var c := sqrt(p[best + 1])
	var off := 0.5 * (a - c) / (a - 2.0 * b + c) if absf(a - 2.0 * b + c) > 1e-12 else 0.0
	return (best + off) * rate / n


## Heart rate (bpm) from lub-dub onsets: gaps alternate short (lub to dub)
## and long (dub to the next lub), so any two consecutive gaps make one beat
## period, whichever the recording started on.
static func _bpm(onsets: PackedFloat32Array) -> float:
	var periods := PackedFloat32Array()
	for i in range(2, onsets.size()):
		periods.append(onsets[i] - onsets[i - 2])
	return 60.0 / AudioAnalysis.median(periods) if not periods.is_empty() else 0.0


## The danger cue's level over the wind in the 125 and 250 Hz octaves
## (where the flight wind is strongest and a headset still plays), the
## better of the two, dB.
static func _danger_over_wind(dg: Dictionary, wd: Dictionary) -> Dictionary:
	var rate: float = dg["rate"]
	var od := _octaves(AudioAnalysis.mean_power(dg["mono"], 2048, 1024, -90.0), rate)
	var ow := _octaves(AudioAnalysis.mean_power(wd["mono"], 2048, 1024, -90.0), rate)
	return {"over_wind_db": maxf(od[0] - ow[0], od[1] - ow[1]), "danger_125_250_db": [od[0], od[1]], "wind_125_250_db": [ow[0], ow[1]]}


## AU4, from the sparrow's session (the Danger bus recorded without a break
## beside the wind; the threat levels set without a predator, so nothing
## screams):
##  * loudness: silent at threat 0, then strictly louder with the threat,
##    +1 dB or more per 0.25 and 15 dB or more from 0.25 to 1 (RMS over
##    exactly one beat period, so the window's start does not matter; each
##    where the drone's fast-flight make-up is 0);
##  * tempo on the mix, on literal ranges (not on heart_rate(), the code
##    under test): a faint threat beats like a resting heart (60-85 bpm),
##    contact races (100-125), 1.35x or more faster; the whole beat envelope
##    repeats at the racing rate; the heart's fundamental moves under a
##    semitone (a resampled loop moved it ~10.6); the dub 0.15-0.24 s after
##    the lub and the pause after it clearly longer: "lub-dub, pause";
##  * over the wind at 125/250 Hz: at 1.5x cruise >= 1 dB at threat 0.5, and
##    in a spread 2.6x dive, where the wind is strongest (round 5: 2.6-2.8 dB
##    under it at threat 0.5), >= 1 dB at 0.5 and >= 6 at 1. (Round 4 pinned
##    threat 1 at 1.5x, +10.7 dB; the spread dive is the harder case.) A
##    tucked dive thins the wind's low end (its 350 Hz high-pass): the danger
##    stood 12-19 dB clear there already.
func test_danger_cue_scales_with_threat() -> void:
	var rate: float = danger["rate"]
	var first := _step(&"sparrow", 0.15)
	var cruise := _step(&"sparrow", 1.0)
	var fast := _step(&"sparrow", 1.5)
	var dive := _step(&"sparrow", 2.6, "tucked")
	var stall := _step(&"sparrow", 0.5, "stalled")
	var mark := {}
	for m in threat_marks:
		if not mark.has(m[0]):
			mark[m[0]] = int(m[1])
	var settle := int(0.18 * rate)
	# One (or two) beat periods of the danger cue from frame a.
	var one := func(level: float, a: int) -> Dictionary:
		return _danger(a, a + int(round(rate / FlightSoundMap.heart_rate(level))))
	var one2 := func(level: float, a: int) -> Dictionary:
		return _danger(a, a + int(round(2.0 * rate / FlightSoundMap.heart_rate(level))))
	var recs := {
		0.0: _danger_of(first),
		0.25: _danger(mark[0.25] + settle, int(cruise["danger_to"])),
		1.0: _danger(mark[1.0] + settle, int(dive["danger_to"])),
	}
	var levels := [0.0, 0.25, 0.5, 0.75, 1.0]
	# Each level's loudness over one beat period from the start of its
	# window: 0.25 in the slow steps, 0.5 at 1.5x cruise, 0.75 at the stall,
	# 1 in the tucked 2.6x dive (the drone's make-up is 0 at all of them).
	var starts := {0.25: mark[0.25] + settle, 0.5: int(fast["danger_from"]), 0.75: int(stall["danger_from"]),
		1.0: int(dive["danger_from"])}
	var dbs := PackedFloat32Array()
	for lv in levels:
		var r: Dictionary = recs[0.0] if lv == 0.0 else one.call(lv, starts[lv])
		dbs.append(AudioAnalysis.db(AudioAnalysis.rms(r["mono"])))
	metric("danger_rms_db", Array(dbs))
	metric("threat_marks", threat_marks)
	near(float(first["threat"]), 0.0, 1e-4, "(threat 0 in the first step)")
	near(float(cruise["threat"]), 0.25, 1e-4, "(threat 0.25 at cruise)")
	near(float(fast["threat"]), 0.5, 1e-4, "(threat 0.5 at 1.5x cruise)")
	near(float(dive["threat"]), 1.0, 1e-4, "(threat 1 in the tucked dive)")
	near(float(stall["threat"]), 0.75, 1e-4, "(threat 0.75 at the stall)")
	lt(dbs[0], -70.0, "no danger sound at threat 0 (%.1f dBFS)" % dbs[0])
	var ok := true
	for i in range(1, dbs.size()):
		if dbs[i] <= dbs[i - 1] + 1.0:
			ok = false
			fail("danger RMS not rising from %.2f to %.2f (%.1f -> %.1f dB)" % [levels[i - 1], levels[i], dbs[i - 1], dbs[i]])
	check(ok, "danger loudness strictly increasing with threat level (>= 1 dB per 0.25)")
	gt(dbs[dbs.size() - 1] - dbs[1], 15.0, "threat 1.0 at least 15 dB louder than 0.25")
	for p in heart_pitches:
		if not is_equal_approx(p, 1.0):
			fail("the heartbeat was resampled (pitch_scale %.3f)" % p)
	check(not heart_pitches.is_empty(), "the heartbeat is never resampled (pitch_scale 1 at every step)")
	# Tempo, pitch and rhythm on the mix.
	var on_lo := _heart_onsets(recs[0.25])
	var on_hi := _heart_onsets(recs[1.0])
	var bpm_lo := _bpm(on_lo)
	var bpm_hi := _bpm(on_hi)
	metric("heart_bpm", [bpm_lo, bpm_hi])
	metric("recorded_s", [(recs[0.25]["mono"] as PackedFloat32Array).size() / rate, (recs[1.0]["mono"] as PackedFloat32Array).size() / rate])
	between(bpm_lo, 60.0, 85.0, "threat 0.25: the heart beats a resting 60-85 bpm (%.1f)" % bpm_lo)
	between(bpm_hi, 100.0, 125.0, "threat 1: the heart races at 100-125 bpm (%.1f)" % bpm_hi)
	gt(bpm_hi / maxf(bpm_lo, 1.0), 1.35, "the heart clearly speeds up with the threat (x%.2f)" % (bpm_hi / maxf(bpm_lo, 1.0)))
	var r1: Dictionary = recs[1.0]
	var env := AudioAnalysis.envelope(r1["mono"], r1["rate"], 0.01)
	var per := AudioAnalysis.periodicity(env, 100.0, 0.8, 3.0)
	metric("beat_hz_at_1", per["hz"])
	between(per["hz"] * 60.0, 100.0, 125.0, "threat 1: the whole beat envelope repeats at 100-125 bpm")
	# Over exactly two beat periods each, so both hold as many lubs as dubs
	# (the lub's partial sits a little under the dub's: a window with one
	# beat more of either reads it up to ~1 semitone apart, whatever the
	# pitch).
	var f_lo := _low_peak_hz(one2.call(0.25, starts[0.25]))
	var f_hi := _low_peak_hz(one2.call(1.0, mark[1.0] + settle))
	metric("heart_hz", [f_lo, f_hi])
	between(f_lo, 50.0, 80.0, "the heart's fundamental sits at the lub/dub's 58-70 Hz")
	lt(absf(log(f_hi / f_lo) / log(2.0) * 12.0), 1.0, "and moves under a semitone from threat 0.25 to 1 (%.1f -> %.1f Hz)" % [f_lo, f_hi])
	var gaps := PackedFloat32Array()
	for i in range(1, on_hi.size()):
		gaps.append(on_hi[i] - on_hi[i - 1])
	var short := INF
	var long := 0.0
	for g in gaps:
		short = minf(short, g)
		long = maxf(long, g)
	metric("heart_onset_gaps_s", Array(gaps))
	gt(on_hi.size(), 4.0, "threat 1: lubs and dubs are separate onsets on the mix (%d)" % on_hi.size())
	between(short, 0.15, 0.24, "threat 1: the dub follows the lub after 0.15-0.24 s (%.2f)" % short)
	gt(long / short, 1.5, "and the pause after the dub is clearly longer (%.2f vs %.2f s): a heartbeat, not an even pulse" % [long, short])
	# Over the wind where it is strongest.
	var over := {"1.5x_0.5": _danger_over_wind(_danger_of(fast), fast["wind"]),
		"2.6x_spread_0.5": _danger_over_wind(_danger_of(_labelled(&"sparrow", "danger_0.5")), _labelled(&"sparrow", "danger_0.5")["wind"]),
		"2.6x_spread_1": _danger_over_wind(_danger_of(_labelled(&"sparrow", "danger_1")), _labelled(&"sparrow", "danger_1")["wind"])}
	metric("danger_over_wind_125_250hz", over)
	near(float(_labelled(&"sparrow", "danger_0.5")["threat"]), 0.5, 1e-4, "(threat 0.5 in the first spread 2.6x step)")
	near(float(_labelled(&"sparrow", "danger_1")["threat"]), 1.0, 1e-4, "(threat 1 in the second)")
	gt(float(over["1.5x_0.5"]["over_wind_db"]), 1.0, "threat 0.5 at 1.5x cruise: the danger cue reaches over the wind at 125/250 Hz (%+.1f dB)" % float(over["1.5x_0.5"]["over_wind_db"]))
	gt(float(over["2.6x_spread_0.5"]["over_wind_db"]), 1.0, "threat 0.5 in a spread 2.6x dive: it reaches over the wind there too (%+.1f dB)" % float(over["2.6x_spread_0.5"]["over_wind_db"]))
	gt(float(over["2.6x_spread_1"]["over_wind_db"]), 6.0, "threat 1 in a spread 2.6x dive: it stands clearly over the wind (%+.1f dB)" % float(over["2.6x_spread_1"]["over_wind_db"]))
	Fixture.save_render(r1, "danger_level_1")
	Fixture.save_measure("danger", {"levels": levels, "rms_db": Array(dbs), "beat_hz": per["hz"], "heart_bpm": [bpm_lo, bpm_hi],
		"heart_hz": [f_lo, f_hi], "onset_gaps_s": Array(gaps), "over_wind": over})


## A copy of the bank's calls that loop, for the simulated sky: a simulated
## minute passes in a fraction of a second, so the voices' players must not
## end on their own in real time; the simulation stops each call when its
## own length has passed on the voices' clock (as the mixer would).
## A clip's octave bands (dB, at 0 dB of gain) over its loudest `win` s (by
## its 10 ms energy envelope).
static func _loudest_bands(st: AudioStream, win: float) -> PackedFloat32Array:
	var d := AudioAnalysis.clip_pcm(st)
	var mono: PackedFloat32Array = d["mono"]
	var rate: float = d["rate"]
	var env := AudioAnalysis.envelope(mono, rate, 0.01)
	var per := maxi(1, int(round(win / 0.01)))
	var best := -1.0
	var best_i := 0
	var acc := 0.0
	for k in env.size():
		acc += env[k] * env[k]
		if k >= per:
			acc -= env[k - per] * env[k - per]
		if acc > best:
			best = acc
			best_i = maxi(0, k - per + 1)
	var a := int(best_i * 0.01 * rate)
	var seg := mono.slice(a, mini(mono.size(), a + int(win * rate)))
	return _octaves(AudioAnalysis.mean_power(seg, 2048, 512, -90.0), rate)


static func _looping_calls(src: AudioBank) -> AudioBank:
	var b := AudioBank.new()
	for sp in CallVoices.VOICE:
		for st in src.calls_for(sp):
			var w := (st as AudioStreamWAV).duplicate() as AudioStreamWAV
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(round(st.get_length() * w.mix_rate))
			var clip: StringName = st.get_meta(&"clip", &"")
			w.set_meta(&"clip", clip)
			if sp == &"moth" or sp == &"starling":
				b._streams[clip] = w
			else:
				if not b._calls.has(sp):
					b._calls[sp] = []
				(b._calls[sp] as Array).append(w)
	return b


## "You are a small bird in a big, alive sky" (DESIGN), with "bird calls for
## each species (3D)": the Ecosystem's sky (AI.md: 60 NPCs, mostly 60-110 m
## out, spawns no nearer than 40 m) must be heard at every player size,
## and most of all at the start sizes. Round 5's verifier laid it out round
## a sparrow-sized player at cruise and heard 0 calls in 14 s (the pigeon 5,
## all 23 dB under the wind; the eagle 90): distances were divided by the
## world scale, so a songbird was cut at 12 m and a crow at 27 m.
##  * Simulated: a voice pool of the director's class, stepped at 60 Hz
##    for 15 s at the sparrow's world scale and 5 s at the pigeon's and
##    the eagle's
##    (its players loop on a muted bus; each call ends when its own length
##    has passed). Every call is placed at the ear by Godot's law on its
##    voice's own settings (which audio_calls_test holds to the mixer within
##    1 dB) with the Calls bus's crowd gain, and heard when it stands over
##    the cruise wind in its own octave (the wind as the session recorded
##    it: the sparrow's, the brightest). Bars: an audible call in every 5 s
##    at every size, and at most a quarter of the calls cut short by
##    another taking their voice (the verifier's bar for a chorus heard as
##    calls, not fragments), and 70% or more of the calls started heard
##    over the wind (the pool's 8 voices are for calls that can be heard:
##    before round 5's CallVoices.MIN_CALL_DB, calls fading out at the edge
##    of their reach took half of them, only to be stolen).
##  * On the mixer: the session flew the sparrow through the same sky up to
##    cruise (2.1 s): calls started, and the loudest 0.4 s of the Calls bus
##    stands over the cruise wind in its own octave.
func test_living_sky_is_heard_over_the_wind() -> void:
	Game.set_state(Game.State.PLAYING)
	var cruise_wind: Dictionary = _step(&"sparrow", 1.0)["wind"]
	var wind_bands := _ear_bands(cruise_wind)
	var wind_aw: float = AudioAnalysis.loudness_aw(cruise_wind["mono"], cruise_wind["rate"], 0.4)["mean"]
	# Each clip's octave bands over its loudest 0.4 s, at 0 dB of gain (on
	# the worker pool: GDScript FFTs).
	var t_prep := Time.get_ticks_msec()
	var src := fx.director.bank
	var streams: Array[AudioStream] = []
	for sp in CallVoices.VOICE:
		for st in src.calls_for(sp):
			streams.append(st)
	var bands_of := []
	bands_of.resize(streams.size())
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void:
		bands_of[i] = _loudest_bands(streams[i], 0.4), streams.size(), -1, true, "audio sky clip bands")
	WorkerThreadPool.wait_for_group_task_completion(task)
	var clip_bands := {}
	for i in streams.size():
		clip_bands[streams[i].get_meta(&"clip", &"")] = bands_of[i]
	var prep_ms := Time.get_ticks_msec() - t_prep
	fx.director.voices.scheduling = false  # only the simulated pool calls
	var looping := _looping_calls(src)
	var _mute := fx.tap_buses("AudioTestSkyMute", 1, AudioBuses.MASTER)
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("AudioTestSkyMute0"), -80.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 505
	var at := fx.listener.global_position
	fx.add_sky(at, rng)
	const DT := 1.0 / 60.0
	var res := {}
	# 15 s at the start size, 5 s at the others (every 5 s window counts).
	for size in [[&"sparrow", SPARROW_WS, 15.0], [&"pigeon", 0.67 / 1.8, 5.0], [&"eagle", EAGLE_WS, 5.0]]:
		var pool := CallVoices.new()
		fx.root.add_child(pool)
		pool.setup(looping, 21)
		for v in pool.voices:
			v.player.bus = "AudioTestSkyMute0"
		var t := 0.0
		var sim_s: float = size[2]
		var heard_in := PackedInt32Array()
		heard_in.resize(int(sim_s / 5.0))
		heard_in.fill(0)
		var calls := 0
		var audible := 0
		var cut := 0
		var ended := 0
		var loudest := -INF
		var species := {}
		var seen := {}  # voice index -> the start time of the call it plays
		var n := 0
		while t < sim_s - 1e-6:
			pool.tick(DT, at, float(size[1]))
			t += DT
			n += 1
			if n % 30 == 0:
				# Let the engine take the players' and the bus's writes (thousands
				# queued in one engine frame stall the next frames for seconds).
				await get_tree().process_frame
			for i in pool.voices.size():
				var v: CallVoices.Voice = pool.voices[i]
				if v.kind != &"call":
					continue
				var full := (v.player.stream as AudioStream).get_length() / maxf(v.player.pitch_scale, 0.01) if v.player.stream else 0.0
				if v.player.playing and not v.fading and pool._clock - v.started >= full:
					v.player.stop()  # its end, as the mixer would reach it
					ended += 1
					seen.erase(i)
				elif v.fading and seen.has(i):
					# Its voice was taken (or its bird left) before the call ended.
					ended += 1
					if pool._clock - float(seen[i]) < full - 0.15:
						cut += 1
					seen.erase(i)
				if v.player.playing and not v.fading and is_equal_approx(v.started, pool._clock) and not seen.has(i):
					seen[i] = v.started
					calls += 1
					var clip: StringName = (v.player.stream as AudioStream).get_meta(&"clip", &"")
					var gain := pool.voice_gain_db(v) + pool.crowd_target_db() + pool.speed_duck_db + pool.cue_duck_db
					var bands: PackedFloat32Array = (clip_bands[clip] as PackedFloat32Array).duplicate()
					for k in bands.size():
						bands[k] += gain + (v.air_db if OCTAVES[k] >= 8000.0 else 0.0)
					var over := _over_in_own_band(bands, wind_bands)
					loudest = maxf(loudest, over)
					if over >= 0.0:
						audible += 1
						heard_in[mini(int(t / 5.0), heard_in.size() - 1)] += 1
						species[String(v.species)] = true
		var tag := String(size[0])
		res[tag] = {"world_scale": snappedf(float(size[1]), 0.001), "calls": calls, "audible": audible,
			"audible_per_5s": Array(heard_in), "loudest_over_wind_db": snappedf(loudest, 0.1),
			"cut_short": cut, "ended": ended, "cut_short_share": snappedf(float(cut) / maxi(1, ended), 0.01),
			"species_heard": species.keys(), "stolen": pool.stats["stolen"], "dropped": pool.stats["dropped"],
			"too_quiet": pool.stats["quiet"]}
		pool.stop_all()
		fx.root.remove_child(pool)
		pool.free()
	metric("living_sky_simulated", res)
	metric("living_sky_prep_ms", prep_ms)
	metric("living_sky_sim_ms", Time.get_ticks_msec() - t_prep - prep_ms)
	# On the mixer (the session's sky, up to cruise).
	var sky_calls: Dictionary = sky.get("calls", {})
	var mixer := {}
	if not sky_calls.is_empty():
		var rate: float = sky_calls["rate"]
		var lw: Dictionary = AudioAnalysis.loudness_aw(sky_calls["mono"], rate, 0.4)
		var a := clampi(int((float(lw["max_at"]) - 0.2) * rate), 0, maxi(0, (sky_calls["l"] as PackedFloat32Array).size() - int(0.4 * rate)))
		var win := {"l": (sky_calls["l"] as PackedFloat32Array).slice(a, a + int(0.4 * rate)),
			"r": (sky_calls["r"] as PackedFloat32Array).slice(a, a + int(0.4 * rate)), "rate": rate}
		mixer = {"seconds": snappedf((sky_calls["mono"] as PackedFloat32Array).size() / rate, 0.01), "started": sky["started"],
			"loudest_aw_db": snappedf(float(lw["max"]), 0.1), "cruise_wind_aw_db": snappedf(wind_aw, 0.1),
			"loudest_over_wind_in_band_db": snappedf(_over_in_own_band(_ear_bands(win), wind_bands), 0.1)}
	metric("living_sky_on_the_mixer", mixer)
	Fixture.save_measure("living_sky", {"simulated": res, "mixer": mixer, "wind_bands_db": Array(wind_bands), "octaves_hz": OCTAVES})
	for tag in res:
		var r: Dictionary = res[tag]
		for k in (r["audible_per_5s"] as Array).size():
			gt(float(r["audible_per_5s"][k]), 0.5, "%s-sized player (world_scale %.3f), the Ecosystem's sky: a call heard over the cruise wind in %d-%d s (%s)" % [
				tag, r["world_scale"], k * 5, k * 5 + 5, r])
		lt(float(r["cut_short_share"]), 0.25, "%s: at most a quarter of the calls cut short by stealing (%.2f)" % [tag, r["cut_short_share"]])
		gt(float(r["audible"]) / maxf(1.0, float(r["calls"])), 0.7, "%s: the voices go to calls the player can hear: 70%% or more of the calls started stand over the cruise wind (%d of %d)" % [tag, r["audible"], r["calls"]])
	check(not mixer.is_empty(), "the session recorded the sky")
	if mixer.is_empty():
		return
	gt(float(mixer["started"]), 0.5, "on the mixer, a sparrow-sized player flying up to cruise: calls start (%d in %.1f s)" % [mixer["started"], mixer["seconds"]])
	gt(float(mixer["loudest_over_wind_in_band_db"]), 0.0, "on the mixer, the loudest call stands over the cruise wind in its own octave (%+.1f dB; %.1f vs %.1f dB A)" % [
		mixer["loudest_over_wind_in_band_db"], mixer["loudest_aw_db"], mixer["cruise_wind_aw_db"]])


## Everything at once: dive wind + edge + buffet + updraft, threat 1, both
## wings flapping hard, catches, a fanfare and a caught stinger, eight
## close NPC calls, every ambience bed, UI clicks.
func test_max_load_never_clips() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "f", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 200.0},
		{"name": "l", "kind": "lake", "position": Vector3(0, 0, 0), "radius": 200.0},
		{"name": "t", "kind": "town", "position": Vector3(0, 0, 0), "radius": 200.0},
		{"name": "m", "kind": "meadow", "position": Vector3(0, 0, 0), "radius": 200.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(3, 4, 0), "radius": 4.0},
	]
	fx.add_world(marks)
	fx.listener.global_position = Vector3(0, 2, 0)
	fx.player.global_position = Vector3(0, 2, 0)
	fx.set_tel({"airspeed": 25.0, "tucked": true, "wing_extension": 0.1, "stalled": true, "in_updraft": 6.0})
	var species := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle", &"moth"]
	for i in species.size():
		var a := TAU * i / species.size()
		fx.add_npc(species[i], Vector3(cos(a) * 1.5, 2.0, sin(a) * 1.5))
	var predator := fx.add_npc(&"eagle", Vector3(0, 2.5, -2))
	Events.threat_changed.emit(1.0, predator)
	# The moths take voices (the scheduler visits them within 12 frames) and
	# the dive's layers settle.
	await Fixture.wait(get_tree(), 0.35)
	# The church bell tolls 3 m away (in a dive the speed duck takes it and
	# the beds 24 dB down: see the heavy-play test for the bell at rest).
	fx.director.ambience.set_world(fx.world)
	check(fx.director.ambience.toll(), "the bell tolls during the pile-up")
	var post := fx.tap(AudioBuses.MASTER)  # after the limiter
	var pre := fx.tap(AudioBuses.MASTER, 0)  # before it
	var recs: Array = []
	# Drive events from a timer while both taps record.
	var driver := Timer.new()
	driver.wait_time = 0.1
	driver.process_mode = Node.PROCESS_MODE_ALWAYS
	fx.root.add_child(driver)
	var n := [0]
	driver.timeout.connect(func() -> void:
		n[0] += 1
		Events.player_flapped.emit(0, 1.0)
		for b in fx.npcs:
			fx.director.voices.request_call(b, 30.0)
		if n[0] % 3 == 0:
			Events.bird_caught.emit(fx.player, fx.npcs[n[0] % fx.npcs.size()])
			fx.director.play_ui(&"click", 0.0)
		if n[0] == 2:
			Events.player_tier_changed.emit(3, 4)
		if n[0] == 5:
			Events.player_caught.emit(predator)
		if n[0] % 7 == 0:
			Events.player_collided.emit(9.0, Vector3.UP))
	driver.start()
	# 1 s: every kind of event in it (the fanfare at 0.2 s, the stinger at
	# 0.5, catches every 0.3, a collision at 0.7) over the continuous pile.
	recs = await fx.record2(get_tree(), pre, post, 1.0)
	driver.stop()
	var pre_pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(recs[0]["l"]), AudioAnalysis.peak(recs[0]["r"])))
	var post_pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(recs[1]["l"]), AudioAnalysis.peak(recs[1]["r"])))
	var post_rms := AudioAnalysis.db(AudioAnalysis.rms(recs[1]["mono"]))
	var pre_rms := AudioAnalysis.db(AudioAnalysis.rms(recs[0]["mono"]))
	metric("pre_limiter_peak_dbfs", pre_pk)
	metric("pre_limiter_rms_dbfs", pre_rms)
	metric("output_peak_dbfs", post_pk)
	metric("output_rms_dbfs", post_rms)
	metric("voices_active", fx.director.voices.active_count())
	metric("limiter_rms_reduction_db", pre_rms - post_rms)
	lt(post_pk, -1.0, "output peak below -1 dBFS at maximum load")
	# The limiter is a safety net, not the mix: even this pile-up costs it
	# less than 3 dB of average gain reduction (see the heavy-play test for
	# realistic loads, where it must not act at all).
	lt(pre_rms - post_rms, 3.0, "limiter reduces the RMS by < 3 dB at maximum load")
	gt(post_rms, -30.0, "output is loud and busy (the load was real)")
	eq(fx.director.voices.active_count() <= CallVoices.MAX_VOICES, true, "voice cap holds under load")
	Fixture.save_render(recs[1], "max_load_output")
	Fixture.save_measure("max_load", {"pre_peak": pre_pk, "post_peak": post_pk, "pre_rms": pre_rms, "post_rms": post_rms})


## Realistic heavy play, where gain staging alone must keep the mix under
## the limiter ceiling (the limiter never acts):
##  A. a tucked dive through a forest by the lake: hard flapping, a hawk
##     closing in (threat 0.8), three birds calling 10-25 m away and two
##     prey caught 50 ms apart in one sweep;
##  B. slow flight round the belfry as the bell tolls 10 m away (no speed
##     duck: the bell at its full level), both wings flapping hard, the
##     hawk at 0.8, calls and two quick catches.
func test_heavy_play_needs_no_limiting() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "f", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 200.0},
		{"name": "l", "kind": "lake", "position": Vector3(60, 0, 0), "radius": 100.0},
		{"name": "v", "kind": "town", "position": Vector3(0, 0, 600), "radius": 130.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(0, 20, 600), "radius": 4.0},
	]
	fx.add_world(marks)
	fx.director.ambience.set_world(fx.world)
	var pre := fx.tap(AudioBuses.MASTER, 0)
	var out := {}
	for scene in ["dive", "belfry"]:
		var at := Vector3(0, 6, 0) if scene == "dive" else Vector3(10, 20, 600)
		fx.listener.global_position = at
		fx.player.global_position = at
		if scene == "dive":
			fx.set_tel({"airspeed": 23.0, "tucked": true, "wing_extension": 0.1, "in_updraft": 2.0})
		else:
			fx.set_tel({"airspeed": FlightSoundMap.cruise(0.03) * 0.35, "tucked": false, "wing_extension": 1.0, "in_updraft": 0.0})
		var callers := [fx.add_npc(&"crow", at + Vector3(10, 2, -5)), fx.add_npc(&"sparrow", at + Vector3(-12, -1, 8)), fx.add_npc(&"gull", at + Vector3(5, 14, 20))]
		var prey := [fx.add_npc(&"moth", at + Vector3(0, 0, -1)), fx.add_npc(&"wren", at + Vector3(0, 0, -1.5))]
		var hawk := fx.add_npc(&"hawk", at + Vector3(0, 6, 15))
		Events.threat_changed.emit(0.8, hawk)
		await Fixture.wait(get_tree(), 0.3)
		fx.director.ambience.settle(at)
		if scene == "belfry":
			check(fx.director.ambience.toll(), "belfry: the bell tolls")
		var driver := Timer.new()
		driver.wait_time = 0.3
		fx.root.add_child(driver)
		var n := [0]
		driver.timeout.connect(func() -> void:
			n[0] += 1
			Events.player_flapped.emit(0, 1.0)
			fx.director.voices.request_call(callers[n[0] % 3], 20.0)
			if n[0] == 2:
				# Two prey in one sweep, 50 ms apart.
				Events.bird_caught.emit(fx.player, prey[0])
				get_tree().create_timer(0.05, true, false, true).timeout.connect(func() -> void:
					Events.bird_caught.emit(fx.player, prey[1])))
		driver.start()
		# Three hard flaps, the calls, and the two catches with their tails.
		var rec := await fx.record(get_tree(), pre, 1.0)
		driver.stop()
		driver.queue_free()
		var pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"])))
		var rms := AudioAnalysis.db(AudioAnalysis.rms(rec["mono"]))
		out[scene] = {"peak": pk, "rms": rms}
		lt(pk, AudioBuses.CEILING_DB, "%s: heavy play peaks below the limiter ceiling (%.1f dBFS)" % [scene, pk])
		gt(rms, -30.0, "%s: heavy play is clearly audible (%.1f dBFS RMS)" % [scene, rms])
		Fixture.save_render(rec, "heavy_play_premaster" if scene == "dive" else "heavy_play_belfry_premaster")
		Events.threat_changed.emit(0.0, null)
		for b in callers + prey + [hawk]:
			if is_instance_valid(b):
				fx.npcs.erase(b)
				b.queue_free()
		await Fixture.wait(get_tree(), 0.05)
	metric("pre_limiter_peak_dbfs", {"dive": out["dive"]["peak"], "belfry": out["belfry"]["peak"]})
	metric("pre_limiter_rms_dbfs", {"dive": out["dive"]["rms"], "belfry": out["belfry"]["rms"]})
	Fixture.save_measure("heavy_play", out)
