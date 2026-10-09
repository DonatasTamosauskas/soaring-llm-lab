extends TestCase
## Flight diagnostic (integration: the ceiling fix). The verifier's lid
## scenarios (tests/probes/flight/r7x_experience_probe_test.gd, sections 3
## and the climb diagnostic) plus the real world's 300 m lid, reported per
## case: the highest point under the lid, every contact, the climb rate, and
## the bob at the top. Informative (the pinned tests are in
## tests/unit/flight/ceiling_test.gd).
##   tools/gd.sh flceil --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_ceiling_diag
## Output: artifacts/flight/ceiling/diag_<tag>.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0

var fx: FX
var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight] ", s)


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var tag: String = Paths.arg("tag", "now")
	var path := Paths.artifacts("flight").path_join("ceiling/diag_%s.txt" % tag)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


## One run under a slab lid at ceil_y. Returns the numbers.
func _run(sp: StringName, ceil_y: float, start_below: float, seconds: float, hz: float, amp: float,
		thermal: float, roll: float, pitch: float, circle: bool) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		if thermal > 0.0:
			w.thermal_core = thermal
			w.thermal_center = Vector3.ZERO
			w.thermal_radius = 60.0
		FlightGeometry.box(w, Vector3(0, ceil_y + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
	fx.world.ceiling = ceil_y
	var p := fx.player
	var pr := p.model.params
	var cal := p.wing_input.calibration
	var start := Vector3(0, ceil_y - start_below, 0)
	if circle:
		var tr := p.model.trim_solution(pitch)
		var v: float = tr["v"]
		var rad := minf(v * v / (9.81 * tan(30.0 * DEG)), 40.0)
		start.x = -rad
	p.start_flying(start, 0.0, 0.0)
	var roll_cmd := roll
	if circle and hz <= 0.0:
		roll_cmd = 30.0 * DEG / pr.phi_max
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if roll_cmd != 0.0 or pitch != 0.0:
			b.synth(pitch, roll_cmd, 1.0, cal)
		if hz > 0.0:
			ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
	var st := {"top": -INF, "t_top": 0.0, "y_at": {}, "lo2": INF, "hi2": -INF, "stuns": 0, "prev": p.mode, "near_lid": 0, "c_prev": 0}
	fx.reset_events()
	var t_us := Time.get_ticks_usec()
	fx.on_tick = func(i: int, f: Variant) -> void:
		var q: PlayerBird = f.player
		var top := q.model.position.y + q.model.params.r_body
		if top > float(st["top"]):
			st["top"] = top
			st["t_top"] = i * DT
		for ts: float in [1.0, 3.0, 5.0, 8.0]:
			if absf(i * DT - ts) < 0.5 * DT:
				st["y_at"][ts] = q.model.position.y
		if i * DT > seconds * 0.5:
			st["lo2"] = minf(float(st["lo2"]), top)
			st["hi2"] = maxf(float(st["hi2"]), top)
		# Contacts made with the body's top within 2 m of the lid (the lid's,
		# whatever their kind; ground contacts are not the lid's).
		var c: Dictionary = q.contacts
		var call: int = c["slide"] + c["stun"] + c["silent"] + c["brush"] + c["land"]
		if call > int(st["c_prev"]) and ceil_y - top < 2.0:
			st["near_lid"] = int(st["near_lid"]) + call - int(st["c_prev"])
		st["c_prev"] = call
	fx.run(seconds)
	var ya: Dictionary = st["y_at"]
	var climb := (float(ya.get(5.0, 0.0)) - float(ya.get(1.0, 0.0))) / 4.0
	var nc: int = p.contacts["slide"] + p.contacts["stun"] + p.contacts["silent"] + p.contacts["brush"] + p.contacts["land"]
	var out := {"gap": ceil_y - float(st["top"]), "t_top": st["t_top"], "contacts": nc, "stun": p.contacts["stun"],
		"lid": int(st["near_lid"]),
		"slide": p.contacts["slide"], "silent": p.contacts["silent"], "collided": fx.events["collided"],
		"climb": climb, "bob": float(st["hi2"]) - float(st["lo2"]), "low2": ceil_y - float(st["hi2"]),
		"end_y": p.model.position.y, "mode": p.mode_name(), "ms": (Time.get_ticks_usec() - t_us) / 1000.0,
		"stalls": fx.events["stalled"]}
	fx.teardown()
	fx = null
	await get_tree().process_frame
	return out


func _fmt(tag: String, r: Dictionary) -> String:
	return "%s: top gap %.2f m (at %.1f s), 2nd half gap %.2f..%.2f m (bob %.2f m), lid contacts %d, all contacts %d (stun %d slide %d silent %d), collided %d, climb(1-5 s) %.2f m/s, stalls %d, end y %.1f %s [%.0f ms]" % [
		tag, r["gap"], r["t_top"], r["low2"], r["low2"] + r["bob"], r["bob"], r["lid"], r["contacts"], r["stun"], r["slide"], r["silent"],
		r["collided"], r["climb"], r["stalls"], r["end_y"], r["mode"], r["ms"]]


func test_climb_under_lid() -> void:
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		for s: Array in [[1.3, 45.0, "reference"], [2.0, 60.0, "frantic"], [1.0, 40.0, "slow"]]:
			var r := await _run(sp, 80.0, 40.0, 40.0, s[0], s[1], 0.0, 0.0, 0.0, false)
			_log(_fmt("[climb] %s %s %.1f Hz %.0f deg" % [sp, s[2], s[0], s[1]], r))
			eq(r["stun"], 0, "%s %s: no stun" % [sp, s[2]])
			eq(r["lid"], 0, "%s %s: no lid contact" % [sp, s[2]])
	var r2 := await _run(&"sparrow", 80.0, 40.0, 40.0, 1.3, 45.0, 0.0, 0.5, 0.0, false)
	_log(_fmt("[climb] sparrow reference roll 0.5", r2))
	eq(r2["lid"], 0, "sparrow reference roll 0.5: no lid contact")


func test_thermal_under_lid() -> void:
	# [species, flap hz, amp, roll, pitch]
	for c: Array in [[&"sparrow", 2.0, 60.0, 0.3, 0.2], [&"sparrow", 0.0, 0.0, 0.0, 0.6], [&"starling", 2.0, 60.0, 0.3, 0.2],
			[&"pigeon", 2.0, 60.0, 0.3, 0.2], [&"pigeon", 0.0, 0.0, 0.0, 0.6], [&"eagle", 0.0, 0.0, 0.0, 0.6],
			[&"eagle", 2.0, 60.0, 0.3, 0.2], [&"sparrow", 1.3, 45.0, 0.3, 0.2]]:
		var r := await _run(c[0], 80.0, 30.0, 60.0, c[1], c[2], 4.0, c[3], c[4], true)
		_log(_fmt("[thermal] %s %s" % [c[0], ("flap %.1f Hz %.0f deg roll %.1f" % [c[1], c[2], c[3]]) if c[1] > 0.0 else "soaring 30 deg"], r))
		eq(r["stun"], 0, "%s thermal: no stun" % c[0])
		eq(r["lid"], 0, "%s thermal: no lid contact" % c[0])


## Below the fade the lid changes nothing: the same climb under a 300 m and
## a 3000 m ceiling, from 200 m, compared while the body's top is below 250 m.
func test_normal_climb_unaffected() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var tr := []
		for ceil_y: float in [300.0, 3000.0]:
			fx = FX.new(self)
			await fx.setup(sp)
			fx.world.ceiling = ceil_y
			var p := fx.player
			p.start_flying(Vector3(0, 200.0, 0), 0.0, 0.0)
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				ScriptedPoseSource.flap(b, t + 0.5, 60.0, 2.0)
			var ys := PackedFloat64Array()
			fx.on_tick = func(_i: int, f: Variant) -> void:
				ys.append(f.player.model.position.y)
			fx.run(20.0)
			tr.append(ys)
			fx.teardown()
			fx = null
			await get_tree().process_frame
		var a: PackedFloat64Array = tr[0]
		var b: PackedFloat64Array = tr[1]
		var worst := 0.0
		var n := 0
		var t250 := -1.0
		for i in mini(a.size(), b.size()):
			if b[i] > 250.0 - 0.3:
				t250 = i * DT
				break
			worst = maxf(worst, absf(a[i] - b[i]))
			n += 1
		var rate := (b[maxi(n - 1, 0)] - b[0]) / maxf(n * DT, DT)
		_log("[normal] %s frantic from 200 m: identical to the 3000 m ceiling up to 250 m within %.6f m over %d ticks (reached 250 m at %.1f s, %.2f m/s); at 20 s y %.1f (300 m lid) vs %.1f (3000 m)" % [
			sp, worst, n, t250, rate, a[a.size() - 1], b[b.size() - 1]])
		lt(worst, 1e-4, "%s: the climb below 250 m is unchanged" % sp)


## The real world's lid (scenes/world/world.tscn), from 40 m below it at the
## spawn: reference and frantic strokes.
func test_real_world_lid() -> void:
	var ws := load("res://scenes/world/world.tscn") as PackedScene
	var world := ws.instantiate() as World
	add_child(world)
	var n := 0
	while not world.is_generated and n < 600:
		await get_tree().process_frame
		n += 1
	check(world.is_generated, "the real world generates")
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		for s: Array in [[1.3, 45.0], [2.0, 60.0]]:
			fx = FX.new(self)
			await fx.setup(sp)
			var tw := fx.world
			tw.get_parent().remove_child(tw)
			tw.free()
			fx.world = world
			var p := fx.player
			var spawn := world.get_player_spawn().origin
			var start := Vector3(spawn.x, world.ceiling - 40.0, spawn.z)
			p.start_flying(start, 0.0, 0.0)
			var hz: float = s[0]
			var amp: float = s[1]
			fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
			fx.reset_events()
			var st := {"top": -INF}
			fx.on_tick = func(_i: int, f: Variant) -> void:
				var q: PlayerBird = f.player
				st["top"] = maxf(float(st["top"]), q.model.position.y + q.model.params.r_body)
			fx.run(40.0)
			var nc: int = p.contacts["slide"] + p.contacts["stun"] + p.contacts["silent"] + p.contacts["brush"]
			_log("[real world] %s %.1f Hz %.0f deg from %.0f m: top gap %.2f m, contacts %d (stun %d), collided %d, end y %.1f %s" % [
				sp, hz, amp, start.y, world.ceiling - float(st["top"]), nc, p.contacts["stun"], fx.events["collided"], p.model.position.y, p.mode_name()])
			eq(p.contacts["stun"], 0, "%s: no stun under the real lid" % sp)
			fx.world = null
			fx.teardown()
			fx = null
			await get_tree().process_frame
	world.get_parent().remove_child(world)
	world.queue_free()
	await get_tree().process_frame


## Trace one case every 0.5 s (--case=starling,2.0,60,0.3,0.2,4.0 : species, hz, amp, roll, pitch, thermal).
func test_trace() -> void:
	var cs: String = Paths.arg("case", "")
	check(true, "trace: --case given or skipped")
	if cs.is_empty():
		return
	var a := cs.split(",")
	var sp := StringName(a[0])
	var hz := float(a[1])
	var amp := float(a[2])
	var roll := float(a[3])
	var pitch := float(a[4])
	var thermal := float(a[5])
	var ceil_y := float(Paths.arg("ceil", "80"))
	var below := float(Paths.arg("below", "30"))
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		if thermal > 0.0:
			w.thermal_core = thermal
			w.thermal_center = Vector3.ZERO
			w.thermal_radius = 60.0
		FlightGeometry.box(w, Vector3(0, ceil_y + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
	fx.world.ceiling = ceil_y
	var p := fx.player
	var pr := p.model.params
	var cal := p.wing_input.calibration
	var tr := p.model.trim_solution(pitch)
	var v: float = tr["v"]
	var rad := minf(v * v / (9.81 * tan(30.0 * DEG)), 40.0)
	p.start_flying(Vector3(-rad if thermal > 0.0 else 0.0, ceil_y - below, 0), 0.0, 0.0)
	fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if roll != 0.0 or pitch != 0.0:
			b.synth(pitch, roll, 1.0, cal)
		if hz > 0.0:
			ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
	fx.on_tick = func(i: int, f: Variant) -> void:
		if i % 36 != 0:
			return
		var q: PlayerBird = f.player
		var m := q.model
		_log("t %5.1f y %6.2f vy %+5.2f V %5.2f vh %5.2f bank %+5.1f th %+5.1f aoa %+5.1f st %s end %.2f ls %.2f flapN/W %.2f lift/W %.2f r %.1f wind %.2f mode %s" % [
			i * DT, m.position.y, m.velocity.y, m.airspeed(), Vector2(m.velocity.x, m.velocity.z).length(), rad_to_deg(m.phi), rad_to_deg(m.theta),
			rad_to_deg(m.alpha), m.stalled, minf(m.endurance_l, m.endurance_r), q.env.lift_scale, m.flap_n / (pr.mass * 9.81), m.lift_n / (pr.mass * 9.81),
			Vector2(m.position.x, m.position.z).length(), m.wind.y, q.mode_name()])
	fx.run(float(Paths.arg("secs", "60")))


## Momentum alone into the lid (a zoom): the body's top 1 m under it, rising
## at 8 m/s while flying on at cruise (4.4-6.5 m/s at the lid, over v_stun
## for the sparrow and the pigeon).
func test_zoom_into_lid() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		fx = FX.new(self)
		await fx.setup(sp, func(w: Variant) -> void:
			FlightGeometry.box(w, Vector3(0, 80.0 + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
		fx.world.ceiling = 80.0
		var p := fx.player
		var pr := p.model.params
		var start := Vector3(0, 80.0 - pr.r_body - 1.0, 0)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, 8.0, -pr.v_c), 0.0)
		fx.reset_events()
		fx.run(3.0)
		_log("[zoom] %s: contacts %s, collided %d (impacts %s), mode %s, y %.2f, v %s" % [sp, str(p.contacts), fx.events["collided"],
			str(fx.collide_impacts), p.mode_name(), p.model.position.y, p.model.velocity.snapped(Vector3.ONE * 0.01)])
		eq(p.contacts["stun"], 0, "%s: a zoom into the lid never stuns" % sp)
		gt(p.contacts["lid"], 0, "%s: the zoom reached the lid" % sp)
		fx.teardown()
		fx = null
		await get_tree().process_frame


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


## Reference for the level-off's feel: the same strokes in full air
## (3000 m ceiling) stopped after 5 s (the player stops flapping mid-climb,
## arms held out), and the level-off under the lid, both measured from 1.5 s.
func test_stop_flapping_reference() -> void:
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		for s: Array in [[1.3, 45.0], [2.0, 60.0]]:
			var out := []
			for kind: String in ["stop", "lid", "free"]:
				fx = FX.new(self)
				var lid := kind == "lid"
				await fx.setup(sp, func(w: Variant) -> void:
					if lid:
						FlightGeometry.box(w, Vector3(0, 85.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
				if lid:
					fx.world.ceiling = 80.0
				var p := fx.player
				p.start_flying(Vector3(0, 40.0, 0), 0.0, 0.0)
				var hz: float = s[0]
				var amp: float = s[1]
				fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					if kind != "stop" or t < 5.0:
						ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
				var vys := PackedFloat64Array()
				fx.on_tick = func(_i: int, f: Variant) -> void:
					vys.append(f.player.model.velocity.y)
				fx.run(20.0)
				out.append(_stroke_mean_decel(vys, hz, int(1.5 / DT)))
				out.append(vys)
				fx.teardown()
				fx = null
				await get_tree().process_frame
			var dif := PackedFloat64Array()
			var la: PackedFloat64Array = out[3]
			var fr: PackedFloat64Array = out[5]
			for i in la.size():
				dif.append(la[i] - fr[i])
			var extra := _stroke_mean_decel(dif, s[0], 0)
			finite(extra, "feel metrics are numbers")
			_log("[feel] %s %.1f Hz %.0f deg: stroke-mean deceleration when the player stops flapping mid-climb %.2f m/s^2; the thin air's level-off %.2f m/s^2; flapping on in full air %.2f m/s^2; the thin air's own share %.2f m/s^2" % [sp, s[0], s[1], out[0], out[2], out[4], extra])


## Arriving at the thin air from below (the game's usual case): flapping
## from 100 m under a 150 m lid, and the same flight in full air. The
## stroke-mean deceleration from the band's entry on, lid vs full air.
func test_arrival_from_below() -> void:
	var ceil_y := 150.0
	var band := FlightTuning.new().thin_air_band
	for sp: StringName in [&"sparrow", &"starling", &"pigeon", &"eagle"]:
		for s: Array in [[1.3, 45.0], [2.0, 60.0]]:
			var out := []
			for kind: String in ["lid", "free"]:
				fx = FX.new(self)
				var lid := kind == "lid"
				await fx.setup(sp, func(w: Variant) -> void:
					if lid:
						FlightGeometry.box(w, Vector3(0, ceil_y + 5.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
				if lid:
					fx.world.ceiling = ceil_y
				var p := fx.player
				var r := p.model.params.r_body
				p.start_flying(Vector3(0, ceil_y - 100.0, 0), 0.0, 0.0)
				var hz: float = s[0]
				var amp: float = s[1]
				fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
					b.set_airplane()
					ScriptedPoseSource.flap(b, t + 0.5, amp, hz)
				var vys := PackedFloat64Array()
				var gaps := PackedFloat64Array()
				fx.on_tick = func(_i: int, f: Variant) -> void:
					vys.append(f.player.model.velocity.y)
					gaps.append(ceil_y - f.player.model.position.y - r)
				fx.run(45.0)
				out.append(vys)
				out.append(gaps)
				fx.teardown()
				fx = null
				await get_tree().process_frame
			var gl: PackedFloat64Array = out[1]
			var i_band := -1
			for i in gl.size():
				if gl[i] < band:
					i_band = i
					break
			var top := INF
			for gv in gl:
				top = minf(top, gv)
			var settle := 0.0
			for i in range(gl.size() - 720, gl.size()):
				settle += gl[i] / 720.0
			var from_i := maxi(i_band - 36, 0)
			var dl := _stroke_mean_decel(out[0], s[0], from_i)
			var df := _stroke_mean_decel(out[2], s[0], from_i)
			finite(dl, "arrival metrics are numbers")
			_log("[arrival] %s %.1f Hz %.0f deg: enters the thin air at %.1f s; top %.2f m under the lid, last 10 s mean %.2f m; stroke-mean deceleration from then on: lid %.2f m/s^2, full air %.2f m/s^2" % [
				sp, s[0], s[1], i_band * DT, top, settle, dl, df])


## Air rising at 4 m/s everywhere under the lid (the strongest, widest
## updraft there could be): a neutral / slow glide rides it up until the
## thin air can no longer carry the bird.
func test_uniform_updraft() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for pitch: float in [0.0, 0.6]:
			fx = FX.new(self)
			await fx.setup(sp, func(w: Variant) -> void:
				w.uniform_wind = Vector3(0, float(Paths.arg("up", "4.0")), 0)
				FlightGeometry.box(w, Vector3(0, 85.0, 0), Vector3(3000, 10, 3000), FlightGeometry.C_WALL, false))
			fx.world.ceiling = 80.0
			var p := fx.player
			var cal := p.wing_input.calibration
			p.start_flying(Vector3(0, 50.0, 0), 0.0, 0.0)
			fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
				b.set_airplane()
				b.synth(pitch, 0.0, 1.0, cal)
			var st := {"top": INF, "t": 0.0, "late": 0.0}
			fx.on_tick = func(i: int, f: Variant) -> void:
				var q: PlayerBird = f.player
				var gap := 80.0 - (q.model.position.y + q.model.params.r_body)
				if gap < float(st["top"]):
					st["top"] = gap
					st["t"] = i * DT
				if i * DT > 40.0:
					st["late"] += gap / (20.0 * 72.0)
			fx.run(60.0)
			eq(p.contacts["stun"], 0, "no stun in the updraft")
			_log("[updraft] %s pitch %.1f in air rising %s m/s: top %.2f m under the lid at %.1f s, mean over the last 20 s %.2f m, contacts %s, end %s" % [
				sp, pitch, Paths.arg("up", "4.0"), st["top"], st["t"], st["late"], str(p.contacts), p.mode_name()])
			fx.teardown()
			fx = null
			await get_tree().process_frame
