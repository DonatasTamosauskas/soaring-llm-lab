extends TestCase
## CE: the arena's lid (integration fix). The world closes the sky with an
## invisible slab whose underside is World.ceiling (soaring_world.
## _build_boundary). Under it the air thins (FlightEnv.thin_air): lift, drag
## AND the flap force fade together, smoothly, so a climb simply stalls out
## below the ceiling, and a thermal cannot carry a bird up there either.
## Should the lid still be met (only momentum can reach it: a zoom), the
## contact is a slide, never a stun.
##
## The verifier's finding (r7x, tests/probes/flight/r7x_experience_probe_test.gd;
## artifacts/flight/verify/r7x/r7x_ceiling_lid.png): the fade covered lift and
## drag but not the flap force, so a flapping bird climbed into the lid at
## full rate and was stunned again and again (sparrow 6 stuns in 40 s of
## reference strokes from 40 m below, pigeon 5, eagle 11 bumps).
##
## The suite runs the verifier's scenario (reference strokes and frantic
## flapping at sparrow / starling / pigeon / eagle from 40 m under an 80 m
## lid slab, and circling in a 4 m/s thermal) with its durations shortened;
## --full=1 runs them at the verifier's 40 s / 60 s and adds more cases.
## Evidence: artifacts/flight/ceiling/ce_lid.png (ce_lid_full.png with --full=1).

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const FS := preload("res://tests/unit/flight/flight_scenarios.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0
const LID := 80.0

var fx: FX
## Runs for the evidence plot: [label, the _flap_run() record].
var _plot_rows: Array = []


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


static func _full() -> bool:
	return Paths.arg("full", "") != ""


## A fixture under a lid slab (10 m thick, underside at LID) with the World's
## ceiling at LID, and optionally the verifier's 4 m/s bell thermal (60 m).
func _lid_fx(sp: StringName, thermal := 0.0, lid_y := LID) -> FX:
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		if thermal > 0.0:
			w.thermal_core = thermal
			w.thermal_center = Vector3.ZERO
			w.thermal_radius = 60.0
		FlightGeometry.box(w, Vector3(0, lid_y + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
	fx.world.ceiling = lid_y
	return fx


## Every contact the player had, of any kind (the verifier counted slide,
## stun, silent and brush; land and lid are added).
static func _contacts(p: PlayerBird) -> int:
	var c: Dictionary = p.contacts
	return int(c["slide"]) + int(c["stun"]) + int(c["silent"]) + int(c["brush"]) + int(c["land"]) + int(c["lid"])


# --- CE-1: the thin air's profile ---------------------------------------------------------

func test_ce1_thin_air_profile_is_smooth_and_bounded() -> void:
	var tu := FlightTuning.new()
	var band := tu.thin_air_band
	var flo := tu.thin_air_floor
	near(FlightEnv.thin_air(band, band, flo), 1.0, 1e-9, "full air at the band's start")
	near(FlightEnv.thin_air(band + 100.0, band, flo), 1.0, 1e-9, "full air below it")
	near(FlightEnv.thin_air(INF, band, flo), 1.0, 1e-9, "no ceiling: full air")
	near(FlightEnv.thin_air(flo, band, flo), 0.0, 1e-9, "no air at the floor gap")
	near(FlightEnv.thin_air(0.0, band, flo), 0.0, 1e-9, "no air at the lid")
	near(FlightEnv.thin_air(-3.0, band, flo), 0.0, 1e-9, "no air above it")
	# Monotonic, and C1 wherever there is air: the slope is 0 where the fade
	# starts (no kink where normal air ends) and continuous down to the floor
	# (s = 1 - (1 - u)^2: it changes by 2 h / L^2 per step h), where the air
	# is gone.
	var L := band - flo
	var h := 0.01
	var prev := -1.0
	var worst_jump := 0.0
	var bad := 0
	var g := flo + 2.0 * h
	while g <= band + 2.0:
		var s := FlightEnv.thin_air(g, band, flo)
		if s < prev - 1e-12:
			bad += 1
		prev = s
		var d0 := (FlightEnv.thin_air(g, band, flo) - FlightEnv.thin_air(g - h, band, flo)) / h
		var d1 := (FlightEnv.thin_air(g + h, band, flo) - FlightEnv.thin_air(g, band, flo)) / h
		worst_jump = maxf(worst_jump, absf(d1 - d0))
		g += 0.05
	eq(bad, 0, "the air only thins going up")
	lt(worst_jump, 2.0 * h / (L * L) + 1e-9, "the density's slope is continuous where there is air (C1)")
	near((FlightEnv.thin_air(band, band, flo) - FlightEnv.thin_air(band - h, band, flo)) / h, 0.0, 2.0 * h / (L * L) + 1e-9,
		"the fade starts with zero slope")
	# Where flapping birds level off (density 0.6-0.8) the slope is at most
	# 1.3 / L: gentler than a smoothstep's 1.5 / L at its middle.
	for sv: float in [0.6, 0.8]:
		var lo := flo
		var hi := band
		for it in 60:
			var mid := 0.5 * (lo + hi)
			if FlightEnv.thin_air(mid, band, flo) < sv:
				lo = mid
			else:
				hi = mid
		var slope := (FlightEnv.thin_air(lo + h, band, flo) - FlightEnv.thin_air(lo - h, band, flo)) / (2.0 * h)
		lt(slope * L, 1.3, "slope x band at density %.1f (%.3f; a smoothstep's middle is 1.5)" % [sv, slope * L])
	# The design's two ends: flight below 250 m under the 300 m lid is in
	# full air (the whole band lies above it), and the last 5 m under the
	# lid are dead air, which only momentum can cross (a thermal or a
	# flapping bird levels off below them).
	near(FlightEnv.thin_air(300.0 - 250.0, band, flo), 1.0, 1e-9, "below 250 m (300 m lid) the air is untouched")
	near(FlightEnv.thin_air(4.99, band, flo), 0.0, 1e-9, "the last 5 m under the lid are dead air")
	metric("band_m", band)
	metric("floor_m", flo)


# --- CE-2: every force fades with the air, the flap force too -----------------------------

## Two identical models, one substep from the same state mid-stroke: in air
## of density ratio s the lift, the drag and the flap force are s times
## those in full air (the root cause: round 6 faded lift and drag only).
func test_ce2_flap_force_lift_and_drag_fade_with_the_air() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for s: float in [0.6, 0.25]:
			var a := FS.model(sp)
			var b := FS.model(sp)
			var pv := Vector3(0, 50, 0)
			a.reset(pv, Vector3(0, 0, -a.params.v_c), 0.0)
			b.reset(pv, Vector3(0, 0, -b.params.v_c), 0.0)
			var cmd := FS.flap(a, 0.0, 0.0, 1.0)
			var wa := WingState.new()
			var wb := WingState.new()
			var ea := FlightEnv.new()
			var eb := FlightEnv.new()
			var h := 1.0 / 144.0
			# Into the middle of a downstroke (both in full air: identical).
			for i in 50:
				cmd.call(i, wa)
				cmd.call(i, wb)
				a.step(wa, ea, h)
				b.step(wb, eb, h)
			vnear(a.position, b.position, 1e-9, "%s: identical before the thin air" % sp)
			gt(a.f_flap.length(), 0.3 * a.params.mass * FS.G, "%s: mid-stroke (flap force %.2f W)" % [sp, a.f_flap.length() / (a.params.mass * FS.G)])
			# One substep: A in full air, B in air of ratio s.
			eb.lift_scale = s
			cmd.call(50, wa)
			cmd.call(50, wb)
			a.step(wa, ea, h)
			b.step(wb, eb, h)
			vnear(b.f_flap, a.f_flap * s, 1e-6 * a.f_flap.length(), "%s: flap force x %.2f in air of ratio %.2f" % [sp, s, s])
			vnear(b.f_lift, a.f_lift * s, 1e-6 * maxf(a.f_lift.length(), 1e-6), "%s: lift x %.2f" % [sp, s])
			vnear(b.f_drag, a.f_drag * s, 1e-6 * maxf(a.f_drag.length(), 1e-6), "%s: drag x %.2f" % [sp, s])
	# No air at all: no force but gravity, whatever the wings do (a hard
	# flapping hover included).
	var m := FS.model(&"sparrow")
	m.reset(Vector3(0, 50, 0), Vector3.ZERO, 0.0)
	var e := FlightEnv.new()
	e.lift_scale = 0.0
	var ws := WingState.new()
	var fl := FS.flap(m, 0.0, 0.0, 1.3)
	for i in 72:
		fl.call(i, ws)
		m.step(ws, e, DT)
	near(m.velocity.y, -FS.G * 1.0, 0.02, "in air of ratio 0 a flapping sparrow falls freely (vy after 1 s)")
	near(m.flap_n, 0.0, 1e-9, "no flap force in no air")


# --- CE-3: the verifier's scenario: flapping from 40 m under the lid ----------------------

## The stroke-mean vertical speed (a moving average over one stroke) and the
## hardest it ever falls over half a second from tick `from_i` on: what the
## player feels of a climb stopping (the wingbeat's own bob averages out).
static func _stroke_mean_decel(vys: PackedFloat64Array, hz: float, from_i := 0) -> float:
	var k := maxi(int(round(72.0 / hz)), 1)
	var mean := PackedFloat64Array()
	var acc := 0.0
	for i in vys.size():
		acc += vys[i]
		if i >= k:
			acc -= vys[i - k]
		if i >= k - 1:
			mean.append(acc / k)
	var w := 36
	var worst := 0.0
	for i in range(maxi(w, from_i), mean.size()):
		worst = maxf(worst, (mean[i - w] - mean[i]) / (w * DT))
	return worst


## Flies `sp` with symmetric strokes from `start_y` under a lid slab at
## `lid_y` (0: none, the fixture's 3000 m ceiling), recording the body's top
## under the ceiling, the vertical speed and the air's density ratio.
func _flap_run(sp: StringName, start_y: float, hz: float, amp: float, secs: float, lid_y: float) -> Dictionary:
	if lid_y > 0.0:
		await _lid_fx(sp, 0.0, lid_y)
	else:
		fx = FX.new(self)
		await fx.setup(sp)
	var p := fx.player
	var r := p.model.params.r_body
	var ceil_y := fx.world.ceiling
	p.start_flying(Vector3(0, start_y, 0), 0.0, 0.0)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
	fx.reset_events()
	var ts := PackedFloat64Array()
	var gaps := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var vys := PackedFloat64Array()
	var dens := PackedFloat64Array()
	fx.on_tick = func(i: int, f: Variant) -> void:
		var q: PlayerBird = f.player
		ts.append(i * DT)
		ys.append(q.model.position.y)
		gaps.append(ceil_y - (q.model.position.y + r))
		vys.append(q.model.velocity.y)
		dens.append(q.env.lift_scale)
	fx.run(secs)
	var top_gap := INF
	var t_top := 0.0
	for i in gaps.size():
		if gaps[i] < top_gap:
			top_gap = gaps[i]
			t_top = ts[i]
	var out := {"ts": ts, "ys": ys, "gaps": gaps, "vys": vys, "dens": dens, "top_gap": top_gap, "t_top": t_top,
		"contacts": _contacts(p), "stun": p.contacts["stun"], "collided": fx.events["collided"]}
	fx.assert_comfort(self, "%s %.1f Hz" % [sp, hz])
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func test_ce3_flapping_from_40_m_under_the_lid_never_touches_it() -> void:
	var secs := 40.0 if _full() else 16.0
	var flo := FlightTuning.new().thin_air_floor
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		for st: Array in [["reference", 1.3, 45.0], ["frantic", 2.0, 60.0]]:
			var hz: float = st[1]
			var o := await _flap_run(sp, LID - 40.0, hz, st[2], secs, LID)
			var gaps: PackedFloat64Array = o["gaps"]
			var climb := (gaps[0] - gaps[int(3.0 / DT)]) / 3.0
			var decel := _stroke_mean_decel(o["vys"], hz)
			var tag := "%s %s strokes (%.1f Hz, %.0f deg)" % [sp, st[0], hz, st[2]]
			print("[flight] CE-3 %s: top %.2f m under the lid at %.1f s, first 3 s %.2f m/s, stroke-mean deceleration %.2f m/s^2, contacts %d, stuns %d" % [
				tag, o["top_gap"], o["t_top"], climb, decel, o["contacts"], o["stun"]])
			eq(o["stun"], 0, "%s: never stunned" % tag)
			eq(o["contacts"], 0, "%s: never touches the lid (or anything)" % tag)
			eq(o["collided"], 0, "%s: no collision events" % tag)
			gt(climb, 1.0, "%s: climbs (%.2f m/s over the first 3 s)" % [tag, climb])
			# It stalls out in the thin air: the top of the climb stays out of
			# the dead air under the lid (and so far off the lid itself).
			gt(float(o["top_gap"]), flo + 5.0, "%s: levels off in the thin air (top %.2f m under the lid)" % [tag, o["top_gap"]])
			metric("%s_%s_top_gap" % [sp, st[0]], o["top_gap"])
			metric("%s_%s_decel" % [sp, st[0]], decel)
			if st[0] == "reference" and sp != &"starling":
				_plot_rows.append(["40 m under: " + String(sp), o])


# --- CE-4: circling in a thermal under the lid ---------------------------------------------

func test_ce4_thermal_circling_under_the_lid_never_reaches_it() -> void:
	var secs := 60.0 if _full() else 30.0
	var flo := FlightTuning.new().thin_air_floor
	# The verifier's cases: [species, flap Hz, amplitude, roll, pitch, air]
	# (air: "column" = the verifier's 4 m/s bell thermal, 60 m; "sky" = air
	# rising at 4 m/s everywhere, a glide straight ahead: no circle to drift
	# out of, the strongest and widest lift there could be).
	var cases: Array = [[&"sparrow", 2.0, 60.0, 0.3, 0.2, "column"], [&"eagle", 0.0, 0.0, 0.0, 0.6, "column"],
		[&"eagle", 0.0, 0.0, 0.0, 0.6, "sky"]]
	if _full():
		cases += [[&"sparrow", 0.0, 0.0, 0.0, 0.6, "column"], [&"pigeon", 2.0, 60.0, 0.3, 0.2, "column"],
			[&"starling", 0.0, 0.0, 0.0, 0.6, "column"], [&"pigeon", 0.0, 0.0, 0.0, 0.6, "column"],
			[&"sparrow", 1.3, 45.0, 0.3, 0.2, "column"], [&"sparrow", 0.0, 0.0, 0.0, 0.6, "sky"], [&"pigeon", 0.0, 0.0, 0.0, 0.0, "sky"]]
	for c: Array in cases:
		var sp: StringName = c[0]
		var hz: float = c[1]
		var amp: float = c[2]
		var pitch: float = c[4]
		var sky: bool = c[5] == "sky"
		await _lid_fx(sp, 0.0 if sky else 4.0)
		if sky:
			fx.world.set("uniform_wind", Vector3(0, 4.0, 0))
		var p := fx.player
		var pr := p.model.params
		var cal := p.wing_input.calibration
		var tr := p.model.trim_solution(pitch)
		var v: float = tr["v"]
		var rad := minf(v * v / (FS.G * tan(30.0 * DEG)), 40.0)
		p.start_flying(Vector3(0.0 if sky else -rad, LID - 30.0, 0), 0.0, 0.0)
		var roll: float = c[3] if hz > 0.0 else (0.0 if sky else 30.0 * DEG / pr.phi_max)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			b.synth(pitch, roll, 1.0, cal)
			if hz > 0.0:
				ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
		fx.reset_events()
		var st := {"top": INF, "t": 0.0, "up": 0.0}
		fx.on_tick = func(i: int, f: Variant) -> void:
			var q: PlayerBird = f.player
			var gap := LID - (q.model.position.y + pr.r_body)
			if gap < float(st["top"]):
				st["top"] = gap
				st["t"] = i * DT
			st["up"] = maxf(float(st["up"]), q.model.wind.y)
		fx.run(secs)
		var tag := ("%s gliding (pitch %.1f) in air rising 4 m/s everywhere" % [sp, pitch]) if sky else \
			("%s %s in a 4 m/s thermal" % [sp, ("circling, flapping %.1f Hz %.0f deg" % [hz, amp]) if hz > 0.0 else "soaring at 30 deg bank"])
		print("[flight] CE-4 %s: top %.2f m under the lid at %.1f s, contacts %d, stuns %d, end y %.1f" % [tag, st["top"], st["t"], _contacts(p), p.contacts["stun"], p.model.position.y])
		gt(float(st["up"]), 3.0, "%s: the thermal lifted it (%.2f m/s)" % [tag, st["up"]])
		eq(p.contacts["stun"], 0, "%s: never stunned" % tag)
		eq(_contacts(p), 0, "%s: never touches the lid" % tag)
		gt(float(st["top"]), flo, "%s: the thermal cannot lift it through the thin air (top %.2f m under the lid)" % [tag, st["top"]])
		fx.assert_comfort(self, tag)
		metric("%s_%s_top_gap" % [sp, "sky" if sky else ("flap" if hz > 0.0 else "soar")], st["top"])
		fx.teardown()
		fx = null
		await get_tree().process_frame


# --- CE-5: arriving from below: untouched below 250 m, then a gentle level-off ------------

## The game's usual case: a bird flapping up from 205 m under the 300 m lid,
## and the same flight under the fixture's 3000 m ceiling. Below 250 m the
## two are the same flight to the bit (the thin air starts at 255 m for the
## body's top), so the climb rate there is the same. Above, the climb
## levels off in the thin air without touching the lid, and its stroke-mean
## deceleration stays under a quarter of g. For scale (the ceiling diag,
## tests/shots/flight_ceiling_diag_test.gd): the player stopping the wings
## in mid-climb decelerates the same climbs at 4.9-7.4 m/s^2 (0.5-0.75 g);
## the old lid reversed them at ~13 m/s^2, and stunned.
func test_ce5_arriving_from_below_untouched_below_250_m_then_levels_off_gently() -> void:
	var cases: Array = [[&"sparrow", 1.3, 45.0], [&"eagle", 1.3, 45.0]]
	if _full():
		cases += [[&"pigeon", 2.0, 60.0], [&"starling", 1.3, 45.0], [&"starling", 2.0, 60.0], [&"pigeon", 1.3, 45.0], [&"sparrow", 1.0, 40.0]]
	var band := FlightTuning.new().thin_air_band
	var flo := FlightTuning.new().thin_air_floor
	for c: Array in cases:
		var sp: StringName = c[0]
		var hz: float = c[1]
		var amp: float = c[2]
		var tag := "%s %.1f Hz %.0f deg" % [sp, hz, amp]
		var lid := await _flap_run(sp, 205.0, hz, amp, 25.0 if not _full() else 45.0, 300.0)
		var free := await _flap_run(sp, 205.0, hz, amp, 16.0 if _full() else 12.5, 0.0)
		var a: PackedFloat64Array = lid["ys"]
		var b: PackedFloat64Array = free["ys"]
		var n := 0
		var worst := 0.0
		while n < b.size() and b[n] < 250.0:
			worst = maxf(worst, absf(a[n] - b[n]))
			n += 1
		var rate_lid := (a[n - 1] - a[0]) / (n * DT)
		var rate_free := (b[n - 1] - b[0]) / (n * DT)
		var gaps: PackedFloat64Array = lid["gaps"]
		var i_band := 0
		while i_band < gaps.size() and gaps[i_band] >= band:
			i_band += 1
		var decel := _stroke_mean_decel(lid["vys"], hz, maxi(i_band - 36, 0))
		print("[flight] CE-5 %s: 205 -> 250 m in %.1f s at %.3f m/s under the 300 m lid, %.3f m/s under the 3000 m ceiling (largest height difference %.6f m); into the thin air at %.1f s, top %.2f m under the lid at %.1f s, stroke-mean deceleration %.2f m/s^2, contacts %d" % [
			tag, n * DT, rate_lid, rate_free, worst, i_band * DT, lid["top_gap"], lid["t_top"], decel, lid["contacts"]])
		check(n < b.size(), "%s: the climb reaches 250 m within the full-air run (%.1f s)" % [tag, b.size() * DT])
		near(worst, 0.0, 0.0, "%s: the same flight to the bit below 250 m" % tag)
		near(rate_lid, rate_free, 0.0, "%s: the same climb rate below 250 m (%.3f m/s)" % [tag, rate_free])
		check(i_band < gaps.size(), "%s: reaches the thin air" % tag)
		eq(lid["contacts"], 0, "%s: never touches the lid" % tag)
		gt(float(lid["top_gap"]), flo + 5.0, "%s: levels off in the thin air (top %.2f m under the lid)" % [tag, lid["top_gap"]])
		lt(decel, 0.25 * FS.G, "%s: the thin air stops the climb gently (stroke-mean deceleration %.2f m/s^2)" % [tag, decel])
		metric("%s_%.1fHz_climb_rate_below_250" % [sp, hz], rate_lid)
		metric("%s_%.1fHz_arrival_decel" % [sp, hz], decel)
		if hz == 1.3:
			_plot_rows.append(["from 205 m: " + String(sp), lid])


# --- CE-6: momentum into the lid: a slide, never a stun -------------------------------------

## The body's top 1 m under the lid, rising at 8 m/s (6.7 m/s at the lid:
## over the sparrow's and pigeon's stun speed). Only momentum crosses the
## dead air, so this is the only way up there.
func test_ce6_a_zoom_into_the_lid_slides_and_never_stuns() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		await _lid_fx(sp)
		var p := fx.player
		var pr := p.model.params
		var start := Vector3(0, LID - pr.r_body - 1.0, 0)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, 8.0, -pr.v_c), 0.0)
		fx.reset_events()
		var st := {"stunned": 0, "top": INF}
		fx.on_tick = func(_i: int, f: Variant) -> void:
			var q: PlayerBird = f.player
			if q.mode == PlayerBird.Mode.STUNNED:
				st["stunned"] += 1
			st["top"] = minf(float(st["top"]), LID - (q.model.position.y + pr.r_body))
		fx.run(1.0)
		var vh := Vector2(p.model.velocity.x, p.model.velocity.z).length()
		var imp := float(fx.collide_impacts[0]) if fx.collide_impacts.size() > 0 else 0.0
		print("[flight] CE-6 %s: contacts %s, collided %d (impact %.2f m/s, stun speed %.2f), mode %s, speed along the lid %.2f m/s" % [
			sp, str(p.contacts), fx.events["collided"], imp, maxf(0.35 * pr.v_c, 2.0), p.mode_name(), vh])
		eq(p.contacts["lid"], 1, "%s: the zoom reaches the lid once" % sp)
		eq(p.contacts["slide"], 1, "%s: a slide" % sp)
		eq(p.contacts["stun"], 0, "%s: never a stun" % sp)
		eq(st["stunned"], 0, "%s: never stunned" % sp)
		if sp != &"eagle":
			gt(imp, maxf(0.35 * pr.v_c, 2.0), "%s: at a speed that stuns against a wall (%.2f m/s)" % [sp, imp])
		gt(float(st["top"]), -0.01, "%s: never through the lid" % sp)
		eq(p.mode, PlayerBird.Mode.FLYING, "%s: flies on" % sp)
		gt(vh, 0.9 * pr.v_c, "%s: keeps its speed along the lid (%.2f m/s)" % [sp, vh])
		fx.assert_comfort(self, "%s zoom" % sp)
		fx.teardown()
		fx = null
		await get_tree().process_frame


# --- evidence plot -----------------------------------------------------------------------

func test_ce_zz_plot() -> void:
	if _plot_rows.is_empty():
		return
	var tu := FlightTuning.new()
	var pl := FlightPlot.new(1600, 1000, "CE: flapping under the arena's lid (reference strokes, 1.3 Hz 45 deg)")
	pl.note("The air thins over the last %.0f m under World.ceiling (FlightEnv.thin_air: 1 - (1 - u)^2, to nothing %.0f m under the lid) and the flap force fades with lift and drag, so every climb levels off in the thin air: no contact, no stun. Left: the verifier's r7x scenario, from 40 m under the lid (before the fix every size hit the lid about 9 s in and bounced off it again and again: artifacts/flight/verify/r7x/r7x_ceiling_lid.png). Right: arriving from 205 m under a 300 m lid, the game's usual case." % [tu.thin_air_band, tu.thin_air_floor])
	var W := 690
	var H := 250
	var x2 := 70 + W + 100
	var p1 := pl.panel(Rect2i(70, 210, W, H), "40 m under: top of the body - ceiling (m)", "t (s)", "m")
	var p2 := pl.panel(Rect2i(70, 210 + H + 90, W, H), "40 m under: vertical speed (m/s)", "t (s)", "m/s")
	var p3 := pl.panel(Rect2i(x2, 210, W, H), "From 205 m: top of the body - ceiling (m)", "t (s)", "m")
	var p4 := pl.panel(Rect2i(x2, 210 + H + 90, W, H), "From 205 m: air density ratio", "t (s)", "")
	var s1 := 0
	var s2 := 0
	for rw in _plot_rows:
		var lbl: String = rw[0]
		var o: Dictionary = rw[1]
		var ts: PackedFloat64Array = o["ts"]
		var neg := PackedFloat64Array()
		for gv in (o["gaps"] as PackedFloat64Array):
			neg.append(-gv)
		var name := lbl.substr(lbl.find(": ") + 2)
		if lbl.begins_with("40 m"):
			p1.line(ts, neg, s1, name)
			p2.line(ts, o["vys"], s1, name)
			s1 += 1
		else:
			p3.line(ts, neg, s2, name)
			p4.line(ts, o["dens"], s2, name)
			s2 += 1
	p1.set_y(-46.0, 12.0)
	p3.set_y(-100.0, 50.0)
	for pp in [p1, p3]:
		pp.hline(0.0, FlightPlot.AXIS, "lid (World.ceiling)")
		pp.hline(-tu.thin_air_floor, FlightPlot.AXIS, "no air")
		pp.hline(-tu.thin_air_band, FlightPlot.AXIS, "thin air starts")
	p2.hline(0.0, FlightPlot.AXIS)
	p4.set_y(0.0, 1.3)
	var path := Paths.artifacts("flight").path_join("ceiling/ce_lid%s.png" % ("_full" if _full() else ""))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	eq(pl.save(path), OK, "plot saved")
	print("[flight] CE plot: ", path)
