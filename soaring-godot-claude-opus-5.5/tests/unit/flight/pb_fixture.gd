extends RefCounted
## L3 fixture: the real scenes/player/player.tscn in a flight test world,
## driven by scripted arm poses (auto_process off, ticked directly).
## Every tick runs the comfort monitor (F11 / PB-01 / PB-02 / PB-03): the
## PlayerBird and XROrigin3D bases are pure yaw with unit scale, the origin's
## local basis is identity, the rig yaw rate and acceleration stay within
## the caps except on flagged ticks, and the camera sits on the body.
##   var fx := FX.new(self)
##   await fx.setup(&"sparrow", func(w): w.add_perch(...))
##   fx.player.start_flying(Vector3(0, 50, 0), 0.0)
##   fx.run(5.0)
##   fx.teardown()

const PLAYER := preload("res://scenes/player/player.tscn")
const TW := preload("res://tests/unit/flight/flight_test_world.gd")
const DT := 1.0 / 72.0

var suite: Node
var world: World
var player: PlayerBird
var body: HumanPoseModel
var src: ScriptedPoseSource
## driver.call(tick, t, body) sets the arms each tick (default: airplane).
var driver: Callable
## Called after every tick: cb.call(tick_index, fixture)
var on_tick: Callable
var ticks := 0
var events := {"flapped": 0, "stalled": 0, "collided": 0, "perched": 0, "took_off": 0, "spawned": 0}
var collide_impacts: Array[float] = []
var comfort := {"max_rate": 0.0, "max_accel": 0.0, "basis_bad": 0, "scale_bad": 0, "origin_bad": 0,
	"camera_err": 0.0, "checked": 0, "cam_jerk": 0.0, "body_jerk": 0.0}
## Camera / body heights of the last two ticks (vertical jerk monitor).
var _vh: Array = []
var check_camera := true
var _skip := 0
var _conns: Array = []


func _init(p_suite: Node) -> void:
	suite = p_suite


func setup(sp: StringName, world_setup: Callable = Callable(), seed := 1) -> void:
	world = TW.new()
	if world_setup.is_valid():
		world_setup.call(world)
	suite.add_child(world)
	body = HumanPoseModel.new(seed)
	driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
	src = ScriptedPoseSource.new(body, func(tick: int, t: float, b: HumanPoseModel) -> void:
		driver.call(tick, t, b))
	player = PLAYER.instantiate() as PlayerBird
	player.auto_process = false
	player.use_settings = false
	player.drive_world_scale = true
	player.default_source = &"none"
	player.mass = FlightParams.species_mass(sp)
	suite.add_child(player)
	# Calibration is WingInput's own suite (WI-22); flight tests fly the
	# default calibration so a held pose is never captured as "flat".
	player.auto_calibrate = false
	player.set_pose_source(src)
	_connect()
	# No physics frame to wait for (fix round 6): Jolt's space answers queries
	# about a static body as soon as it enters the tree (r6 diag
	# space_immediate). Round 5 waited two physics frames here, 28 ms of wall
	# time per fixture and ~10 s of the suite.


func _connect() -> void:
	var pairs := [
		[Events.player_flapped, func(_s: int, _st: float) -> void: events["flapped"] += 1],
		[Events.player_stalled, func() -> void: events["stalled"] += 1],
		[Events.player_collided, func(imp: float, _n: Vector3) -> void:
			events["collided"] += 1
			collide_impacts.append(imp)],
		[Events.player_perched, func(_p: Vector3) -> void: events["perched"] += 1],
		[Events.player_took_off, func() -> void: events["took_off"] += 1],
		[Events.player_spawned, func(_b: Bird) -> void: events["spawned"] += 1],
	]
	for pr in pairs:
		(pr[0] as Signal).connect(pr[1])
		_conns.append(pr)


func teardown() -> void:
	for pr in _conns:
		if (pr[0] as Signal).is_connected(pr[1]):
			(pr[0] as Signal).disconnect(pr[1])
	_conns.clear()
	if player != null and is_instance_valid(player):
		# A bot source's state lambda was built inside its (RefCounted)
		# owner, which it keeps alive: cut it so the owner can go.
		var ps := player.pose_source
		if ps is BotPoseSource:
			(ps as BotPoseSource).state_fn = Callable()
		player.get_parent().remove_child(player)
		player.free()
	if world != null and is_instance_valid(world):
		world.get_parent().remove_child(world)
		world.free()
	if player != null:
		player = null
	var o := XRServer.world_scale
	if o != 1.0:
		XRServer.world_scale = 1.0
	# Break the RefCounted cycles (fixture -> src -> lambda -> fixture, and
	# the tests' driver / on_tick lambdas capturing the fixture): otherwise
	# every fixture leaks at exit (round 1: 778 objects for the suite).
	if src != null:
		src.driver = Callable()
		src.body = null
	src = null
	driver = Callable()
	on_tick = Callable()
	body = null
	world = null


## Restart the comfort statistics (a fixture reused for several flights).
func reset_comfort() -> void:
	for k in comfort:
		comfort[k] = 0 if comfort[k] is int else 0.0
	_vh.clear()
	_skip = 2


func reset_events() -> void:
	for k in events:
		events[k] = 0
	collide_impacts.clear()


func run(seconds: float) -> void:
	var n := int(round(seconds / DT))
	for i in n:
		step()


func step() -> void:
	player.tick(DT)
	ticks += 1
	_monitor()
	if on_tick.is_valid():
		on_tick.call(ticks, self)


func _monitor() -> void:
	var p := player
	comfort["checked"] += 1
	var b := p.global_basis
	if b.y.dot(Vector3.UP) < 1.0 - 1e-6:
		comfort["basis_bad"] += 1
	if absf(b.determinant() - 1.0) > 1e-5 or absf(b.x.length() - 1.0) > 1e-5:
		comfort["scale_bad"] += 1
	var ob := p.origin.global_basis
	if ob.y.dot(Vector3.UP) < 1.0 - 1e-6 or absf(ob.determinant() - 1.0) > 1e-5:
		comfort["basis_bad"] += 1
	if not p.origin.transform.basis.is_equal_approx(Basis.IDENTITY):
		comfort["origin_bad"] += 1
	if p.yaw_flagged:
		_skip = 2
		_vh.clear()
	elif _skip > 0:
		_skip -= 1
	else:
		comfort["max_rate"] = maxf(comfort["max_rate"], absf(p.rig_yaw_rate))
		comfort["max_accel"] = maxf(comfort["max_accel"], absf(p.rig_yaw_accel))
	# Vertical comfort (PB-08b): the view's per-tick jerk (|second
	# difference| of the camera's height, perceived cm) against the body's,
	# while flying. A hitch in the view shows up as its own size.
	if p.mode == PlayerBird.Mode.FLYING:
		_vh.append([p.camera.global_position.y, p.model.position.y, maxf(p.origin.world_scale, 1e-4)])
		if _vh.size() > 3:
			_vh.pop_front()
		if _vh.size() == 3:
			var ws: float = _vh[1][2]
			var cj := absf(float(_vh[2][0]) - 2.0 * float(_vh[1][0]) + float(_vh[0][0])) / ws * 100.0
			var bj := absf(float(_vh[2][1]) - 2.0 * float(_vh[1][1]) + float(_vh[0][1])) / ws * 100.0
			comfort["cam_jerk"] = maxf(comfort["cam_jerk"], cj)
			comfort["body_jerk"] = maxf(comfort["body_jerk"], bj)
	else:
		_vh.clear()
	if check_camera and p.mode == PlayerBird.Mode.FLYING:
		# (By name: the round-6 old-code check runs the suite on round-5
		# sources, whose offset was the vertical heave alone.)
		var want: Vector3 = p.model.position + (p.call(&"view_offset") if p.has_method(&"view_offset") else Vector3.UP * p.heave_offset())
		comfort["camera_err"] = maxf(comfort["camera_err"], p.camera.global_position.distance_to(want))


## Standard comfort assertions for any scenario (F11).
func assert_comfort(t: Variant, tag: String) -> void:
	t.gt(comfort["checked"], 0, "%s: monitored ticks" % tag)
	t.eq(comfort["basis_bad"], 0, "%s: rig never pitches or rolls (basis y = up, every tick)" % tag)
	t.eq(comfort["scale_bad"], 0, "%s: PlayerBird unit scale (every tick)" % tag)
	t.eq(comfort["origin_bad"], 0, "%s: XROrigin3D local basis is identity" % tag)
	t.lt(rad_to_deg(comfort["max_rate"]), 240.0 + 1e-3, "%s: rig yaw rate <= 240 deg/s" % tag)
	# The cap itself (+ float round-off): the rig's safety net clamps to
	# exactly 720 deg/s^2 (round 2 allowed a 5 % slack it never needed).
	t.lt(rad_to_deg(comfort["max_accel"]), 720.0 + 1e-3, "%s: rig yaw accel <= 720 deg/s^2" % tag)
	if check_camera:
		t.lt(comfort["camera_err"], 0.001, "%s: camera = body + heave (m)" % tag)
		# 1.1 (fix round 2; round 1 allowed 1.4): the smoother only acts on
		# steady flapping and never adds motion, measured <= 1.06 x across the
		# verifier's human-flapping probe, held-out seeds and the bot course.
		# 0.05 cm: numerical floor.
		t.lt(comfort["cam_jerk"], 1.1 * comfort["body_jerk"] + 0.05,
			"%s: the view's vertical jerk never exceeds the body's (cm perceived, body %.2f)" % [tag, comfort["body_jerk"]])


## Airplane arms with a symmetric pitch / roll / spread from commands.
func synth(p: float, r: float, spread := 1.0) -> Callable:
	var cal := player.wing_input.calibration
	return func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.synth(p, r, spread, cal)
