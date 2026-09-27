extends Node
## Records the flights the UI suites replay, from the real FlightModel, into
## tests/unit/ui/ui_flight_runs.json (in the real tree, not the sandbox).
##
## The UI tests must depend only on core contracts, stubs or the area's own
## mocks (ARCHITECTURE hard rules): flight is still in fix rounds, and a
## changed FlightModel signature would stop the UI suites parsing. So the
## flights are flown here, once, and the suites replay the recording (as
## they already do for flight's B1 course, ui_b1_flightpath.json). Rerun
## this after a flight-model change to refresh them:
##
##   tools/gd.sh ui --headless res://tests/shots/ui_flight_record.tscn
##
## Recorded:
##  - "tutorial": the flight the tutorial asks for ("Flap to climb", then
##    "Glide"): a sparrow from trim, wrists neutral, bursts of N strokes at
##    1 Hz then G s of gliding. [t, flight-path angle deg, speed m/s] at
##    20 Hz. "2+2" (60 s) and "3+3" (36 s).
##  - "tilt": "Tilt for speed" flights: a symmetric wing-pitch command held
##    from `tilt_at`, with or without flapping bursts, for a sparrow and an
##    eagle; per frame the telemetry the lesson reads, as PlayerBird reports
##    it: airspeed, vertical_speed, flapping (WingInput's 0.3 s low-pass of
##    the stroke), pitch_input (WingState.pitch). Frames every `dt` s: 1/72
##    for the tilts (as flown), 1/24 for the 60 s neutral-wrist runs (every
##    third frame of a 72 Hz flight: their pitch_input is 0 throughout, so
##    the lesson's window can never open whatever the rate).

const DT := 1.0 / 72.0


func _ready() -> void:
	var out := {
		"about": "Flights for the UI suites, flown on the real FlightModel by tests/shots/ui_flight_record.gd; replayed by ui_hud_test and ui_onboarding_test so the UI suites never call flight internals.",
		"recorded": Time.get_datetime_string_from_system(true),
		"tutorial": {
			"2+2": _tutorial_series(2, 2.0, 60.0),
			"3+3": _tutorial_series(3, 3.0, 36.0),
		},
		"tilt": {},
	}
	var tilt: Dictionary = out["tilt"]
	for sp: StringName in [&"sparrow", &"eagle"]:
		for c: Array in [[1, 3.0], [2, 2.0], [3, 3.0], [0, 0.0]]:
			tilt["%s flap %d + glide %.0f s, wrists neutral, 60 s" % [sp, c[0], c[1]]] = _fly(sp, 0.0, int(c[0]), float(c[1]), 60.0, 0.0, 3)
		for p: float in [-0.35, 0.35, -0.6, 0.6]:
			tilt["%s glide, tilt %+.2f" % [sp, p]] = _fly(sp, p, 0, 0.0, 6.0, 0.0, 1)
	tilt["sparrow flap 2, then tilt -0.60 at once"] = _fly(&"sparrow", -0.6, 2, 30.0, 8.0, 2.05, 1)
	var root := OS.get_environment("SOARING_ROOT")
	if root.is_empty():
		root = ProjectSettings.globalize_path("res://")
	var path := root.path_join("tests/unit/ui/ui_flight_runs.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "", false))
	f.close()
	print("[ui] recorded %d tutorial and %d tilt flights into %s" % [(out["tutorial"] as Dictionary).size(), tilt.size(), path])
	get_tree().quit(0)


## [t, gamma_deg, speed] at 20 Hz of the tutorial's flap-and-glide.
static func _tutorial_series(strokes: int, glide_s: float, seconds: float) -> Array:
	var m := FlightModel.new(FlightParams.species_mass(&"sparrow"), FlightTuning.new())
	m.trim(Vector3(0.0, 80.0, 0.0), 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var rows: Array = []
	var cycle := float(strokes) + glide_s
	var next := 0.0
	for i in int(seconds / DT):
		var t := i * DT
		var ph := fmod(t, cycle)
		if ph < float(strokes):
			ws.set_commands(0.0, 0.0, 1.0, 1.0, ph, 1.0, 0, NAN, m.params.x)
		else:
			ws.set_commands(0.0, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, env, DT)
		if t >= next:
			var v := m.velocity
			rows.append([snappedf(t, 0.001), snappedf(rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length())), 0.01), snappedf(v.length(), 0.001)])
			next += 0.05
	return rows


## A "Tilt for speed" flight: pitch command `pitch` from `tilt_at` on,
## flapping bursts of `strokes` strokes at 1 Hz and `glide_s` gliding between
## them until the tilt (strokes 0 = a glide). Every `every`-th 72 Hz frame.
static func _fly(species: StringName, pitch: float, strokes: int, glide_s: float, seconds: float, tilt_at: float, every: int) -> Dictionary:
	var m := FlightModel.new(FlightParams.species_mass(species), FlightTuning.new())
	m.trim(Vector3(0.0, 80.0, 0.0), 0.0)
	var ws := WingState.new()
	var env := FlightEnv.new()
	var lp := 0.0
	var k_lp := 1.0 - exp(-DT / 0.3)
	var cycle := float(strokes) + glide_s
	var cols := {"airspeed": [], "vertical_speed": [], "flapping": [], "pitch_input": []}
	for i in int(seconds / DT):
		var t := i * DT
		var p := pitch if t >= tilt_at else 0.0
		var ph := fmod(t, cycle) if strokes > 0 else cycle
		var stroking := strokes > 0 and ph < float(strokes) and (tilt_at <= 0.0 or t < tilt_at)
		if stroking:
			ws.set_commands(p, 0.0, 1.0, 1.0, ph, 1.0, 0, NAN, m.params.x)
		else:
			ws.set_commands(p, 0.0, 1.0, 0.0, 0.0)
		m.step(ws, env, DT)
		lp += (maxf(ws.flap_l, ws.flap_r) - lp) * k_lp
		if i % every != 0:
			continue
		var tl := m.telemetry()
		(cols["airspeed"] as Array).append(snappedf(float(tl["airspeed"]), 0.001))
		(cols["vertical_speed"] as Array).append(snappedf(float(tl["vertical_speed"]), 0.001))
		(cols["flapping"] as Array).append(snappedf(clampf(lp, 0.0, 1.0), 0.001))
		(cols["pitch_input"] as Array).append(snappedf(ws.pitch, 0.001))
	return {"species": String(species), "pitch": pitch, "strokes": strokes, "glide_s": glide_s, "seconds": seconds,
		"tilt_at": tilt_at, "dt": DT * every, "frames": (cols["airspeed"] as Array).size(), "columns": cols}
