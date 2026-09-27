extends TestCase
## Round-6 verifier probes (experience & requirements lens) for the audio
## area. Aimed at what the earlier rounds (r2x..r5x, r2eng..r5eng) did not
## cover:
##  * the shipped compressed assets (UI sounds, menu music) decoded offline
##    (AudioStreamPlayback.mix_audio) and on the mixer: does every one-shot
##    end at a decay, or with a hard cut (a click on every pause)?
##  * the real game's emitters: the AI area's real Ecosystem and the
##    gameloop area's real GameLoop in the real SoaringWorld, with the audio
##    director and a mock player flying laps: calls by species, voices,
##    raptor screams, threat events, NPC catches, ambience zones, cost and
##    errors (every earlier probe used mock NPCs and hand-fed events);
##  * the danger scream's meaning in a living sky: how often ordinary
##    (non-threatening) hawks and eagles scream at a sparrow-sized player,
##    and whether the threat's scream stands out from them.
## Only the audio area's fixture and public API plus core contracts are used,
## except test_real_game_sky, which deliberately instances the other areas'
## shipped scenes (informational integration check).
## Run: tools/gd.sh audio_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=r6x
## Outputs: artifacts/audio/verify/r6x/.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")
const OUT := "audio/verify/r6x"

var fx: Fixture
var _out := {}


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(Paths.artifacts(OUT))


func after_all() -> void:
	var path := Paths.artifacts(OUT).path_join("measurements.json")
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
	Game.set_state(Game.State.PLAYING)
	fx = null


func after_each() -> void:
	if fx:
		fx.teardown()
	fx = null
	await Fixture.wait(get_tree(), 0.1)


static func _db(x: float) -> float:
	return AudioAnalysis.db(x)


## Writes a recording to artifacts/audio/verify/r6x/<name>.wav.
static func _save(rec: Dictionary, name: String) -> void:
	var path := Paths.artifacts(OUT).path_join(name + ".wav")
	AudioSynth.make_wav(rec["l"], rec["r"], int(rec["rate"])).save_to_wav(path)


## Decodes any stream offline (the engine's own decoder, no mixer): mono
## float frames at the playback's output rate, up to max_s.
static func _decode(st: AudioStream, max_s: float = 40.0) -> PackedFloat32Array:
	var pb := st.instantiate_playback()
	var out := PackedFloat32Array()
	if pb == null:
		return out
	pb.start(0.0)
	var cap := int(max_s * AudioServer.get_mix_rate())
	while out.size() < cap:
		var fr: PackedVector2Array = pb.mix_audio(1.0, 1024)
		if fr.is_empty():
			break
		for v in fr:
			out.append(0.5 * (v.x + v.y))
		if not pb.is_playing():
			break
	pb.stop()
	return out


## How a one-shot ends: the level of its last `win` seconds of sound and the
## size of the step to silence after its last sample, both in dB re its peak.
static func _ending(buf: PackedFloat32Array, rate: float, win: float = 0.005) -> Dictionary:
	var pk := AudioAnalysis.peak(buf)
	var last := buf.size() - 1
	while last > 0 and absf(buf[last]) < 1e-6:
		last -= 1
	var n := maxi(1, int(win * rate))
	var tail := AudioAnalysis.rms(buf, maxi(0, last - n), last + 1)
	return {"peak_dbfs": _db(pk), "tail_db": _db(tail) - _db(pk), "step_db": _db(absf(buf[last])) - _db(pk),
		"sound_s": float(last + 1) / rate}


# ---------------------------------------------------------------- tests ---

## Every UI sound plays on a menu or pause (open on every pause, close on
## every resume). A one-shot whose data stops at a high level ends in a
## click. Measured offline (engine decoder) and on the UI bus of the mixer.
func test_ui_sounds_end_without_a_click() -> void:
	fx = Fixture.new()
	fx.build(self, false)
	await wait_frames(2)
	var rate := AudioServer.get_mix_rate()
	var res := {}
	for kind in AudioDirector.UI_LEVEL:
		var st: AudioStream = fx.director.bank.get_stream(StringName("ui_" + String(kind)))
		if not check(st != null, "ui_%s exists" % kind):
			continue
		var buf := _decode(st, 3.0)
		var e := _ending(buf, rate)
		res[String(kind)] = e
		print("[audio-verify] ui_%s offline: %.3f s, peak %.1f dBFS, last 5 ms %.1f dB re peak, final step %.1f dB re peak" % [
			kind, e["sound_s"], e["peak_dbfs"], e["tail_db"], e["step_db"]])
		# A fade to silence: the last 5 ms at least 30 dB under the peak and
		# the final sample's step no bigger than that.
		lt(e["tail_db"], -30.0, "ui_%s: last 5 ms of sound %.1f dB re peak (a cut, not a decay)" % [kind, e["tail_db"]])
		lt(e["step_db"], -30.0, "ui_%s: final step to silence %.1f dB re peak (a click)" % [kind, e["step_db"]])
	_out["ui_endings_offline"] = res
	# The pause "open" on the mixer: the UI bus around the end of the sound.
	var cap := fx.tap(AudioBuses.UI)
	Game.set_state(Game.State.MENU)
	await Fixture.wait(get_tree(), 0.6)
	cap.clear_buffer()
	fx.director.play_ui(&"open")
	var rec: Dictionary = await fx.record(get_tree(), cap, 0.7)
	var m: PackedFloat32Array = rec["mono"]
	var e2 := _ending(m, rate)
	# The largest sample-to-sample jump in the 2 ms around the end, against
	# the largest jump anywhere in the sound (a cut shows as an outlier).
	var last := m.size() - 1
	while last > 0 and absf(m[last]) < 1e-6:
		last -= 1
	var jmax := 0.0
	for i in range(1, last):
		jmax = maxf(jmax, absf(m[i] - m[i - 1]))
	print("[audio-verify] ui_open on the UI bus: sound %.3f s, peak %.1f dBFS, last 5 ms %.1f dB re peak, final step %.1f dB re peak (%.4f abs), max inner step %.4f" % [
		e2["sound_s"], e2["peak_dbfs"], e2["tail_db"], e2["step_db"], absf(m[last]), jmax])
	_out["ui_open_on_mixer"] = e2
	_save(rec, "ui_open_on_mixer")
	lt(e2["step_db"], -30.0, "ui_open on the mixer ends %.1f dB re peak into silence" % e2["step_db"])


# ------------------------------------------------------------ real game ---

## Octave bands (Hz, centres) the calls live in.
const OCTAVES := [500.0, 1000.0, 2000.0, 4000.0, 8000.0]


## Scales captured frames by a bus fader value (dB), appending mono to out.
static func _append_scaled(out: PackedFloat32Array, frames: PackedVector2Array, gain_db: float) -> void:
	var g := db_to_linear(gain_db)
	for v in frames:
		out.append(0.5 * (v.x + v.y) * g)


## Per-window octave comparison of two mono signals: for each window, the
## best margin (dB) of a over b in OCTAVES and a's A-weighted level.
static func _windows(a: PackedFloat32Array, b: PackedFloat32Array, rate: float, win_s: float) -> Array:
	var n := int(win_s * rate)
	var out := []
	var i := 0
	while i + n <= mini(a.size(), b.size()):
		var sa := a.slice(i, i + n)
		var sb := b.slice(i, i + n)
		var pa := AudioAnalysis.mean_power(sa, 1024, 512, -200.0)
		var pb := AudioAnalysis.mean_power(sb, 1024, 512, -200.0)
		var best := -INF
		var best_hz := 0.0
		for c in OCTAVES:
			var la := AudioAnalysis.band_db(pa, rate, c / sqrt(2.0), c * sqrt(2.0))
			var lb := AudioAnalysis.band_db(pb, rate, c / sqrt(2.0), c * sqrt(2.0))
			if la - lb > best:
				best = la - lb
				best_hz = c
		out.append({"t": i / rate, "margin": best, "hz": best_hz, "a_aw": AudioAnalysis.a_level_db(pa, rate),
			"b_aw": AudioAnalysis.a_level_db(pb, rate)})
		i += n
	return out


## The shipped game's emitters: the AI area's real Ecosystem (60 NPCs) and
## the gameloop area's real GameLoop in the real SoaringWorld, with the audio
## director and a sparrow-sized mock player flying laps at cruise 20 m over
## the ground round the player spawn. 30 s measured on the mixer after a
## 12 s warm-up. What a player hears: how often a call stands over the wind,
## calls by species, raptor screams (threatening or not), threat events,
## NPC catches, zones, voices, cost and errors.
func test_real_game_sky() -> void:
	var elog: Variant = ErrorLog.install()
	var w := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(w)
	await wait_physics(3)
	if not w.is_generated:
		await w.generated
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	var p := fx.player
	var ws := float(SizeRules.species_data(&"sparrow")["span"]) / 1.8
	var speed := FlightSoundMap.cruise(p.mass)
	fx.set_tel({"airspeed": speed, "world_scale": ws, "wing_extension": 1.0, "tucked": false, "perched": false})
	var spawn := w.get_player_spawn().origin
	var radius := 60.0
	var gmax := -INF
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, w.ground_height(spawn.x + cos(a) * radius, spawn.z + sin(a) * radius))
	var h := gmax + 20.0
	var eco := (load("res://scenes/ai/ecosystem.tscn") as PackedScene).instantiate() as Ecosystem
	eco.auto_step = false
	eco.max_npcs = 60
	eco.rng_seed = 5
	add_child(eco)
	var gl := GameLoop.new()
	gl.auto_step = false
	gl.verbose = false
	gl.records_path = "user://r6x_records.cfg"
	gl.opening_respite_s = 0.0
	add_child(gl)
	await wait_frames(2)
	gl.start_run()
	var ang := [0.0]
	var drive := func(dt: float) -> void:
		ang[0] += speed / radius * dt
		var a: float = ang[0]
		var pos := Vector3(spawn.x + cos(a) * radius, h, spawn.z + sin(a) * radius)
		var vel := Vector3(-sin(a), 0.0, cos(a)) * speed
		if p.alive:
			p.global_position = pos
			p.velocity = vel
		fx.listener.global_transform = Transform3D(Basis.looking_at(vel.normalized()), p.global_position)
	# Warm-up: populate the sky (spawns come 4 per 0.5 s) off the clock.
	var dt := 1.0 / 60.0
	for i in 720:
		drive.call(dt)
		eco.step(dt)
		gl.step(dt)
	await wait_frames(2)
	print("[audio-verify] warm-up done: %d NPCs %s" % [eco.count(), eco.stats()["by_species"]])
	# Measured, in real time.
	var threats := {"events": 0, "max": 0.0, "species": {}}
	var on_threat := func(lv: float, pred: Bird) -> void:
		threats["events"] += 1
		threats["max"] = maxf(threats["max"], lv)
		if pred != null and is_instance_valid(pred):
			threats["species"][String(pred.species)] = int(threats["species"].get(String(pred.species), 0)) + 1
	Events.threat_changed.connect(on_threat)
	var cues := {}
	var on_cue := func(n: StringName, _info: Dictionary) -> void:
		cues[String(n)] = int(cues.get(String(n), 0)) + 1
	fx.director.cue.connect(on_cue)
	var npc_catches := [0]
	var on_caught := func(pred: Bird, _prey: Bird) -> void:
		if pred != null and is_instance_valid(pred) and not pred.is_player():
			npc_catches[0] += 1
	Events.bird_caught.connect(on_caught)
	var on_phys := func() -> void:
		drive.call(get_physics_process_delta_time())
	get_tree().physics_frame.connect(on_phys)
	eco.auto_step = true
	gl.auto_step = true
	var calls_cap := fx.tap(AudioBuses.CALLS, -1, 2.0)
	var wind_cap := fx.tap(AudioBuses.WIND, -1, 2.0)
	var danger_cap := fx.tap(AudioBuses.DANGER, -1, 2.0)
	var danger_m := PackedFloat32Array()
	var lv_samples := PackedFloat32Array()
	var calls_bus := AudioServer.get_bus_index(AudioBuses.CALLS)
	fx.director.reset_perf()
	var rate := AudioServer.get_mix_rate()
	var calls_m := PackedFloat32Array()
	var wind_m := PackedFloat32Array()
	calls_cap.clear_buffer()
	wind_cap.clear_buffer()
	var voices: CallVoices = fx.director.voices
	var seen := PackedFloat64Array()
	seen.resize(voices.voices.size())
	for i in seen.size():
		seen[i] = voices.voices[i].started
	var starts: Array = []
	var max_active := 0
	var active_sum := 0.0
	var frames_n := 0
	var zones := {}
	var st0: Dictionary = voices.stats.duplicate()
	var t0 := Time.get_ticks_msec()
	var measure_s := 30.0
	var next_zone := 0.0
	while (Time.get_ticks_msec() - t0) / 1000.0 < measure_s:
		await get_tree().process_frame
		var nc := calls_cap.get_frames_available()
		if nc > 0:
			_append_scaled(calls_m, calls_cap.get_buffer(nc), AudioServer.get_bus_volume_db(calls_bus))
		var nw := wind_cap.get_frames_available()
		if nw > 0:
			_append_scaled(wind_m, wind_cap.get_buffer(nw), 0.0)
		var nd := danger_cap.get_frames_available()
		if nd > 0:
			_append_scaled(danger_m, danger_cap.get_buffer(nd), 0.0)
		lv_samples.append(fx.director.threat_level)
		for i in voices.voices.size():
			var v: CallVoices.Voice = voices.voices[i]
			if v.started != seen[i]:
				seen[i] = v.started
				var d := voices.distance_m(v.player.global_position)
				starts.append({"t": (Time.get_ticks_msec() - t0) / 1000.0, "species": String(v.species), "kind": String(v.kind),
					"urgent": v.urgent, "d": d, "aud": CallVoices.audibility(v.species, d),
					"threat": v.bird != null and v.bird == voices.threat})
		var act := voices.active_count()
		max_active = maxi(max_active, act)
		active_sum += act
		frames_n += 1
		var el := (Time.get_ticks_msec() - t0) / 1000.0
		if el >= next_zone:
			next_zone += 1.0
			for z in fx.director.ambience.weights:
				zones[String(z)] = maxf(float(zones.get(String(z), 0.0)), float(fx.director.ambience.weights[z]))
	get_tree().physics_frame.disconnect(on_phys)
	Events.threat_changed.disconnect(on_threat)
	Events.bird_caught.disconnect(on_caught)
	fx.director.cue.disconnect(on_cue)
	var perf: Dictionary = fx.director.perf_stats()
	var st1: Dictionary = voices.stats.duplicate()
	var eco_stats := eco.stats()
	eco.auto_step = false
	gl.auto_step = false
	# Analysis: 0.4 s windows, the calls (after the Calls fader) against the
	# wind in each octave.
	var wins := _windows(calls_m, wind_m, rate, 0.4)
	var over3 := 0
	var over10 := 0
	for wv in wins:
		if wv["margin"] >= 3.0 and wv["a_aw"] > -90.0:
			over3 += 1
		if wv["margin"] >= 10.0 and wv["a_aw"] > -90.0:
			over10 += 1
	var by_sp := {}
	var raptor := {"ordinary": 0, "ordinary_loud": 0, "threat": 0, "aud": []}
	for s in starts:
		if s["kind"] != "call":
			continue
		by_sp[s["species"]] = int(by_sp.get(s["species"], 0)) + 1
		if s["species"] == "hawk" or s["species"] == "eagle":
			if s["urgent"]:
				raptor["threat"] += 1
			else:
				raptor["ordinary"] += 1
				if float(s["aud"]) > -45.0:
					raptor["ordinary_loud"] += 1
			(raptor["aud"] as Array).append(snappedf(float(s["aud"]), 0.1))
	var calls_started := int(st1["started"]) - int(st0["started"])
	# The danger cue in ordinary flight: how often the heart is heard.
	var dblk := int(rate * 0.4)
	var d_on40 := 0
	var d_on50 := 0
	var d_n := 0
	var wind_rms := _db(AudioAnalysis.rms(wind_m))
	var i_d := 0
	while i_d + dblk <= danger_m.size():
		var lv_d := _db(AudioAnalysis.rms(danger_m, i_d, i_d + dblk))
		d_n += 1
		if lv_d > -40.0:
			d_on40 += 1
		if lv_d > -50.0:
			d_on50 += 1
		i_d += dblk
	var t_pos := 0
	var t_25 := 0
	for x in lv_samples:
		if x > 0.0:
			t_pos += 1
		if x >= 0.25:
			t_25 += 1
	var res := {
		"npcs": eco.count(), "eco_by_species": eco_stats["by_species"], "eco_by_state": eco_stats["by_state"],
		"calls_started_per_min": calls_started * 60.0 / measure_s, "calls_by_species": by_sp,
		"stolen": int(st1["stolen"]) - int(st0["stolen"]), "quiet": int(st1["quiet"]) - int(st0["quiet"]),
		"dropped": int(st1["dropped"]) - int(st0["dropped"]), "gone": int(st1["gone"]) - int(st0["gone"]),
		"fx": int(st1["fx"]) - int(st0["fx"]), "npc_catches": npc_catches[0],
		"max_active": max_active, "mean_active": active_sum / maxf(frames_n, 1.0),
		"windows": wins.size(), "windows_call_over_wind_3db": over3, "windows_call_over_wind_10db": over10,
		"threat": threats, "cues": cues, "raptors": raptor, "zones_max": zones,
		"perf_mean_ms": perf["mean"], "perf_p95_ms": perf["p95"], "perf_max_ms": perf["max"],
		"errors": elog.errors, "error_samples": elog.samples, "warnings": elog.warnings,
		"player_alive": p.alive, "game_state": Game.state_name(),
		"danger_windows_over_-40dbfs": float(d_on40) / maxf(d_n, 1), "danger_windows_over_-50dbfs": float(d_on50) / maxf(d_n, 1),
		"threat_time_above_0": float(t_pos) / maxf(lv_samples.size(), 1), "threat_time_above_0_25": float(t_25) / maxf(lv_samples.size(), 1),
		"wind_rms_dbfs": wind_rms, "danger_rms_dbfs": _db(AudioAnalysis.rms(danger_m)),
	}
	_out["real_game_sky"] = res
	print("[audio-verify] real sky: %s" % JSON.stringify(res))
	elog.uninstall()
	# Teardown: the sky first (its birds leave while the director listens).
	eco.queue_free()
	gl.queue_free()
	await wait_frames(3)
	w.queue_free()
	await wait_frames(2)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://r6x_records.cfg"))
	# Bars (what the brief and the builder claim for the living sky).
	gt(calls_started, int(measure_s / 5.0), "a call started at least every 5 s in the real sky")
	lt(max_active, 9, "at most 8 voices")
	gt(float(over3) / maxf(wins.size(), 1), 0.2, "a call over the wind (3 dB, its octave) in at least 20% of 0.4 s windows")
	lt(perf["mean"], 1.0, "director cost < 1 ms/frame with the real Ecosystem")
	eq(elog.errors, 0, "no engine/script errors: %s" % [elog.samples])


# --------------------------------------------------- the scream's meaning ---

## Records the loudest 0.4 s (A-weighted, both ears summed like the suite)
## of the Calls bus while one call plays.
func _call_loudness(cap: AudioEffectCapture, seconds: float = 3.3) -> float:
	var rec: Dictionary = await fx.record(get_tree(), cap, seconds)
	var l: PackedFloat32Array = rec["l"]
	var r: PackedFloat32Array = rec["r"]
	var sum := PackedFloat32Array()
	sum.resize(l.size())
	for i in l.size():
		sum[i] = l[i] + r[i]
	return AudioAnalysis.loudness_aw(sum, rec["rate"])["max"]


## DESIGN: "danger (predator screech getting louder)". The threatening
## predator's scream is the hawk's own call. How often does an ordinary
## hawk (hunting something else) scream at a sparrow-sized player, and how
## much louder is the threat's scream than an ordinary hawk's call from the
## same distance? Rendered on the mixer at cruise, one call at a time.
func test_threat_scream_stands_out_from_ordinary_raptors() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	var ws := float(SizeRules.species_data(&"sparrow")["span"]) / 1.8
	fx.set_tel({"airspeed": FlightSoundMap.cruise(0.03), "world_scale": ws})
	var voices: CallVoices = fx.director.voices
	# How often an ordinary hawk calls: the pace the scheduler draws.
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, -40))
	hawk.state_str = "hunt"
	var sum := 0.0
	for i in 2000:
		sum += voices._interval(hawk)
	var per_min_hunting := 60.0 / (sum / 2000.0)
	hawk.state_str = "soar"
	sum = 0.0
	for i in 2000:
		sum += voices._interval(hawk)
	var per_min_soaring := 60.0 / (sum / 2000.0)
	hawk.state_str = "hunt"
	var cap := fx.tap(AudioBuses.CALLS)
	var res := {"per_min_hunting": per_min_hunting, "per_min_soaring": per_min_soaring}
	for d in [20.0, 40.0, 70.0, 100.0, 150.0]:
		hawk.global_position = Vector3(0, 100, -d)
		# An ordinary call (the hawk hunts something else).
		Events.threat_changed.emit(0.0, null)
		await Fixture.wait(get_tree(), 0.3)
		voices.request_call(hawk)
		var ordinary: float = await _call_loudness(cap)
		await Fixture.wait(get_tree(), 0.4)
		# The same hawk as the threat: its scream at the 0.6 crossing.
		Events.threat_changed.emit(0.7, hawk)
		var threat: float = await _call_loudness(cap)
		Events.threat_changed.emit(0.0, null)
		fx.director._screech_cool = 0.0
		await Fixture.wait(get_tree(), 0.4)
		res["d%d" % int(d)] = {"ordinary_db_a": snappedf(ordinary, 0.1), "threat_db_a": snappedf(threat, 0.1),
			"threat_minus_ordinary": snappedf(threat - ordinary, 0.1),
			"model_ordinary": snappedf(CallVoices.audibility(&"hawk", d), 0.1)}
		print("[audio-verify] hawk at %d m: ordinary call %.1f dB A, the threat's scream %.1f dB A (+%.1f)" % [d, ordinary, threat, threat - ordinary])
	print("[audio-verify] an ordinary hawk calls %.1f times a minute hunting, %.1f otherwise (reach %d m)" % [
		per_min_hunting, per_min_soaring, int(CallVoices.VOICE[&"hawk"]["reach"])])
	_out["threat_scream_vs_ordinary"] = res
	# The bar a director would set: the warning must not sound like the
	# background. From 40 m in, the threat's scream should at least stand
	# 3 dB over an ordinary hawk's call from the same place.
	gt(float(res["d40"]["threat_minus_ordinary"]), 3.0, "the threat's scream from 40 m stands out from an ordinary hawk's call there")
	lt(per_min_hunting, per_min_soaring + 0.01, "a hunting hawk does not scream more often than a soaring one (hunters are silent; the scream is the warning)")


# --------------------------------------------------------- game session ---

## One whole round of play as a player meets it, recorded on every bus
## (each scaled by its own and its parents' faders, so the lines are what
## reaches the output): the menu, take-off from a wood, a hawk closing in,
## a dive and a catch, being caught, the respawn, a pause, the run's end
## and the menu again. Checks that each state lands on its mix and that
## nothing is left sounding where it does not belong; draws the timeline.
func test_a_whole_session_timeline() -> void:
	Game.set_state(Game.State.MENU)
	fx = Fixture.new()
	fx.build(self)
	var wld := fx.add_world([{"kind": "forest", "name": "wood", "position": Vector3(0, 0, 0), "radius": 120.0}])
	wld.ground = 0.0
	await wait_frames(2)
	var p := fx.player
	var cruise := FlightSoundMap.cruise(p.mass)
	var ws := float(SizeRules.species_data(&"sparrow")["span"]) / 1.8
	fx.set_tel({"airspeed": 0.0, "perched": true, "world_scale": ws, "wing_extension": 1.0, "tucked": false})
	p.global_position = Vector3(0, 4, 0)
	p.velocity = Vector3.ZERO
	fx.listener.global_position = Vector3(0, 4, 0)
	var hawk := fx.add_npc(&"hawk", Vector3(0, 30, -80))
	hawk.state_str = "hunt"
	var moth := fx.add_npc(&"moth", Vector3(0, 60, -30))
	var names := ["Master", "Music", "UI", "Ambience", "SFX", "Wind", "Body", "Danger", "Calls"]
	var buses := {}
	var caps := {}
	var data := {}
	for n in names:
		buses[n] = AudioServer.get_bus_index(n)
		caps[n] = fx.tap(StringName(n), -1, 3.0)
		data[n] = PackedFloat32Array()
	var parent := {"Master": [], "Music": ["Master"], "UI": ["Master"], "Ambience": ["Master"], "SFX": ["Master"],
		"Wind": ["SFX", "Master"], "Body": ["SFX", "Master"], "Danger": ["SFX", "Master"], "Calls": ["SFX", "Master"]}
	var master_peak := 0.0
	var marks: Array = []
	var ev := {"flaps": 0, "caught_at": -1.0}
	var cue_log: Array = []
	fx.director.cue.connect(func(n: StringName, _i: Dictionary) -> void:
		cue_log.append("%s@%.2f" % [n, (data["Master"] as PackedFloat32Array).size() / AudioServer.get_mix_rate()]))
	var total := 23.0
	for c in caps.values():
		(c as AudioEffectCapture).clear_buffer()
	var rate := AudioServer.get_mix_rate()
	var t0 := Time.get_ticks_msec()
	var done := {}
	var once := func(key: String, t: float, at: float) -> bool:
		if t >= at and not done.has(key):
			done[key] = true
			marks.append([key, at])
			return true
		return false
	while true:
		await get_tree().process_frame
		# The script runs on the audio's own clock (the captured Master), so
		# the event marks and the recorded blocks line up.
		var t := (data["Master"] as PackedFloat32Array).size() / rate
		var wall := (Time.get_ticks_msec() - t0) / 1000.0
		if wall > total + 20.0:
			break
		# --- the script ---
		if once.call("PLAY", t, 3.0):
			Game.set_state(Game.State.PLAYING)
		for k in 4:
			if once.call("flap%d" % k, t, 5.0 + 0.4 * k):
				Events.player_flapped.emit(0, 0.9)
				ev["flaps"] += 1
		if t >= 5.0 and t < 10.0 and p.alive:
			var sp := cruise * clampf((t - 5.0) / 1.5, 0.0, 1.0)
			fx.set_tel({"airspeed": sp, "perched": sp <= 0.0})
			p.velocity = Vector3(0, 0, -sp)
		if t >= 7.0 and t < 10.0:
			var k := (t - 7.0) / 3.0
			hawk.global_position = p.global_position + Vector3(0, 26.0 - 20.0 * k, -80.0 + 65.0 * k)
			var lv := snappedf(0.85 * k, 0.02)
			if absf(lv - fx.director.threat_level) >= 0.02:
				Events.threat_changed.emit(lv, hawk)
		if once.call("DIVE", t, 10.0):
			fx.set_tel({"tucked": true, "wing_extension": 0.1})
		if t >= 10.0 and t < 12.0 and p.alive:
			var sp2 := cruise * lerpf(1.0, 2.6, clampf((t - 10.0) / 1.0, 0.0, 1.0))
			fx.set_tel({"airspeed": sp2})
			p.velocity = Vector3(0, -sp2 * 0.5, -sp2 * 0.87)
		if once.call("CATCH", t, 11.0):
			moth.global_position = p.global_position
			Events.bird_caught.emit(p, moth)
			# The prey leaves the world, as GameLoop and the Ecosystem do.
			moth.alive = false
			moth.get_parent().remove_child(moth)
			fx.npcs.erase(moth)
			moth.queue_free()
		if once.call("CAUGHT", t, 12.0):
			Events.threat_changed.emit(1.0, hawk)
			p.alive = false
			Events.player_caught.emit(hawk)
			Game.set_state(Game.State.CAUGHT)
			# GameLoop clears its watch outside PLAYING.
			Events.threat_changed.emit(0.0, null)
			ev["caught_at"] = t
		if once.call("RESPAWN", t, 14.5):
			p.alive = true
			# Straight back into flight at cruise (so the pause has a wind to duck).
			fx.set_tel({"airspeed": cruise, "perched": false, "tucked": false, "wing_extension": 1.0})
			p.velocity = Vector3(0, 0, -cruise)
			hawk.global_position = Vector3(0, 60, -250)
			Game.set_state(Game.State.PLAYING)
		if once.call("PAUSE", t, 15.5):
			Game.set_state(Game.State.PAUSED)
		if once.call("RESUME", t, 18.0):
			Game.set_state(Game.State.PLAYING)
		if once.call("ENDED", t, 19.0):
			Game.set_state(Game.State.ENDED)
		if once.call("MENU", t, 21.0):
			Game.set_state(Game.State.MENU)
		fx.listener.global_position = p.global_position
		# --- capture, each bus scaled by the faders it passes through ---
		var gains := {}
		for n in names:
			var g: float = AudioServer.get_bus_volume_db(buses[n])
			for par in parent[n]:
				g += AudioServer.get_bus_volume_db(buses[par])
			gains[n] = g
		for n in names:
			var cap: AudioEffectCapture = caps[n]
			var nf := cap.get_frames_available()
			if nf > 0:
				var fr := cap.get_buffer(nf)
				_append_scaled(data[n], fr, gains[n])
				if n == "Master":
					for v in fr:
						master_peak = maxf(master_peak, maxf(absf(v.x), absf(v.y)))
		if t >= total:
			break
	var sizes := {}
	for n in names:
		sizes[n] = snappedf((data[n] as PackedFloat32Array).size() / rate, 0.01)
	print("[audio-verify] session: %.1f s of wall time, captured seconds per bus %s" % [(Time.get_ticks_msec() - t0) / 1000.0, sizes])
	# --- analysis: 100 ms blocks, dBFS RMS as it reaches the output ---
	var blk := int(rate * 0.1)
	var series := []
	var lvl := {}
	for n in names:
		var m: PackedFloat32Array = data[n]
		var xs := PackedFloat32Array()
		var ys := PackedFloat32Array()
		var i := 0
		while i + blk <= m.size():
			xs.append(i / rate)
			ys.append(maxf(-90.0, _db(AudioAnalysis.rms(m, i, i + blk))))
			i += blk
		lvl[n] = ys
		if n != "SFX":
			series.append({"name": n, "x": xs, "y": ys})
	var at := func(n: String, a: float, b: float) -> float:
		var ys: PackedFloat32Array = lvl[n]
		var s := 0.0
		var c := 0
		for k in range(int(a * 10), mini(int(b * 10), ys.size())):
			s += db_to_linear(ys[k]) ** 2
			c += 1
		return _db(sqrt(s / maxf(c, 1)))
	var r := {
		"menu_music": at.call("Music", 1.0, 3.0), "menu_wind": at.call("Wind", 1.0, 3.0),
		"play_music_after_1_7s": at.call("Music", 4.7, 5.0), "perched_ambience": at.call("Ambience", 3.8, 4.8),
		"flaps_body": at.call("Body", 5.0, 6.6), "cruise_wind": at.call("Wind", 8.0, 9.5),
		"cruise_ambience": at.call("Ambience", 8.0, 9.5),
		"danger_rising": [at.call("Danger", 7.5, 8.0), at.call("Danger", 8.5, 9.0), at.call("Danger", 9.5, 10.0)],
		"dive_wind": at.call("Wind", 11.2, 11.9), "catch_sfx": at.call("SFX", 11.0, 11.3),
		"danger_after_caught": at.call("Danger", 13.0, 14.4), "caught_sfx": at.call("SFX", 12.0, 12.8),
		"wind_after_caught": at.call("Wind", 13.0, 14.4),
		"pause_ui": at.call("UI", 15.5, 15.9), "pause_music_late": at.call("Music", 17.3, 18.0),
		"pause_sfx": at.call("SFX", 16.0, 18.0), "play_sfx_before_pause": at.call("SFX", 14.9, 15.5),
		"ended_music": at.call("Music", 20.3, 21.0), "ended_danger": at.call("Danger", 19.5, 21.0),
		"final_menu_music": at.call("Music", 21.5, 23.0), "final_menu_body": at.call("Body", 21.5, 23.0),
		"final_menu_danger": at.call("Danger", 21.5, 23.0), "master_peak_dbfs": _db(master_peak),
		"flaps": ev["flaps"], "cues": cue_log,
	}
	_out["session_timeline"] = r
	print("[audio-verify] session: %s" % JSON.stringify(r))
	var note := "EVENTS: " + " ".join(marks.map(func(mk: Array) -> String: return "%s %.1f" % [mk[0], mk[1]]))
	var top_s := series.filter(func(e: Dictionary) -> bool: return e["name"] in ["Master", "Music", "UI", "Ambience"])
	var low_s := series.filter(func(e: Dictionary) -> bool: return e["name"] in ["Wind", "Body", "Danger", "Calls"])
	var img_a := AudioPlot.chart("ONE ROUND OF PLAY: OUTPUT, MUSIC, UI, AMBIENCE", top_s,
		{"x_label": "TIME S", "y_label": "DBFS RMS (100 MS, AFTER FADERS)", "y_min": -90.0, "y_max": 0.0,
		"note": note.left(150), "width": 1400, "height": 520})
	var img_b := AudioPlot.chart("ONE ROUND OF PLAY: WIND, WINGBEATS/BODY, DANGER, CALLS", low_s,
		{"x_label": "TIME S", "y_label": "DBFS RMS (100 MS, AFTER FADERS)", "y_min": -90.0, "y_max": 0.0,
		"note": note.left(150), "width": 1400, "height": 520})
	AudioPlot.stack([img_a, img_b]).save_png(Paths.artifacts(OUT).path_join("session_timeline.png"))
	var full := {"l": data["Master"], "r": data["Master"], "rate": rate}
	_save(full, "session_master")
	# --- bars ---
	gt(r["menu_music"], -50.0, "menu music audible in the menu")
	lt(r["menu_wind"], -70.0, "no wind in the menu while perched")
	lt(r["play_music_after_1_7s"], -60.0, "music gone 1.7 s into play")
	gt(r["cruise_wind"], r["cruise_ambience"] + 6.0, "cruise wind over the ambience")
	check(r["danger_rising"][0] < r["danger_rising"][1] and r["danger_rising"][1] < r["danger_rising"][2], "danger rises as the hawk closes: %s" % [r["danger_rising"]])
	lt(r["danger_after_caught"], -60.0, "danger gone once caught (threat cleared)")
	gt(r["pause_ui"], -60.0, "the pause plays its UI sound")
	gt(r["pause_music_late"], -50.0, "music back in the pause")
	lt(r["pause_sfx"], r["play_sfx_before_pause"] - 15.0, "gameplay ducked in the pause")
	gt(r["ended_music"], -50.0, "music at the run's end")
	lt(r["final_menu_danger"], -70.0, "no danger in the menu")
	lt(r["final_menu_body"], -70.0, "no flight body sounds in the menu")
	lt(r["master_peak_dbfs"], -1.0, "the output never clips")


## An NPC that hunts: its `target` is what NpcBird exposes (the prey it
## chases), so CallVoices.is_player_threat() sees a bird stooping at the
## player.
class HunterNpc:
	extends Fixture.MockNpc
	var target: Bird = null


## The scream at the 0.6 crossing ("predator screech getting louder") when
## the predator happens to be mid-call already. A hunting hawk calls every
## 5-11 s and its calls last 1.2-3 s, so this is a common moment. Does the
## player still hear a fresh scream (at once, or once the call ends), or is
## the warning lost for the rest of the attack?
func test_scream_is_not_lost_when_the_hawk_is_mid_call() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	var ws := float(SizeRules.species_data(&"sparrow")["span"]) / 1.8
	fx.set_tel({"airspeed": FlightSoundMap.cruise(0.03), "world_scale": ws})
	var voices: CallVoices = fx.director.voices
	var res := {}
	for case_i in 2:
		var hawk := HunterNpc.new()
		hawk.species = &"hawk"
		hawk.mass = float(SizeRules.species_data(&"hawk")["mass"])
		hawk.state_str = "hunt"
		fx.root.add_child(hawk)
		fx.npcs.append(hawk)
		hawk.global_position = fx.player.global_position + Vector3(0, 20, -90)
		if case_i == 1:
			hawk.target = fx.player  # it hunts the player (its calls are urgent)
		var screams := [0]
		var on_cue := func(n: StringName, _i: Dictionary) -> void:
			if n == &"screech":
				screams[0] += 1
		fx.director.cue.connect(on_cue)
		# Its call starts (the long cut, so the crossing lands inside it).
		var clips := fx.director.bank.calls_for(&"hawk")
		var longest: AudioStream = clips[0]
		for c in clips:
			if c.get_length() > longest.get_length():
				longest = c
		voices._request(hawk, {"species": &"hawk", "stream": longest, "kind": &"call", "prio": voices.priority(hawk),
			"db": CallVoices.clip_gain_db(&"hawk", longest), "pitch": 1.0, "urgent": voices.is_player_threat(hawk)})
		await Fixture.wait(get_tree(), 0.6)
		var mid_call := false
		for v in voices.voices:
			if v.bird == hawk and v.player.playing and not v.fading:
				mid_call = true
		# GameLoop's threat ramp as the hawk closes: 0.5 -> crossing 0.6 -> 0.9
		# over 4 s, the hawk from 90 m to 20 m.
		var t0 := Time.get_ticks_msec()
		var urgent_started := 0
		var seen := {}
		while (Time.get_ticks_msec() - t0) / 1000.0 < 4.5:
			await get_tree().process_frame
			var k := clampf((Time.get_ticks_msec() - t0) / 4000.0, 0.0, 1.0)
			hawk.global_position = fx.player.global_position + Vector3(0, 20.0 - 10.0 * k, -90.0 + 70.0 * k)
			var lv := snappedf(0.5 + 0.4 * k, 0.02)
			if absf(lv - fx.director.threat_level) >= 0.02:
				Events.threat_changed.emit(lv, hawk)
			for v in voices.voices:
				if v.bird == hawk and v.player.playing and not v.fading and v.urgent and not seen.has(v.started):
					seen[v.started] = true
					urgent_started += 1
		fx.director.cue.disconnect(on_cue)
		var tag := "not_targeting" if case_i == 0 else "targeting_player"
		res[tag] = {"mid_call_at_crossing": mid_call, "screech_cues": screams[0], "urgent_calls_started_after": urgent_started}
		print("[audio-verify] hawk %s: mid-call at the crossing %s, screams %d, urgent calls during the attack %d" % [
			tag, mid_call, screams[0], urgent_started])
		Events.threat_changed.emit(0.0, null)
		fx.director._screech_cool = 0.0
		fx.npcs.erase(hawk)
		hawk.queue_free()
		await Fixture.wait(get_tree(), 0.5)
	_out["scream_mid_call"] = res
	gt(float(res["not_targeting"]["screech_cues"]), 0.5, "the threat's scream is heard at (or right after) the 0.6 crossing even if the hawk was mid-call")
	gt(float(res["targeting_player"]["screech_cues"]), 0.5, "... and when the hawk hunts the player")
