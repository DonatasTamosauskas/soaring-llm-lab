extends RefCounted
## Flies the FlightCourse with the bot pilot on a real PlayerBird (B1) and
## records everything the tests and plots need. Shared by bot_course_test.gd
## and tests/shots/flight_plots.gd.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0

var fx: FX
var course: FlightCourse
var pilot: FlightAutopilot
var bot: BotPoseSource
var species: StringName
var rec := {"t": PackedFloat64Array(), "x": PackedFloat64Array(), "y": PackedFloat64Array(), "z": PackedFloat64Array(),
	"v": PackedFloat64Array(), "bank": PackedFloat64Array(), "pitch_in": PackedFloat64Array(), "roll_in": PackedFloat64Array(),
	"flap": PackedFloat64Array(), "phase": PackedInt32Array(), "alpha": PackedFloat64Array()}
var window_err := Vector2(INF, INF)     # (lateral, vertical) at the wall plane
var window_crossed := false
var window_speed := 0.0
var perched_t := -1.0
var perched_on_target := false
var limit_s := 0.0


func _init(p_fx: FX, sp: StringName) -> void:
	fx = p_fx
	species = sp


## A seeded run: the bot's body (tremor, twist noise) and novice noise.
func setup(novice := false, preset := 1, seed := 21) -> void:
	course = FlightCourse.new(FlightParams.species_mass(species))
	var c := course
	await fx.setup(species, func(w: Variant) -> void:
		c.build(w, false, false))
	var p := fx.player
	if preset != 1:
		var tu := p.tuning.duplicate() as FlightTuning
		tu.preset = preset
		p.tuning = tu
		p.model.set_tuning(tu)
	pilot = FlightAutopilot.new(p.model.params, course)
	var pl := p
	bot = BotPoseSource.new(pilot, func() -> Dictionary:
		return {"pos": pl.model.position, "vel": pl.model.velocity, "airspeed": pl.model.airspeed()}, 21)
	bot.calibration = p.wing_input.calibration
	bot.body.set_seed(seed)
	bot.rng.seed = seed
	bot.set_novice(novice)
	p.set_pose_source(bot)
	p.start_flying(course.start.origin, 0.0, 0.0)
	limit_s = 1.6 * course.length_to_perch() / course.v_c + 10.0


## The window crossing, the first stun (-1 if none) and whether the bird
## was still flying when it crossed.
var stun_t := -1.0


## Flies the course; with stop_at_window the run ends just past the window
## (B2 measures window + turn completion only).
func fly(stop_at_window := false) -> void:
	var p := fx.player
	var z_wall := course.window_center.z
	var prev_z := p.model.position.z
	var n := int(ceil(limit_s / DT))
	for i in n:
		fx.step()
		var pos := p.model.position
		var r := rec
		r["t"].append(i * DT)
		r["x"].append(pos.x)
		r["y"].append(pos.y)
		r["z"].append(pos.z)
		r["v"].append(p.model.airspeed())
		r["bank"].append(rad_to_deg(p.model.phi))
		r["pitch_in"].append(p.wing_state().pitch)
		r["roll_in"].append(p.telemetry()["roll_input"])
		r["flap"].append(0.5 * (p.wing_state().flap_l + p.wing_state().flap_r))
		r["phase"].append(pilot.phase)
		r["alpha"].append(rad_to_deg(p.model.alpha))
		if not window_crossed and pos.x > 0.5 * course.offset and prev_z < z_wall and pos.z >= z_wall:
			window_crossed = true
			window_err = Vector2(pos.x - course.window_center.x, pos.y - course.window_center.y)
			window_speed = p.model.airspeed()
		prev_z = pos.z
		if stun_t < 0.0 and p.mode == PlayerBird.Mode.STUNNED:
			stun_t = i * DT
		if stop_at_window and window_crossed and pos.z > z_wall + 2.0 * course.span:
			break
		if stop_at_window and stun_t >= 0.0:
			break
		if p.mode == PlayerBird.Mode.PERCHED:
			perched_t = i * DT
			perched_on_target = p.perch == course.perch
			pilot.mark_done()
			break


## Crossed the window inside the opening's clearance, not stunned before.
func window_ok(frac := 1.0) -> bool:
	var c := course
	var tol := Vector2(c.span - c.r_body, 0.75 * c.span - c.r_body)
	return window_crossed and stun_t < 0.0 and absf(window_err.x) <= frac * tol.x \
		and absf(window_err.y) <= frac * tol.y


func worst_window_frac() -> float:
	var c := course
	var tol := Vector2(c.span - c.r_body, 0.75 * c.span - c.r_body)
	return maxf(absf(window_err.x) / tol.x, absf(window_err.y) / tol.y)


func csv(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("t,x,y,z,V,bank_deg,alpha_deg,pitch_in,roll_in,flap,phase")
	for i in rec["t"].size():
		f.store_line("%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.3f,%.3f,%.3f,%d" % [rec["t"][i], rec["x"][i], rec["y"][i], rec["z"][i],
			rec["v"][i], rec["bank"][i], rec["alpha"][i], rec["pitch_in"][i], rec["roll_in"][i], rec["flap"][i], rec["phase"][i]])


## The B1 figure: top view, side view (along-track altitude), airspeed and
## the pilot's arm-derived commands.
func plot(path: String) -> void:
	var c := course
	var pl := FlightPlot.new(1600, 900, "Bot pilot course: %s (poses only)" % species)
	pl.note("window error lat %+.3f m, vert %+.3f m (tolerance %.3f / %.3f); perched %s at %.1f s (limit %.0f s); stuns %d, frame hits %d" % [
		window_err.x, window_err.y, c.span - c.r_body, 0.75 * c.span - c.r_body, str(perched_on_target), perched_t, limit_s,
		fx.player.contacts["stun"], fx.player.contacts["slide"]])
	var top := pl.panel(Rect2i(80, 110, 700, 330), "Top view", "x (m)", "z (m)")
	top.equal_aspect = true
	var px := PackedFloat64Array()
	var pz := PackedFloat64Array()
	for q in c.path:
		px.append(q.x)
		pz.append(-q.z)
	top.line(px, pz, 0, "planned path", 1, FlightPlot.MUTED)
	top.line(rec["x"], FlightPlot_neg(rec["z"]), 0, "flown")
	top.segment(Vector2(c.window_center.x - 10.0, -c.window_center.z), Vector2(c.window_center.x + 10.0, -c.window_center.z), FlightPlot.INK, 3, "window wall")
	top.points(PackedFloat64Array([c.perch_grip.x]), PackedFloat64Array([-c.perch_grip.z]), 1, "perch", 5)
	var side := pl.panel(Rect2i(880, 110, 680, 330), "Side view (return leg)", "z (m)", "alt (m)")
	var sz := PackedFloat64Array()
	var sy := PackedFloat64Array()
	for i in rec["t"].size():
		if rec["x"][i] > 0.5 * c.offset:
			sz.append(rec["z"][i])
			sy.append(rec["y"][i])
	side.line(sz, sy, 0, "altitude")
	side.rect_data(Rect2(c.window_center.z - c.wall_thick * 0.5, c.window_center.y - 0.5 * c.window_h, c.wall_thick, c.window_h), FlightPlot.INK, "window")
	side.points(PackedFloat64Array([c.perch_grip.z]), PackedFloat64Array([c.perch_grip.y]), 1, "perch", 5)
	var sp := pl.panel(Rect2i(80, 520, 700, 300), "Airspeed", "t (s)", "m/s")
	sp.line(rec["t"], rec["v"], 0, "airspeed")
	sp.hline(c.v_c, FlightPlot.series_color(2), "V_c")
	sp.hline(fx.player.model.params.v_min, FlightPlot.series_color(7), "V_min")
	sp.legend_pos = 2
	var cm := pl.panel(Rect2i(880, 520, 680, 300), "Commands read from the arms", "t (s)", "")
	cm.line(rec["t"], rec["pitch_in"], 0, "pitch (wrists)")
	cm.line(rec["t"], rec["roll_in"], 1, "roll (wrists)")
	cm.line(rec["t"], rec["flap"], 2, "flap effort")
	cm.set_y(-1.1, 1.3)
	pl.save(path)


static func FlightPlot_neg(a: PackedFloat64Array) -> PackedFloat64Array:
	var o := PackedFloat64Array()
	o.resize(a.size())
	for i in a.size():
		o[i] = -a[i]
	return o
