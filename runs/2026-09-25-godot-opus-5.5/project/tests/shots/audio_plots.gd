extends Node
## Charts of the audio evidence (headless, drawn with Godot's Image) from
## artifacts/audio/measurements.json (written by the audio tests) and from
## FlightSoundMap's curves:
##   plots/wind_rms_vs_airspeed.png   AU1 measured on the mixer
##   plots/wind_curves.png            designed levels per layer vs speed
##   plots/wind_cutoff.png            wind brightness vs speed (spread/tucked)
##   plots/tuck_spectrum.png          AU1 spread vs tucked spectra
##   plots/stall_envelope.png         AU1 buffet envelopes
##   plots/danger.png                 AU4 measured + designed
##   plots/calls_map.png              AU2 species in pitch x note-rate space
##   plots/call_balance.png           call levels at 25 m: rendered on the mixer (now and as round 3 found it) and the model
##   plots/catch_duck.png             the catch duck vs speed; crunch, stinger and fanfare over the wind they land in
##   plots/programme_loudness.png     the menu music against a glide at cruise, at the output (LUFS)
##   plots/wind_over_ambience.png     the wind at cruise vs every bed, per octave
##   plots/speed_ducks.png            wind level and the ambience / calls ducks vs speed
##   plots/bell_vs_distance.png       the church bell's level vs distance and size
##   plots/ambience_map.png           zone weights over the world's landmarks
##   plots/bad_input_recovery.png     every input fed NaN/INF/absurd values: worst level 0.5 s later
##   plots/successive_screams.png     a closing hawk's new calls: world metres and the floor vs rounds 3-4
##   plots/living_sky.png             calls heard in the Ecosystem's sky per player size, round 5 before/after
##   plots/call_endings.png           how every shipped call ends (dB under its loudest 50 ms), before/after
##   plots/danger_over_wind.png       the danger cue over the wind at 1.5x and in a spread 2.6x dive
##
##   tools/gd.sh audio --headless res://tests/shots/audio_plots.tscn

var out := ""
var m := {}


func _ready() -> void:
	out = Paths.artifacts("audio/plots")
	var path := Paths.artifacts("audio").path_join("measurements.json")
	if FileAccess.file_exists(path):
		m = JSON.parse_string(FileAccess.get_file_as_string(path))
	else:
		print("[audio] no measurements.json: run the audio tests first")
	_wind_rms()
	_wind_curves()
	_tuck()
	_stall()
	_danger()
	_calls()
	_call_balance()
	_catch_duck()
	_programme()
	_wind_over_ambience()
	_speed_ducks()
	_bell()
	_bad_inputs()
	_screams()
	_living_sky()
	_call_endings()
	_danger_over_wind()
	await _ambience()
	get_tree().quit()


static func _p(a: Array) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	for v in a:
		o.append(float(v))
	return o


func _save(img: Image, name: String) -> void:
	img.save_png(out.path_join(name))
	print("[audio] plot ", name)


## A verifier's measurements (read only), or {}.
static func _verifier(folder: String) -> Dictionary:
	var path := Paths.artifacts("audio/verify").path_join(folder).path_join("measurements.json")
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


func _wind_rms() -> void:
	if not m.has("wind_rms"):
		return
	var w: Dictionary = m["wind_rms"]
	var series := []
	for sp in ["sparrow", "eagle"]:
		if w.has(sp):
			series.append({"name": "%s (cruise %.1f m/s)" % [sp, FlightSoundMap.cruise(0.03 if sp == "sparrow" else 3.0)],
				"x": _p(w[sp]["airspeed"]), "y": _p(w[sp]["rms_db"]), "dots": true})
	var note := "RMS OF THE WIND BUS, RENDERED BY THE ENGINE MIXER (WINGS SPREAD). STRICTLY RISING FOR BOTH SIZES."
	if m.has("dive_vs_glide"):
		var dg: Dictionary = m["dive_vs_glide"]
		note += "  SPARROW TUCKED DIVE %.1f DB VS GLIDE %.1f DB (+%.1f)" % [dg["dive_db"], dg["glide_db"], dg["dive_db"] - dg["glide_db"]]
	_save(AudioPlot.chart("AU1 WIND LOUDNESS VS AIRSPEED", series, {"x_label": "AIRSPEED M/S", "y_label": "RMS DBFS",
		"note": note, "x_min": 0.0, "y_max": -10.0, "y_min": -75.0}), "wind_rms_vs_airspeed.png")


func _wind_curves() -> void:
	var xs := PackedFloat32Array()
	var body := PackedFloat32Array()
	var body_t := PackedFloat32Array()
	var edge := PackedFloat32Array()
	var edge_t := PackedFloat32Array()
	for i in 131:
		var x := i * 0.02
		xs.append(x)
		body.append(maxf(-60.0, FlightSoundMap.body_db(x, 0.0)))
		body_t.append(maxf(-60.0, FlightSoundMap.body_db(x, 1.0)))
		edge.append(maxf(-60.0, FlightSoundMap.edge_db(x, 0.0)))
		edge_t.append(maxf(-60.0, FlightSoundMap.edge_db(x, 1.0)))
	_save(AudioPlot.chart("WIND LAYER LEVELS (DESIGN)", [
		{"name": "body, spread", "x": xs, "y": body},
		{"name": "body, tucked", "x": xs, "y": body_t},
		{"name": "edge hiss, spread", "x": xs, "y": edge},
		{"name": "edge hiss, tucked", "x": xs, "y": edge_t},
	], {"x_label": "AIRSPEED / CRUISE", "y_label": "LAYER GAIN DB", "y_min": -60.0, "y_max": 0.0,
		"note": "FLIGHTSOUNDMAP: BODY -14.3 DB AT CRUISE, -3 DB AT 2.6X; TUCK +2.5 DB AND THE EDGE LAYER (BRIGHT, THIN)."}), "wind_curves.png")
	var series := []
	for spec in [["sparrow", 0.03], ["eagle", 3.0]]:
		for tk in [0.0, 1.0]:
			var ys := PackedFloat32Array()
			for x in xs:
				ys.append(FlightSoundMap.body_cutoff(x, tk, spec[1]) / 1000.0)
			series.append({"name": "%s %s" % [spec[0], "tucked" if tk > 0.0 else "spread"], "x": xs, "y": ys})
	_save(AudioPlot.chart("WIND BRIGHTNESS: LOW-PASS CUT-OFF", series, {"x_label": "AIRSPEED / CRUISE", "y_label": "KHZ",
		"y_min": 0.0, "note": "DULL RUMBLE WHEN SLOW, ROAR IN A DIVE; TUCKED IS BRIGHTER, BIGGER BIRDS DARKER. TUCK ALSO HIGH-PASSES 350 HZ (THINNER)."}), "wind_cutoff.png")


func _tuck() -> void:
	if not m.has("tuck"):
		return
	var t: Dictionary = m["tuck"]
	var rate: float = t["rate"]
	var ps := _p(t["spread_power"])
	var pt := _p(t["tucked_power"])
	var n := (ps.size() - 1) * 2
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	var yt := PackedFloat32Array()
	for i in range(2, ps.size(), 2):
		var f := i * rate / n
		if f < 40.0 or f > 16000.0:
			continue
		xs.append(f)
		ys.append(maxf(-110.0, 10.0 * log(maxf(ps[i], 1e-14)) / log(10.0)))
		yt.append(maxf(-110.0, 10.0 * log(maxf(pt[i], 1e-14)) / log(10.0)))
	var c: Array = t["centroid"]
	var lf: Array = t["low_frac"]
	_save(AudioPlot.chart("AU1 TUCK: BRIGHTER AND THINNER (SAME SPEED, 2X CRUISE)", [
		{"name": "wings spread", "x": xs, "y": ys},
		{"name": "tucked", "x": xs, "y": yt},
	], {"x_label": "FREQUENCY HZ", "y_label": "POWER DB", "log_x": true, "x_min": 40.0, "x_max": 16000.0, "y_min": -110.0,
		"note": "CENTROID %d -> %d HZ, SHARE BELOW 400 HZ %.0f%% -> %.0f%%. MEAN SPECTRA OF THE RENDERED WIND BUS." % [int(c[0]), int(c[1]), lf[0] * 100.0, lf[1] * 100.0]}), "tuck_spectrum.png")


func _stall() -> void:
	if not m.has("stall"):
		return
	var st: Dictionary = m["stall"]
	var series := []
	var note := ""
	for sp in ["sparrow", "eagle"]:
		if not st.has(sp):
			continue
		var env := _p(st[sp]["env"])
		var xs := PackedFloat32Array()
		var ys := PackedFloat32Array()
		var pk := 0.0
		for v in env:
			pk = maxf(pk, v)
		for i in mini(env.size(), 350):
			xs.append(i * 0.002)
			ys.append(env[i] / maxf(pk, 1e-9))
		series.append({"name": "%s: %.2f Hz (want %.2f), periodicity %.2f" % [sp, st[sp]["hz"], st[sp]["want"], st[sp]["strength"]], "x": xs, "y": ys})
	_save(AudioPlot.chart("AU1 STALL BUFFET ENVELOPE (2 MS RMS, NORMALISED)", series, {"x_label": "TIME S", "y_label": "ENVELOPE",
		"y_min": 0.0, "y_max": 1.0, "note": "PERIODIC FEATHER FLUTTER; RATE SCALES WITH SIZE (14 HZ SPARROW, ~10 HZ EAGLE). SILENT WHEN NOT STALLED."}), "stall_envelope.png")


func _danger() -> void:
	var xs := PackedFloat32Array()
	var h := PackedFloat32Array()
	var d := PackedFloat32Array()
	for i in 101:
		var lv := i / 100.0
		xs.append(lv)
		h.append(maxf(-60.0, FlightSoundMap.heart_db(lv)))
		d.append(maxf(-60.0, FlightSoundMap.drone_db(lv)))
	var dm := PackedFloat32Array()
	for v in d:
		dm.append(v + FlightSoundMap.danger_makeup_db(2.6, 0.0) if v > -60.0 else v)
	var series := [{"name": "heartbeat gain (design)", "x": xs, "y": h}, {"name": "tension drone gain (design)", "x": xs, "y": d},
		{"name": "drone in a spread 2.6x dive (+ its make-up)", "x": xs, "y": dm}]
	if m.has("danger"):
		series.append({"name": "measured danger bus RMS (dBFS)", "x": _p(m["danger"]["levels"]),
			"y": _p((m["danger"]["rms_db"] as Array).map(func(v: float) -> float: return maxf(-60.0, v))), "dots": true})
	_save(AudioPlot.chart("AU4 DANGER CUE VS THREAT LEVEL", series, {"x_label": "EVENTS.THREAT_CHANGED LEVEL", "y_label": "DB",
		"y_min": -60.0, "y_max": 0.0, "note": "SILENT AT 0, STRICTLY LOUDER WITH THE THREAT; THE HEARTBEAT ALSO SPEEDS UP (60 -> 111 BPM) AT A FIXED PITCH."}), "danger.png")


func _calls() -> void:
	if not m.has("calls"):
		return
	var med: Dictionary = m["calls"]["medians"]
	var clips: Dictionary = m["calls"]["clips"]
	var mx := PackedFloat32Array()
	var my := PackedFloat32Array()
	var labs := []
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	for sp in med:
		mx.append(med[sp]["dominant"])
		my.append(log(float(med[sp]["note_rate"]) + 0.5) / log(2.0))
		labs.append(sp)
		for c in clips[sp]:
			cx.append(c["dominant"])
			cy.append(log(float(c["note_rate"]) + 0.5) / log(2.0))
	var img := AudioPlot.chart("AU2 SPECIES CALLS: PITCH VS RHYTHM", [
		{"name": "each call clip", "x": cx, "y": cy, "dots": true, "line": false, "color": Color("#b9b8b2")},
		{"name": "species median", "x": mx, "y": my, "dots": true, "line": false, "labels": labs},
	], {"x_label": "DOMINANT PITCH HZ (LOG)", "y_label": "LOG2(NOTES/S + 0.5)", "log_x": true, "x_min": 400.0, "x_max": 8000.0, "y_min": -1.0, "y_max": 5.0,
		"note": "EVERY PAIR DIFFERS BY >= 1/4 OCTAVE IN PITCH OR CENTROID, OR >= 1/2 OCTAVE IN NOTE RATE OR LENGTH; EVERY CLIP IS NEAREST ITS OWN SPECIES.",
		"height": 600})
	_save(img, "calls_map.png")


## Level (A-weighted short-term) of a clip of loudness `loud_clip` played
## at `gain` dB at distance d (world metres), by Godot's law (unit / d, the
## near-field cap, the linear fade to the reach). The per-call random
## offset averages -0.25 dB.
static func _heard(sp: StringName, loud_clip: float, gain: float, d: float, cap: float) -> float:
	var v: Dictionary = CallVoices.VOICE[sp]
	var att := minf(gain + 20.0 * log(float(v["unit"]) / d) / log(10.0), cap)
	return loud_clip + att - 0.25 + 20.0 * log(maxf(1.0 - d / float(v["reach"]), 1e-5)) / log(10.0)


func _call_balance() -> void:
	var order := ["wren", "sparrow", "swallow", "starling", "pigeon", "crow", "gull", "hawk", "eagle"]
	var nx := PackedFloat32Array()
	var ny := PackedFloat32Array()
	for i in order.size():
		var sp := StringName(order[i])
		for clip in CallVoices.CALL_LOUDNESS:
			if not String(clip).begins_with(order[i] + "_"):
				continue
			var lc: float = CallVoices.CALL_LOUDNESS[clip]
			var g := float(CallVoices.VOICE[sp]["loud"]) - lc
			nx.append(i + 1.0)
			ny.append(_heard(sp, lc, g, 25.0, minf(g + CallVoices.NEAR_BOOST_DB, 0.0)) + CallVoices.air_loss_db(sp, 25.0))
	var series := [{"name": "model: every clip (Godot's distance law, air absorption)", "x": nx, "y": ny, "dots": true, "line": false,
		"color": AudioPlot.SERIES[0].lerp(AudioPlot.SURFACE, 0.5)}]
	var note := ""
	# As shipped in round 2, rendered by the round-3 experience verifier
	# (first clip per species, the default air-absorption shelf on).
	var vpath := Paths.artifacts("audio/fix_r3").path_join("verifier_r3x_measurements_before.json")
	if FileAccess.file_exists(vpath):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(vpath))
		if v is Dictionary and (v as Dictionary).has("calls_on_mixer"):
			var shipped: Dictionary = v["calls_on_mixer"]["as_shipped_25m"]
			var sx := PackedFloat32Array()
			var sy := PackedFloat32Array()
			for i in order.size():
				if shipped.has(order[i]):
					sx.append(i + 0.8)
					sy.append(float(shipped[order[i]]["dba"]))
			series.append({"name": "round 2 on the mixer (godot's default shelf; round-3 verifier)", "x": sx, "y": sy, "dots": true, "line": true,
				"color": Color("#b9b8b2")})
	if m.has("call_balance_mixer"):
		var mix: Dictionary = m["call_balance_mixer"]
		var mx := PackedFloat32Array()
		var my := PackedFloat32Array()
		var labs := []
		var lo := INF
		var hi := -INF
		for i in order.size():
			var row: Dictionary = mix.get(order[i], {})
			if row.has("at25_db"):
				mx.append(i + 1.2)
				my.append(float(row["at25_db"]))
				labs.append(order[i])
				if i < 5:
					lo = minf(lo, my[-1])
					hi = maxf(hi, my[-1])
		series.append({"name": "now on the mixer (loudest clip per species, both ears)", "x": mx, "y": my, "dots": true, "line": true,
			"labels": labs, "color": AudioPlot.INK})
		note = "ON THE MIXER NOW: WREN..PIGEON WITHIN %.1f DB (LIMIT 6); THE MODEL WITHIN 0.6 DB OF THE MIXER FOR EVERY SPECIES." % (hi - lo)
	_save(AudioPlot.chart("AU2 CALL LEVELS AT 25 PERCEIVED M (A-WEIGHTED, LOUDEST 0.4 S)", series,
		{"x_label": "SPECIES (SMALL TO LARGE)", "y_label": "DB A", "x_min": 0.5, "x_max": 9.8, "y_min": -70.0, "y_max": -10.0,
		"note": note, "height": 560}), "call_balance.png")


## The catch duck by speed (design, spread and tucked) and what the mixer
## measured: the duck at the catch and the crunch over the wind it lands in.
func _catch_duck() -> void:
	var xs := PackedFloat32Array()
	var spread := PackedFloat32Array()
	var tucked := PackedFloat32Array()
	for i in range(0, 131):
		var x := i / 50.0
		xs.append(x)
		spread.append(FlightSoundMap.catch_duck_db(FlightSoundMap.body_db(x, 0.0)))
		tucked.append(FlightSoundMap.catch_duck_db(FlightSoundMap.body_db(x, 1.0)))
	var series := [{"name": "designed duck, wings spread", "x": xs, "y": spread}, {"name": "designed duck, tucked", "x": xs, "y": tucked}]
	var note := ""
	if m.has("catch_over_wind"):
		var d: Dictionary = m["catch_over_wind"]
		var px := PackedFloat32Array()
		var py := PackedFloat32Array()
		var cx := PackedFloat32Array()
		var cy := PackedFloat32Array()
		for k in [["1.2x", 1.2], ["2.6x_tucked", 2.6]]:
			if d.has(k[0]):
				px.append(k[1])
				py.append(float(d[k[0]]["wind_during_db"]) - float(d[k[0]]["wind_before_db"]))
				cx.append(k[1])
				cy.append(float(d[k[0]]["crunch_over_wind_db"]))
		series.append({"name": "measured duck of the wind (a-weighted)", "x": px, "y": py, "dots": true, "line": false, "color": AudioPlot.INK})
		series.append({"name": "measured crunch over the wind it lands in (db a)", "x": cx, "y": cy, "dots": true, "line": false, "color": AudioPlot.SERIES[3]})
		note = "THE CRUNCH STANDS %.1f DB A OVER THE WIND AT 1.2X AND %.1f IN A TUCKED 2.6X DIVE (ROUND 3 FOUND +2.6 AT 2.4X; TEST >= 6)." % [cy[0], cy[-1]]
		# Round 4: the caught stinger and the fanfare in the same tucked dive.
		var rx := PackedFloat32Array()
		var ry := PackedFloat32Array()
		var dx := PackedFloat32Array()
		var dy := PackedFloat32Array()
		var labs := []
		for k in [["caught", 2.52, "stinger"], ["fanfare", 2.68, "fanfare"]]:
			if d.has(k[0]):
				rx.append(k[1])
				ry.append(float(d[k[0]]["cue_over_wind_db"]))
				dx.append(k[1])
				dy.append(float(d[k[0]]["wind_during_db"]) - float(d[k[0]]["wind_before_db"]))
				labs.append(k[2])
		if not rx.is_empty():
			series.append({"name": "stinger / fanfare over the dive wind (db a)", "x": rx, "y": ry, "dots": true, "line": false,
				"labels": labs, "color": AudioPlot.SERIES[4]})
			series.append({"name": "their duck of the wind", "x": dx, "y": dy, "dots": true, "line": false, "labels": labs,
				"color": AudioPlot.INK_2})
			if ry.size() == 2:
				note = "OVER THE WIND IT LANDS IN: THE CRUNCH %.1f DB A AT 1.2X, %.1f IN A TUCKED 2.6X DIVE; THE STINGER %.1f, THE FANFARE %.1f (TEST >= 6)." % [
					cy[0], cy[-1], ry[0], ry[1]]
	_save(AudioPlot.chart("CUES: THE WIND STEPS BACK FOR THE CUE, DEEPER IN A DIVE", series,
		{"x_label": "AIRSPEED / CRUISE", "y_label": "DB", "x_max": 2.85, "y_min": -16.0, "y_max": 22.0,
		"hlines": [{"y": 0.0, "label": ""}, {"y": 6.0, "label": "TEST: CUE >= 6 DB A OVER THE WIND"}], "note": note}), "catch_duck.png")


## Programme loudness at the output across ordinary play and the menu:
## the round-3 experience verifier's own probe on round 2 and on this
## round's code (same method: master tap, 2 s ungated K-weighted), plus this
## suite's pinned pair (the menu intro, a glide 100 m up).
func _programme() -> void:
	var states := ["menu", "perched_forest_birds", "flapping_cruise_5m", "glide_cruise_20m", "slow_glide_0.6x_5m", "dive_2.4x_tucked"]
	var series := []
	var note := ""
	for spec in [["round 2 (verifier's probe)", "verifier_r3x_measurements_before.json", Color("#b9b8b2")],
			["now (the same probe, rerun)", "verifier_probes/r3x/measurements.json", AudioPlot.INK]]:
		var path := Paths.artifacts("audio/fix_r3").path_join(spec[1])
		if not FileAccess.file_exists(path):
			continue
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (v is Dictionary and (v as Dictionary).has("ordinary_play_loudness")):
			continue
		var o: Dictionary = v["ordinary_play_loudness"]
		var xs := PackedFloat32Array()
		var ys := PackedFloat32Array()
		var labs := []
		for i in states.size():
			if o.has(states[i]):
				xs.append(i + 1)
				ys.append(float(o[states[i]]["lufs"]))
				labs.append("%.1f" % ys[-1])
		var row := {"name": spec[0], "x": xs, "y": ys, "dots": true, "line": true, "color": spec[2]}
		if spec[2] == AudioPlot.INK:
			row["labels"] = labs
		series.append(row)
		note += "%s: GLIDE %.1f LU UNDER THE MENU. " % ["ROUND 2" if spec[2] != AudioPlot.INK else "NOW", float(o["menu"]["lufs"]) - float(o["glide_cruise_20m"]["lufs"])]
	if m.has("programme_loudness"):
		var p: Dictionary = m["programme_loudness"]
		series.append({"name": "this suite (menu intro, glide 100 m up; pinned <= 8 lu apart)", "x": PackedFloat32Array([1.0, 4.0]),
			"y": PackedFloat32Array([float(p["menu_lufs"]), float(p["glide_cruise_lufs"])]), "dots": true, "line": false, "color": AudioPlot.SERIES[3]})
	if series.is_empty():
		return
	_save(AudioPlot.chart("PROGRAMME LOUDNESS AT THE OUTPUT (LUFS)", series,
		{"x_label": "1 MENU  2 PERCHED, BIRDS  3 FLAPPING AT CRUISE  4 GLIDE AT CRUISE  5 SLOW GLIDE  6 TUCKED DIVE", "y_label": "LUFS",
		"x_min": 0.5, "x_max": 6.5, "y_min": -46.0, "y_max": -16.0, "note": note.strip_edges(), "height": 560}), "programme_loudness.png")


func _wind_over_ambience() -> void:
	if not m.has("wind_over_ambience"):
		return
	var d: Dictionary = m["wind_over_ambience"]["sparrow"]
	var oct := _p(d["octaves_hz"])
	var series := [{"name": "wind at cruise (sparrow, wind bus)", "x": oct, "y": _p(d["wind_oct"]), "dots": true, "color": AudioPlot.INK}]
	var i := 0
	for zone in ["forest", "lake", "village", "meadow", "cliffs"]:
		var z: Dictionary = d[zone]
		series.append({"name": "%s bed at cruise" % zone, "x": oct, "y": _p(z["bed_oct"]), "color": AudioPlot.SERIES[i]})
		i += 1
	var meadow: Dictionary = d["meadow"]
	var rest := PackedFloat32Array()
	for v in meadow["bed_oct"]:
		rest.append(float(v) - float(meadow["duck_db"]))
	series.append({"name": "meadow bed perched (no speed duck)", "x": oct, "y": rest, "color": AudioPlot.SERIES[3].lerp(AudioPlot.SURFACE, 0.55)})
	_save(AudioPlot.chart("SPEED CUE: WIND AT CRUISE OVER EVERY AMBIENCE BED, 4 M UP", series, {"x_label": "OCTAVE BAND HZ", "y_label": "BAND LEVEL DB (PER EAR, RMS-REFERENCED)",
		"log_x": true, "x_min": 110.0, "x_max": 4500.0, "y_min": -110.0, "y_max": -30.0,
		"note": "WIND ON THE MIXER; BEDS = WHOLE LOOPS AT THEIR PLAYERS' GAIN (SPEED DUCK %.1f DB). WIND LEADS BY >= %.1f DB A." % [
			float(meadow["duck_db"]), _worst_margin(d)], "height": 600}), "wind_over_ambience.png")


static func _worst_margin(d: Dictionary) -> float:
	var w := INF
	for zone in ["forest", "lake", "village", "meadow", "cliffs"]:
		w = minf(w, float(d[zone]["margin_a"]))
	return w


func _speed_ducks() -> void:
	var xs := PackedFloat32Array()
	var body := PackedFloat32Array()
	var amb := PackedFloat32Array()
	var calls := PackedFloat32Array()
	var makeup := PackedFloat32Array()
	var lift_t := PackedFloat32Array()
	for i in range(1, 131):
		var x := i / 50.0
		xs.append(x)
		body.append(maxf(-60.0, FlightSoundMap.body_db(x)))
		amb.append(FlightSoundMap.ambience_duck_db(x))
		calls.append(FlightSoundMap.calls_duck_db(x))
		makeup.append(FlightSoundMap.danger_makeup_db(x, 0.0))
		lift_t.append(-FlightSoundMap.calls_duck_db(x) + FlightSoundMap.threat_call_lift_db(FlightSoundMap.edge_db(x, 1.0)))
	_save(AudioPlot.chart("SPEED: THE WIND RISES, THE WORLD RECEDES, THE DANGER KEEPS ITS PLACE", [
		{"name": "wind body level (db)", "x": xs, "y": body},
		{"name": "ambience speed duck (db)", "x": xs, "y": amb},
		{"name": "npc calls speed duck (db)", "x": xs, "y": calls},
		{"name": "drone make-up, wings spread (db, round 5)", "x": xs, "y": makeup},
		{"name": "threatening predator's call lift, tucked (db, round 5)", "x": xs, "y": lift_t},
	], {"x_label": "AIRSPEED / CRUISE", "y_label": "DB", "y_min": -60.0, "y_max": 12.0,
		"hlines": [{"y": FlightSoundMap.ambience_duck_db(1.0), "label": "beds at cruise"}],
		"note": "BEDS RECEDE FROM 0.55X (15.9 DB DOWN AT CRUISE); CALLS DIP IN A DIVE; THE DRONE AND THE THREAT'S CALL RISE WITH THE WIND THAT MASKS THEM.", "height": 600}), "speed_ducks.png")


func _bell() -> void:
	var xs := PackedFloat32Array()
	var ws1 := PackedFloat32Array()
	var ws_small := PackedFloat32Array()
	var cruise := PackedFloat32Array()
	var old := PackedFloat32Array()
	var duck := FlightSoundMap.ambience_duck_db(1.0)
	for i in 60:
		var d := 2.0 * pow(150.0, i / 59.0)
		xs.append(d)
		ws1.append(_bell_gain(d, 1.0, 0.0))
		# Rounds 2-4 scaled its distances by the player's size.
		ws_small.append(_bell_gain(d, 0.24 / 1.7, 0.0))
		cruise.append(_bell_gain(d, 1.0, duck))
		# Round 1: unit 60 m, volume -6 dB, max_db at Godot's default +3 dB,
		# 900 m reach, no world scale.
		var att := minf(-6.0 + 20.0 * log(60.0 / d) / log(10.0), 3.0)
		old.append(att + 20.0 * log(maxf(1.0 - d / 900.0, 1e-5)) / log(10.0))
	var series := [
		{"name": "round 1 (max_db +3 db default)", "x": xs, "y": old, "color": Color("#b9b8b2")},
		{"name": "rounds 2-4, sparrow-sized player (perceived distance)", "x": xs, "y": ws_small, "color": Color("#8a8984")},
		{"name": "now, at rest, every player size (world metres)", "x": xs, "y": ws1},
		{"name": "now, flying at cruise (speed duck)", "x": xs, "y": cruise},
	]
	var note := "GAIN BY GODOT'S INVERSE-DISTANCE LAW WITH THE BELL'S SETTINGS."
	if m.has("bell_measured"):
		var bm: Dictionary = m["bell_measured"]
		series.append({"name": "measured at 8 m: stroke peak - clip peak", "x": _p([8.0]), "y": _p([float(bm["stroke_peak_at_8m_dbfs"]) - float(bm["clip_peak_dbfs"])]), "dots": true, "line": false, "color": AudioPlot.INK})
		note += " STROKE AT THE TOWER MEASURED %.1f DBFS PEAK ON THE AMBIENCE BUS." % float(bm["stroke_peak_at_8m_dbfs"])
	_save(AudioPlot.chart("CHURCH BELL LEVEL VS DISTANCE TO THE BELFRY", series, {"x_label": "WORLD DISTANCE M (LOG)", "y_label": "GAIN DB",
		"log_x": true, "y_min": -50.0, "y_max": 6.0, "hlines": [{"y": AmbienceZones.BELL_DB, "label": "cap %.0f db" % AmbienceZones.BELL_DB}],
		"note": note, "height": 560}), "bell_vs_distance.png")


## The bell's gain at world distance d; ws < 1 draws the perceived-distance
## law of rounds 2-4 (distances scaled by the player's size).
static func _bell_gain(d: float, ws: float, duck: float) -> float:
	var unit := AmbienceZones.BELL_UNIT * ws
	var reach := AmbienceZones.BELL_REACH * ws
	var att := minf(AmbienceZones.BELL_DB + duck + 20.0 * log(unit / d) / log(10.0), AmbienceZones.BELL_DB + duck)
	return att + 20.0 * log(maxf(1.0 - d / reach, 1e-5)) / log(10.0)


## Zone weights over the real world when it loads (world area's scene via
## the World contract only), else over a small mock layout.
## Round 4: every input fed NaN, +INF, -INF, +1e30 and -1e30 for 4 frames
## (tests/unit/audio/audio_input_test.gd): per input, the worst deviation of
## any layer, bus fader, filter or duck from its level before, 0.5 s after
## normal input resumed. One row per input, a dot per bad value, the worst
## printed at the right (the dots' colours are not the only cue).
func _bad_inputs() -> void:
	if not m.has("bad_input_recovery"):
		return
	var d: Dictionary = m["bad_input_recovery"]
	var worst: Dictionary = d["worst_by_case"]
	var tol := float(d.get("tol_db", 1.5))
	var values := ["nan", "inf", "-inf", "1e30", "-1e30"]
	var rows := []  # input names in first-seen order
	var by := {}  # input -> {value index: dev}
	for label: String in worst:
		var at := label.rfind("=")
		var input := label.substr(0, at)
		var raw := label.substr(at + 1)
		var vi := 0
		if raw == "inf":
			vi = 1
		elif raw == "-inf":
			vi = 2
		elif raw.begins_with("-9") or raw.begins_with("-1"):
			vi = 4
		elif raw.begins_with("9") or raw.begins_with("1"):
			vi = 3
		if not by.has(input):
			by[input] = {}
			rows.append(input)
		by[input][vi] = float(worst[label][0])
	var w := 960
	var row_h := 22
	var top := 84
	var legend_h := 30
	var h := top + rows.size() * row_h + 40 + legend_h
	var img := AudioPlot.canvas(w, h)
	AudioPlot.text(img, 16, 16, "BAD INPUT: EVERY LEVEL BACK 0.5 S LATER", AudioPlot.INK, 2)
	AudioPlot.text(img, 16, 40, "EACH INPUT FED NAN, +INF, -INF, +1E30, -1E30 FOR 4 FRAMES, THEN NORMAL VALUES: THE WORST LAYER, BUS, FILTER OR DUCK", AudioPlot.INK_2)
	AudioPlot.text(img, 16, 52, "0.5 S LATER, AGAINST ITS LEVEL BEFORE (%d CASES). NOTHING HANDED TO THE ENGINE WAS EVER NON-FINITE." % int(d.get("cases", 0)), AudioPlot.INK_2)
	var left := 190
	var right := 70
	var pw := w - left - right
	var xmax := 2.0
	var fx := func(v: float) -> float: return left + pw * clampf(v, 0.0, xmax) / xmax
	for i in 5:
		var xv := i * 0.5
		var px := int(fx.call(xv))
		AudioPlot.rect(img, px, top - 4, 1, rows.size() * row_h + 4, AudioPlot.GRID)
		var lab := AudioPlot.fmt(xv)
		AudioPlot.text(img, px - AudioPlot.text_width(lab) / 2, top + rows.size() * row_h + 6, lab, AudioPlot.INK_2)
	var tx := int(fx.call(tol))
	for y in range(top - 12, top + rows.size() * row_h, 3):
		AudioPlot.rect(img, tx, y, 1, 2, AudioPlot.INK_2)
	AudioPlot.text(img, tx + 4, top - 14, "TOLERANCE %.1f DB" % tol, AudioPlot.INK_2)
	AudioPlot.text(img, left + pw / 2 - 90, top + rows.size() * row_h + 20, "DB FROM THE LEVEL BEFORE, 0.5 S LATER", AudioPlot.INK_2)
	for r in rows.size():
		var input: String = rows[r]
		var y := top + r * row_h
		AudioPlot.text_right(img, left - 10, y + row_h / 2 - 3, input.replace("telemetry.", "tel.").replace("_", " "), AudioPlot.INK)
		AudioPlot.rect(img, left, y + row_h / 2, pw, 1, AudioPlot.GRID)
		var mx := 0.0
		for vi in 5:
			if (by[input] as Dictionary).has(vi):
				var dev: float = by[input][vi]
				mx = maxf(mx, dev)
				# Each bad value on its own line within the row, so dots at the
				# same deviation stay visible.
				AudioPlot.dot(img, Vector2(fx.call(dev), y + row_h / 2 + (vi - 2) * 3), 3.0, AudioPlot.SERIES[vi])
		AudioPlot.text(img, left + pw + 10, y + row_h / 2 - 3, "%.2f" % mx, AudioPlot.INK)
	var lx := left
	var ly := h - legend_h + 6
	for vi in 5:
		AudioPlot.rect(img, lx, ly + 2, 14, 4, AudioPlot.SERIES[vi])
		AudioPlot.text(img, lx + 20, ly, values[vi], AudioPlot.INK)
		lx += 20 + AudioPlot.text_width(values[vi]) + 24
	_save(img, "bad_input_recovery.png")


## Round 4: a hawk hunting a sparrow-sized player calls again and again as
## it closes in. The level each new call starts at, relative to the hawk's
## unit level: the free-field law (with Godot's fade to the reach), round 3's
## flat -6 dB floor under it, the rising floor now, and what the suite
## measured on the voices.
func _screams() -> void:
	var ws := 0.24 / 1.7
	var xs := PackedFloat32Array()
	var perceived := PackedFloat32Array()
	var r4 := PackedFloat32Array()
	var world := PackedFloat32Array()
	var now := PackedFloat32Array()
	# The loudest one voice plays the hawk (0 dB of gain): its clip needs
	# -2.4 dB at the unit distance (CallVoices.clip_gain_db).
	var full := -(float(CallVoices.VOICE[&"hawk"]["loud"]) - float(CallVoices.CALL_LOUDNESS[&"hawk_1"]))
	var dm := 3.0
	while dm <= 120.0:
		xs.append(dm)
		var p := CallVoices.distance_db(&"hawk", dm / ws)
		perceived.append(maxf(p, -30.0))
		r4.append(maxf(p, CallVoices.threat_floor_db(dm / ws)))
		var w := minf(CallVoices.distance_db(&"hawk", dm), full)
		world.append(maxf(w, -30.0))
		now.append(minf(maxf(w, CallVoices.threat_floor_db(dm / ws)), full))
		dm *= 1.05
	var series := [
		{"name": "rounds 2-4: an ordinary call, perceived distance (cut past 42 m)", "x": xs, "y": perceived, "color": Color("#b9b8b2")},
		{"name": "round 4: the threat's call (the rising floor)", "x": xs, "y": r4, "color": Color("#8a8984")},
		{"name": "now: an ordinary call, world metres", "x": xs, "y": world, "color": AudioPlot.SERIES[0]},
		{"name": "now: the threat's call (floor, then its natural level, to a full voice)", "x": xs, "y": now, "color": AudioPlot.SERIES[1]},
	]
	var note := ""
	if m.has("successive_screams"):
		var d: Dictionary = m["successive_screams"]
		var mx := PackedFloat32Array()
		var my := PackedFloat32Array()
		for i in (d["dist_m"] as Array).size():
			mx.append(float(d["dist_m"][i]))
			my.append(float(d["gain_db"][i]))
		series.append({"name": "measured: each new call's start (the suite)", "x": mx, "y": my, "dots": true, "line": false, "color": AudioPlot.INK})
		note = "A HAWK HUNTING A SPARROW-SIZED PLAYER (WORLD SCALE 0.14): EACH NEW CALL LOUDER UNTIL A FULL VOICE; +%.1f DB FROM 60 TO 10 M." % (my[3] - my[0])
	_save(AudioPlot.chart("PREDATOR SCREECH GETTING LOUDER: NEW CALLS AS THE HAWK CLOSES IN", series,
		{"x_label": "HAWK DISTANCE, WORLD M (SPARROW SCALE)", "y_label": "DB RELATIVE TO THE HAWK'S UNIT LEVEL", "log_x": true,
		"x_min": 3.0, "x_max": 120.0, "y_min": -30.0, "y_max": 4.0, "hlines": [{"y": full, "label": "A FULL VOICE"}], "note": note, "height": 600}),
		"successive_screams.png")


## Round 5: the Ecosystem's sky (60 NPCs, mostly 60-110 m out) round a
## player at cruise, per size: calls started per minute as the round-5
## verifier measured them (perceived distances: 0 at sparrow size), in its
## probe rerun on round 5's code, and the suite's simulation (calls started
## and those heard over the cruise wind in their own octave).
func _living_sky() -> void:
	var sizes := ["sparrow", "pigeon", "eagle"]
	var xs := _p([1.0, 2.0, 3.0])
	var series := []
	var before: Dictionary = _verifier("r5x").get("living_sky", {})
	if not before.is_empty():
		series.append({"name": "round 4 code (verifier's probe): calls started / min", "x": xs,
			"y": _p(sizes.map(func(sz: String) -> float: return float(before[sz]["calls_per_min"]))), "dots": true, "color": Color("#b9b8b2")})
	var rerun_path := Paths.artifacts("audio/fix_r5/verifier_probes/r5x/measurements.json")
	if FileAccess.file_exists(rerun_path):
		var rr: Dictionary = (JSON.parse_string(FileAccess.get_file_as_string(rerun_path)) as Dictionary).get("living_sky", {})
		if not rr.is_empty():
			series.append({"name": "now (verifier's probe rerun): calls started / min", "x": xs,
				"y": _p(sizes.map(func(sz: String) -> float: return float(rr[sz]["calls_per_min"]))), "dots": true, "color": AudioPlot.SERIES[0]})
	var note := ""
	if m.has("living_sky"):
		var sim: Dictionary = m["living_sky"]["simulated"]
		var per_min := func(sz: String, key: String) -> float:
			var secs := 5.0 * (sim[sz]["audible_per_5s"] as Array).size()
			return float(sim[sz][key]) * 60.0 / secs
		series.append({"name": "now (suite simulation): calls started / min", "x": xs,
			"y": _p(sizes.map(func(sz: String) -> float: return per_min.call(sz, "calls"))), "dots": true, "color": AudioPlot.SERIES[1]})
		series.append({"name": "now (suite simulation): heard over the cruise wind / min", "x": xs,
			"y": _p(sizes.map(func(sz: String) -> float: return per_min.call(sz, "audible"))), "dots": true, "color": AudioPlot.SERIES[2]})
		var mix: Dictionary = m["living_sky"].get("mixer", {})
		note = "1 SPARROW (WS 0.13)  2 PIGEON (0.37)  3 EAGLE (1.17). CUT SHORT BY STEALING %d%%." % int(round(100.0 * float(sim["sparrow"]["cut_short_share"])))
		if not mix.is_empty():
			note += " ON THE MIXER: LOUDEST CALL %.1f DB A, CRUISE WIND %.1f." % [float(mix["loudest_aw_db"]), float(mix["cruise_wind_aw_db"])]
	_save(AudioPlot.chart("A LIVING SKY: CALLS IN THE ECOSYSTEM'S SKY BY PLAYER SIZE", series,
		{"x_label": "PLAYER SIZE", "y_label": "PER MINUTE", "x_min": 0.8, "x_max": 3.2, "y_min": 0.0,
		"hlines": [{"y": 12.0, "label": "ONE EVERY 5 S"}], "note": note, "height": 600}), "living_sky.png")


## Round 5: how every shipped call ends: the 50 ms before its final 40 ms
## fade, dB under its loudest 50 ms (the verifier's measure; the suite
## holds it under -20 dB).
func _call_endings() -> void:
	if not m.has("call_endings"):
		return
	var now: Dictionary = m["call_endings"]
	var before: Dictionary = _verifier("r5x").get("call_endings_db_re_loudest", {})
	var names: Array = now.keys()
	names.sort()
	var xs := PackedFloat32Array()
	var yn := PackedFloat32Array()
	var labs: Array[String] = []
	var xb := PackedFloat32Array()
	var yb := PackedFloat32Array()
	for i in names.size():
		xs.append(i + 1)
		yn.append(maxf(-60.0, float(now[names[i]])))
		var nm: String = names[i]
		labs.append(nm.left(2) + nm.right(1))
		if before.has(nm) and absf(float(before[nm]) - float(now[nm])) > 0.05:
			xb.append(i + 1)
			yb.append(float(before[nm]))
	var series := [{"name": "now", "x": xs, "y": yn, "dots": true, "line": false, "labels": labs, "color": AudioPlot.SERIES[0]}]
	if not xb.is_empty():
		series.append({"name": "round 4 (the clips re-cut in round 5)", "x": xb, "y": yb, "dots": true, "line": false, "color": AudioPlot.SERIES[3]})
	_save(AudioPlot.chart("HOW THE SHIPPED CALLS END", series,
		{"x_label": "CLIP (ALPHABETICAL: CR CROW, EA EAGLE, GU GULL, HA HAWK, PI PIGEON, SP SPARROW, ST STARLING, SW SWALLOW, WR WREN)",
		"y_label": "DB UNDER THE LOUDEST 50 MS", "y_min": -60.0, "y_max": 0.0, "x_min": 0.0, "x_max": names.size() + 1.5,
		"hlines": [{"y": -20.0, "label": "BAR: -20 DB"}],
		"note": "THE 50 MS BEFORE EACH CLIP'S END FADE (-60 = SILENT). ROUND 4: 9 CUTS STOPPED MID-NOTE; NOW EVERY CALL HAS DIED AWAY.", "height": 600}),
		"call_endings.png")


## Round 5: the danger cue over the wind in the 125/250 Hz octaves at 1.5x
## cruise and in a spread 2.6x dive, at threat 0.5 and 1: round 4's code
## (the verifier's probe) and now (the suite).
func _danger_over_wind() -> void:
	if not m.has("danger") or not (m["danger"] as Dictionary).has("over_wind"):
		return
	var ow: Dictionary = m["danger"]["over_wind"]
	var series := [
		{"name": "now, threat 0.5", "x": _p([1.5, 2.6]), "y": _p([ow["1.5x_0.5"]["over_wind_db"], ow["2.6x_spread_0.5"]["over_wind_db"]]), "dots": true, "color": AudioPlot.SERIES[0]},
		{"name": "now, threat 1", "x": _p([2.6]), "y": _p([ow["2.6x_spread_1"]["over_wind_db"]]), "dots": true, "line": false, "color": AudioPlot.SERIES[1]},
	]
	var r4: Dictionary = _verifier("r4x").get("danger_in_dive", {})
	if r4.has("spread_2.6x"):
		series.append({"name": "round 4 code (verifier's probe), threat 0.5", "x": _p([1.5, 2.6]),
			"y": _p([r4["spread_1.5x"]["danger@0.5"]["band_125_250_margin_db"], r4["spread_2.6x"]["danger@0.5"]["band_125_250_margin_db"]]),
			"dots": true, "color": Color("#b9b8b2")})
		series.append({"name": "round 4 code, threat 1", "x": _p([1.5, 2.6]),
			"y": _p([r4["spread_1.5x"]["danger@1.0"]["band_125_250_margin_db"], r4["spread_2.6x"]["danger@1.0"]["band_125_250_margin_db"]]),
			"dots": true, "color": Color("#8a8984")})
	_save(AudioPlot.chart("THE DANGER CUE OVER THE WIND, WINGS SPREAD", series,
		{"x_label": "AIRSPEED / CRUISE", "y_label": "DB OVER THE WIND AT 125/250 HZ", "x_min": 1.3, "x_max": 2.8, "y_min": -6.0, "y_max": 14.0,
		"hlines": [{"y": 1.0, "label": "BAR AT 0.5: 1 DB"}, {"y": 6.0, "label": "BAR AT 1: 6 DB"}],
		"note": "THE DRONE RISES WITH THE WIND'S BODY ABOVE 1.5X (UP TO 6 DB); A TUCK THINS THE WIND INSTEAD (12-19 DB CLEAR).", "height": 560}),
		"danger_over_wind.png")


func _ambience() -> void:
	var w: World = null
	if ResourceLoader.exists("res://scenes/world/world.tscn") and Paths.arg("mock", "") == "":
		var ps := load("res://scenes/world/world.tscn") as PackedScene
		if ps:
			var node := ps.instantiate()
			if node is World:
				w = node
				add_child(w)
	if w == null:
		print("[audio] ambience map: world scene unavailable, using a mock layout")
		return
	if not w.is_generated:
		await w.generated
	var amb := AmbienceZones.new()
	add_child(amb)
	amb.setup(null)
	amb.set_world(w)
	var R := w.bounds_radius
	var size := 360
	var img := AudioPlot.canvas(size + 260, size + 90)
	var colors := {&"trees": AudioPlot.SERIES[5], &"water": AudioPlot.SERIES[0], &"village": AudioPlot.SERIES[1], &"meadow": AudioPlot.SERIES[3], &"open": AudioPlot.SERIES[6]}
	AudioPlot.text(img, 10, 10, "AMBIENCE ZONES OVER THE WORLD (3 M ABOVE GROUND)", AudioPlot.INK, 2)
	AudioPlot.text(img, 10, 32, "EACH PIXEL: THE LOUDEST ZONE'S COLOUR, FADED BY ITS WEIGHT. FROM WORLD.GET_LANDMARKS().", AudioPlot.INK_2)
	var ox := 10
	var oy := 60
	for py in size:
		for px in size:
			var x := (float(px) / size * 2.0 - 1.0) * R
			var z := (float(py) / size * 2.0 - 1.0) * R
			var gh := w.ground_height(x, z)
			var wts := amb.compute_weights(Vector3(x, gh + 3.0, z), 3.0)
			var best := &""
			var bw := 0.0
			for zn in wts:
				if wts[zn] > bw:
					bw = wts[zn]
					best = zn
			var col := AudioPlot.SURFACE
			if bw > 0.0:
				col = AudioPlot.SURFACE.lerp(colors[best], clampf(bw, 0.0, 1.0) * 0.85)
			img.set_pixel(ox + px, oy + py, col)
	var ly := oy
	for zn in colors:
		AudioPlot.rect(img, ox + size + 20, ly + 2, 14, 10, colors[zn])
		AudioPlot.text(img, ox + size + 40, ly + 3, String(zn), AudioPlot.INK)
		ly += 22
	AudioPlot.text(img, ox + size + 20, ly + 10, "PALE VIOLET: OPEN-AIR FLOOR", AudioPlot.INK_2)
	AudioPlot.text(img, ox + size + 20, ly + 24, "(SOFT BREEZE AT 0.3)", AudioPlot.INK_2)
	_save(img, "ambience_map.png")
	w.queue_free()
	amb.queue_free()
	await get_tree().process_frame
