extends RefCounted
## Scenario library for the flight suites (FLIGHT_SPEC §14.1): model
## factories, a tick-indexed runner, a recorder, and plot helpers. Preload it:
##   const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
## Inputs are indexed by tick, never by an accumulated float time.

const S3: Array[StringName] = [&"sparrow", &"pigeon", &"eagle"]
const SP: Array[StringName] = [&"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
const DT := 1.0 / 72.0
const G := 9.81


static func model(sp: StringName, preset := 1) -> FlightModel:
	var tu := FlightTuning.new()
	tu.preset = preset
	return FlightModel.new(FlightParams.species_mass(sp), tu)


static func tuning(preset := 1) -> FlightTuning:
	var tu := FlightTuning.new()
	tu.preset = preset
	return tu


## Runs `ticks` ticks. cmd.call(i, ws) sets this tick's commands (i counts
## from 0 within this run). Returns the WingState used.
static func run(m: FlightModel, ticks: int, cmd: Callable, env: FlightEnv = null, rec: Rec = null,
		dt := DT, ws: WingState = null) -> WingState:
	var w := ws if ws != null else WingState.new()
	var e := env if env != null else FlightEnv.new()
	for i in ticks:
		if cmd.is_valid():
			cmd.call(i, w)
		m.step(w, e, dt)
		if rec != null:
			rec.add(m, w, dt)
	return w


## Glide command at fixed pitch/roll, spread, no flapping.
static func glide(p := 0.0, r := 0.0, spread := 1.0) -> Callable:
	return func(_i: int, ws: WingState) -> void:
		ws.set_commands(p, r, spread, 0.0, 0.0)


## Reference-stroke flapping at `effort` (table from the model's size).
static func flap(m: FlightModel, p := 0.0, r := 0.0, effort := 1.0, tilt := NAN, one_wing := 0, dt := DT) -> Callable:
	var x := m.params.x
	return func(i: int, ws: WingState) -> void:
		ws.set_commands(p, r, 1.0, effort, i * dt, 1.0, one_wing, tilt, x)


class Rec:
	var t := PackedFloat64Array()
	var x := PackedFloat64Array()
	var y := PackedFloat64Array()
	var z := PackedFloat64Array()
	var v := PackedFloat64Array()
	var vy := PackedFloat64Array()
	var vh := PackedFloat64Array()
	var alpha := PackedFloat64Array()
	var theta := PackedFloat64Array()
	var phi := PackedFloat64Array()
	var gam := PackedFloat64Array()
	var heading := PackedFloat64Array()
	var yaw_rate := PackedFloat64Array()
	var dpsi := PackedFloat64Array()
	var flap_l := PackedFloat64Array()
	var flap_r := PackedFloat64Array()
	var pitch := PackedFloat64Array()
	var roll := PackedFloat64Array()
	var g_load := PackedFloat64Array()
	var flap_fy := PackedFloat64Array()
	var cl := PackedFloat64Array()
	var sig := PackedFloat64Array()
	var stalled := PackedByteArray()
	var events: Array = []
	var _t := 0.0
	var _n := 0

	func add(m: FlightModel, ws: WingState, dt: float) -> void:
		_n += 1
		var tt := _n * dt
		t.append(tt)
		x.append(m.position.x)
		y.append(m.position.y)
		z.append(m.position.z)
		v.append(m.airspeed())
		vy.append(m.velocity.y)
		vh.append(Vector2(m.velocity.x, m.velocity.z).length())
		alpha.append(rad_to_deg(m.alpha))
		theta.append(rad_to_deg(m.theta))
		phi.append(rad_to_deg(m.phi))
		gam.append(rad_to_deg(m.gam))
		heading.append(m.heading())
		yaw_rate.append(m.yaw_rate)
		dpsi.append(rad_to_deg(m.dpsi))
		flap_l.append(ws.flap_l)
		flap_r.append(ws.flap_r)
		pitch.append(ws.pitch)
		roll.append(ws.roll)
		g_load.append(m.g_load)
		flap_fy.append(m.f_flap.y)
		cl.append(m._cl)
		sig.append(m.sigma)
		stalled.append(1 if m.stalled else 0)
		for e in m.drain_events():
			events.append([tt, e])

	func size() -> int:
		return t.size()

	## Index of the first sample at or after time tt.
	func at(tt: float) -> int:
		for i in t.size():
			if t[i] >= tt - 1e-9:
				return i
		return t.size() - 1

	func count(ev: String) -> int:
		var c := 0
		for e in events:
			if e[1] == ev:
				c += 1
		return c

	func csv(path: String) -> void:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return
		f.store_line("t,x,y,z,V,vy,alpha,theta,phi,gamma,heading,dpsi,flap_l,flap_r,pitch,roll,g_load,stalled")
		for i in t.size():
			f.store_line("%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.5f,%.4f,%.3f,%.3f,%.3f,%.3f,%.3f,%d" % [
				t[i], x[i], y[i], z[i], v[i], vy[i], alpha[i], theta[i], phi[i], gam[i], heading[i],
				dpsi[i], flap_l[i], flap_r[i], pitch[i], roll[i], g_load[i], stalled[i]])


static func minv(a: PackedFloat64Array, i0 := 0, i1 := -1) -> float:
	var e := a.size() if i1 < 0 else mini(i1, a.size())
	var m := INF
	for i in range(i0, e):
		m = minf(m, a[i])
	return m


static func maxv(a: PackedFloat64Array, i0 := 0, i1 := -1) -> float:
	var e := a.size() if i1 < 0 else mini(i1, a.size())
	var m := -INF
	for i in range(i0, e):
		m = maxf(m, a[i])
	return m


static func argmax(a: PackedFloat64Array, i0 := 0, i1 := -1) -> int:
	var e := a.size() if i1 < 0 else mini(i1, a.size())
	var m := -INF
	var k := i0
	for i in range(i0, e):
		if a[i] > m:
			m = a[i]
			k = i
	return k


static func mean(a: PackedFloat64Array, i0 := 0, i1 := -1) -> float:
	var e := a.size() if i1 < 0 else mini(i1, a.size())
	var s := 0.0
	var n := 0
	for i in range(i0, e):
		s += a[i]
		n += 1
	return s / maxf(n, 1)


static func sub(a: PackedFloat64Array, b: float) -> PackedFloat64Array:
	var o := PackedFloat64Array()
	o.resize(a.size())
	for i in a.size():
		o[i] = a[i] - b
	return o


static func scale(a: PackedFloat64Array, k: float) -> PackedFloat64Array:
	var o := PackedFloat64Array()
	o.resize(a.size())
	for i in a.size():
		o[i] = a[i] * k
	return o


static func out_dir() -> String:
	return Paths.artifacts("flight")


## Flapping from a detector table (FlapDetector.stroke_table / reference_table)
## sampled at the tick's phase: exactly what the detector would output for
## that arm motion, without the pose chain.
static func table_flap(tab: Dictionary, hz: float, p := 0.0, tilt := 0.0, one_wing := 0, dt := DT, r := 0.0) -> Callable:
	var fl: PackedFloat32Array = tab["flap"]
	var ups: PackedFloat32Array = tab["up"]
	var n := fl.size()
	return func(i: int, ws: WingState) -> void:
		var ph := fposmod(i * dt * hz, 1.0) * n
		var i0 := int(floorf(ph)) % n
		var i1 := (i0 + 1) % n
		var k := ph - floorf(ph)
		var f := lerpf(fl[i0], fl[i1], k)
		var u := lerpf(ups[i0], ups[i1], k)
		ws.pitch = p
		ws.roll = r
		ws.ext_l = 1.0
		ws.ext_r = 1.0
		ws.flap_dir_l = WingState.dir_for_tilt(tilt)
		ws.flap_dir_r = ws.flap_dir_l
		ws.flap_l = f if one_wing <= 0 else 0.0
		ws.flap_r = f if one_wing >= 0 else 0.0
		ws.up_l = u if one_wing <= 0 else 0.0
		ws.up_r = u if one_wing >= 0 else 0.0
		ws.stroke_period = clampf(1.0 / hz, 0.3, 1.5)


## Frame of the model now: forward, banked up, banked right.
static func frame(m: FlightModel) -> Array:
	var fh := FlightMath.yaw_forward(m.chi)
	var rh := Vector3(cos(m.chi), 0.0, -sin(m.chi))
	var up_b := Vector3.UP * cos(m.phi) + rh * sin(m.phi)
	var r_b := rh * cos(m.phi) - Vector3.UP * sin(m.phi)
	return [fh, up_b, r_b]


static func energy_height(m: FlightModel) -> float:
	return m.position.y + m.velocity.length_squared() / (2.0 * G)


## Mean horizontal ground speed after time t0 from positions.
static func horiz_speed_mean(rec: Rec, t0: float) -> float:
	var i0 := rec.at(t0)
	var i1 := rec.size() - 1
	if i1 <= i0:
		return 0.0
	return Vector2(rec.x[i1] - rec.x[i0], rec.z[i1] - rec.z[i0]).length() / (rec.t[i1] - rec.t[i0])


## F1 "upstroke much weaker than the downstroke", measured on the force the
## model APPLIES (fix round 3). The same WingState stream (next_ws.call(i)
## returns tick i's) is flown three times from the same trimmed glide: as
## given, with the upstroke commands zeroed and with the downstroke commands
## zeroed. The vertical flap impulse of the last two is what each command
## produces. Round 2 split one run's impulse in the ratio of the commands
## (up_gain x up : flap), so a model whose force ignored up_gain passed.
## Also returned: the impulse applied while the arms fall vs while they rise
## (arm_down.call(i) tells which), which differs from the causal split
## because tau_f smooths each downstroke's force into the next upstroke.
static func upstroke_split(sp: StringName, next_ws: Callable, ticks: int, arm_down: Callable) -> Dictionary:
	var m_all := model(sp)
	var m_dn := model(sp)
	var m_up := model(sp)
	for m in [m_all, m_dn, m_up]:
		(m as FlightModel).trim(Vector3(0, 500, 0), 0.0, 0.0)
	var env := FlightEnv.new()
	var w_dn := WingState.new()
	var w_up := WingState.new()
	var r := {"down": 0.0, "up": 0.0, "all": 0.0, "arm_fall": 0.0, "arm_rise": 0.0, "up_gain": m_all.params.up_gain}
	for i in ticks:
		var w: WingState = next_ws.call(i)
		w_dn.copy_from(w)
		w_dn.up_l = 0.0
		w_dn.up_r = 0.0
		w_up.copy_from(w)
		w_up.flap_l = 0.0
		w_up.flap_r = 0.0
		r["down"] += _v_impulse(m_dn, w_dn, env)
		r["up"] += _v_impulse(m_up, w_up, env)
		var d := _v_impulse(m_all, w, env)
		r["all"] += d
		r["arm_fall" if bool(arm_down.call(i)) else "arm_rise"] += d
	r["up_over_down"] = float(r["up"]) / maxf(float(r["down"]), 1e-9)
	r["rise_over_fall"] = float(r["arm_rise"]) / maxf(float(r["arm_fall"]), 1e-9)
	return r


## One tick; the vertical (banked-up) flap impulse it applied (N s).
static func _v_impulse(m: FlightModel, w: WingState, env: FlightEnv) -> float:
	var i0 := m.flap_impulse
	m.step(w, env, DT)
	return (m.flap_impulse - i0).dot(frame(m)[1])
