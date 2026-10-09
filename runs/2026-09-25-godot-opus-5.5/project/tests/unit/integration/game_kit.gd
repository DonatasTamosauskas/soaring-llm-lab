extends RefCounted
## TEST-ONLY: the whole game (scenes/main.tscn) under test, and ways to play
## it the way a player does:
##  * boot()        instances main.tscn (quit_for_real off) and waits for the
##                  real startup (BOOT -> MENU) to finish;
##  * the menus     the UI in its VR mode with scripted laser pointers
##                  (UIPointerSource), clicked by aiming at a button and
##                  pulling the trigger (click / hold);
##  * flying        flight's BotPoseSource (human arm motion through the real
##                  WingInput) under IntegrationPilot, which cruises an
##                  orbit over the valley or chases a target;
##  * staging       NPC birds (the AI's NpcBird) placed on the player's path:
##                  prey hovering still, or a predator striking at the player
##                  along a scripted line, so catches and deaths happen
##                  through GameLoop's real catch rule on schedule;
##  * a Logger that counts every error and warning (IntegrationLog).
## Game time: run the suites with --fixed-fps 72 (one physics tick per
## frame, as fast as the machine allows: deterministic and quick). Without
## it (a plain runner, e.g. the whole tests/unit), the kit runs the game
## SPEED times faster than real time instead: SPEED x the tick rate with
## Engine.time_scale = SPEED, so every tick still integrates exactly 1/72 s
## (a time_scale alone would lengthen every step) and the simulation is the
## game's own; only wall-clock timers (the UI's 0.2 s pointer grace and
## 250 ms menu debounce) are relatively shorter, which the kit's waits allow
## for.
const SPEED := 3

const MAIN := preload("res://scenes/main.tscn")
const Pilot := preload("res://tests/unit/integration/integration_pilot.gd")
const Bot := preload("res://tests/unit/integration/integration_bot.gd")
const Log := preload("res://tests/unit/integration/integration_log.gd")
const TICK := 1.0 / 72.0

var host: Node
var main: GameMain
var log: Logger
var left: UIPointerSource
var right: UIPointerSource
var pilot: FlightAutopilot
var bot: BotPoseSource
## Events seen since boot: name -> count; and the last payloads.
var seen := {}
var last := {}
## Orbit the pilot cruises when it has no target (centre, radius).
var orbit_centre := Vector3.ZERO
var orbit_radius := 110.0
var orbit_dir := 1.0
## What the pilot navigates by when not chasing: &"orbit" (a circle round
## orbit_centre) or &"heading" (straight on, pilot.heading).
var nav := &"orbit"
## Birds this kit placed (freed at teardown).
var staged: Array[Node] = []
## A predator flying a scripted strike at the player: {bird, speed}.
var strike := {}
## A live bird the pilot is chasing (see chase_bird).
var chase_target: NpcBird = null
## Staged prey keeping to the player's height (see stage_prey).
var coop := {}
const COOP_M := 8.0
## Staged prey hovering a set distance beside the player's path (see
## stage_prey): bird -> that distance (m, to the left of the path).
var beside := {}
## ...kept there until the player is this close along its path (then the
## bird is still). A reach longer than the distance beside takes the bird
## before this point (at sqrt(reach^2 - beside^2) along: 0.34 m for a
## sparrow's moth at 1.7 spans), so the pass measures the catch reach, not
## the bot's aim: the wingbeat moves a sparrow's body up to ~0.3 m in the
## last 0.6 m of a pass (the lab, integration_catchpass_lab_test.gd).
const BESIDE_FREEZE_M := 0.25
var _ticker: Node
var _saved_sleep := -1
var _saved_time := []


class _Ticker:
	extends Node
	var kit: RefCounted

	func _init(k: RefCounted) -> void:
		kit = k
		name = "IntegrationTicker"
		# Before the birds and the game loop in every tick (they run at
		# priority 0 and 100): targets and strikes use this tick's state.
		process_physics_priority = -50
		process_mode = Node.PROCESS_MODE_PAUSABLE

	func _physics_process(dt: float) -> void:
		kit.call(&"_tick", dt)


## Boots the real game. Returns false if it did not reach MENU in time.
func boot(p_host: Node, vr_menus := true) -> bool:
	host = p_host
	log = Log.install()
	_saved_sleep = OS.low_processor_usage_mode_sleep_usec
	# Headless Godot idles 6.9 ms a frame; the game needs every frame.
	OS.low_processor_usage_mode_sleep_usec = 500
	for sig in ["run_started", "run_ended", "bird_caught", "player_caught", "player_grew", "player_tier_changed",
			"player_spawned", "player_flapped", "player_perched", "player_took_off", "game_state_changed",
			"threat_changed", "target_changed", "menu_requested"]:
		Events.connect(sig, _on_event.bind(sig))
	await _fast_time()
	# A comfort choice to play with (diagnostics: --turn_comfort=0.25..1).
	if Paths.arg("turn_comfort") != "":
		Settings.set_value("turn_comfort", float(Paths.arg("turn_comfort")))
	main = MAIN.instantiate() as GameMain
	main.quit_for_real = false
	host.add_child(main)
	var t0 := Time.get_ticks_msec()
	while not main.is_loaded and Time.get_ticks_msec() - t0 < 60000:
		await host.get_tree().process_frame
	if not main.is_loaded:
		return false
	_ticker = _Ticker.new(self)
	host.add_child(_ticker)
	orbit_centre = main.world.get_player_spawn().origin
	if vr_menus:
		use_vr_menus()
	await frames(3)
	return true


## Use a game that is already running (a harness inside main.tscn).
func attach(p_host: Node, p_main: GameMain) -> void:
	host = p_host
	main = p_main
	log = Log.install()
	for sig in ["run_started", "run_ended", "bird_caught", "player_caught", "player_grew", "player_tier_changed",
			"player_spawned", "player_flapped", "player_perched", "player_took_off", "game_state_changed",
			"threat_changed", "target_changed", "menu_requested"]:
		Events.connect(sig, _on_event.bind(sig))
	_ticker = _Ticker.new(self)
	host.add_child(_ticker)
	orbit_centre = main.world.get_player_spawn().origin


func teardown() -> void:
	_disconnect_events()
	for n in staged:
		if is_instance_valid(n):
			n.queue_free()
	staged.clear()
	if is_instance_valid(_ticker):
		_ticker.queue_free()
	if Game.state == Game.State.PAUSED:
		Game.set_state(Game.State.MENU)
	if is_instance_valid(main):
		# As the game's own Quit does: every sound stopped and drained, or
		# Godot's AudioServer reports the playbacks still in use at exit.
		if main.audio != null and is_instance_valid(main.audio):
			await main.audio.shutdown()
		main.queue_free()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 300:
		await host.get_tree().process_frame
	if _saved_sleep >= 0:
		OS.low_processor_usage_mode_sleep_usec = _saved_sleep
	if not _saved_time.is_empty():
		Engine.time_scale = _saved_time[0]
		Engine.physics_ticks_per_second = _saved_time[1]
		Engine.max_physics_steps_per_frame = _saved_time[2]
		_saved_time = []
	if log:
		log.uninstall()


## With --fixed-fps every frame's delta is exactly 1/72 s; otherwise run the
## game SPEED x faster than real time (see SPEED).
func _fast_time() -> void:
	var fixed := true
	for i in 6:
		await host.get_tree().process_frame
		if absf(host.get_tree().root.get_process_delta_time() - 1.0 / 72.0) > 1e-6:
			fixed = false
	if fixed:
		return
	_saved_time = [Engine.time_scale, Engine.physics_ticks_per_second, Engine.max_physics_steps_per_frame]
	Engine.time_scale = float(SPEED)
	Engine.physics_ticks_per_second = 72 * SPEED
	Engine.max_physics_steps_per_frame = 4 * SPEED
	print("[integration] real-time runner: the game runs %dx real time (%d ticks/s of 1/72 s)" % [SPEED, 72 * SPEED])


func _disconnect_events() -> void:
	for sig in ["run_started", "run_ended", "bird_caught", "player_caught", "player_grew", "player_tier_changed",
			"player_spawned", "player_flapped", "player_perched", "player_took_off", "game_state_changed",
			"threat_changed", "target_changed", "menu_requested"]:
		for conn in Events.get_signal_connection_list(sig):
			var cb: Callable = conn["callable"]
			if cb.get_object() == self:
				Events.disconnect(sig, cb)


func _on_event(a: Variant = null, b: Variant = null, c: Variant = null, sig := "") -> void:
	# Signals have 0-3 arguments; the bound name comes last.
	var args: Array = [a, b, c]
	var name := sig
	if name.is_empty():
		# bind() appends: with fewer arguments the name lands in a, b or c.
		for i in range(2, -1, -1):
			if args[i] is String:
				name = args[i]
				args.resize(i)
				break
	seen[name] = int(seen.get(name, 0)) + 1
	last[name] = args


func count(sig: String) -> int:
	return int(seen.get(sig, 0))


# --- time ----------------------------------------------------------------------

func frames(n: int) -> void:
	for i in n:
		await host.get_tree().process_frame


## Game seconds (physics ticks).
func advance(seconds: float) -> void:
	for i in int(ceil(seconds * 72.0)):
		await host.get_tree().physics_frame


## Waits (in game seconds) until cond() is true; returns whether it became so.
func wait_until(cond: Callable, max_s: float) -> bool:
	for i in int(ceil(max_s * 72.0)):
		if cond.call():
			return true
		await host.get_tree().physics_frame
	return cond.call()


# --- menus ---------------------------------------------------------------------

## The UI in its VR form (curved panels in the rig, laser pointers) driven by
## scripted pointer sources, as the UI area's own tests do.
func use_vr_menus() -> void:
	main.ui.set_vr_mode(true)
	left = UIPointerSource.new(&"left_hand")
	right = UIPointerSource.new(&"right_hand")
	main.ui.set_pointer_sources(left, right)
	park_hands()


func park_hands() -> void:
	var cam := main.player.camera
	var down := Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)
	var ws := main.player.origin.world_scale
	for s: UIPointerSource in [left, right]:
		var side := -1.0 if s == left else 1.0
		s.aim = Transform3D(down, cam.global_transform * (Vector3(0.25 * side, -0.6, -0.2) * ws))
		s.trigger_value = 0.0


func screen() -> StringName:
	return main.ui.current_screen_id()


func button(screen_id: StringName, id: StringName) -> Button:
	var s := main.ui.get_screen(screen_id)
	return s.get_button(id) if s else null


func aim_at(c: Control) -> void:
	var cam := main.player.camera
	var ws := main.player.origin.world_scale
	var hand := cam.global_transform * (Vector3(0.22, -0.35, -0.25) * ws)
	right.aim_at(hand, main.ui.menu_panel.control_to_world(c))


## Aim at the button and pull the trigger (a full click over real frames).
## Returns whether the pointer hovered that very button before the pull.
func click(screen_id: StringName, id: StringName) -> bool:
	var b := button(screen_id, id)
	if b == null:
		return false
	aim_at(b)
	await frames(2)
	var t0 := Time.get_ticks_msec()
	while not main.ui.pointer.accepting_clicks() and Time.get_ticks_msec() - t0 < 1000:
		await frames(1)
	var hovered := main.ui.pointer.hovered() == b
	right.trigger_value = 1.0
	await frames(2)
	right.trigger_value = 0.0
	await frames(3)
	park_hands()
	return hovered


## Aim and hold the trigger for a hold-to-confirm button (Restart, Quit to menu).
func hold(screen_id: StringName, id: StringName) -> bool:
	var b := button(screen_id, id)
	if b == null:
		return false
	aim_at(b)
	await frames(2)
	var t0 := Time.get_ticks_msec()
	while not main.ui.pointer.accepting_clicks() and Time.get_ticks_msec() - t0 < 1000:
		await frames(1)
	var hovered := main.ui.pointer.hovered() == b
	right.trigger_value = 1.0
	var need := (b as HoldButton).hold_seconds + 0.25 if b is HoldButton else 1.2
	await advance_frames_for(need)
	right.trigger_value = 0.0
	await frames(3)
	park_hands()
	return hovered


## Process frames covering `seconds` of frame time (HoldButton counts delta).
func advance_frames_for(seconds: float) -> void:
	var acc := 0.0
	while acc < seconds:
		await host.get_tree().process_frame
		acc += host.get_tree().root.get_process_delta_time()


# --- flying --------------------------------------------------------------------

## Hands the player to the bot pilot (arm poses -> the real WingInput).
## `pilot_script`: another pilot (e.g. integration_chase_pilot.gd).
func fly_bot(seed_value := 21, pilot_script: GDScript = null) -> void:
	var p := main.player
	pilot = (pilot_script if pilot_script != null else Pilot).new(p.model.params, null)
	pilot.set(&"world", main.world)
	pilot.set(&"heading", p.rig_yaw)
	# A pilot that looks where it flies (integration_person_pilot.gd) casts
	# in the game's physics space.
	if &"space" in pilot:
		pilot.set(&"space", p.get_world_3d().direct_space_state)
	bot = Bot.new(pilot, func() -> Dictionary:
		return {"pos": p.model.position, "vel": p.model.velocity, "airspeed": p.model.airspeed()}, seed_value)
	bot.calibration = p.wing_input.calibration
	p.set_pose_source(bot)
	if not main.game_loop.player_mass_changed.is_connected(_on_mass):
		main.game_loop.player_mass_changed.connect(_on_mass)


func _on_mass(_o: float, _n: float, _r: StringName) -> void:
	# The model re-derives its parameters from the new mass; so must the pilot.
	if pilot != null:
		(func() -> void: pilot.set_params(main.player.model.params)).call_deferred()


func set_mode(m: StringName) -> void:
	pilot.set(&"mode", m)


## Chase `pos` (the pilot also flies at its height).
func chase(pos: Vector3) -> void:
	pilot.set(&"target", pos)
	pilot.set(&"chase", true)


func cruise() -> void:
	chase_target = null
	pilot.set(&"target", Vector3.INF)
	pilot.set(&"chase", false)
	nav = &"orbit"


## Chase a live NPC (the loop's target cue names one) until it is caught,
## hides or is gone.
func chase_bird(b: NpcBird) -> void:
	chase_target = b
	nav = &"orbit"


## Straight on along the current flight direction.
func fly_straight() -> void:
	var v := main.player.velocity
	if Vector2(v.x, v.z).length() > 0.5:
		pilot.set(&"heading", atan2(-v.x, -v.z))
	pilot.set(&"target", Vector3.INF)
	pilot.set(&"chase", false)
	nav = &"heading"


func _tick(dt: float) -> void:
	if main == null or not is_instance_valid(main) or not main.is_loaded:
		return
	var p := main.player
	# Cruise: an orbit round the valley's centre of life (a point 40 deg
	# ahead on the circle), so a long flight never runs into the valley's
	# walls.
	if pilot != null and not bool(pilot.get(&"chase")) and nav == &"orbit":
		var rel := p.global_position - orbit_centre
		var ang := atan2(rel.z, rel.x) + orbit_dir * deg_to_rad(40.0)
		var wp := orbit_centre + Vector3(cos(ang), 0.0, sin(ang)) * orbit_radius
		pilot.set(&"target", Vector3(wp.x, INF, wp.z))
	# Chasing a live bird: the pilot flies at where it is now.
	if chase_target != null:
		if not is_instance_valid(chase_target) or not chase_target.alive or chase_target.hidden:
			chase_target = null
			cruise()
		elif pilot != null:
			pilot.set(&"target", chase_target.get_body_position())
			pilot.set(&"chase", true)
	# Prey beside the path: kept level with the player and exactly its
	# distance beside the line the player is flying, where it is along that
	# line, until the player is BESIDE_FREEZE_M from it.
	for b in beside.keys():
		if not is_instance_valid(b) or not (b as Bird).alive:
			beside.erase(b)
			continue
		var n2 := b as Node3D
		var head := p.get_body_position()
		var vh := Vector3(p.velocity.x, 0.0, p.velocity.z)
		if vh.length() < 1.0:
			continue
		var fwd := vh.normalized()
		var along := (n2.global_position - head).dot(fwd)
		if along < BESIDE_FREEZE_M:
			beside.erase(b)
			continue
		var left := Vector3.UP.cross(fwd)
		n2.global_position = head + fwd * along + left * float(beside[b])
		if pilot != null and bool(pilot.get(&"chase")):
			pilot.set(&"target", head + fwd * along)
	# Cooperative prey: level with the player until it is COOP_M away.
	for b in coop.keys():
		if not is_instance_valid(b) or not (b as Bird).alive:
			coop.erase(b)
			continue
		var n := b as Node3D
		var rel := n.global_position - p.get_body_position()
		if Vector2(rel.x, rel.z).length() > COOP_M:
			n.global_position.y = lerpf(n.global_position.y, p.get_body_position().y, 1.0 - exp(-dt / 0.4))
			if pilot != null and bool(pilot.get(&"chase")):
				pilot.set(&"target", n.global_position)
		else:
			coop.erase(b)
	# A scripted strike: the predator flies straight at the player's head.
	if not strike.is_empty():
		var b: Node3D = strike["bird"]
		if not is_instance_valid(b) or not (b as Bird).alive or not p.alive:
			strike = {}
		else:
			var to := p.get_body_position() - b.global_position
			var d := to.length()
			var step := minf(float(strike["speed"]) * dt, maxf(d - 0.05, 0.0))
			var dir := to / maxf(d, 1e-3)
			b.global_position += dir * step
			(b as Bird).velocity = dir * float(strike["speed"])
			b.global_basis = Basis.looking_at(dir, Vector3.UP)


# --- staging -------------------------------------------------------------------

## An NpcBird of `species` at `pos` facing `face`, frozen in the air (its own
## tick off): a target that does not flee.
func stage_bird(species: StringName, pos: Vector3, face: Vector3) -> NpcBird:
	var n := NpcBird.new()
	n.configure(species, -1.0, 77 + staged.size(), Habitat.for_world(main.world))
	n.name = "Staged_%s_%d" % [species, staged.size()]
	main.add_child(n)
	n.set_physics_process(false)
	n.global_position = pos
	var f := Vector3(face.x, 0.0, face.z).normalized() if Vector2(face.x, face.z).length() > 1e-3 else Vector3.FORWARD
	n.global_basis = Basis.looking_at(f, Vector3.UP)
	n.velocity = Vector3.ZERO
	if n.model:
		n.model.snap()
	staged.append(n)
	return n


## Prey hovering `ahead` m in front of the player (along its flight path, at
## its height), and the pilot chasing it. Returns the bird.
## `side_m` > 0: a pass BESIDE the bird instead of through it - the bird
## hovers level with the player, `side_m` to the left of the line the
## player flies (kept there until the player is BESIDE_FREEZE_M from it
## along the line, then still), and the pilot flies straight on. The pass
## goes by at `side_m`: a near miss of a known size, which the player's
## catch reach must cover (integration hygiene: through the bird, any reach
## caught it).
func stage_prey(species: StringName, ahead := 22.0, side_m := 0.0) -> NpcBird:
	var p := main.player
	var v := p.velocity
	var dir := Vector3(v.x, 0.0, v.z).normalized() if Vector2(v.x, v.z).length() > 1.0 else -p.global_basis.z
	var pos := p.get_body_position() + dir * ahead
	if side_m > 0.0:
		pos += Vector3.UP.cross(dir) * side_m
	var b := stage_bird(species, pos, -dir)
	if side_m > 0.0:
		beside[b] = side_m
		chase(p.get_body_position() + dir * ahead)
		return b
	chase(pos)
	# A cooperative target: until the player is COOP_M away the prey keeps
	# to the player's (smoothed) height, so a catch test is about the game's
	# catch path, not the bot's altitude hold (its wingbeat scatter left
	# hovering prey ~0.7-1.4 m under the path).
	coop[b] = true
	return b


## A predator `ahead` m in front of the player that strikes at it along a
## straight line at `speed` m/s (through the real catch rule).
func stage_strike(species: StringName, ahead := 30.0, speed := 12.0) -> NpcBird:
	var p := main.player
	var v := p.velocity
	var dir := Vector3(v.x, 0.0, v.z).normalized() if Vector2(v.x, v.z).length() > 1.0 else -p.global_basis.z
	var pos := p.get_body_position() + dir * ahead
	var b := stage_bird(species, pos, -dir)
	strike = {"bird": b, "speed": speed}
	return b


func free_staged() -> void:
	strike = {}
	for n in staged:
		if is_instance_valid(n):
			release(n)
	staged.clear()


## Frees a staged bird. NPCs that fled it or hunted it keep their stale
## reference until their own tick drops it, exactly as with any bird freed
## outside the Ecosystem: the whole-game suites count every error, so they
## pin that the AI tolerates it. (Integration round 1 removed a workaround
## here that dropped those references first and hid NpcBrain._sense's
## "previously freed instance" SCRIPT ERROR.)
func release(b: Node) -> void:
	if not is_instance_valid(b):
		return
	if b is NpcBird and (b as NpcBird).brain:
		(b as NpcBird).brain.on_removed()
	(b as Bird).alive = false
	b.queue_free()


# --- facts -----------------------------------------------------------------------

func stats() -> Dictionary:
	return main.game_loop.get_run_stats()


func orphans() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))


func nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func objects() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_COUNT))
