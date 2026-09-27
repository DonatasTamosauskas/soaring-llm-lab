extends Node
## Evidence plots for the flight area (FLIGHT_SPEC §14.6), computed from the
## real classes and drawn headless into Images by FlightPlot:
##
##   tools/gd.sh flight --headless res://tests/shots/flight_plots.tscn [-- --only=f2,f3]
##
## Writes artifacts/flight/*.png (+ CSVs for the scenario runs) and the
## contact sheet artifacts/flight/overview.png. Every plot is reviewed by eye
## and indexed in docs/areas/FLIGHT.md.
##
## Colour follows the entity: each species keeps one categorical slot across
## every plot (sparrow blue ... eagle red), in the fixed palette order.

const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const WR := preload("res://tests/unit/flight/wing_rig.gd")
const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const BC := preload("res://tests/unit/flight/bot_course.gd")
const HM := preload("res://tests/unit/flight/heave_metrics.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0

var _out := ""
var _only: PackedStringArray = []
var _written: PackedStringArray = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_out = Paths.artifacts("flight")
	var o := Paths.arg("only", "")
	if not o.is_empty():
		_only = o.split(",")
	var jobs := [
		["f2", _f2_balloon_sag], ["f2map", _f2_alpha_map], ["f3", _f3_stall], ["f3lc", _f3_lift_curve], ["f4", _f4_turn],
		["f7c", _f7_turn_circles], ["f7p", _f7_glide_polars], ["f1", _f1_flap_impulse], ["f1h", _f1_hover],
		["f5", _f5_tuck_dive], ["f6", _f6_thermals], ["f8", _f8_energy], ["wi", _wi_channels],
	]
	for j in jobs:
		if _only.is_empty() or _only.has(j[0]):
			var t0 := Time.get_ticks_msec()
			(j[1] as Callable).call()
			print("[flight] plot %s (%d ms)" % [j[0], Time.get_ticks_msec() - t0])
	if _only.is_empty() or _only.has("f11"):
		await _f11_comfort()
	if _only.is_empty() or _only.has("heave"):
		await _pb08_heave()
	if _only.is_empty() or _only.has("b1"):
		await _b1_tracks()
	if _only.is_empty() or _only.has("r3"):
		_r3_perch_wind()
	if _only.is_empty() or _only.has("r4"):
		await _r4_view_turns()
		await _r4_strokes()
		await _r4_perch_rest()
	if _only.is_empty() or _only.has("r5"):
		await _r5_ground()
		await _r5_resume_hitch()
	if _only.is_empty() or _only.has("r6"):
		await _r6_slopes()
		await _r6_takeoff()
	_overview()
	print("[flight] plots done: %d files" % _written.size())
	get_tree().quit()


## Species colour slot: fixed per species across every figure.
static func slot(sp: StringName) -> int:
	return maxi(0, FS.SP.find(sp))


func _save(pl: FlightPlot, name: String) -> void:
	var path := _out.path_join(name + ".png")
	pl.save(path)
	_written.append(path)


## Small-multiple rectangles: rows x cols over the figure body.
static func cells(rows: int, cols: int, top := 130, left := 90, w := 1600, h := 900, gap_x := 90, gap_y := 90) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var cw := (w - left - 40 - (cols - 1) * gap_x) / cols
	var ch := (h - top - 60 - (rows - 1) * gap_y) / rows
	for r in rows:
		for c in cols:
			out.append(Rect2i(left + c * (cw + gap_x), top + r * (ch + gap_y), cw, ch))
	return out


static func arr(n: int) -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(n)
	return a


# --- F2: balloon (pitch +0.5) and sag (pitch -0.5) -------------------------------
func _f2_balloon_sag() -> void:
	var pl := FlightPlot.new(1600, 900, "F2 pitch: +0.5 balloons up then settles slower, -0.5 sags then settles faster")
	var cs := cells(3, 3, 140, 90, 1600, 900, 90, 62)
	var notes := PackedStringArray()
	for k in 3:
		var sp: StringName = FS.S3[k]
		var m0 := FS.model(sp)
		var p := m0.params
		var v0: float = m0.trim_solution(0.0)["v"]
		var dur := 3.0 * p.t_ph + 5.0
		var pa := pl.panel(cs[k], "%s: balloon, pitch +0.5" % sp, "", "spans")
		var ps := pl.panel(cs[k + 3], "%s: sag, pitch -0.5" % sp, "", "path angle, deg")
		var pv := pl.panel(cs[k + 6], "%s: airspeed" % sp, "t (s)", "V / V0")
		for pitch in [0.5, -0.5]:
			var m := FS.model(sp)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var rec := FS.Rec.new()
			FS.run(m, int(dur * 72), FS.glide(pitch), null, rec)
			var s := 0 if pitch > 0.0 else 1
			# Altitude against the NEW trim's steady glide path from the start:
			# the curve rises (or drops) and then goes flat once the phugoid
			# has settled - the net height the transition traded.
			var ref := arr(rec.size())
			var tn := m0.trim_solution(pitch)
			var sink_n := -float(tn["v"]) * sin(float(tn["gamma"]))
			for i in rec.size():
				ref[i] = (rec.y[i] - (500.0 - sink_n * rec.t[i])) / p.span
			if pitch > 0.0:
				pa.line(rec.t, ref, s)
			else:
				ps.line(rec.t, rec.gam, s, "flight path")
				ps.hline(rad_to_deg(float(tn["gamma"])), FlightPlot.INK2, "new trim")
			pv.line(rec.t, FS.scale(rec.v, 1.0 / v0), s, "pitch %+.1f" % pitch)
			if pitch > 0.0:
				var ipk := FS.argmax(rec.y)
				notes.append("%s rise %.1f spans at %.2f s" % [sp, (rec.y[ipk] - 500.0) / p.span, rec.t[ipk]])
				rec.csv(_out.path_join("f2_balloon_%s.csv" % sp))
		pv.hline(float(m0.trim_solution(0.5)["v"]) / v0, FlightPlot.MUTED, "trim +0.5")
		pv.hline(float(m0.trim_solution(-0.5)["v"]) / v0, FlightPlot.INK2, "trim -0.5")
		pa.hline(0.0, FlightPlot.AXIS)
		ps.legend_pos = 0
		pv.set_y(0.35, 1.8)
	pl.note("; ".join(notes) + " (absolute rise above the start). Top row: height against the new trim's steady glide path - flat once the phugoid has settled (<= 0.8 T_ph, FM-03). Middle: the nose drops and the path steepens to the faster trim (FM-04).")
	_save(pl, "f2_balloon_sag")


# --- F2: the pitch map (trimmed alpha and speed vs the wrist pitch command) ----
func _f2_alpha_map() -> void:
	var pl := FlightPlot.new(1600, 900, "F2 pitch map: trimmed angle of attack and airspeed vs pitch command")
	var cs := cells(1, 2)
	var pa := pl.panel(cs[0], "Trimmed angle of attack", "pitch command", "deg")
	var pv := pl.panel(cs[1], "Trimmed airspeed / V_c", "pitch command", "V / V_c")
	for sp in FS.S3:
		var m := FS.model(sp)
		var xs := PackedFloat64Array()
		var al := PackedFloat64Array()
		var vs := PackedFloat64Array()
		for i in 41:
			var pc := -1.0 + i * 0.05
			var tr := m.trim_solution(pc)
			if not tr.has("v") or not is_finite(float(tr["v"])):
				continue
			xs.append(pc)
			al.append(rad_to_deg(float(tr.get("alpha", NAN))))
			vs.append(float(tr["v"]) / m.params.v_c)
		pa.line(xs, al, slot(sp), String(sp))
		pv.line(xs, vs, slot(sp), String(sp))
		if sp == &"pigeon":
			pa.hline(rad_to_deg(m.params.alpha_s), FlightPlot.INK2, "stall angle alpha_s")
	pa.legend_pos = 1
	pl.note("Nose-up is linear in alpha (the balloon lever); nose-down is linear in lift (full down = zero lift); stall protection caps +1 below alpha_s. The alpha map is the same for every size (the three curves coincide); speeds scale with each bird's V_c.")
	_save(pl, "f2_alpha_map")


# --- F3: stall and recovery (FM-05 a) --------------------------------------------
func _f3_stall() -> void:
	var pl := FlightPlot.new(1600, 1100, "F3 stall: full nose-up held 2 s from a slow trim, then released")
	var cs := cells(4, 3, 130, 90, 1600, 1100, 90, 55)
	var notes := PackedStringArray()
	for k in 3:
		var sp: StringName = FS.S3[k]
		var m := FS.model(sp)
		var p := m.params
		m.trim(Vector3(0, 500, 0), 0.0, 0.8)
		var v_t: float = m.trim_solution(0.0)["v"]
		var rec := FS.Rec.new()
		FS.run(m, 2 * 72, FS.glide(1.0), null, rec)
		FS.run(m, int(3.0 * p.t_ph * 72), FS.glide(0.0), null, rec)
		var pa := pl.panel(cs[k], "%s: angle of attack" % sp, "", "deg")
		pa.line(rec.t, rec.alpha, slot(sp), "alpha")
		pa.hline(rad_to_deg(p.alpha_s), FlightPlot.INK2, "alpha_s")
		# Lift coefficient: what the wing gives vs what attached flow would
		# give at the same angle (the gap is the stall's lift collapse).
		var cl_n := PackedFloat64Array()
		var cl_att := PackedFloat64Array()
		for i in rec.size():
			cl_n.append(rec.cl[i] / p.cl_max)
			cl_att.append(m.lift_coefficient(deg_to_rad(rec.alpha[i]), 0.0) / p.cl_max)
		var pc := pl.panel(cs[k + 3], "%s: CL / CL_max" % sp, "", "")
		pc.line(rec.t, cl_att, 0, "attached flow, same alpha", 2, FlightPlot.MUTED)
		pc.line(rec.t, cl_n, slot(sp), "wing (separation blend)")
		pc.hline(1.0, FlightPlot.AXIS)
		var pv := pl.panel(cs[k + 6], "%s: V / V_trim" % sp, "", "")
		pv.line(rec.t, FS.scale(rec.v, 1.0 / v_t), slot(sp))
		pv.hline(1.0, FlightPlot.MUTED)
		var ph := pl.panel(cs[k + 9], "%s: altitude change" % sp, "t (s)", "m")
		ph.line(rec.t, FS.sub(rec.y, 500.0), slot(sp))
		for e in rec.events:
			for pn in [pa, pc, pv, ph]:
				(pn as FlightPlot.PlotPanel).vline(float(e[0]), FlightPlot.INK if e[1] == "stall" else FlightPlot.MUTED, str(e[1]) if pn == pa else "")
		for pn in [pa, pc, pv, ph]:
			(pn as FlightPlot.PlotPanel).vline(2.0, FlightPlot.AXIS, "release" if pn == pv else "")
		var i_st := rec.size() - 1
		for e in rec.events:
			if e[1] == "stall":
				i_st = rec.at(float(e[0]))
				break
		var peak := FS.maxv(cl_n, 0, i_st + 1)
		var low := INF
		for i in range(i_st, rec.at(2.0)):
			if rec.stalled[i] == 1:
				low = minf(low, cl_n[i])
		notes.append("%s: %d stall(s), CL %.2f -> %.2f CL_max" % [sp, rec.count("stall"), peak, low])
	pl.note("; ".join(notes) + ". Black = stall, grey = unstall. Once the flow separates the wing gives ~0.55 CL_max where attached flow would give ~1 (FM-05, FM-05c). Recovery <= 0.8 T_ph, height lost <= 0.6 V_t^2/g.")
	_save(pl, "f3_stall")


# --- F3: the lift curve (FM-05c) ----------------------------------------------------
func _f3_lift_curve() -> void:
	var pl := FlightPlot.new(1600, 700, "F3 lift curve: attached vs separated flow (FlightModel.lift_coefficient)")
	var cs := cells(1, 3, 120, 90, 1600, 700, 90, 60)
	for k in 3:
		var sp: StringName = FS.S3[k]
		var m := FS.model(sp)
		var p := m.params
		var xs := PackedFloat64Array()
		var att := PackedFloat64Array()
		var sep := PackedFloat64Array()
		var half := PackedFloat64Array()
		for i in 181:
			var a := deg_to_rad(-5.0 + 45.0 * i / 180.0)
			xs.append(rad_to_deg(a))
			att.append(m.lift_coefficient(a, 0.0) / p.cl_max)
			sep.append(m.lift_coefficient(a, 1.0) / p.cl_max)
			half.append(m.lift_coefficient(a, 0.5) / p.cl_max)
		var pn := pl.panel(cs[k], "%s (alpha_s %.1f deg)" % [sp, rad_to_deg(p.alpha_s)], "alpha (deg)", "CL / CL_max")
		pn.legend_pos = 1
		pn.line(xs, att, slot(sp), "attached (separation 0)")
		pn.line(xs, half, 0, "separation 0.5", 2, FlightPlot.MUTED)
		pn.line(xs, sep, 0, "stalled (separation 1)", 3, FlightPlot.INK)
		pn.vline(rad_to_deg(p.alpha_s), FlightPlot.INK2, "alpha_s")
		pn.hline(0.65, FlightPlot.AXIS, "FM-05c bound 0.65")
	pl.note("Attached flow reaches CL_max at alpha_s and separates geometrically within 6 deg past it; the stalled blend drops the whole curve to the 0.6 CL_max plateau (flat-plate lift at high alpha). FM-05c asserts <= 0.65 CL_max for alpha_s .. alpha_s + 10 deg at every size.")
	_save(pl, "f3_lift_curve")


# --- F4: coordinated turn ----------------------------------------------------------
func _f4_turn() -> void:
	var pl := FlightPlot.new(1600, 900, "F4 coordinated turn: heading rate vs g tan(bank) / V (roll input 0.6 and 1.0)")
	var cs := cells(2, 3)
	for k in 3:
		var sp: StringName = FS.S3[k]
		var pr := pl.panel(cs[k], "%s: heading rate" % sp, "t (s)", "deg/s")
		var pb := pl.panel(cs[k + 3], "%s: bank and sideslip" % sp, "t (s)", "deg")
		for j in 2:
			var roll: float = [0.6, 1.0][j]
			var m := FS.model(sp)
			m.trim(Vector3(0, 500, 0), 0.0, 0.0)
			var rec := FS.Rec.new()
			FS.run(m, 6 * 72, FS.glide(0.0, roll), null, rec)
			var rate := arr(rec.size())
			var ideal := arr(rec.size())
			for i in rec.size():
				rate[i] = -rad_to_deg(rec.yaw_rate[i])
				ideal[i] = rad_to_deg(FS.G * tan(deg_to_rad(rec.phi[i])) / rec.v[i])
			pr.line(rec.t, rate, 2 * j, "measured, roll %.1f" % roll)
			pr.line(rec.t, ideal, 2 * j + 1, "g tan(bank)/V, roll %.1f" % roll, 1)
			pb.line(rec.t, rec.phi, 2 * j, "bank, roll %.1f" % roll)
			pb.line(rec.t, rec.dpsi, 2 * j + 1, "sideslip, roll %.1f" % roll)
		pr.legend_pos = 2
		pb.legend_pos = 2
	pl.note("Measured and ideal overlap (FM-08: mean ratio within 3%/5%, every sample within 20%, sideslip < 0.1 deg).")
	_save(pl, "f4_turn")


# --- F7: turn circles, all sizes ---------------------------------------------------
func _f7_turn_circles() -> void:
	var pl := FlightPlot.new(1600, 900, "F7 turn circles at full roll input (top view): bigger birds turn wider")
	var pn := pl.panel(Rect2i(90, 130, 1440, 700), "Top view: entry, then one full circle (gliding, no flapping)", "x (m)", "-z (m)")
	pn.equal_aspect = true
	var table := PackedStringArray()
	for sp in FS.SP:
		var m := FS.model(sp)
		m.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		# One full circle after the entry: stop when the heading has turned 360 deg.
		var turned := {"a": 0.0, "prev": m.heading()}
		var cmd := FS.glide(0.0, 1.0)
		var ws := WingState.new()
		var env := FlightEnv.new()
		for i in 60 * 72:
			cmd.call(i, ws)
			m.step(ws, env, DT)
			rec.add(m, ws, DT)
			var h := m.heading()
			turned["a"] += absf(wrapf(h - float(turned["prev"]), -PI, PI))
			turned["prev"] = h
			if float(turned["a"]) >= TAU + 0.05:
				break
		pn.line(rec.x, FS.scale(rec.z, -1.0), slot(sp), String(sp))
		var r := m.airspeed() * m.airspeed() / (FS.G * tan(absf(m.phi)))
		table.append("%s %.1f m" % [sp, r])
	pn.legend_pos = 1
	pl.note("Radius V^2/(g tan bank) in the steady circle: " + ", ".join(table) + ".")
	_save(pl, "f7_turn_circles")


# --- F7: glide polars ---------------------------------------------------------------
func _f7_glide_polars() -> void:
	var pl := FlightPlot.new(1600, 900, "F7 glide polars: steady glide vertical speed vs airspeed, every size")
	var pn := pl.panel(Rect2i(90, 130, 1440, 690), "Trimmed glides across the pitch range (dots: neutral pitch = cruise)", "airspeed (m/s)", "vertical speed (m/s)")
	for sp in FS.SP:
		var m := FS.model(sp)
		var vs := PackedFloat64Array()
		var sk := PackedFloat64Array()
		for i in 32:
			var pc := -0.6 + i * 0.05
			var tr := m.trim_solution(pc)
			var v := float(tr.get("v", NAN))
			var g := float(tr.get("gamma", NAN))
			if not is_finite(v) or not is_finite(g):
				continue
			vs.append(v)
			sk.append(v * sin(g))
		pn.line(vs, sk, slot(sp), String(sp))
		var t0 := m.trim_solution(0.0)
		pn.points(PackedFloat64Array([float(t0["v"])]), PackedFloat64Array([float(t0["v"]) * sin(float(t0["gamma"]))]), slot(sp), "", 5)
	pn.legend_pos = 3
	pl.note("Dots mark cruise (neutral pitch), a little faster than best glide. The polar shifts right and down with size: bigger birds glide faster and sink faster (F7).")
	_save(pl, "f7_glide_polars")


# --- F1: flap impulse arrows (FM-11) -------------------------------------------------
func _f1_flap_impulse() -> void:
	var pl := FlightPlot.new(1600, 900, "F1 flap impulse in the bird's (forward, up) plane follows the wing-normal tilt")
	var cs := cells(1, 3, 150, 90, 1600, 900, 90, 90)
	var tilts := [0.0, 17.0, 35.0, -20.0]
	for k in 3:
		var sp: StringName = FS.S3[k]
		var pn := pl.panel(cs[k], "%s (bank 0 and 30 deg)" % sp, "forward: impulse / (m g), s", "up, s")
		pn.equal_aspect = true
		for bank_deg in [0.0, 30.0]:
			for j in tilts.size():
				var tilt: float = tilts[j]
				var m := FS.model(sp)
				m.trim(Vector3(0, 500, 0), 0.0, 0.0)
				var roll := deg_to_rad(bank_deg) / m.params.phi_max
				if bank_deg > 0.0:
					FS.run(m, 3 * 72, FS.glide(0.0, roll))
				var acc := Vector3.ZERO
				var cmd := FS.flap(m, 0.0, roll, 1.0, tilt)
				var ws := WingState.new()
				var env := FlightEnv.new()
				for i in 72:
					cmd.call(i, ws)
					var i0 := m.flap_impulse
					m.step(ws, env, DT)
					var d := m.flap_impulse - i0
					var fr := FS.frame(m)
					acc += Vector3(d.dot(fr[0]), d.dot(fr[1]), d.dot(fr[2]))
				var w := m.params.mass * FS.G
				var tip := Vector2(acc.x, acc.y) / w
				var lbl := "tilt %+d deg" % int(tilt) if bank_deg == 0.0 else ""
				if bank_deg == 0.0:
					pn.arrow(Vector2.ZERO, tip, FlightPlot.series_color(j), lbl)
				else:
					pn.points(PackedFloat64Array([tip.x]), PackedFloat64Array([tip.y]), j, "", 5)
		pn.hline(0.0, FlightPlot.AXIS)
		pn.legend_pos = 2
	pl.note("One second of reference strokes. Arrows: level flight; dots: the same stroke in a 30 deg banked turn, measured in the banked frame - the direction matches within 1 deg (FM-11). A backward tilt brakes, so the power cap (force x speed) does not shorten it.")
	_save(pl, "f1_flap_impulse")


# --- F1: hover capability vs mass (FM-14) -------------------------------------------
func _f1_hover() -> void:
	var pl := FlightPlot.new(1600, 900, "Hover: flap force at zero airspeed vs body weight, and free hovering")
	var cs := cells(1, 2, 150)
	var pf := pl.panel(cs[0], "Held at zero airspeed: mean vertical flap force / weight", "log10 mass (g)", "")
	var pz := pl.panel(cs[1], "Free from rest, reference strokes: altitude", "t (s)", "m")
	var xs := PackedFloat64Array()
	var ref := PackedFloat64Array()
	var fr := PackedFloat64Array()
	for i in 17:
		var mass := 0.02 * pow(5.0 / 0.02, i / 16.0)
		for kind in ["ref", "frantic"]:
			var m := FlightModel.new(mass, FS.tuning())
			m.reset(Vector3(0, 500, 0), Vector3.ZERO, 0.0)
			var tab := FlapDetector.reference_table(m.params.x) if kind == "ref" \
				else FlapDetector.stroke_table(m.params.x, deg_to_rad(30.0), 2.2, 0.5, false, 72.0)
			var hz := 1.0 if kind == "ref" else 2.2
			var cmd := FS.table_flap(tab, hz, 0.5, 0.0)
			var ws := WingState.new()
			var env := FlightEnv.new()
			var sum := 0.0
			var n := 0
			for k in 7 * 72:
				cmd.call(k, ws)
				# A test stand: the bird is held still, so this is the force
				# the strokes make with no airspeed (endurance cap included).
				m.position = Vector3(0, 500, 0)
				m.velocity = Vector3.ZERO
				m.step(ws, env, DT)
				if k >= 2 * 72:
					sum += m.f_flap.y
					n += 1
			var ratio := sum / n / (mass * FS.G)
			if kind == "ref":
				ref.append(ratio)
			else:
				fr.append(ratio)
		xs.append(log(mass * 1000.0) / log(10.0))
	pf.line(xs, ref, 0, "reference stroke (1 Hz)")
	pf.line(xs, fr, 1, "frantic (2.2 Hz, 30 deg; endurance-capped)")
	pf.hline(1.0, FlightPlot.INK2, "weight")
	for sp in FS.SP:
		var lx := log(FlightParams.species_mass(sp) * 1000.0) / log(10.0)
		pf.vline(lx, FlightPlot.GRID)
		pf.label_at(Vector2(lx + 0.02, 0.63), String(sp))
	pf.legend_pos = 0
	for sp in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		var m := FS.model(sp)
		m.reset(Vector3(0, 500, 0), Vector3.ZERO, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 7 * 72, FS.table_flap(FlapDetector.reference_table(m.params.x), 1.0, 0.5, 0.0), null, rec)
		pz.line(rec.t, FS.sub(rec.y, 500.0), slot(sp), String(sp))
	pz.hline(0.0, FlightPlot.AXIS)
	pz.legend_pos = 3
	pl.note("Sparrow-size birds lift more than their weight and hover-climb; starlings barely; from pigeon size up no stroke rate holds height, and frantic flapping buys <= 1.2x the reference force (FM-14).")
	_save(pl, "f1_hover")


# --- F5: tuck dive and pull-out (FM-15 / FM-16) ---------------------------------------
func _f5_tuck_dive() -> void:
	var pl := FlightPlot.new(1600, 900, "F5 tuck dive to V_max (governor), then spread and pull out")
	var cs := cells(2, 2)
	var pv := pl.panel(cs[0], "Airspeed / V_max", "t (s)", "")
	var pg := pl.panel(cs[1], "Flight path angle", "t (s)", "deg")
	var pn := pl.panel(cs[2], "Load factor", "t (s)", "g")
	var ph := pl.panel(cs[3], "Height lost / span", "t (s)", "spans")
	for sp in FS.S3:
		var m := FS.model(sp)
		var p := m.params
		m.trim(Vector3(0, 2000, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 12 * 72, FS.glide(-1.0, 0.0, 0.0), null, rec)
		# Spread and pull (+0.5) until the path is level again, then relax
		# to neutral like a pilot would (holding the pull zooms into a climb).
		var st := {"level": false}
		FS.run(m, int(3.0 * p.t_ph * 72), func(_i: int, ws: WingState) -> void:
			if m.gam >= 0.0:
				st["level"] = true
			ws.set_commands(0.0 if st["level"] else 0.5, 0.0, 1.0, 0.0, 0.0), null, rec)
		pv.line(rec.t, FS.scale(rec.v, 1.0 / p.v_max), slot(sp), String(sp))
		pg.line(rec.t, rec.gam, slot(sp), String(sp))
		pn.line(rec.t, rec.g_load, slot(sp), String(sp))
		ph.line(rec.t, FS.scale(FS.sub(rec.y, 2000.0), 1.0 / p.span), slot(sp), String(sp))
	for pnl in [pv, pg, pn, ph]:
		(pnl as FlightPlot.PlotPanel).vline(12.0, FlightPlot.AXIS, "spread" if pnl == pv else "")
	pv.hline(1.0, FlightPlot.INK2, "V_max")
	pv.legend_pos = 2
	pl.note("Tuck: 0.95 V_max within 8 s, never above 1.03 V_max (FM-15). Spread at 12 s and pull (+0.5) to level, then neutral: peak load <= n_max + 0.2, height loss <= 1.25x the ideal circle (FM-16); the excess speed then bleeds off in a damped phugoid.")
	_save(pl, "f5_tuck_dive")


# --- F6: updrafts and thermal spirals (FM-19 / FM-20) -----------------------------------
func _f6_thermals() -> void:
	var pl := FlightPlot.new(1600, 900, "F6 soaring without flapping: a 3 m/s updraft and a 4 m/s bell thermal")
	var cs := cells(1, 3, 150)
	var pu := pl.panel(cs[0], "3 m/s updraft, neutral", "t (s)", "m")
	var pt := pl.panel(cs[1], "Bell thermal, 30 deg bank", "t (s)", "m")
	var pz := pl.panel(cs[2], "Spirals, top view", "x (m)", "z")
	pz.equal_aspect = true
	for sp in FS.S3:
		var m := FS.model(sp)
		m.trim(Vector3(0, 500, 0), 0.0, 0.0)
		var rec := FS.Rec.new()
		FS.run(m, 30 * 72, FS.glide(0.0), FlightEnv.uniform(Vector3(0, 3, 0)), rec)
		pu.line(rec.t, FS.sub(rec.y, 500.0), slot(sp), String(sp))
	for sp in FS.SP:
		var m := FS.model(sp)
		var env := FlightEnv.new()
		env.wind_fn = func(pos: Vector3) -> Vector3:
			var r2 := (pos.x * pos.x + pos.z * pos.z) / (44.0 * 44.0)
			return Vector3.ZERO if r2 >= 1.0 else Vector3(0.0, 4.0 * pow(1.0 - r2, 2.0), 0.0)
		var tr := m.trim_solution(0.6)
		var v: float = tr["v"]
		var rad := v * v / (FS.G * tan(deg_to_rad(30.0)))
		m.trim(Vector3(-rad, 300, 0), 0.0, 0.6)
		var rec := FS.Rec.new()
		FS.run(m, 60 * 72, FS.glide(0.6, deg_to_rad(30.0) / m.params.phi_max), env, rec)
		pt.line(rec.t, FS.sub(rec.y, 300.0), slot(sp), String(sp))
		if FS.S3.has(sp):
			pz.line(rec.x, rec.z, slot(sp), String(sp))
	pz.circle(Vector2.ZERO, 44.0, FlightPlot.MUTED, "thermal edge")
	pu.legend_pos = 1
	pt.legend_pos = 1
	pl.note("Altitude gained. Left: neutral glide in a uniform 3 m/s updraft (FM-19). Middle: circling a bell thermal (4 m/s core, radius 44 m) at 30 deg bank - every size nets > 0.6 m/s (FM-20); bigger birds circle wider and climb less (W1 flag). No flapping anywhere on this page.")
	_save(pl, "f6_thermals")


# --- F8: energy with drag and thrust off (FM-22) ------------------------------------
func _f8_energy() -> void:
	var pl := FlightPlot.new(1600, 900, "F8 integrator: energy drift with drag and thrust off")
	var cs := cells(1, 2, 150)
	var pe := pl.panel(cs[0], "Energy drift / kinetic energy height", "t (s)", "%")
	var pa := pl.panel(cs[1], "Bank (the manoeuvres)", "t (s)", "deg")
	var rng := RandomNumberGenerator.new()
	rng.seed = 22
	for sp in FS.S3:
		var m := FS.model(sp)
		m.drag_enabled = false
		m.trim(Vector3(0, 800, 0), 0.0, 0.0)
		var e0 := FS.energy_height(m)
		var ke0 := m.velocity.length_squared() / (2.0 * FS.G)
		var ts := PackedFloat64Array()
		var es := PackedFloat64Array()
		var bs := PackedFloat64Array()
		var cmd := [0.0, 0.0]
		var ws := WingState.new()
		var env := FlightEnv.new()
		for i in 20 * 72:
			if i % 36 == 0:
				cmd = [rng.randf_range(-0.5, 0.8), rng.randf_range(-1.0, 1.0)]
			ws.set_commands(cmd[0], cmd[1], 1.0, 0.0, 0.0)
			m.step(ws, env, DT)
			ts.append((i + 1) * DT)
			es.append((FS.energy_height(m) - e0) / ke0 * 100.0)
			bs.append(rad_to_deg(m.phi))
		pe.line(ts, es, slot(sp), String(sp))
		pa.line(ts, bs, slot(sp), String(sp))
	pe.hline(2.0, FlightPlot.INK2, "F8 bound +-2%")
	pe.hline(-2.0, FlightPlot.INK2)
	pe.legend_pos = 3
	pl.note("Random pitch/roll commands every 0.5 s for 20 s. Heun (RK2) with symmetric attitude splitting at 144 Hz keeps the drift more than 20x inside the +-2% bound (FM-22).")
	_save(pl, "f8_energy")


# --- WingInput channels per gesture --------------------------------------------------
func _wi_channels() -> void:
	var spans := [[0.0, 2.0, "airplane"], [2.0, 4.0, "wrists up"], [4.0, 6.0, "wrists down"], [6.0, 8.0, "roll right"],
		[8.0, 11.0, "strokes"], [11.0, 13.0, "tuck"], [13.0, 15.0, "sweep back"], [15.0, 18.0, "torso turn"], [18.0, 21.0, "look around"]]
	var drv := func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t >= 2.0 and t < 4.0:
			b.arms[0].twist = 25.0 * DEG
			b.arms[1].twist = 25.0 * DEG
		elif t >= 4.0 and t < 6.0:
			b.arms[0].twist = -20.0 * DEG
			b.arms[1].twist = -20.0 * DEG
		elif t >= 6.0 and t < 8.0:
			b.arms[0].twist = 20.0 * DEG
			b.arms[1].twist = -20.0 * DEG
			b.arms[0].dihedral = 15.0 * DEG
			b.arms[1].dihedral = -15.0 * DEG
		elif t >= 8.0 and t < 11.0:
			ScriptedPoseSource.flap(b, t - 8.0, 45.0, 1.0)
		elif t >= 11.0 and t < 13.0:
			b.arms[0].elbow = 150.0 * DEG
			b.arms[1].elbow = 150.0 * DEG
		elif t >= 13.0 and t < 15.0:
			b.arms[0].sweep = -40.0 * DEG
			b.arms[1].sweep = -40.0 * DEG
		elif t >= 15.0 and t < 18.0:
			b.torso_yaw = -60.0 * DEG * clampf((t - 15.0) / 1.0, 0.0, 1.0)
		elif t >= 18.0:
			b.torso_yaw = -60.0 * DEG
			b.head_yaw = 1.2 * sin(2.0 * (t - 18.0))
			b.head_pitch = 0.5 * sin(3.0 * (t - 18.0))
		b.humanize(DT)
	var r := WR.new(drv)
	var n := int(21.0 / DT)
	var ts := arr(n)
	var ch := {}
	for k in ["pitch", "roll", "flap_l", "flap_r", "ext_l", "ext_r", "body_yaw", "twist_l", "twist_r"]:
		ch[k] = arr(n)
	for i in n:
		var w := r.step()
		ts[i] = (i + 1) * DT
		ch["pitch"][i] = w.pitch
		ch["roll"][i] = w.roll
		ch["flap_l"][i] = w.flap_l
		ch["flap_r"][i] = w.flap_r
		ch["ext_l"][i] = w.ext_l
		ch["ext_r"][i] = w.ext_r
		ch["body_yaw"][i] = rad_to_deg(w.body_yaw)
		ch["twist_l"][i] = rad_to_deg(w.twist_l)
		ch["twist_r"][i] = rad_to_deg(w.twist_r)
	var pl := FlightPlot.new(1600, 900, "WingInput channels per gesture (poses -> WingInput, default calibration)")
	var cs := cells(4, 1, 130, 90, 1600, 900, 0, 50)
	var p0 := pl.panel(cs[0], "Commands", "", "")
	p0.line(ts, ch["pitch"], 0, "pitch")
	p0.line(ts, ch["roll"], 1, "roll")
	var p1 := pl.panel(cs[1], "Credited flap effort", "", "")
	p1.line(ts, ch["flap_l"], 0, "left")
	p1.line(ts, ch["flap_r"], 1, "right")
	var p2 := pl.panel(cs[2], "Extension (1 spread, 0 tucked)", "", "")
	p2.line(ts, ch["ext_l"], 0, "left")
	p2.line(ts, ch["ext_r"], 1, "right")
	var p3 := pl.panel(cs[3], "Wrist twist and torso yaw", "t (s)", "deg")
	p3.line(ts, ch["twist_l"], 0, "twist left")
	p3.line(ts, ch["twist_r"], 1, "twist right")
	p3.line(ts, ch["body_yaw"], 2, "torso yaw")
	for pn in [p0, p1, p2, p3]:
		for s in spans:
			(pn as FlightPlot.PlotPanel).vline(float(s[0]), FlightPlot.GRID)
	for s in spans:
		p0.label_at(Vector2(float(s[0]) + 0.1, 1.05), str(s[2]), FlightPlot.INK)
	p0.set_y(-1.1, 1.3)
	p1.set_y(-0.05, 1.3)
	p2.set_y(-0.05, 1.1)
	pl.note("Looking around (18-21 s) and turning the torso change no command; a torso turn only moves the body frame (body steer).")
	_save(pl, "wi_channels")


# --- F11: comfort across a composite flight (the rig never pitches or rolls) -----------
func _f11_comfort() -> void:
	var fx := FX.new(self)
	await fx.setup(&"sparrow")
	var f := fx
	f.player.start_flying(Vector3(0, 120, 0), 0.0, 0.0)
	var cal := f.player.wing_input.calibration
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t < 3.0:
			pass
		elif t < 7.0:
			ScriptedPoseSource.flap(b, t, 40.0, 1.2)
			b.arms[0].twist = -10.0 * DEG
			b.arms[1].twist = -10.0 * DEG
		elif t < 10.0:
			b.synth(0.2, 1.0, 1.0, cal)
		elif t < 13.0:
			b.synth(0.0, -0.8, 1.0, cal, 1.0, 1.0, 0.5)
		elif t < 16.0:
			b.synth(-1.0, 0.0, 0.0, cal)
		elif t < 19.0:
			b.synth(0.9, 0.0, 1.0, cal)
		elif t < 23.0:
			b.torso_yaw = -PI * 0.5 * clampf((t - 19.0) / 2.0, 0.0, 1.0)
		else:
			b.torso_yaw = -PI * 0.5
			ScriptedPoseSource.flap(b, t, 45.0, 1.0, -1)
		b.humanize(DT)
	var rec := {"t": PackedFloat64Array(), "bank": PackedFloat64Array(), "cam_roll": PackedFloat64Array(), "cam_pitch": PackedFloat64Array(),
		"rate": PackedFloat64Array(), "acc": PackedFloat64Array(), "pitch": PackedFloat64Array()}
	var prev := {"rate": 0.0}
	f.on_tick = func(tick: int, fix: Variant) -> void:
		var p: PlayerBird = fix.player
		var b := p.origin.global_basis
		rec["t"].append(tick * DT)
		rec["bank"].append(rad_to_deg(p.model.phi))
		rec["pitch"].append(rad_to_deg(p.model.theta))
		# Rig tilt: how far the origin's right (x) and back (z) axes leave the
		# horizontal = its roll and pitch. Both must stay exactly 0.
		rec["cam_roll"].append(rad_to_deg(asin(clampf(b.x.normalized().y, -1.0, 1.0))))
		rec["cam_pitch"].append(rad_to_deg(asin(clampf(b.z.normalized().y, -1.0, 1.0))))
		rec["rate"].append(rad_to_deg(p.rig_yaw_rate))
		rec["acc"].append(rad_to_deg((p.rig_yaw_rate - float(prev["rate"])) / DT))
		prev["rate"] = p.rig_yaw_rate
	f.run(26.0)
	var pl := FlightPlot.new(1600, 900, "F11 comfort (sparrow): the bird banks and pitches, the rig only yaws")
	var cs := cells(3, 1, 130, 90, 1600, 900, 0, 60)
	var pa := pl.panel(cs[0], "Bird attitude vs rig tilt", "", "deg")
	pa.line(rec["t"], rec["bank"], 0, "bird bank")
	pa.line(rec["t"], rec["pitch"], 1, "bird pitch")
	pa.line(rec["t"], rec["cam_roll"], 2, "rig roll", 3)
	pa.line(rec["t"], rec["cam_pitch"], 3, "rig pitch", 3)
	pa.legend_pos = 1
	var pr := pl.panel(cs[1], "Rig yaw rate", "", "deg/s")
	pr.line(rec["t"], rec["rate"], 0, "rig yaw rate")
	pr.hline(240.0, FlightPlot.INK2, "cap 240")
	pr.hline(-240.0, FlightPlot.INK2)
	var pc := pl.panel(cs[2], "Rig yaw acceleration", "t (s)", "deg/s^2")
	pc.line(rec["t"], rec["acc"], 0, "rig yaw accel")
	pc.hline(720.0, FlightPlot.INK2, "cap 720")
	pc.hline(-720.0, FlightPlot.INK2)
	pl.note("Glide 0-3 s, flap 3-7, bank right 7-10 and left 10-13, dive 13-16, flare 16-19, torso turn 19-23, one-wing flaps 23-26. Max |rate| %.0f deg/s, max |accel| %.0f deg/s^2." % [
		rad_to_deg(fx.comfort["max_rate"]), rad_to_deg(fx.comfort["max_accel"])])
	_save(pl, "f11_comfort")
	fx.teardown()


# --- Fix round 3: heading steps are paid to the view smoothly ---------------------
## Sparrow, cruise into a wall at 30 / 60 / 90 deg with the arms still (C8b):
## the stun re-seats the heading (a step), the view (rig + torso) follows it
## along one minimum-jerk turn inside 120 deg/s and 240 deg/s^2. Last panel:
## a 2.64 m/s crosswind front ramped over 0.5 s (PB-26): the air path turns
## 16 deg under the bird, the heading weathercocks 0.4 of it, smoothly.
## Round 4 (the lead's view-comfort direction): a stun deflects the velocity
## and turns the bird at most 40 deg; ViewTurn is a time-optimal follower
## that cannot run away (round 3's re-planned quintic, compiled here from the
## preserved round-3 source, beside it); a stun in a room never spins the
## view on the floor (round 3's trace reproduced on the round-3 sources).
func _r4_view_turns() -> void:
	var pl := FlightPlot.new(1600, 900, "Round 4: small forced turns, paid inside 120 deg/s and 240 deg/s^2 (sparrow)")
	var cs := cells(2, 2, 175, 90, 1600, 900, 90, 80)
	var ph := pl.panel(cs[0], "Wall stun at 30 / 60 / 90 deg: heading (thin), view (thick)", "t after contact (s)", "deg")
	var pr := pl.panel(cs[1], "View yaw rate after the stun", "t after contact (s)", "deg/s")
	var k := 0
	var note_s := ""
	for inc: float in [30.0, 60.0, 90.0]:
		var fx := FX.new(self)
		await fx.setup(&"sparrow", func(w: Variant) -> void:
			w.with_ground = false
			w.add_wall(Vector3(0, 100, -20), Vector3(400, 200, 1.0)))
		var p := fx.player
		var prm := p.model.params
		p.start_flying(Vector3(prm.v_c * 0.8 * cos(inc * DEG), 100, -20 + 0.5 + prm.r_body + prm.v_c * 0.8 * sin(inc * DEG)), (90.0 - inc) * DEG, 0.0)
		var rec := {"t": PackedFloat64Array(), "h": PackedFloat64Array(), "v": PackedFloat64Array(), "r": PackedFloat64Array(), "t0": -1.0, "h0": 0.0, "step": 0.0, "hp": p.model.heading()}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pl2: PlayerBird = f.player
			var dh := absf(FlightMath.wrap_angle(pl2.model.heading() - float(rec["hp"])))
			rec["hp"] = pl2.model.heading()
			if float(rec["t0"]) < 0.0 and pl2.mode == PlayerBird.Mode.STUNNED:
				rec["t0"] = tick * DT
				rec["h0"] = pl2.rig_yaw
				rec["step"] = dh
			if float(rec["t0"]) < 0.0:
				return
			var tt := tick * DT - float(rec["t0"])
			rec["t"].append(tt)
			rec["h"].append(rad_to_deg(FlightMath.wrap_angle(pl2.model.heading() - float(rec["h0"]))))
			rec["v"].append(rad_to_deg(FlightMath.wrap_angle(pl2.rig_yaw + pl2.wing_state().body_yaw - float(rec["h0"]))))
			rec["r"].append(rad_to_deg(pl2.rig_yaw_rate))
		fx.run(4.5)
		ph.line(rec["t"], rec["h"], k, "heading %d deg" % int(inc), 1)
		ph.line(rec["t"], rec["v"], k, "view %d deg" % int(inc), 3)
		pr.line(rec["t"], rec["r"], k, "%d deg" % int(inc))
		note_s += "%d deg: stun turn %.0f deg, %d stun(s). " % [int(inc), rad_to_deg(rec["step"]), p.contacts["stun"]]
		fx.teardown()
		k += 1
	ph.hline(40.0, FlightPlot.INK2, "40 deg")
	ph.hline(-40.0, FlightPlot.INK2)
	ph.legend_pos = 3
	pr.hline(120.0, FlightPlot.INK2, "ViewTurn 120")
	pr.hline(-120.0, FlightPlot.INK2)
	pr.hline(240.0, FlightPlot.INK, "cap 240")
	pr.hline(-240.0, FlightPlot.INK)
	pr.legend_pos = 2
	# The verifier's infeasible re-plan: a payout at -101 deg/s and still
	# accelerating is owed 170 deg more the same way.
	var pv := pl.panel(cs[2], "ViewTurn: 170 deg more owed during a payout", "t (s)", "payout rate (deg/s)")
	var old_src := _old_viewturn()
	for which in 2:
		var vt: Variant = ViewTurn.new() if which == 0 else (old_src.new() if old_src != null else null)
		if vt == null:
			continue
		# The verifier's repro: a payout at -101 deg/s, still accelerating at
		# -162 deg/s^2, is owed 170 deg more the same way.
		vt.rate = deg_to_rad(-101.0)
		vt.acc = deg_to_rad(-162.0)
		var ts := PackedFloat64Array([0.0])
		var rs := PackedFloat64Array([-101.0])
		var t := DT
		vt.owe(deg_to_rad(-170.0))
		for i in int(4.0 / DT):
			var x2: float = vt.step(DT)
			ts.append(t)
			rs.append(rad_to_deg(x2 / DT))
			t += DT
		pv.line(ts, rs, 0 if which == 0 else 7, "round 4 (bang-bang)" if which == 0 else "round 3 (re-planned quintic)", 3 if which == 0 else 2)
	pv.hline(-120.0, FlightPlot.INK2, "-120 cap")
	pv.set_y(-1200.0, 150.0)
	pv.legend_pos = 2
	# The verifier's worst room flight: the rig's yaw rate.
	var pw := pl.panel(cs[3], "4 x 2.5 x 4 m room, sparrow at 1.2 V_c (the verifier's worst)", "t (s)", "rig yaw rate (deg/s)")
	var old_csv := _out.path_join("verify/r4_round3_code/room_worst_trace.csv")
	if FileAccess.file_exists(old_csv):
		var f := FileAccess.open(old_csv, FileAccess.READ)
		f.get_line()
		var ts := PackedFloat64Array()
		var rs := PackedFloat64Array()
		while not f.eof_reached():
			var ln := f.get_line()
			if ln.is_empty():
				continue
			var c := ln.split(",")
			ts.append(float(c[0]))
			rs.append(float(c[8]))
		pw.line(ts, rs, 7, "round 3 (floor spin)", 2)
	var fx3 := FX.new(self)
	await fx3.setup(&"sparrow", func(w: Variant) -> void:
		w.with_ground = false
		w.add_wall(Vector3(0, 100, -2.1), Vector3(4.4, 2.9, 0.2))
		w.add_wall(Vector3(0, 100, 2.1), Vector3(4.4, 2.9, 0.2))
		w.add_wall(Vector3(-2.1, 100, 0), Vector3(0.2, 2.9, 4.4))
		w.add_wall(Vector3(2.1, 100, 0), Vector3(0.2, 2.9, 4.4))
		w.add_wall(Vector3(0, 98.65, 0), Vector3(4.4, 0.2, 4.4))
		w.add_wall(Vector3(0, 101.35, 0), Vector3(4.4, 0.2, 4.4)))
	var p3 := fx3.player
	var yaw := 255.0 * DEG
	p3.start_flying(Vector3(0.8, 100.0, 0.4), yaw, 0.0)
	p3.model.reset(Vector3(0.8, 100.0, 0.4), FlightMath.yaw_forward(yaw) * p3.model.params.v_c * 1.2, yaw)
	var rt := {"t": PackedFloat64Array(), "r": PackedFloat64Array()}
	fx3.on_tick = func(tick: int, f: Variant) -> void:
		rt["t"].append(tick * DT)
		rt["r"].append(rad_to_deg((f.player as PlayerBird).rig_yaw_rate))
	fx3.run(20.0)
	pw.line(rt["t"], rt["r"], 0, "round 4", 3)
	pw.set_x(0.0, 20.0)
	pw.legend_pos = 0
	fx3.teardown()
	pl.note("A stun turns the bird at most 40 deg (round 3: 110 deg head-on); the rest is the bird lining up with the wall it slides along. " + note_s + "ViewTurn: bang-bang inside 120 deg/s and 240 deg/s^2, no search (round 3's quintic ran off its plan and spun the view on the floor).")
	_save(pl, "r4_view_turns")


## The round-3 ViewTurn, compiled from the preserved source (class_name
## stripped: it would clash with the current one). Null if unavailable.
func _old_viewturn() -> GDScript:
	var path := _out.path_join("verify/r3_sources/view_turn.gd.txt")
	if not FileAccess.file_exists(path):
		return null
	var src := FileAccess.get_file_as_string(path).replace("class_name ViewTurn\n", "")
	var g := GDScript.new()
	g.source_code = src
	if g.reload() != OK:
		return null
	return g


## Round 4: one-arm strokes turn the bird away every stroke; natural
## asymmetry in a symmetric stroke no longer moves the view.
func _r4_strokes() -> void:
	var pl := FlightPlot.new(1600, 900, "Round 4: one-arm and uneven strokes (through the arm poses)")
	var cs := cells(2, 2, 175, 90, 1600, 900, 90, 80)
	var pt := pl.panel(cs[0], "10 left-arm strokes, top view (m)", "x (+ right)", "forward")
	var ph := pl.panel(cs[1], "10 left-arm strokes: heading change (deg; - = right)", "t (s)", "deg")
	var note_s := ""
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var fx := FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
		fx.run(0.5)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if t < 10.25:
				ScriptedPoseSource.flap(b, t + 0.25, 45.0, 1.0, -1)
		var o := p.model.position
		var h0 := p.model.heading()
		var r := {"x": PackedFloat64Array(), "z": PackedFloat64Array(), "t": PackedFloat64Array(), "h": PackedFloat64Array()}
		var t0 := fx.ticks
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var m: FlightModel = f.player.model
			r["x"].append(m.position.x - o.x)
			r["z"].append(-(m.position.z - o.z))
			r["t"].append((tick - t0) * DT)
			r["h"].append(rad_to_deg(FlightMath.wrap_angle(m.heading() - h0)))
		fx.run(11.0)
		pt.line(r["x"], r["z"], slot(sp), String(sp))
		ph.line(r["t"], r["h"], slot(sp), String(sp))
		note_s += "%s %+.0f deg; " % [sp, r["h"][r["h"].size() - 1]]
		fx.teardown()
	pt.legend_pos = 1
	ph.legend_pos = 3
	var pu := pl.panel(cs[2], "Sparrow, 1 Hz 45 deg strokes, right arm uneven: view yaw", "t (s)", "deg")
	var k := 0
	for c in [[1.0, 0.0, "even"], [0.8, 0.0, "right 20 % smaller"], [1.0, 0.05, "right 50 ms late"], [0.8, 0.05, "both"]]:
		var fx := FX.new(self)
		await fx.setup(&"sparrow")
		var p := fx.player
		p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
		fx.run(0.5)
		var kr: float = c[0]
		var lag: float = c[1]
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 45.0, 1.0, -1)
			ScriptedPoseSource.flap(b, maxf(t - lag, 0.0), 45.0 * kr, 1.0, 1)
		var y0 := p.rig_yaw
		var r := {"t": PackedFloat64Array(), "y": PackedFloat64Array()}
		var t0 := fx.ticks
		fx.on_tick = func(tick: int, f: Variant) -> void:
			r["t"].append((tick - t0) * DT)
			r["y"].append(rad_to_deg(FlightMath.wrap_angle((f.player as PlayerBird).rig_yaw - y0)))
		fx.run(8.0)
		pu.line(r["t"], r["y"], k, c[2], 3 if k == 0 else 2)
		fx.teardown()
		k += 1
	pu.set_y(-8.0, 8.0)
	pu.legend_pos = 3
	# Sideways specific force through one-arm strokes (pigeon).
	var ps := pl.panel(cs[3], "Pigeon, left-arm strokes: sideways specific force", "t (s)", "g (+ right)")
	var fx4 := FX.new(self)
	await fx4.setup(&"pigeon")
	var p4 := fx4.player
	p4.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
	fx4.run(0.5)
	fx4.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t + 0.25, 45.0, 1.0, -1)
	var sf := {"t": PackedFloat64Array(), "g": PackedFloat64Array(), "e": PackedFloat64Array()}
	var t4 := fx4.ticks
	fx4.on_tick = func(tick: int, f: Variant) -> void:
		var m: FlightModel = f.player.model
		var rh := Vector3(cos(m.chi), 0.0, -sin(m.chi))
		var r_b := rh * cos(m.phi) - Vector3.UP * sin(m.phi)
		sf["t"].append((tick - t4) * DT)
		sf["g"].append((m.last_accel() + Vector3(0.0, FlightMath.G, 0.0)).dot(r_b) / FlightMath.G)
		sf["e"].append(rad_to_deg((f.body as HumanPoseModel).arms[0].dihedral) / 100.0)
	fx4.run(6.0)
	ps.line(sf["t"], sf["e"], 2, "left arm elevation (deg / 100)")
	ps.line(sf["t"], sf["g"], 1, "sideways specific force (g)", 3)
	ps.hline(-0.76, FlightPlot.INK2, "round 3 peak -0.76 g")
	ps.set_y(-0.9, 0.6)
	ps.legend_pos = 2
	fx4.teardown()
	pl.note("One-arm strokes turn the bird away from the stroking wing every stroke, banked the way it turns (round 3: the pigeon turned 47 deg toward it): " + note_s + "The wing's force across the body is not applied; the kick acts on the stroke-mean asymmetry beyond a dead zone (round 3: 5-15 deg of wobble per beat).")
	_save(pl, "r4_strokes")


## Round 4: resting on a perch. Arms hanging at the sides, folded or
## fidgeting never leave the branch; a flap does.
func _r4_perch_rest() -> void:
	var pl := FlightPlot.new(1600, 900, "Round 4: resting on a perch is safe; a flap launches (pigeon)")
	var cs := cells(2, 1, 175, 90, 1600, 900, 90, 80)
	var ph := pl.panel(cs[0], "Height (m): arms lowered to the sides at 1 s, 20 s of fidgeting, a flap at 34 s", "t (s)", "m")
	var pa := pl.panel(cs[1], "Left arm elevation (deg) and credited downstroke onsets", "t (s)", "deg")
	var fx := FX.new(self)
	await fx.setup(&"pigeon", func(w: Variant) -> void:
		w.add_perch(Vector3(0, 20, -10), Vector3.FORWARD, 10.0, 0.015, 1.0))
	var p := fx.player
	p.perch_on(fx.world.get_perches()[0])
	var suite: Variant = (load("res://tests/unit/flight/perch_test.gd") as GDScript).new()
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if t < 12.0:
			var q := clampf((t - 1.0) / 0.8, 0.0, 1.0)
			suite._rest_pose(b, q * q * (3.0 - 2.0 * q), -85.0, 20.0)
		elif t < 32.0:
			suite._fidget(b, t - 12.0)
		elif t < 33.5:
			suite._rest_pose(b, 1.0 - clampf((t - 32.0) / 0.5, 0.0, 1.0), -85.0, 20.0)
		else:
			ScriptedPoseSource.flap(b, t - 33.5 + 0.25, 45.0, 1.0)
	var r := {"t": PackedFloat64Array(), "y": PackedFloat64Array(), "e": PackedFloat64Array(), "ot": PackedFloat64Array(), "oy": PackedFloat64Array(), "launch": -1.0}
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pp: PlayerBird = f.player
		var t := tick * DT
		r["t"].append(t)
		r["y"].append(pp.model.position.y)
		r["e"].append(rad_to_deg(pp.wing_input.elevation[0]))
		var d0: FlapDetector = pp.wing_input.detectors[0]
		if d0.onset and d0.onset_strength >= 0.35:
			r["ot"].append(t)
			r["oy"].append(rad_to_deg(pp.wing_input.elevation[0]))
		if float(r["launch"]) < 0.0 and pp.mode == PlayerBird.Mode.FLYING:
			r["launch"] = t
	fx.run(36.0)
	ph.line(r["t"], r["y"], 0, "body height", 3)
	if float(r["launch"]) > 0.0:
		ph.vline(float(r["launch"]), FlightPlot.INK2, "launch %.1f s" % float(r["launch"]))
	pa.line(r["t"], r["e"], 2, "left arm elevation")
	pa.points(r["ot"], r["oy"], 1, "credited downstroke onset", 6)
	pa.hline(-62.0, FlightPlot.INK2, "fold line")
	pa.legend_pos = 3
	fx.teardown()
	suite.free()
	pl.note("Round 3 read arms at the sides as the tuck and dropped the bird (a pigeon fell 20 m). Only a COMPLETED flap launches now: a credited downstroke ending with the wing out. Dropping the arms briskly after raising them is credited too (dots) but ends folded: no launch.")
	_save(pl, "r4_perch_rest")


## Perching success in the world's breeze (P10 / the --full sweep): the
## share of 27 slow glide-ins (left) and of the round-3 verifier's 54
## approaches (right) that perch, per species and wind. Needs the sweep's
## JSON (tests/shots/flight_perchwind_sweep_test.gd).
func _r3_perch_wind() -> void:
	var sets := [["glide", "27 slow glide-ins (asserted)"], ["verifier", "Verifier's 54 approaches (reported)"]]
	var winds := ["still", "head 1.5", "head 2.1", "cross 1.5", "cross 2.1", "tail 1.5", "tail 2.1"]
	var pl := FlightPlot.new(1600, 900, "Round 3: perching in the world's breeze (share of approaches that perch)")
	var cs := cells(1, 2, 130, 90, 1600, 900, 90, 0)
	var any := false
	for si in sets.size():
		var path := _out.path_join("perch_wind_sweep_%s.json" % sets[si][0])
		if not FileAccess.file_exists(path):
			continue
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (d is Dictionary):
			continue
		any = true
		var pn := pl.panel(cs[si], sets[si][1], "wind (0 still, 1-2 head, 3-4 cross, 5-6 tail; 1.5 / 2.1 m/s)", "share")
		# Headroom above the bars for the legend (at 1.05 it hid the tailwind bars).
		pn.set_y(0.0, 1.25)
		pn.set_x(-0.6, winds.size() - 0.4)
		var k := 0
		for sp in [&"sparrow", &"pigeon", &"eagle"]:
			if not (d as Dictionary).has(String(sp)):
				continue
			var row: Dictionary = d[String(sp)]
			var xs := PackedFloat64Array()
			var ys := PackedFloat64Array()
			for wi in winds.size():
				if row.has(winds[wi]):
					xs.append(wi + (k - 1) * 0.22)
					ys.append(float(row[winds[wi]]["share"]))
			for i in xs.size():
				pn.rect_data(Rect2(xs[i] - 0.1, 0.0, 0.2, ys[i]), FlightPlot.series_color(slot(sp)), String(sp) if i == 0 else "", true)
			k += 1
		pn.hline(0.8, FlightPlot.INK2, "0.8")
	if not any:
		return
	pl.note("Glide-ins asserted: head and cross >= 80 %, tail 2.1 m/s >= 70 % of still air. Round 2 (verifier): sparrow 67 % still, 44 % in a 1.5 m/s headwind, 0 % in a 1.5 m/s crosswind. Now the assist acquires on the air or ground path and holds the branch, carries the wind's drift on its own budget, brakes on the ground speed and cancels a dive; the capture judges min(airspeed, ground speed).")
	_save(pl, "r3_perch_wind")


# --- F12: the bot course tracks (B1) ---------------------------------------------
func _b1_tracks() -> void:
	for sp in [&"sparrow", &"pigeon", &"eagle"]:
		var path := _out.path_join("b1_course_%s.png" % sp)
		var fx := FX.new(self)
		var b := BC.new(fx, sp)
		await b.setup()
		b.fly()
		b.csv(_out.path_join("b1_course_%s.csv" % sp))
		b.plot(path)
		_written.append(path)
		print("[flight] b1 %s window err %s perched %.1f s" % [sp, str(b.window_err), b.perched_t])
		fx.teardown()


# --- PB-08b / PB-08c: camera heave ---------------------------------------------------
const HT := preload("res://tests/unit/flight/heave_test.gd")

## One scripted flight through the real rig: perceived heights of body and
## camera. kind: "cruise" (steady strokes), "irregular" (the round-2
## verifier's human pilot: random stroke durations 0.6-1.4 s and amplitudes,
## short glides), "jitter" (continuous strokes, +-10 % duration jitter).
func _heave_run(sp: StringName, kind: String, secs: float, seed := 12) -> HM:
	var hm := HM.new()
	var fx := FX.new(self)
	await fx.setup(sp)
	fx.player.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
	var sched: Array = HT._irregular(seed, secs, 0.1 if kind == "jitter" else 0.4, 0.0 if kind == "jitter" else 0.35)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if kind == "cruise":
			ScriptedPoseSource.flap(b, t, 25.0, 1.0)
			for a in b.arms:
				a.twist = -20.0 * DEG
			return
		for sc in sched:
			var t0: float = sc[0]
			var dur: float = sc[1]
			if t >= t0 and t < t0 + dur:
				ScriptedPoseSource.flap(b, (t - t0) / dur, float(sc[2]), 1.0)
		b.humanize(DT)
		for a in b.arms:
			a.twist = -12.0 * DEG
	fx.on_tick = func(_tick: int, f: Variant) -> void:
		hm.push(f.player)
	fx.run(secs)
	fx.teardown()
	return hm


static func _heights(hm: HM, which: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var y0 := which[0]
	for i in which.size():
		out.append((which[i] - y0) / hm.ws[i])
	return out


## Height minus its centred 1 s mean (the bob), perceived cm.
static func _bob(hm: HM, which: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(which.size())
	for i in range(36, which.size() - 36):
		var m := 0.0
		for k in range(-36, 37):
			m += which[i + k]
		out[i] = (which[i] - m / 73.0) / hm.ws[i] * 100.0
	return out


func _pb08_heave() -> void:
	var pl := FlightPlot.new(1600, 1100, "PB-08b / PB-08c camera heave (perceived: / world_scale)")
	var cs := cells(3, 2, 130, 90, 1600, 1100, 90, 70)
	var runs := [[&"sparrow", "cruise", 16.0, "sparrow, steady strokes"],
		[&"pigeon", "jitter", 30.0, "pigeon, +-10 % stroke timing jitter"],
		[&"pigeon", "irregular", 30.0, "pigeon, irregular strokes (s12), camera=body"]]
	for k in 3:
		var r: Array = runs[k]
		var hm: HM = await _heave_run(r[0], r[1], r[2], 21 if r[1] == "jitter" else 12)
		var ts := PackedFloat64Array()
		for i in hm.size():
			ts.append(i * DT)
		var bw := hm.band_windows()
		var ph := pl.panel(cs[2 * k], "%s" % r[3], "t (s)", "bob cm")
		ph.line(ts, _bob(hm, hm.body), 0, "body", 2, FlightPlot.MUTED)
		ph.line(ts, _bob(hm, hm.cam), slot(r[0]), "camera")
		var ser: Array = hm.band_window_series()
		var pr := pl.panel(cs[2 * k + 1], "view/body band acc: %.0f %%, worst %.2f x, jerk %.2f/%.2f" % [
			100.0 * bw["cam"] / bw["body"], bw["worst"], hm.max_cam_d2(), hm.max_body_d2()], "t (s)", "")
		pr.set_y(0.0, 1.6)
		pr.hline(1.0, FlightPlot.MUTED, "the body")
		pr.hline(1.5, Color(0.80, 0.22, 0.20), "1.5 x (never)")
		pr.line(ser[0], ser[1], slot(r[0]), "view / body")
	pl.note("Bob = height minus its centred 1 s mean. Right: the round-2 verifier's measure per 3 s window. The correction opens after three regular strokes, eases in, and leaves irregular flapping alone.")
	_save(pl, "pb08_heave")


# --- Round 5: landing on the ground -------------------------------------------------
## Top: arms spread and still from 6 spans + 2 m into a meadow (G2): belly
## height (spans) and speed / V_min (airspeed while flying, ground speed on
## the feet after the touchdown). Bottom left: a full flare (wrists +40 deg)
## begun 1 span up (G4). Bottom right: PB-11's slow touchdown (G1): the
## view's per-tick velocity change over the touchdown speed, against the
## perch capture's P9 bound.
func _r5_ground() -> void:
	var pl := FlightPlot.new(1600, 900, "Round 5: landing on the ground - skim, touch down, run out; a flare lands")
	var cs := cells(2, 2, 175, 90, 1600, 900, 90, 80)
	var pb := pl.panel(cs[0], "Neutral glide into a meadow: belly height", "t (s)", "spans")
	var pv := pl.panel(cs[1], "Same glides: speed / V_min (air, then ground)", "t (s)", "V/Vmin")
	var pf := pl.panel(cs[2], "Full flare (+40 deg) from 1 span: belly height", "t after the flare (s)", "spans")
	var pt := pl.panel(cs[3], "Touchdown (PB-11): view dv per tick / touchdown speed", "t (s)", "ratio")
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var fx := FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		var pr := p.model.params
		p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
		var r := {"t": PackedFloat64Array(), "b": PackedFloat64Array(), "v": PackedFloat64Array(), "td": -1.0}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pp: PlayerBird = f.player
			var t := tick * DT
			r["t"].append(t)
			r["b"].append((pp.model.position.y - pr.r_body) / pr.span)
			var v := pp.model.airspeed() if pp.mode == PlayerBird.Mode.FLYING else Vector2(pp.model.velocity.x, pp.model.velocity.z).length()
			r["v"].append(v / pr.v_min)
			if float(r["td"]) < 0.0 and pp.mode == PlayerBird.Mode.GROUNDED:
				r["td"] = t
		fx.run(20.0)
		pb.line(r["t"], r["b"], slot(sp), "%s (down %.1f s)" % [sp, r["td"]], 3)
		pv.line(r["t"], r["v"], slot(sp), String(sp), 3)
		fx.teardown()
		# The full flare from 1 span.
		fx = FX.new(self)
		await fx.setup(sp)
		p = fx.player
		p.start_flying(Vector3(0, 6.0 * pr.span + 2.0, 0), 0.0, 0.0)
		var q := {"flare": -1.0, "tick0": -1, "t": PackedFloat64Array(), "b": PackedFloat64Array(), "stuns": 0, "td": -1.0}
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if float(q["flare"]) >= 0.0:
				var k := clampf((t - float(q["flare"])) / 0.3, 0.0, 1.0)
				b.arms[0].twist = k * 40.0 * DEG
				b.arms[1].twist = k * 40.0 * DEG
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pp: PlayerBird = f.player
			if float(q["flare"]) < 0.0 and pp.model.position.y - pr.r_body < pr.span:
				q["flare"] = fx.src.tick * DT
				q["tick0"] = tick
			if int(q["tick0"]) >= 0:
				var t := (tick - int(q["tick0"])) * DT
				q["t"].append(t)
				q["b"].append((pp.model.position.y - pr.r_body) / pr.span)
				if float(q["td"]) < 0.0 and pp.mode == PlayerBird.Mode.GROUNDED:
					q["td"] = t
		fx.run(28.0)
		pf.line(q["t"], q["b"], slot(sp), "%s (down %.1f s, stuns %d)" % [sp, q["td"], p.contacts["stun"]], 3)
		fx.teardown()
		# PB-11's touchdown.
		fx = FX.new(self)
		await fx.setup(sp)
		p = fx.player
		var start := Vector3(0, pr.r_body + 0.25, 0)
		p.start_flying(start, 0.0, 0.0)
		var v0 := Vector3(0, -0.2 * pr.v_min, -0.6 * pr.v_min)
		p.model.reset(start, v0, 0.0)
		var u := {"last": p.camera.global_position, "lastv": v0, "t": PackedFloat64Array(), "r": PackedFloat64Array(), "n": 0}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pp: PlayerBird = f.player
			var c := pp.camera.global_position
			var v: Vector3 = (c - u["last"]) / DT
			if int(u["n"]) > 0:
				u["t"].append(tick * DT)
				u["r"].append((v - u["lastv"]).length() / v0.length())
			u["n"] += 1
			u["last"] = c
			u["lastv"] = v
		fx.run(1.0)
		pt.line(u["t"], u["r"], slot(sp), String(sp), 2)
		fx.teardown()
	pv.hline(1.2, FlightPlot.INK2, "touchdown 1.2 V_min")
	pv.hline(1.0, FlightPlot.INK2, "V_min")
	pt.hline(0.45, FlightPlot.INK2, "P9 bound 0.45")
	pt.set_y(0.0, 0.6)
	pb.legend_pos = 1
	pl.note("Round 4: below stall speed the pigeon and eagle slid on the grass for 7 and 15 s and stopped in one tick (0.58-0.98 x the touchdown speed per tick); a full flare stunned the sparrow from every height. Now the grass has friction, a wing at or below 1.2 V_min touching it has landed and runs out on its feet at 0.6 g, the legs take the fall (the view dips at most 0.75 body radius), below ~10 m a full flare is the maximum-lift flare (no committed stall), and a slow flaring bird lowers its legs and tail.")
	_save(pl, "r5_ground")


## Left: resuming from the pause menu (PB-29): bank and flap force after the
## arms come back from the menu pose. Middle: slow arm sweeps through
## engine frame hitches (WI-34): the detected flap effort with and without
## the XR source's frame timing. Right: a sparrow perching in the world's
## full 2.64 m/s breeze (P13): distance to the grip.
func _r5_resume_hitch() -> void:
	var pl := FlightPlot.new(1600, 900, "Round 5: resume, frame hitches and the full breeze")
	var cs := cells(1, 3, 175, 90, 1600, 900, 80, 0)
	var pr_ := pl.panel(cs[0], "Resume: |bank| after it", "t after resume (s)", "deg")
	var ph := pl.panel(cs[1], "Hitches + slow arm sweeps: flap", "t (s)", "effort")
	var pw := pl.panel(cs[2], "Sparrow, 2.64 m/s: to the grip", "t (s)", "spans")
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var fx := FX.new(self)
		await fx.setup(sp)
		var p := fx.player
		p.start_flying(Vector3(0, 120, 0), 0.0, 0.0)
		var st := {"phase": 0, "t_res": 0.0}
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if int(st["phase"]) == 1:
				var k := clampf((t - float(st["t_res"])) / 0.8, 0.0, 1.0)
				var e := k * k * (3.0 - 2.0 * k)
				b.arms[0].dihedral = lerpf(-80.0 * DEG, 0.0, e)
				b.arms[1].dihedral = lerpf(35.0 * DEG, 0.0, e)
				b.arms[1].sweep = lerpf(60.0 * DEG, 0.0, e)
				b.arms[1].elbow = lerpf(20.0 * DEG, 0.0, e)
				b.head_yaw = lerpf(20.0 * DEG, 0.0, e)
				b.room_offset = Vector3(0.3, 0.0, -0.4)
		fx.run(2.0)
		st["phase"] = 1
		st["t_res"] = fx.src.tick * DT
		p.notification(Node.NOTIFICATION_UNPAUSED)
		var r := {"t": PackedFloat64Array(), "bank": PackedFloat64Array(), "k0": fx.ticks}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			r["t"].append((tick - int(r["k0"])) * DT)
			r["bank"].append(absf(rad_to_deg(f.player.model.phi)))
		fx.run(3.0)
		pr_.line(r["t"], r["bank"], slot(sp), "%s (max %.1f deg, %d flaps)" % [sp, _max(r["bank"]), fx.events["flapped"]], 3)
		fx.teardown()
	pr_.set_y(0.0, 75.0)
	pr_.hline(70.6, FlightPlot.INK2, "round 4 sparrow 70.6")
	# Frame hitches through the XR source (the WI-34 set-up); round 5 on top.
	for timing: bool in [false, true]:
		var rr := _hitch_trace(timing)
		ph.line(rr[0], rr[1], 0 if timing else 3, "frame timing on (round 5)" if timing else "off (round 4)", 3 if timing else 2)
	ph.set_y(-0.02, 0.35)
	# The full breeze.
	for wd in [["head", Vector3(0, 0, 2.64), 0], ["cross", Vector3(2.64, 0, 0), 2], ["tail", Vector3(0, 0, -2.64), 4]]:
		var fx := FX.new(self)
		await fx.setup(&"sparrow", func(w: Variant) -> void:
			w.add_perch(Vector3(0, 20, -10), Vector3.FORWARD, 10.0, 0.015, 1.0)
			w.uniform_wind = wd[1])
		var p := fx.player
		var pr := p.model.params
		var tgt := Vector3(0, 20, -10) + Vector3.UP * pr.r_body
		var start := tgt + Vector3(0, 0.3 * pr.span, 6.0 * pr.span)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, 0, -1.2 * 0.8 * pr.v_min) + (wd[1] as Vector3), 0.0)
		fx.driver = fx.synth(0.3, 0.0, 1.0)
		var r := {"t": PackedFloat64Array(), "d": PackedFloat64Array(), "perch": -1.0}
		fx.on_tick = func(tick: int, f: Variant) -> void:
			var pp: PlayerBird = f.player
			r["t"].append(tick * DT)
			r["d"].append(pp.model.position.distance_to(tgt) / pr.span)
			if float(r["perch"]) < 0.0 and pp.mode == PlayerBird.Mode.PERCHED:
				r["perch"] = tick * DT
		fx.run(3.0)
		pw.line(r["t"], r["d"], int(wd[2]), "%s wind (perched %.2f s)" % [wd[0], r["perch"]], 3)
		fx.teardown()
	pl.note("Round 4: resuming from a pointing pose banked the bird to 56-71 deg and credited a wingbeat; engine frame hitches turned slow arm sweeps into flaps; a sparrow never perched into or across the 2.64 m/s breeze. Now the detectors restart and the controls wait for the arms to settle, hand velocity is measured over the real frame interval, and the perch assist keeps a closing speed into the wind while a slow brush of the branch no longer locks the capture out.")
	_save(pl, "r5_resume_hitch")


static func _max(a: PackedFloat64Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return m


## WI-34's slow sweeps with a 100 ms hitch every 0.5 s through the XR source
## (injected engine clock): [t, mean flap effort].
func _hitch_trace(timing: bool) -> Array:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var lh := XRController3D.new()
	var rh := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(lh)
	origin.add_child(rh)
	add_child(origin)
	var src := XRPoseSource.new(origin, cam, lh, rh)
	src.assume_tracked = true
	src.frame_timing = timing
	var clock := {"frame": 0, "t": 0.0}
	src.clock = func() -> Vector2: return Vector2(float(clock["frame"]), float(clock["t"]))
	var wi := WingInput.new()
	wi.auto_calibrate = false
	var body := HumanPoseModel.new(3)
	var fr := PoseFrame.new()
	var truth := PoseFrame.new()
	var ts := PackedFloat64Array()
	var fs := PackedFloat64Array()
	var real_t := 0.0
	var tick_t := 0.0
	while real_t < 8.0:
		var ticks := 7 if int(clock["frame"]) % 36 == 35 else 1
		real_t += ticks * DT
		clock["frame"] = int(clock["frame"]) + 1
		clock["t"] = real_t
		body.set_airplane()
		var e := deg_to_rad(25.0) * sin(TAU * 0.25 * real_t)
		body.arms[0].dihedral = e
		body.arms[1].dihedral = e
		body.frame(truth)
		cam.transform = truth.head
		lh.transform = truth.left
		rh.transform = truth.right
		for k in ticks:
			src.sample(fr, DT)
			var w := wi.update(fr, DT)
			tick_t += DT
			ts.append(tick_t)
			fs.append(0.5 * (w.flap_l + w.flap_r))
	origin.queue_free()
	return [ts, fs]


# --- Round 6: slopes and roofs -------------------------------------------------------------

const R6_H0 := 30.0


static func _r6_slope(deg: float) -> Callable:
	return func(w: Variant) -> void:
		FlightGeometry.slope(w, Vector3(0, R6_H0, 0), deg, Vector2(120.0, 900.0), FlightGeometry.C_GROUND, false)


## The worst per-tick change of the camera's velocity / the approach speed,
## for a touchdown on a slope (the round-6 experience verifier's set-up).
func _r6_touchdown(sp: StringName, deg: float, vf: float, vs: float, gap: float) -> float:
	var fx := FX.new(self)
	await fx.setup(sp, _r6_slope(deg))
	var p := fx.player
	var pr := p.model.params
	var z0 := -2.0 * pr.span
	var start := Vector3(0, R6_H0 - z0 * tan(deg * DEG) + (pr.r_body + gap) / cos(deg * DEG), z0)
	p.start_flying(start, 0.0, 0.0)
	var v0 := Vector3(0, -vs, -vf) * pr.v_min
	p.model.reset(start, v0, 0.0)
	var st := {"last": p.camera.global_position, "lastv": v0, "worst": 0.0}
	fx.on_tick = func(_i: int, f: Variant) -> void:
		var c: Vector3 = f.player.camera.global_position
		var v: Vector3 = (c - st["last"]) / DT
		st["worst"] = maxf(st["worst"], (v - st["lastv"]).length())
		st["last"] = c
		st["lastv"] = v
	fx.run(1.5)
	var out := float(st["worst"]) / v0.length() if p.contacts["stun"] == 0 else NAN
	fx.teardown()
	return out


## Top: the touchdown's worst per-tick view velocity change against the
## slope rising ahead, for the verifier's flared approach (1.1 V_min) and
## PB-11's (0.6 V_min), round 6 (lines) against round 5 (crosses, from the
## round-6 experience verifier's own probe; a stun is left out). Bottom
## left: run-outs along slopes (pigeon). Bottom right: the legs after a
## steep sparrow touchdown on the flat and on a 38 deg roof.
func _r6_slopes() -> void:
	var pl := FlightPlot.new(1600, 1000, "Round 6: touchdowns on slopes and roofs")
	var cs := cells(2, 2, 185, 90, 1600, 1000, 90, 90)
	var pa := pl.panel(cs[0], "1.1 V_min approach: view dv/tick / speed", "slope rising ahead (deg)", "")
	var pb := pl.panel(cs[1], "PB-11 approach: view dv/tick / speed", "slope rising ahead (deg)", "")
	var pc := pl.panel(cs[2], "Pigeon run-outs: speed / V_min", "t after the touchdown (s)", "")
	var pd := pl.panel(cs[3], "Sparrow sinking 0.7 V_min: legs", "t (s)", "r_body")
	var degs := [0.0, 5.0, 10.0, 15.0, 20.0, 25.0, 30.0, 34.0, 38.0, 44.0]
	# Round 5, from verify/r6exp/experience_probe.txt ("sweep" and PB-11 lines;
	# NAN = stunned).
	var r5a := {&"sparrow": [0.07, 0.10, 0.15, 0.78, 0.54, 0.52, 0.56, 0.56, NAN, NAN],
		&"pigeon": [0.04, 0.06, 0.06, 0.11, 0.14, 0.77, 0.62, 0.52, 0.43, NAN],
		&"eagle": [0.03, 0.04, 0.04, 0.10, 0.11, 0.14, 0.24, 0.33, 0.42, NAN]}
	var r5b_deg := [0.0, 5.0, 10.0, 20.0, 38.0]
	var r5b := {&"sparrow": [0.32, 0.38, 0.44, 0.58, 0.77], &"pigeon": [0.08, 0.09, 0.13, 0.26, 0.38], &"eagle": [0.05, 0.06, 0.09, 0.16, 0.46]}
	var worst := {}
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var xs := PackedFloat64Array()
		var ya := PackedFloat64Array()
		var yb := PackedFloat64Array()
		for d: float in degs:
			xs.append(d)
			ya.append(await _r6_touchdown(sp, d, 1.1, 0.15, 0.1))
			yb.append(await _r6_touchdown(sp, d, 0.6, 0.2, 0.25))
		worst[sp] = [ya, yb]
		pa.line(xs, ya, slot(sp), "%s round 6" % sp, 3)
		pa.points(xs, ya, slot(sp))
		pb.line(xs, yb, slot(sp), "%s round 6" % sp, 3)
		pb.points(xs, yb, slot(sp))
		var x5 := PackedFloat64Array()
		var y5 := PackedFloat64Array()
		for i in degs.size():
			x5.append(degs[i])
			y5.append(float(r5a[sp][i]))
		pa.points(x5, y5, slot(sp), "%s round 5" % sp, 3, FlightPlot.series_color(slot(sp)).lerp(Color.WHITE, 0.45))
		var x6 := PackedFloat64Array()
		var y6 := PackedFloat64Array()
		for i in r5b_deg.size():
			x6.append(r5b_deg[i])
			y6.append(float(r5b[sp][i]))
		pb.points(x6, y6, slot(sp), "%s round 5" % sp, 3, FlightPlot.series_color(slot(sp)).lerp(Color.WHITE, 0.45))
	for pp: FlightPlot.PlotPanel in [pa, pb]:
		pp.hline(0.45, FlightPlot.INK2, "P9 / G1 bound 0.45")
		pp.set_y(0.0, 1.0)
	# Run-outs (pigeon): 1.0 V_min touchdowns up 20 and 38 deg, across a 38
	# deg roof, the flat, and down 20 deg.
	var runs := [[20.0, 0.0, 0.05, "up 20 deg"], [38.0, 0.0, 0.05, "up 38 deg"], [38.0, 60.0, 0.05, "38 deg, 60 deg across"],
		[0.0, 0.0, 0.05, "flat"], [-20.0, 0.0, 0.5, "down 20 deg"]]
	var k := 0
	for r in runs:
		var deg: float = r[0]
		var fx := FX.new(self)
		await fx.setup(&"pigeon", _r6_slope(deg))
		var p := fx.player
		var pr := p.model.params
		var yaw := float(r[1]) * DEG
		var z0 := 2.0 * pr.span
		var start := Vector3(0, R6_H0 - z0 * tan(deg * DEG) + (pr.r_body + 0.02) / cos(deg * DEG), z0)
		p.start_flying(start, yaw, 0.0)
		p.model.reset(start, FlightMath.yaw_forward(yaw) * pr.v_min + Vector3.DOWN * float(r[2]) * pr.v_min, yaw)
		var q := {"t0": -1, "t": PackedFloat64Array(), "v": PackedFloat64Array()}
		fx.on_tick = func(i: int, f: Variant) -> void:
			var pp: PlayerBird = f.player
			if int(q["t0"]) < 0 and pp.mode == PlayerBird.Mode.GROUNDED:
				q["t0"] = i
			if int(q["t0"]) >= 0 and pp.mode == PlayerBird.Mode.GROUNDED:
				q["t"].append((i - int(q["t0"])) * DT)
				q["v"].append(pp.model.velocity.length() / pr.v_min)
		fx.run(4.5)
		pc.line(q["t"], q["v"], k, String(r[3]), 3)
		fx.teardown()
		k += 1
	# The legs: a sparrow sinking at 0.7 V_min, 0.4 V_min forward, onto the flat
	# and onto a 38 deg roof facing the ridge, from outside the feet's reach.
	k = 0
	for deg: float in [0.0, 38.0]:
		var fx := FX.new(self)
		await fx.setup(&"sparrow", _r6_slope(deg))
		var p := fx.player
		var pr := p.model.params
		var z0 := -2.0 * pr.span
		var start := Vector3(0, R6_H0 - z0 * tan(deg * DEG) + 5.0 * pr.r_body / cos(deg * DEG), z0)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, -0.7, -0.4) * pr.v_min, 0.0)
		var n := FlightGeometry.slope_normal(deg)
		var q := {"t": PackedFloat64Array(), "o": PackedFloat64Array(), "b": PackedFloat64Array()}
		fx.on_tick = func(i: int, f: Variant) -> void:
			var pp: PlayerBird = f.player
			q["t"].append(i * DT)
			# The camera's height along the normal above where the body rests.
			q["o"].append(((pp.camera.global_position - Vector3(0, R6_H0, 0)).dot(n) - pr.r_body) / pr.r_body)
			q["b"].append(((pp.model.position - Vector3(0, R6_H0, 0)).dot(n) - pr.r_body) / pr.r_body)
		fx.run(0.3)
		pd.line(q["t"], q["o"], k * 2, "camera, %s" % ("flat" if deg == 0.0 else "38 deg roof"), 3)
		pd.line(q["t"], q["b"], k * 2 + 1, "body, %s" % ("flat" if deg == 0.0 else "38 deg roof"), 2)
		fx.teardown()
		k += 1
	pd.hline(1.0, FlightPlot.INK2, "the feet's reach (1 r_body)")
	pd.hline(-0.75, FlightPlot.INK2, "deepest bend (0.75 r_body)")
	pd.hline(0.0, FlightPlot.AXIS, "")
	pl.note("Round 5 met the ground with the belly, ran level with a 0.3 body-radius step-up and bent the legs vertically only: facing up a slope the run and the speed into the slope stopped in one tick (up to 0.85 x), and a 38-44 deg roof stunned. Now the feet reach one body radius beyond the body and meet the ground first, the legs take the speed into it along the surface normal over reach + bend (1.75 body radii), a touchdown may come in at up to 1 V_min into the surface, and the run-out keeps to the ground's plane, braking at mu g cos(slope) plus gravity along it (at least 0.3 g).")
	_save(pl, "r6_slopes")
	for sp in worst:
		print("[flight] r6_slopes %s: flared %s | PB-11 %s" % [sp, worst[sp][0], worst[sp][1]])


## Take-offs facing up slopes (6 s of reference strokes, 1.3 Hz 45 deg):
## took_off events and the way made up the slope, round 6 against round 5
## (the round-6 experience verifier's sweep); and an eagle's bounds up a
## long 38 deg slope, over a village roof's ridge, and banking away.
func _r6_takeoff() -> void:
	var pl := FlightPlot.new(1600, 900, "Round 6: taking off facing up a slope")
	var cs := cells(1, 3, 185, 90, 1600, 900, 80, 0)
	var pa := pl.panel(cs[0], "took_off events, 6 s of strokes", "slope (deg)", "")
	var pb := pl.panel(cs[1], "Way made up the slope, spans", "slope (deg)", "")
	var pc := pl.panel(cs[2], "Eagle, 38 deg: height over it, spans", "t (s)", "")
	var degs := [20.0, 25.0, 30.0, 34.0, 38.0, 44.0]
	var r5 := {&"sparrow": [1, 7, 7, 7, 7, 7], &"pigeon": [1, 3, 3, 3, 3, 3], &"eagle": [2, 2, 3, 3, 3, 3]}
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var xs := PackedFloat64Array()
		var ye := PackedFloat64Array()
		var yc := PackedFloat64Array()
		var y5 := PackedFloat64Array()
		for i in degs.size():
			var deg: float = degs[i]
			var fx := FX.new(self)
			await fx.setup(sp, _r6_slope(deg))
			var p := fx.player
			var pr := p.model.params
			var z0 := -2.0 * pr.span
			var start := Vector3(0, R6_H0 - z0 * tan(deg * DEG) + (pr.r_body + 0.05) / cos(deg * DEG), z0)
			p.start_flying(start, 0.0, 0.0)
			p.model.reset(start, Vector3(0, -0.2, -0.3) * pr.v_min, 0.0)
			fx.run(2.0)
			var up := Vector3(0, sin(deg * DEG), -cos(deg * DEG))
			var s0 := (p.model.position - Vector3(0, R6_H0, 0)).dot(up)
			var t0 := fx.src.tick * DT
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				ScriptedPoseSource.flap(b, t - t0 + 0.5, 45.0, 1.3)
			fx.reset_events()
			fx.run(6.0)
			xs.append(deg)
			ye.append(fx.events["took_off"])
			yc.append(((p.model.position - Vector3(0, R6_H0, 0)).dot(up) - s0) / pr.span)
			y5.append(float(r5[sp][i]))
			fx.teardown()
		pa.line(xs, ye, slot(sp), "%s round 6" % sp, 3)
		pa.points(xs, ye, slot(sp))
		pa.points(xs, y5, slot(sp), "%s round 5" % sp, 3, FlightPlot.series_color(slot(sp)).lerp(Color.WHITE, 0.45))
		pb.line(xs, yc, slot(sp), String(sp), 3)
		pb.points(xs, yc, slot(sp))
	pa.set_y(0.0, 8.0)
	# The eagle: a long 38 deg slope straight on, the same with a banked turn
	# away, and a village roof (ridge 2.7 m up the slope).
	var k := 0
	for mode_: String in ["long slope, straight on", "long slope, banks away", "village roof, over the ridge"]:
		var fx := FX.new(self)
		var roof := mode_.begins_with("village")
		var ridge := Vector3(0, 6.0 + 3.2 * tan(38.0 * DEG), 0)
		if roof:
			await fx.setup(&"eagle", func(w: Variant) -> void:
				FlightGeometry.gable_roof(w, ridge, 38.0, 3.2, 12.0, FlightGeometry.C_FRAME, false))
		else:
			await fx.setup(&"eagle", _r6_slope(38.0))
		var p := fx.player
		var pr := p.model.params
		var n := FlightGeometry.slope_normal(38.0)
		var base := ridge if roof else Vector3(0, R6_H0, 0)
		var zl := 0.66 * 3.2 if roof else -2.0 * pr.span
		var surf := base + Vector3(0, -zl * tan(38.0 * DEG), zl)
		var start := surf + n * (pr.r_body + 0.05)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, -0.2, -0.3) * pr.v_min, 0.0)
		fx.run(2.0)
		var t0 := fx.src.tick * DT
		var cal := p.wing_input.calibration
		var st := {"to": -1.0}
		var bank := mode_.contains("banks")
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			if bank and float(st["to"]) >= 0.0 and t - float(st["to"]) < 1.5:
				b.synth(0.0, 0.7, 1.0, cal)
			ScriptedPoseSource.flap(b, t - t0 + 0.5, 45.0, 1.3)
		fx.reset_events()
		var q := {"t": PackedFloat64Array(), "c": PackedFloat64Array()}
		fx.on_tick = func(i: int, f: Variant) -> void:
			var pp: PlayerBird = f.player
			if float(st["to"]) < 0.0 and f.events["took_off"] > 0:
				st["to"] = fx.src.tick * DT
			var pos := pp.model.position
			var h := (pos - base).dot(n) - pr.r_body
			if roof:
				# Above the front slope, the back slope, or beyond the eaves.
				if pos.z < 0.0:
					h = (pos - base).dot(Vector3(0, n.y, -n.z)) - pr.r_body
				if absf(pos.z) > 3.2:
					h = pos.y - pr.r_body
			q["t"].append(fx.src.tick * DT - t0)
			q["c"].append(h / pr.span)
		fx.run(8.0)
		pc.line(q["t"], q["c"], k, "%s (took_off %d, perched %d)" % [mode_, fx.events["took_off"], fx.events["perched"]], 3)
		fx.teardown()
		k += 1
	pc.hline(0.0, FlightPlot.AXIS, "")
	pc.set_y(-0.2, 6.0)
	pl.note("Right: the height over the roof, then over the ground past its far eave (the step at 3.1 s). Round 5 launched level into the slope and touched the bird down again on the next tick: a took_off / perched pair on every stroke, stuck (crosses). Now the launch runs up along the slope and off it, and a bird taking off is not landed again while it keeps flapping: a sparrow climbs straight out; a pigeon or an eagle, which cannot out-climb a steep slope (an eagle climbs ~12 deg from a standing start), bounds up it and stands on its feet when the launch is spent (never sliding back). Over a village roof's ridge, or with a banked turn away, it leaves.")
	_save(pl, "r6_takeoff")


func _overview() -> void:
	var order := ["f1_flap_impulse", "f1_hover", "f2_balloon_sag", "f2_alpha_map", "f3_stall", "f3_lift_curve", "f4_turn", "f5_tuck_dive",
		"f6_thermals", "f7_turn_circles", "f7_glide_polars", "f8_energy", "f11_comfort", "pb08_heave", "wi_channels",
		"b1_course_sparrow", "b1_course_pigeon", "b1_course_eagle", "f13_keys_sparrow", "f13_keys_pigeon", "r4_view_turns", "r4_strokes", "r4_perch_rest", "r3_perch_wind", "r5_ground", "r5_resume_hitch", "r6_slopes", "r6_takeoff"]
	var paths := PackedStringArray()
	for n in order:
		var p: String = _out.path_join(n + ".png")
		if FileAccess.file_exists(p):
			paths.append(p)
	FlightPlot.contact_sheet(paths, 4, _out.path_join("overview.png"), 800, "Soaring flight area: evidence overview")
	print("[flight] overview: %d tiles" % paths.size())
