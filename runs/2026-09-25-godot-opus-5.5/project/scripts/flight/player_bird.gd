class_name PlayerBird
extends Bird
## The player's bird and XR rig (FLIGHT_SPEC §10). Root of
## scenes/player/player.tscn:
##   PlayerBird (pausable; yaw only, never scaled)
##   └── XROrigin3D (group player_rig, PROCESS_MODE_ALWAYS; translation only)
##       ├── XRCamera3D
##       ├── LeftHand / RightHand   (XRController3D, pose grip: the wings)
##       ├── LeftAim / RightAim     (XRController3D, pose aim: pointers)
##       └── WingAnchors/L, R       (where wing visuals attach)
##
## Per physics tick: poses -> WingInput -> body steer -> FlightModel ->
## continuous sweep -> rig. The body IS the eye: global_position is the head
## point in the world, the XROrigin3D is offset so the tracked camera lands
## exactly on it (plus a bounded heave offset). The rig only ever yaws and
## translates (comfort: the view never pitches or rolls, C1), and growth is
## world_scale, never node scale (C2).

enum Mode { SPAWNING, FLYING, PERCHED, GROUNDED, STUNNED, CAUGHT }
enum Contact { NONE, SILENT, SLIDE, LAND, STUN }

const MODE_NAMES := ["spawning", "flying", "perched", "grounded", "stunned", "caught"]
const LAYER_WORLD := 1
const LAYER_PERCH := 2

@export var tuning: FlightTuning
## Tests set false and call tick(dt) themselves.
@export var auto_process := true
## Pose source when none is set: &"auto" (XR when VR is active, else
## desktop), &"xr", &"desktop", &"none".
@export var default_source := &"auto"
## Fallback growth driver for scenes without the VR area's WorldScaleDriver
## (which owns world_scale in the game). Off by default.
@export var drive_world_scale := false
## Camera near plane per unit world_scale when this bird drives the scale
## itself (flight's dev scenes; in the game VR's WorldScaleDriver does, with
## the same factor): 0.06 since integration round 1 (was 0.03), for the
## Quest's 24-bit depth buffer (WorldScaleDriver.NEAR_K explains why).
const NEAR_PER_WORLD_SCALE := 0.06
@export var comfort_caps := true
@export var body_steer := true
@export var heave_smoothing := true
@export var perch_needs_grip := false
## Perch assist (G16), on top of the tuning preset's switch.
@export var perch_assist := true
## Print a telemetry line every N seconds (0 = off).
@export var log_interval := 0.0
## Automatic neutral capture while uncalibrated (§5.10) — only while
## perched, spawning or grounded: a bank held calmly for 1.2 s in flight
## must never become the player's "flat".
@export var auto_calibrate := true
## Read Settings (assist preset, comfort caps, calibration). Tests set false
## so a settings file left by another suite cannot change the physics.
@export var use_settings := true
## Record every tick's poses to a JSON-lines file for replay regression
## tests (FLIGHT_SPEC R5). Also on with Settings "record_poses" or the
## command line --record-poses[=<path>]. Empty path: user://pose_rec/<stamp>.
@export var record_poses := false
@export var record_path := ""

var mode: Mode = Mode.SPAWNING
var model: FlightModel
var wing_input: WingInput
var pose_source: PoseSource
var perch: Perch
var frame := PoseFrame.new()
var env := FlightEnv.new()
var heave := HeaveSmoother.new()
var recorder: PoseRecorder

var origin: XROrigin3D
var camera: XRCamera3D
var left_hand: XRController3D
var right_hand: XRController3D
var left_aim: XRController3D
var right_aim: XRController3D
var wing_anchors: Array[Node3D] = []

# ---- bookkeeping (read by tests and telemetry) ----
var rig_yaw := 0.0
var rig_yaw_rate := 0.0
var rig_yaw_accel := 0.0
## True on ticks where a yaw step is allowed (respawn, recenter).
var yaw_flagged := false
var controls_enabled := true
var stun_left := 0.0
var perch_candidate: Perch
var perch_candidate_dist := -1.0
var last_contact := Contact.NONE
## Contacts by kind. "lid" counts the contacts with the arena's lid (the
## underside of the sky at World.ceiling) again, beside their kind (slide
## or silent: the lid never stuns, see _classify).
var contacts := {"silent": 0, "slide": 0, "land": 0, "stun": 0, "brush": 0, "lid": 0, "water": 0}
var world_scale_target := 1.0
var tick_count := 0
var tick_us := 0.0
## Ticks on which the rig's comfort safety net had to act (should be rare:
## the physics caps normally keep the heading inside the limits).
var rig_limited_ticks := 0
## The heading jump the model reported this tick (rad): a contact's turn or
## a slow-flight snap, owed to the view (tests measure forced view turns).
var forced_turn := 0.0

var _ws := WingState.new()        ## what the model flies this tick
var _roll_input := 0.0
var _body_share := 0.0
var _bs_lag := 0.0               ## body-steer bank demand through the bank lag
var _bank_lag := 0.0             ## total bank demand through the bank lag
var _h_ref := Vector3.ZERO        ## tracking-space head point mapped onto the body
var _h_valid := false
var _discontinuity := true
var _controls_fade := 1.0
var _spawn_t := 0.0
var _ignore_perch_t := 0.0
var _takeoff_strokes: Array[float] = []
var _time := 0.0
var _world: World
## Tick of the last World lookup: a World that enters the tree after the
## player (a regenerated level) is still found (ARCHITECTURE §3).
var _world_tick := -1
var _sphere := SphereShape3D.new()
var _shape_q := PhysicsShapeQueryParameters3D.new()
var _ray_q := PhysicsRayQueryParameters3D.new()
var _telemetry := {}
## tick_count the telemetry was built for (-1 = stale).
var _tel_tick := -1
var _last_log := 0.0
var _brush_prev := [false, false]
var _ease_t := 0.0
var _no_capture_t := 0.0
## Per wing: the credit of a downstroke begun on a perch or the ground that
## has not ended yet (see _completed_flap).
var _launch_pend: Array[float] = [0.0, 0.0]
## Per wing: time since that downstroke ended low (-1 = it has not).
var _launch_low: Array[float] = [-1.0, -1.0]
var _assist_prev := Vector3.ZERO
## The perch just left: not re-captured until the bird is clear of it.
var _left_perch: Perch
## Colliders of the perch just left: excluded from the sweep for 0.4 s so a
## launch that sinks at first (a big bird) falls off its own branch
## (branches collide on layers 1 + 2).
var _launch_exclude: Array[RID] = []
## Perch capture ease: a cubic Hermite from the capture tick's start point
## with the approach velocity to the grip point at rest (§10.6).
var _ease_from := Vector3.ZERO
var _ease_v0 := Vector3.ZERO
var _ease_len := 0.15
var _dt := 1.0 / 72.0
var _mass_applied := -1.0
var _heave_off := 0.0
var _recenter_pending := false
## A paused recenter's re-aim is on its way (see _recenter_when_tracked).
var _recenter_scheduled := false
## Seconds left of the post-resume hold (see _notification); 0 = none.
var _resume_hold := 0.0
var _pause_sent := false
## Heading changes the view owes and pays smoothly (a bounce or slide off a
## wall re-seats the heading in one tick): see ViewTurn. Body steer reads
## rig_yaw + view_turn.debt, the yaw the view is heading for.
var view_turn := ViewTurn.new()
## Rate (rad/s) of the flown turn the rig is following directly (the rest of
## the rig's rate is view_turn's payout).
var _ff_rate := 0.0
## The perch the assist is flying to, held until passed (see _assist_target).
var _assist_perch: Perch
## The touchdown run-out's velocity along the ground (GROUNDED; see
## _touch_down and _run_out).
var _run_v := Vector3.ZERO
## The sweep's contact is perch geometry (see _sweep, _classify).
var _hit_perch := false
## Rock and walls the body touched lately (core loop fix round 1): the air
## cannot blow INTO a solid face, so for WALL_AIR_S after a contact with a
## face (normal below FLOOR_NY) the wind the flight model feels has no
## component into it (_wall_wind). The valley's wind field is not bounded by
## the geometry: at the west cliff it blows into the rock at 2.7 m/s with a
## 1.3-1.5 m/s updraft, and a slow eagle or hawk under the overhang was held
## against the face by it - "flying" at 1.3 m/s airspeed, not stalled, not
## sinking - for 4-10 minutes of real-chain runs (pin_escape_test).
const WALL_AIR_S := 0.3
const WALL_FLOOR_NY := 0.7
var _wall_n: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _wall_t: Array[float] = [0.0, 0.0]
var _wall_world: World = null
## The sweep's contact is the arena's lid: met from below at World.ceiling
## (see _sweep, _classify).
var _hit_lid := false
## The contact in hand is a water surface (World.is_water): never ground.
var _hit_water := false
## Speed a bird that meets the water leaves it with (m/s up, at least): a
## splash and a hop, never a stand (integration round 1: a bird gliding
## down onto the lake stood on it, its eye at the water line).
const WATER_HOP := 1.6
## The legs at a touchdown (fix round 5): a time-optimal dip of the camera
## that takes up the speed into the ground and comes back (the follower's
## debt is minus the dip). _leg_dt: the part of the touchdown tick left
## after the contact (the legs' first step), -1 otherwise.
var _legs := ViewTurn.new()
var _leg_dt := -1.0
## The legs' axis (fix round 6): the surface normal they met. The camera
## bends along it, so on a slope the legs take the whole speed into the
## surface (round 5 bent them vertically and stopped the rest in one tick).
var _leg_n := Vector3.UP
## The legs are bending (phase 1 of _legs_step), not yet standing back up.
var _leg_bend := false
## The ground under the feet while GROUNDED (fix round 6): the touchdown's
## surface normal, then whatever the run-out follows. The run-out runs
## along this plane and a take-off leaves it. UP otherwise.
var _ground_n := Vector3.UP
## Seconds since a take-off from the ground, -1 = none (fix round 6; see
## _update_takeoff_hold): while it holds, touching the ground is not a
## touchdown.
var _takeoff_t := -1.0
## _time of the last stroke onset (either wing).
var _last_stroke_t := -INF
## The camera's offset from the body this tick (heave plus the legs, m).
var _view_off := Vector3.ZERO
## The last sweep or run-out cast met perch geometry (see _cast).
var _cast_perch := false
## Prints every contact classification (collision debugging).
var debug_contacts := false


func _init() -> void:
	mass = 0.03


func _ready() -> void:
	add_to_group(&"player")
	process_mode = Node.PROCESS_MODE_PAUSABLE
	if tuning == null:
		tuning = FlightTuning.default_tuning()
	_bind_rig()
	model = FlightModel.new(mass, tuning)
	_apply_settings()
	wing_input = WingInput.new(_load_calibration())
	_apply_mass()
	if pose_source == null:
		_default_pose_source()
	_shape_q.shape = _sphere
	_shape_q.collide_with_areas = false
	_ray_q.collide_with_areas = false
	if has_node(^"/root/Events"):
		Events.recenter_requested.connect(_on_recenter)
		Events.settings_changed.connect(_on_setting_changed)
	if has_node(^"/root/VR") and VR.has_signal(&"recentered"):
		VR.recentered.connect(_on_recenter)
	_start_recording()
	respawn(global_transform)


func _start_recording() -> void:
	var arg := Paths.arg("record-poses", "")
	if not arg.is_empty():
		record_poses = true
		if arg != "true":
			record_path = arg
	if use_settings and has_node(^"/root/Settings") and bool(Settings.get_value("record_poses", false)):
		record_poses = true
	if not record_poses:
		return
	recorder = PoseRecorder.new()
	if recorder.start(record_path):
		print("[flight] recording poses to ", ProjectSettings.globalize_path(recorder.path))
	else:
		push_warning("[flight] could not open the pose recording %s" % recorder.path)
		recorder = null


func _notification(what: int) -> void:
	# Unpaused: the player may have walked or moved their arms during the
	# pause menu; the first poses after it are trusted, not rejected as a
	# tracker glitch (PB-13 S2), and no stroke carries over (fix round 5).
	# The controls stay neutral until the arms are back out and settled
	# (both extended past 0.6, neither swinging faster than 0.5 rad/s) or for
	# at most 1.5 s, then fade in over 0.4 s as after a stun: round 4 flew
	# the arms' way back from the menu pose at full authority (up to 70 deg
	# of bank and 79 deg of view turn in 3 s).
	if what == NOTIFICATION_UNPAUSED and wing_input != null:
		wing_input.resume()
		_resume_hold = 1.5
		_controls_fade = 0.0


func _exit_tree() -> void:
	# Godot 4 does not chain virtual callbacks: without super() Bird's
	# _exit_tree never runs, the player stays in the Birds registry after it
	# leaves the tree, and every later Birds.nearby / all() walk touches a
	# freed instance (round-2 verifier finding).
	super()
	if recorder != null:
		recorder.stop()
		print("[flight] pose recording closed: %d frames" % recorder.lines)


func _bind_rig() -> void:
	origin = get_node_or_null(^"XROrigin3D") as XROrigin3D
	if origin == null:
		origin = XROrigin3D.new()
		origin.name = "XROrigin3D"
		add_child(origin)
	origin.add_to_group(&"player_rig")
	origin.process_mode = Node.PROCESS_MODE_ALWAYS
	camera = origin.get_node_or_null(^"XRCamera3D") as XRCamera3D
	if camera == null:
		camera = XRCamera3D.new()
		camera.name = "XRCamera3D"
		origin.add_child(camera)
	camera.far = 3000.0
	left_hand = _controller(&"LeftHand", &"left_hand", &"grip")
	right_hand = _controller(&"RightHand", &"right_hand", &"grip")
	left_aim = _controller(&"LeftAim", &"left_hand", &"aim")
	right_aim = _controller(&"RightAim", &"right_hand", &"aim")
	var anchors := origin.get_node_or_null(^"WingAnchors")
	if anchors == null:
		anchors = Node3D.new()
		anchors.name = "WingAnchors"
		origin.add_child(anchors)
	wing_anchors.clear()
	for n in [&"L", &"R"]:
		var a := anchors.get_node_or_null(NodePath(String(n))) as Node3D
		if a == null:
			a = Node3D.new()
			a.name = n
			anchors.add_child(a)
		wing_anchors.append(a)
	for c in origin.get_children():
		c.process_mode = Node.PROCESS_MODE_ALWAYS


func _controller(node_name: StringName, tracker: StringName, pose: StringName) -> XRController3D:
	var c := origin.get_node_or_null(NodePath(String(node_name))) as XRController3D
	if c == null:
		c = XRController3D.new()
		c.name = node_name
		origin.add_child(c)
	c.tracker = tracker
	c.pose = pose
	return c


func _default_pose_source() -> void:
	var kind := default_source
	if kind == &"auto":
		var vr_active: bool = has_node(^"/root/VR") and bool(VR.get("active"))
		kind = &"xr" if vr_active else &"desktop"
	match kind:
		&"xr":
			var xs := XRPoseSource.new(origin, camera, left_hand, right_hand)
			# The game's XR poses: hand velocity over the real frame interval
			# (engine frame hitches, fix round 5).
			xs.frame_timing = true
			set_pose_source(xs)
		&"desktop":
			set_pose_source(DesktopPoseSource.new())
		_:
			set_pose_source(null)


func _load_calibration() -> WingCalibration:
	var cal := WingCalibration.new()
	if use_settings and has_node(^"/root/Settings"):
		var d: Variant = Settings.get_value("wing_calibration", {})
		if d is Dictionary and not (d as Dictionary).is_empty():
			cal.from_dict(d)
		cal.seated = cal.seated or bool(Settings.get_value("seated", false))
	return cal


func _apply_settings() -> void:
	var s := func(k: String, dflt: Variant) -> Variant:
		return Settings.get_value(k, dflt) if use_settings and has_node(^"/root/Settings") else dflt
	var preset: int = int(s.call("flight_assist", tuning.preset))
	# Developer-menu flight levers (Settings dev_*, each 0..1; see
	# scripts/ui/screens/dev_screen.gd). Without Settings the tuning's own
	# values (the tested physics) stand.
	var lv := {}
	if use_settings and has_node(^"/root/Settings"):
		lv = {
			"flap_power": 0.5 + 2.0 * float(s.call("dev_flap_power", 0.55)),
			"glide_efficiency": 0.8 + 0.8 * float(s.call("dev_speed", 0.625)),
			"dive_speed": 0.8 + 0.8 * float(s.call("dev_speed", 0.625)),
			"roll_rate_scale": 0.6 + 1.4 * float(s.call("dev_roll_rate", 0.5)),
			"stretch_bonus": 1.0 * float(s.call("dev_stretch_bonus", 0.6)),
		}
	var changed := preset != tuning.preset
	for k in lv:
		changed = changed or absf(float(tuning.get(k)) - float(lv[k])) > 1e-4
	if changed:
		tuning = tuning.duplicate() as FlightTuning
		tuning.preset = preset
		for k in lv:
			tuning.set(k, lv[k])
		model.set_tuning(tuning)
	body_steer = bool(s.call("body_steer", body_steer)) and tuning.assists()[&"body_steer"]
	heave_smoothing = bool(s.call("heave_smoothing", heave_smoothing))
	perch_needs_grip = bool(s.call("perch_needs_grip", perch_needs_grip))
	# The player's turn-speed choice (Settings "turn_comfort"; never faster
	# than the tuning's own cap), unless a raw cap is set (dev/tests).
	var tc := FlightTuning.turn_comfort_rate(float(s.call("turn_comfort", 1.0)))
	var rate := float(s.call("comfort_max_yaw_rate", minf(tuning.comfort_max_yaw_rate_deg, tc)))
	var acc := float(s.call("comfort_max_yaw_accel", minf(tuning.comfort_max_yaw_accel_deg,
			rate * FlightTuning.TURN_COMFORT_ACCEL_PER_RATE)))
	model.comfort_yaw_rate = deg_to_rad(rate) if comfort_caps else 0.0
	model.comfort_yaw_accel = deg_to_rad(acc) if comfort_caps else 0.0
	view_turn.max_rate = deg_to_rad(minf(tuning.view_turn_rate_deg, rate))
	view_turn.max_acc = deg_to_rad(minf(tuning.view_turn_accel_deg, acc))
	if wing_input != null:
		wing_input.deadzone_scale = tuning.deadzone_scale()
		wing_input.invert_pitch = bool(s.call("invert_pitch", false))
		wing_input.sweep_pitch = bool(s.call("sweep_pitch", true))
		wing_input.wrist_sensitivity = clampf(float(s.call("wrist_sensitivity", 1.0)), 0.5, 2.0)
		wing_input.soar_lock_enabled = bool(s.call("soar_lock", true))
		wing_input.auto_trim = bool(s.call("auto_trim", true))
		if use_settings and has_node(^"/root/Settings"):
			# Playtest #1: a real dead zone and a steeper curve (small hand
			# movements do nothing, far deflections turn hard).
			var dz := 20.0 * float(s.call("dev_turn_deadzone", 0.5))
			var full := lerpf(70.0, 25.0, float(s.call("dev_turn_sensitivity", 0.5)))
			var expo := 1.0 + 2.0 * float(s.call("dev_turn_curve", 0.5))
			wing_input.turn_deadzone_deg = dz
			wing_input.arm_full_deg = full + 5.0
			wing_input.tilt_full_deg = full
			wing_input.arm_expo = expo
			wing_input.tilt_expo = expo
			wing_input.arm_turn = bool(s.call("dev_arm_turn", true))
			wing_input.tilt_turn = bool(s.call("dev_tilt_turn", true))
			wing_input.tilt_invert = bool(s.call("dev_tilt_invert", true))
			var relaxed := bool(s.call("dev_relaxed_glide", true))
			wing_input.glide_reach_cap = 0.48 if relaxed else 10.0
			wing_input.fold_elevation_cap = deg_to_rad(-68.0) if relaxed else 0.0


func _on_setting_changed(_key: String, _value: Variant) -> void:
	_apply_settings()


# ==========================================================================
# Public API (ARCHITECTURE §6, FLIGHT_SPEC §10.1)

func is_player() -> bool:
	return true


func get_body_position() -> Vector3:
	return global_position


## Beak heading with body pitch (not the gaze, not the rig).
func get_forward() -> Vector3:
	return model.forward() if model != null else -global_basis.z


## Where the player is looking (AI uses it for "out of view" spawning).
func get_view_direction() -> Vector3:
	return -camera.global_basis.z if camera != null else get_forward()


func set_pose_source(src: PoseSource) -> void:
	pose_source = src
	if src != null:
		src.reset()
	_discontinuity = true


func wing_state() -> WingState:
	return wing_input.state if wing_input != null else _ws


func set_controls_enabled(on: bool) -> void:
	controls_enabled = on


func begin_calibration(kind: StringName) -> void:
	wing_input.begin_calibration(kind)


func calibration_status() -> Dictionary:
	return wing_input.calibration_status()


func mode_name() -> String:
	return MODE_NAMES[mode]


## Place the eye at xform.origin facing its yaw; perch on a fitting perch
## within one span, else hover SPAWNING for 0.5 s. The only allowed yaw step.
func respawn(xform: Transform3D) -> void:
	_apply_mass()
	var f := -xform.basis.z
	var yaw := FlightMath.yaw_of(f) if Vector2(f.x, f.z).length() > 1e-4 else 0.0
	rig_yaw = yaw
	model.reset(xform.origin, Vector3.ZERO, yaw)
	_reset_rig_motion()
	model.theta = 0.0
	velocity = Vector3.ZERO
	wing_input.reset()
	if pose_source != null:
		pose_source.reset()
	heave.reset()
	_release_perch()
	_left_perch = null
	stun_left = 0.0
	_controls_fade = 1.0
	_spawn_t = 0.0
	_ignore_perch_t = 0.0
	_takeoff_strokes.clear()
	_discontinuity = true
	mode = Mode.SPAWNING
	alive = true
	perched = false
	var p := _nearest_perch(xform.origin, model.params.span, false)
	if p != null:
		perch_on(p)
	_apply_rig(0.0)
	if has_node(^"/root/Events"):
		Events.player_spawned.emit(self)


## Start in trimmed flight (lab, bot, tests): eye at `pos`, heading `yaw`,
## the steady glide of `pitch`. Rig yaw follows (a flagged yaw step).
func start_flying(pos: Vector3, yaw: float, pitch := 0.0) -> void:
	_release_perch()
	model.trim(pos, yaw, pitch)
	rig_yaw = FlightMath.wrap_angle(yaw - wing_input.state.body_yaw)
	_reset_rig_motion()
	mode = Mode.FLYING
	stun_left = 0.0
	_controls_fade = 1.0
	_ignore_perch_t = 0.0
	_discontinuity = true
	heave.reset()
	velocity = model.velocity
	_apply_rig(0.0)


## Force a perch (respawn, tests).
func perch_on(p: Perch) -> void:
	if p == null:
		return
	_release_perch()
	perch = p
	p.occupant = self
	mode = Mode.PERCHED
	perched = true
	model.reset(_perch_point(p), Vector3.ZERO, model.heading())
	model.theta = 0.0
	velocity = Vector3.ZERO
	_ease_t = 0.0
	_takeoff_strokes.clear()
	_reset_rig_motion()


## A teleport (respawn, start_flying, a forced perch) starts the view at
## rest. The previous flight's rig yaw rate, its pending view turn and the
## body-steer lags belong to that flight: round 2 kept them, so after
## "Restart run" from a pause taken mid-turn the comfort clamp wound the old
## 206 deg/s down over the spawn (28 deg of view rotation with no heading
## change) and body steer launched the bird 30 deg off the respawn yaw.
func _reset_rig_motion() -> void:
	rig_yaw_rate = 0.0
	rig_yaw_accel = 0.0
	_ff_rate = 0.0
	view_turn.reset()
	_bs_lag = 0.0
	_bank_lag = 0.0
	_body_share = 0.0
	# The perching state of that flight too: the capture lockout after a
	# contact and the assist's last push (its gravity compensation reads it).
	_assist_perch = null
	_no_capture_t = 0.0
	_assist_prev = Vector3.ZERO
	_launch_pend[0] = 0.0
	_launch_pend[1] = 0.0
	_run_v = Vector3.ZERO
	_legs.reset()
	_leg_dt = -1.0
	_leg_bend = false
	_leg_n = Vector3.UP
	_ground_n = Vector3.UP
	_takeoff_t = -1.0
	_last_stroke_t = -INF
	_tel_tick = -1
	if model != null:
		model.take_heading_step()
	yaw_flagged = true


func on_caught(by: Bird) -> void:
	super.on_caught(by)
	_release_perch()
	mode = Mode.CAUGHT
	controls_enabled = false


func _on_mass_changed() -> void:
	if model != null:
		_apply_mass()


func _apply_mass() -> void:
	if model == null:
		return
	if not is_equal_approx(_mass_applied, mass):
		model.set_mass(mass)
		_mass_applied = mass
		species = SizeRules.species_for_mass(mass)
	if wing_input != null:
		wing_input.size_x = model.params.x


func _on_recenter() -> void:
	_recenter_pending = true
	if is_inside_tree() and get_tree().paused and not can_process() and not _recenter_scheduled:
		_recenter_scheduled = true
		_recenter_when_tracked.call_deferred()


## Paused, the body does not tick but the rig tracks the head (integration
## round 2, the Quest verifier: a recenter taken in the pause menu turned
## the view at the press - the runtime's center_on_hmd - and turned the
## whole world back 51.5 deg at Resume, when the next tick re-aimed the
## rig). So the re-aim runs as soon as the runtime's new reference frame
## has reached the tracked nodes (two frames on): the view changes once, at
## the press, exactly as a recenter in flight does (it faces the body the
## way the bird flies), and Resume never turns it.
func _recenter_when_tracked() -> void:
	for i in 2:
		await get_tree().process_frame
	_recenter_scheduled = false
	if not _recenter_pending or not is_inside_tree() or can_process() or model == null or wing_input == null:
		return  # resumed meanwhile: the tick does it
	_recenter_pending = false
	if pose_source != null:
		pose_source.sample(frame, 1.0 / 72.0)
	wing_input.recenter()
	var wi := wing_input.update(frame, 1.0 / 72.0)
	rig_yaw = FlightMath.wrap_angle(model.heading() - wi.body_yaw)
	view_turn.reset()
	rig_yaw_rate = 0.0
	_ff_rate = 0.0
	yaw_flagged = true
	_discontinuity = true
	_apply_rig(0.0)


# ==========================================================================
# The tick

func _physics_process(dt: float) -> void:
	if auto_process:
		tick(dt)


func tick(dt: float) -> void:
	if not is_finite(dt) or dt <= 0.0 or model == null:
		return
	# One tick never simulates more than 0.1 s: a longer frame hitch loses
	# time instead of feeding every filter one enormous step.
	dt = minf(dt, 0.1)
	_dt = dt
	var t0 := Time.get_ticks_usec()
	_time += dt
	tick_count += 1
	_apply_mass()
	yaw_flagged = false
	_ignore_perch_t = maxf(0.0, _ignore_perch_t - dt)
	var p := model.params
	var ws_scale := _world_scale()

	# 1. poses
	if pose_source != null:
		pose_source.sample(frame, dt)
	else:
		_neutral_frame()
	if recorder != null:
		recorder.record(frame, dt)
	if frame.discontinuity:
		_discontinuity = true
	var recentered := false
	if _recenter_pending:
		_recenter_pending = false
		wing_input.recenter()
		_discontinuity = true
		recentered = true
	# 2. WingInput
	wing_input.auto_calibrate = auto_calibrate and (mode == Mode.PERCHED or mode == Mode.SPAWNING or mode == Mode.GROUNDED)
	wing_input.refine_span = auto_calibrate
	var wi := wing_input.update(frame, dt)
	# Synthetic sources also move the XR nodes so wings, UI rays and
	# screenshots see them: the VALIDATED poses (a glitching sample is held,
	# never written into the camera or the hands).
	if pose_source != null and pose_source.drives_nodes():
		_write_nodes(ws_scale)
	if recentered:
		# The view faces the flight direction again; the heading is untouched
		# (and nothing is owed to the view any more). The rig's own turn stops
		# with the snap (fix round 5): round 4 kept its rate, so a recenter
		# during a view payout turned on the old way, braking at the 720
		# deg/s^2 safety net (up to v^2/2a = 10 deg), and owed that back.
		rig_yaw = FlightMath.wrap_angle(model.heading() - wi.body_yaw)
		view_turn.reset()
		rig_yaw_rate = 0.0
		_ff_rate = 0.0
		yaw_flagged = true
	# Head tracking lost for 1 s: ask for the pause menu once (§5, the
	# same route as the menu button), not on every tick of the loss.
	if wing_input.pause_requested and not _pause_sent:
		_pause_sent = true
		_request_pause()
	elif not wing_input.pause_requested:
		_pause_sent = false
	_ws.copy_from(wi)
	_roll_input = _ws.roll
	if wi.onset_l or wi.onset_r:
		_last_stroke_t = _time
	if _resume_hold > 0.0:
		# Back in a flying pose: both arms out and settled (neither swinging
		# faster than 0.5 rad/s; still on their way back from the menu, the
		# arm dihedral would bank the bird to its limit).
		_resume_hold -= dt
		var d0: FlapDetector = wing_input.detectors[0]
		var d1: FlapDetector = wing_input.detectors[1]
		if wing_input.ext_raw[0] > 0.6 and wing_input.ext_raw[1] > 0.6 and absf(d0.omega) < 0.5 and absf(d1.omega) < 0.5:
			_resume_hold = 0.0
	var steerable := controls_enabled and mode != Mode.STUNNED and mode != Mode.CAUGHT and _resume_hold <= 0.0
	_controls_fade = move_toward(_controls_fade, 1.0 if steerable else 0.0, dt / 0.4)
	if mode == Mode.STUNNED:
		_ws.set_neutral()
		_ws.ext_l = 0.6
		_ws.ext_r = 0.6
	elif not steerable or _controls_fade < 1.0:
		_blend_neutral(_ws, _controls_fade)
	# 3. body steer (§10.4)
	var psi0 := model.heading()
	var phi_bs := 0.0
	var roll_total := _ws.roll
	if mode == Mode.FLYING and body_steer and steerable:
		# The torso's direction against the heading, with the view where it is
		# heading for: a turn still owed to the view (a bounce off a wall) is
		# not the player's torso asking to turn back (round 3 stun-lock).
		var e := FlightMath.wrap_angle(rig_yaw + view_turn.debt + _ws.body_yaw - psi0)
		var dz := deg_to_rad(5.0 if tuning.preset == 2 else 2.0)
		phi_bs = -signf(e) * minf(1.2 * maxf(0.0, absf(e) - dz), 0.8 * p.phi_max)
		roll_total = clampf(_ws.roll + phi_bs / p.phi_max, -1.0, 1.0)
		_ws.roll = roll_total
	# The body-steered share of the CURRENT turn: both demands pass through
	# the model's bank lag first, so the share fades with the bank instead of
	# snapping to 0 at the dead-zone (a rig-rate step = a yaw-accel spike).
	var kb := FlightMath.lp_k(dt, p.tau_bank)
	_bs_lag += (phi_bs - _bs_lag) * kb
	_bank_lag += (roll_total * p.phi_max - _bank_lag) * kb
	if absf(_bank_lag) > 1e-4 and signf(_bs_lag) == signf(_bank_lag):
		_body_share = clampf(_bs_lag / _bank_lag, 0.0, 1.0)
	else:
		_body_share = 0.0
	# 4. environment
	_build_env()
	_update_takeoff_hold(dt)
	# 5. head motion and the mode logic (WingInput's validated head: a NaN
	# or teleporting head sample is held, it never reaches the rig)
	var h := wing_input.head.origin
	var dh := Vector3.ZERO
	if _discontinuity or not _h_valid:
		_h_ref = h
		_h_valid = true
	else:
		dh = h - _h_ref
	var move_from := model.position
	var head_move := Basis(Vector3.UP, rig_yaw) * (dh * ws_scale)
	match mode:
		Mode.SPAWNING:
			_spawn_t += dt
			model.velocity = Vector3.ZERO
			model.displace(head_move)
			_h_ref = h
			if _spawn_t >= 0.5:
				mode = Mode.FLYING
				_launch(0.0)
		Mode.PERCHED, Mode.GROUNDED:
			_tick_perched(dt, h, ws_scale)
		Mode.FLYING, Mode.STUNNED, Mode.CAUGHT:
			model.displace(head_move)
			_h_ref = h
			model.step(_ws, env, dt)
			if mode == Mode.STUNNED:
				stun_left -= dt
				if stun_left <= 0.0:
					mode = Mode.FLYING
	_discontinuity = false
	# 6. perch capture along this tick's path, then continuous collision
	_no_capture_t = maxf(0.0, _no_capture_t - dt)
	var captured := mode == Mode.FLYING and _try_capture(move_from, model.position)
	if not captured and mode != Mode.PERCHED and mode != Mode.GROUNDED:
		_sweep(move_from, model.position)
		_wing_brush(dt)
	# 7. rig
	var psi1 := model.heading()
	# Heading jumps this tick (the small turn a contact gives the body, a
	# slow bird's heading snapping to its path) are owed to the view in full;
	# the flown turn is split with body steer as before.
	var jump := model.take_heading_step()
	forced_turn = jump
	# The perch assist's sideways push crabs the bird into the wind at up to
	# 200 deg/s in the last half second of a landing (a real, external force
	# turns the air path and the body follows it). That part of the turn is
	# owed to the view too and paid smoothly; on capture the bird faces the
	# view anyway (the perched heading follows the torso).
	if env.accel != Vector3.ZERO and mode == Mode.FLYING:
		var va := model.velocity - model.wind
		var vh2 := va.x * va.x + va.z * va.z
		if vh2 > 0.01:
			jump += (va.z * env.accel.x - va.x * env.accel.z) * dt / vh2
	var dpsi := FlightMath.wrap_angle(psi1 - psi0 - jump)
	var in_air := mode != Mode.PERCHED and mode != Mode.GROUNDED
	var turn := 0.0
	if in_air:
		var ff := (dpsi * (1.0 - _body_share) if body_steer else dpsi) / dt
		# The flown turn is followed directly while its rate changes no faster
		# than half the acceleration cap (the physics' own turns stay inside
		# it: a sparrow's full roll-in peaks near 360 deg/s^2). Anything faster
		# (a heading wiggle at a branch contact, a slow bird's heading catching
		# up with its path) is owed to the view and paid smoothly: a 0.14 deg
		# step in one tick would otherwise read as a 720 deg/s^2 jolt.
		if comfort_caps and model.comfort_yaw_accel > 0.0:
			var soft := 0.5 * model.comfort_yaw_accel * dt
			var ffc := clampf(ff, _ff_rate - soft, _ff_rate + soft)
			jump += (ff - ffc) * dt
			ff = ffc
		_ff_rate = ff
		turn = ff * dt
		view_turn.owe(jump)
	else:
		# Perched or grounded the heading follows the view: nothing is owed.
		_ff_rate = 0.0
		view_turn.reset()
	turn += view_turn.step(dt)
	var yaw_prev := rig_yaw
	var want_rate := turn / dt
	# Safety net for the comfort caps (the physics and the view turn already
	# respect them): the rig's yaw rate and its change per tick are bounded.
	# In the air nothing is dropped: what the caps hold back is owed to the
	# view and paid smoothly (round 2 discarded it, leaving the view off the
	# heading for body steer to "correct" back into the wall). Perched or
	# grounded nothing is owed (the heading follows the view): the rig's turn
	# brakes to rest at the acceleration cap, within 240/720 = 0.33 s (round
	# 3 braked through its view-turn plan, which could not start from a rig
	# turning faster than 120 deg/s and spun the view for tens of seconds).
	if comfort_caps and model.comfort_yaw_rate > 0.0:
		var acc_cap := model.comfort_yaw_accel * dt
		var raw := want_rate
		want_rate = clampf(want_rate, rig_yaw_rate - acc_cap, rig_yaw_rate + acc_cap)
		want_rate = clampf(want_rate, -model.comfort_yaw_rate, model.comfort_yaw_rate)
		if absf(raw - want_rate) > 1e-6 and in_air:
			rig_limited_ticks += 1
			view_turn.owe((raw - want_rate) * dt)
	rig_yaw = FlightMath.wrap_angle(rig_yaw + want_rate * dt)
	var rate := FlightMath.wrap_angle(rig_yaw - yaw_prev) / dt
	rig_yaw_accel = (rate - rig_yaw_rate) / dt
	rig_yaw_rate = rate
	_apply_rig(dt)
	# 8. events, growth, telemetry
	_emit_events()
	if drive_world_scale:
		_drive_world_scale(dt)
	velocity = model.velocity
	tick_us = float(Time.get_ticks_usec() - t0)
	# Telemetry read during this tick (an Events handler: the touchdown's
	# player_perched fires before the rig and the legs are placed) holds
	# mid-tick values: the next read rebuilds it from the finished tick (fix
	# round 6, engineering verifier).
	if _tel_tick == tick_count:
		_tel_tick = -1
	if log_interval > 0.0 and _time - _last_log >= log_interval:
		_last_log = _time
		_log_line()


func _world_scale() -> float:
	return maxf(origin.world_scale, 1e-4) if origin != null else 1.0


func _neutral_frame() -> void:
	# No source: a standing player in the airplane pose (keeps the rig sane).
	var b := HumanPoseModel.new()
	b.set_airplane()
	b.frame(frame)


## Synthetic poses into the XR nodes (scaled positions, unscaled bases):
## WingInput's validated head and hands (held through glitches and loss).
func _write_nodes(ws_scale: float) -> void:
	var hd := wing_input.head
	var hl: Transform3D = wing_input.hands[0]
	var hr: Transform3D = wing_input.hands[1]
	camera.transform = Transform3D(hd.basis.orthonormalized(), hd.origin * ws_scale)
	left_hand.transform = Transform3D(hl.basis.orthonormalized(), hl.origin * ws_scale)
	right_hand.transform = Transform3D(hr.basis.orthonormalized(), hr.origin * ws_scale)
	# Aim = grip * Rx(-60 deg) (the measured convention, §3.2).
	var to_aim := Basis(Vector3.RIGHT, deg_to_rad(-60.0))
	left_aim.transform = Transform3D(left_hand.transform.basis * to_aim, left_hand.transform.origin)
	right_aim.transform = Transform3D(right_hand.transform.basis * to_aim, right_hand.transform.origin)


## Pause through the menu request (the UI toggles pause on it, like the
## menu button); a scene without a UI is paused directly. Never resumes.
func _request_pause() -> void:
	if not has_node(^"/root/Game") or Game.state != Game.State.PLAYING:
		return
	print("[flight] head tracking lost for 1 s: requesting the pause menu")
	if has_node(^"/root/Events"):
		Events.menu_requested.emit()
	if Game.state == Game.State.PLAYING:
		Game.set_state(Game.State.PAUSED)


func _blend_neutral(w: WingState, k: float) -> void:
	# Controls off (menus, CAUGHT) or fading back in after a stun.
	var yaw := w.body_yaw
	w.pitch *= k
	w.roll *= k
	w.ext_l = lerpf(1.0, w.ext_l, k)
	w.ext_r = lerpf(1.0, w.ext_r, k)
	w.flap_l *= k
	w.flap_r *= k
	w.up_l *= k
	w.up_r *= k
	w.flap_dir_l = Vector3.UP.lerp(w.flap_dir_l, k).normalized()
	w.flap_dir_r = Vector3.UP.lerp(w.flap_dir_r, k).normalized()
	w.body_yaw = yaw


# ---- environment -------------------------------------------------------------

## The World, looked up again (at most once a tick) while there is none: a
## World added or regenerated after the player must still bring its wind,
## perches and ground (round 2 looked once, at spawn, and never again).
func _find_world() -> World:
	if _world != null and not is_instance_valid(_world):
		_world = null
	if _world == null and tick_count != _world_tick and is_inside_tree():
		_world_tick = tick_count
		_world = World.find(get_tree())
	return _world


## The world's wind at pos, less any part of it blowing into a face the body
## touched within WALL_AIR_S (see _wall_n).
func _wall_wind(pos: Vector3) -> Vector3:
	var w := _wall_world.get_wind(pos) if _wall_world != null and is_instance_valid(_wall_world) else Vector3.ZERO
	for k in 2:
		if _wall_t[k] > 0.0:
			var into := w.dot(_wall_n[k])
			if into < 0.0:
				w -= _wall_n[k] * into
	return w


## Remembers a face the body touched (normal n) for _wall_wind.
func _touch_wall(n: Vector3) -> void:
	if n.y >= WALL_FLOOR_NY:
		return
	var k := 0 if _wall_t[0] <= 0.0 or _wall_n[0].dot(n) > 0.9 else (1 if _wall_t[1] <= 0.0 or _wall_n[1].dot(n) > 0.9 \
			else (0 if _wall_t[0] < _wall_t[1] else 1))
	_wall_n[k] = n
	_wall_t[k] = WALL_AIR_S


func _build_env() -> void:
	for k in 2:
		_wall_t[k] = maxf(0.0, _wall_t[k] - _dt)
	env.clear_assists()
	var w := _find_world()
	var p := model.params
	if w != null:
		if not env.wind_fn.is_valid() or _wall_world != w:
			_wall_world = w
			env.wind_fn = Callable(self, &"_wall_wind")
		# The wind at each wingtip (env.wind_l / wind_r) is for haptics and
		# telemetry only (FlightEnv): it is sampled when telemetry is read
		# (fix round 6: two World.get_wind calls a tick nobody used).
		# Thin air under the lid: lift, drag and the flap force all fade
		# (FlightEnv.thin_air), so a climb stalls out below the ceiling.
		env.lift_scale = FlightEnv.thin_air(w.ceiling - model.position.y - p.r_body, tuning.thin_air_band, tuning.thin_air_floor)
	else:
		_wall_world = null
		env.wind_fn = Callable()
		env.wind_l = Vector3.ZERO
		env.wind_r = Vector3.ZERO
		env.lift_scale = 1.0
	# One ray straight down serves the ground cushion and ground effect
	# (within 2 spans) and the stall guard and landing configuration (down
	# to the guard height, fix round 6). World.ground_height is the terrain
	# only (no buildings, bridge or water-tower deck): round 5's ray reached
	# 2 spans, so over a 25 m flat roof a full flare zoomed above it, read
	# the terrain and stalled (the round-6 experience verifier).
	var reach := maxf(2.0 * p.span, model.stall_guard_height() + p.r_body + 1.0)
	var d := _ground_distance(reach)
	env.ground_distance = d if d <= 2.0 * p.span else INF
	# The belly's height above the ground for the stall guard (fix round 5):
	# the World's terrain, or the ray above when it finds something closer.
	# (The ray, when it hits, is the nearest surface below, which the
	# terrain can only be at or under.)
	var agl := INF
	if is_finite(d):
		agl = d - p.r_body
	elif w != null:
		var gh := w.ground_height(model.position.x, model.position.z)
		if is_finite(gh):
			agl = model.position.y - p.r_body - gh
	env.agl = agl
	perch_candidate = null
	perch_candidate_dist = -1.0
	var had_assist := _assist_prev
	_assist_prev = Vector3.ZERO
	# The model's cached assist flags (tuning.assists() builds a Dictionary
	# per call: twice a tick was ~3 % of the player tick).
	var asst := model.assists
	if mode == Mode.FLYING and perch_assist and asst.get(&"perch_assist", true):
		_assist_prev = had_assist
		_perch_assist()
		if env.accel == Vector3.ZERO:
			_assist_prev = Vector3.ZERO
	else:
		_assist_perch = null
	if mode == Mode.FLYING and _ws.pitch > 0.2 and asst.get(&"ground_cushion", true):
		_landing_config(agl)


func _space() -> PhysicsDirectSpaceState3D:
	return get_world_3d().direct_space_state if is_inside_tree() else null


func _ground_distance(max_d: float) -> float:
	var space := _space()
	if space == null:
		return INF
	_ray_q.from = model.position
	_ray_q.to = model.position + Vector3.DOWN * max_d
	_ray_q.collision_mask = LAYER_WORLD
	var hit := space.intersect_ray(_ray_q)
	if hit.is_empty():
		env.ground_normal = Vector3.UP
		return INF
	env.ground_normal = hit["normal"]
	return model.position.y - float(hit["position"].y)


# ---- perching (§10.6) --------------------------------------------------------

func _perch_point(p: Perch) -> Vector3:
	return p.position + Vector3.UP * model.params.r_body


## `need_ahead`: only perches within 50 deg of where the bird is flying,
## through the air OR over the ground. Round 2 used the ground velocity only:
## a slow bird in a headwind has a steep ground path (1.5 m/s forward, 0.6
## down), the perch dropped out of that cone at two spans and the assist
## (with its gravity compensation) let go under the grip. The air path is
## where the player points the bird; the ground path is where a crabbing
## player's track goes.
func _nearest_perch(pos: Vector3, radius: float, need_ahead: bool) -> Perch:
	var w := _find_world()
	if w == null:
		return null
	var best: Perch = null
	var best_d := INF
	var fwd := model.forward()
	var va := model.velocity - model.wind
	var vdir_air := va.normalized() if va.length() > 0.2 else fwd
	var vdir_gnd := model.velocity.normalized() if model.velocity.length() > 0.2 else fwd
	var cone := cos(deg_to_rad(50.0))
	for pr in w.find_perches(pos, radius, model.params.span):
		var to := _perch_point(pr) - pos
		var d := to.length()
		if need_ahead and d > 1e-3:
			var u := to / d
			if u.dot(vdir_air) < cone and u.dot(vdir_gnd) < cone:
				continue
		if d < best_d:
			best_d = d
			best = pr
	return best


func _v_cap() -> float:
	var grip := maxf(frame.grip.x, frame.grip.y)
	return tuning.perch_capture_speed * model.params.v_min * (1.4 if grip > 0.5 else 1.0)


## The landing speed the capture and the assist judge (fix round 3): the
## slower of the speed over the branch (the ground speed: perches do not
## move) and the airspeed. Into the wind the feet meet the branch slower
## than the air meets the wings, and that is why real birds land into the
## wind; round 2 judged the airspeed only, so a headwind gave no help at all.
## Downwind a bird slow through the air still has its whole wing for the
## last flare, so the tailwind is not made harder than still air (a
## gameplay rule; FLIGHT_SPEC §19 P-3).
func _landing_speed() -> float:
	return minf(model.airspeed(), model.velocity.length())


## The perch the assist flies to: acquired ahead of the bird (above), then
## held until the bird has passed it, left its reach or it stopped fitting.
## Round 2 re-chose every tick, so a bird sinking under the perch in the
## last span lost the assist exactly when it needed it.
func _assist_target(reach: float) -> Perch:
	var held := _assist_perch
	if held != null:
		var to := _perch_point(held) - model.position
		var passed := to.dot(model.velocity) < 0.0 and to.length() > 0.6 * model.params.span
		var taken := not held.is_free() and held.occupant != self
		if held == _left_perch or taken or not held.fits(model.params.span) or passed or to.length() > 1.5 * reach:
			held = null
	if held == null:
		held = _nearest_perch(model.position, reach, true)
		if held == _left_perch:
			held = null
	_assist_perch = held
	return held


func _perch_assist() -> void:
	var p := model.params
	var a := tuning.perch_assist_for(p.x)
	var reach := a.x * p.span + 0.5 * model.airspeed()
	perch_candidate_dist = -1.0
	if _ignore_perch_t > 0.0:
		_assist_perch = null
		return
	var cand := _assist_target(reach)
	perch_candidate = cand
	if cand == null:
		return
	var tgt := _perch_point(cand)
	var dist := (tgt - model.position).length()
	perch_candidate_dist = dist
	var v := _landing_speed()
	var v_cap := _v_cap()
	if v > 1.6 * v_cap or dist < 1e-3:
		return
	# Aim a little above the grip point while far out, converging onto it:
	# birds land from slightly above, and slow flight sinks.
	tgt += Vector3.UP * 0.3 * p.span * clampf((dist - 0.5 * p.span) / (2.0 * p.span), 0.0, 1.0)
	var to := tgt - model.position
	dist = maxf(to.length(), 1e-3)
	# Proportional navigation (N = 3) toward the perch: the acceleration
	# removes the velocity component across the line of sight, so the bird
	# flies straight into the grip point from wherever it is.
	var vel := model.velocity
	var los := to / dist
	var v_perp := vel - los * vel.dot(los)
	var t_go := dist / maxf(vel.dot(los), 0.5)
	var acc := -v_perp * (3.0 / maxf(t_go, 0.15))
	# Gravity-compensated: also cancel the bird's own acceleration across
	# the line of sight (slow flight sinks at up to ~0.5 g near V_cap).
	var a_nat := model.last_accel() - _assist_prev
	acc -= a_nat - los * a_nat.dot(los)
	# Wind: the assist crabs for the player. The wind's component across the
	# line of sight is a drift the player cannot see; removing it gets its
	# own budget on top of the steering cap (up to 0.5 g, what the PN law
	# spends on that drift), so a bird aimed at the branch in the world's
	# breeze still arrives. Still air: exactly the round-2 cap. Round 2 had
	# one shared 0.6 g, mostly spent holding up a bird at 0.8 V_min: a 1.5 m/s
	# crosswind left a sparrow 1.4 spans off the branch every time.
	var w_perp := model.wind - los * model.wind.dot(los)
	var cap := a.y * FlightMath.G + minf(w_perp.length() * 3.0 / maxf(t_go, 0.15), 0.5 * FlightMath.G)
	if acc.length() > cap:
		acc = acc.normalized() * cap
	# Headwind (fix round 5): the bird keeps creeping toward the perch. A slow
	# approach into a wind that is a large share of its stall speed (a
	# sparrow in the world's 2.64 m/s breeze at 30 m: 65 % of V_min) loses
	# airspeed to drag until the air carries it backwards, 0.6 m short of the
	# branch (round 4: never perched). Below a closing speed of 0.25 V_cap
	# along the line of sight the assist cancels the bird's own deceleration
	# along it and closes the gap, from the headwind's own budget (like the
	# crosswind's above: at most 0.5 g, on top of the steering cap): the
	# small wingbeats of a bird landing into the wind. Still air and
	# tailwinds are unchanged.
	var w_head := maxf(0.0, -model.wind.dot(los))
	var v_floor := 0.25 * v_cap
	var v_close := vel.dot(los)
	if w_head > 0.0 and v_close < v_floor:
		var budget := minf(w_head * 3.0 / maxf(t_go, 0.15), 0.5 * FlightMath.G)
		acc += los * clampf(-a_nat.dot(los) + (v_floor - v_close) / 0.3, 0.0, budget)
	# Air-brake (legs, tail and wings up, as landing birds do): just enough
	# deceleration to arrive at 0.95 V_cap, at most 0.5 g along -v (over the
	# ground: the brake slows the bird relative to the branch). The spec's
	# flare and CD bonus alone brake ~0.25 g and a glide cannot get below
	# ~1.03 V_min, so without it no approach reaches the 0.8 V_min capture.
	# The landing speed must drop by dv while the bird covers the distance at
	# its ground speed: a = dv (v_g - dv / 2) / d, which is (v^2 - v_a^2) / 2d in
	# still air. Round 2 used that still-air form with the airspeed, which in
	# a tailwind (the branch arrives sooner) braked half as hard as needed.
	# The brake also cancels the bird's own acceleration along its path (a
	# dive onto a branch from above gains speed as fast as it is braked; the
	# along-path twin of the gravity compensation across the line of sight).
	var v_arrive := 0.95 * v_cap
	var vg := vel.length()
	if v > v_arrive and vg > 0.1:
		var dv := v - v_arrive
		var a_req := dv * maxf(vg - 0.5 * dv, 0.1) / maxf(dist - 0.5 * p.span, 0.05)
		var a_along := maxf(a_nat.dot(vel / vg), 0.0)
		acc -= vel / vg * minf(1.2 * a_req + a_along, 0.5 * FlightMath.G)
	env.accel = acc
	_assist_prev = acc
	# Auto-flare and landing configuration: speed down linearly to 0.9 V_cap
	# at the perch (alpha bias <= 3 deg, legs and tail down <= +0.4 CD).
	var v_goal := lerpf(0.9 * v_cap, 1.6 * v_cap, clampf(dist / reach, 0.0, 1.0))
	var over := (v - v_goal) / maxf(v_goal, 0.1)
	env.alpha_bias = clampf(over * deg_to_rad(6.0), 0.0, deg_to_rad(3.0))
	env.drag_bonus = clampf(over * 0.8, 0.0, 0.4) if v > 0.8 * v_cap else 0.0


## Landing configuration over the ground (fix round 5): a slow bird that
## flares while sinking near the ground lowers its legs and fans its tail,
## as landing birds do (the perch assist's configuration: up to +0.4 CD, at
## most 0.5 g of extra drag). It fades in with the flare (pitch command 0.2
## to 0.6), with slowness (1.6 to 1.3 V_min), with the sink (0 to 0.5 m/s)
## and toward the ground (tuning.landing_config_spans to one span less), so a
## pull-up from a low pass (fast, climbing) and a trimmed skim (no flare) fly
## as before. Round 4 had it only for perches: an eagle's flare over a
## meadow zoomed 7 spans up and then glided at L/D 14 for 20 s before it
## could touch down.
func _landing_config(agl: float) -> void:
	var p := model.params
	if not is_finite(agl) or wing_input.state.tucked:
		return
	var zone := tuning.landing_config_spans * p.span
	var k := FlightMath.sstep(0.2, 0.6, _ws.pitch) \
		* (1.0 - FlightMath.sstep(1.3, 1.6, model.airspeed() / p.v_min)) \
		* FlightMath.sstep(0.0, 0.5, model.wind.y - model.velocity.y) \
		* (1.0 - FlightMath.sstep(zone - p.span, zone, agl))
	if k <= 0.0:
		return
	var v := model.airspeed()
	var q := 0.5 * tuning.rho * v * v * p.s
	var cap := 0.5 * p.mass * FlightMath.G / maxf(q, 1e-6)
	env.drag_bonus = maxf(env.drag_bonus, minf(0.4 * k, cap))


## Capture (§10.6) if this tick's path passes within reach of a free,
## fitting perch slowly enough. Tested before the collision sweep, so a
## gentle approach grabs the branch instead of bouncing off it.
func _try_capture(from: Vector3, to: Vector3) -> bool:
	if mode != Mode.FLYING or _ignore_perch_t > 0.0 or _no_capture_t > 0.0 or not controls_enabled:
		return false
	if wing_input.state.tucked:
		return false  # a tucked bird is diving, not landing
	var p := model.params
	var reach := maxf(0.6 * p.span, 2.0 * p.r_body)
	if _left_perch != null and to.distance_to(_perch_point(_left_perch)) > 1.5 * reach:
		_left_perch = null
	var seg := to - from
	var cand := _nearest_perch(to, reach + seg.length() + 0.01, false)
	if cand == null or cand == _left_perch:
		return false
	var tgt := _perch_point(cand)
	var k := clampf((tgt - from).dot(seg) / maxf(seg.length_squared(), 1e-12), 0.0, 1.0)
	var closest := from + seg * k
	if closest.distance_to(tgt) > reach:
		return false
	var v_cap := _v_cap()
	if _landing_speed() > v_cap or -model.velocity.y > v_cap:
		return false
	if closest.y < cand.position.y - 0.5 * p.span:
		return false
	if perch_needs_grip and maxf(frame.grip.x, frame.grip.y) < 0.5:
		return false
	_capture(cand, from, model.velocity)
	return true


## Grab the perch. The body does not stop in one tick (a 30 m/s perceived
## jolt for a sparrow, then a linear slide to the grip: round 1): it follows
## a cubic Hermite from this tick's start point, leaving with the approach
## velocity, to the grip point at rest. T = 2 d / V makes that a uniform
## deceleration; T <= 3 d / V keeps it from passing the grip point.
func _capture(p: Perch, from := Vector3.INF, v0 := Vector3.ZERO) -> void:
	perch = p
	p.occupant = self
	mode = Mode.PERCHED
	perched = true
	var tgt := _perch_point(p)
	_ease_from = model.position if not from.is_finite() else from
	_ease_v0 = v0
	var d := _ease_from.distance_to(tgt)
	var vv := v0.length()
	if vv > 1e-3 and d > 1e-4:
		_ease_len = clampf(2.0 * d / vv, minf(0.1, 0.98 * 3.0 * d / vv), 0.5)
	else:
		_ease_len = 0.15
		_ease_v0 = Vector3.ZERO
	# This tick is the ease's first step.
	_ease_t = clampf(_ease_len - _dt, 0.0, _ease_len)
	model.position = _ease_point(tgt)
	model.velocity = Vector3.ZERO
	model.airspeed_v = 0.0      # telemetry: a gripping bird has no airspeed
	_takeoff_strokes.clear()
	_launch_pend[0] = 0.0
	_launch_pend[1] = 0.0
	_assist_perch = null
	# Perched, the heading follows the view (C7: perching never turns it):
	# what the view still owed is forgiven, and a turn in progress brakes to
	# rest inside the comfort acceleration cap (tick step 7).
	view_turn.reset()
	if has_node(^"/root/Events"):
		Events.player_perched.emit(p.position)


## Where the capture ease has the body now (_ease_t counts down).
func _ease_point(tgt: Vector3) -> Vector3:
	var u := clampf(1.0 - _ease_t / maxf(_ease_len, 1e-4), 0.0, 1.0)
	var u2 := u * u
	var u3 := u2 * u
	var h00 := 2.0 * u3 - 3.0 * u2 + 1.0
	var h10 := u3 - 2.0 * u2 + u
	var h01 := -2.0 * u3 + 3.0 * u2
	return _ease_from * h00 + _ease_v0 * (h10 * _ease_len) + tgt * h01


func _release_perch() -> void:
	if perch != null and perch.occupant == self:
		perch.occupant = null
	if perch != null:
		_left_perch = perch
	perch = null
	perched = false


func _tick_perched(dt: float, h: Vector3, ws_scale: float) -> void:
	var p := model.params
	# Body locked to the perch (or ground point); easing in after a capture.
	var anchor := _perch_point(perch) if perch != null else model.position
	if mode == Mode.GROUNDED:
		# The touchdown's run-out (fix round 5) moves the ground point.
		_run_out(dt)
		if mode != Mode.GROUNDED:
			return  # ran off an edge: flying again
		anchor = model.position
	if _ease_t > 0.0:
		_ease_t = maxf(0.0, _ease_t - dt)
		model.position = _ease_point(anchor)
	else:
		model.position = anchor
	model.velocity = _run_v if mode == Mode.GROUNDED else Vector3.ZERO
	model.airspeed_v = 0.0
	# The heading follows the torso: turning your body on a perch turns the
	# bird, and the view never rotates.
	model.chi = FlightMath.wrap_angle(rig_yaw + _ws.body_yaw)
	model.dpsi = 0.0
	model.phi = 0.0
	# A perched bird stands level (the flare's nose-up eases out).
	model.theta *= exp(-dt / 0.2)
	# Head motion moves the camera, not the anchor, within a 0.5 m leash.
	var off := h - _h_ref
	var off_h := Vector2(off.x, off.z)
	if off_h.length() > 0.5:
		var excess := off_h - off_h.normalized() * 0.5
		_h_ref += Vector3(excess.x, 0.0, excess.y)
	# Launch. Arms hanging at the sides (or folded, hands to the chest) are
	# the REST pose and never launch: the tuck means "dive" only in flight
	# (fix round 4; round 3's tuck-drop threw a player who relaxed on a
	# branch 20 m to the ground). Off a perch only a completed flap launches
	# (see _completed_flap). On the ground the credited onset still does:
	# the stroke must lift the bird with its whole downstroke (launched at
	# the bottom of the stroke it settled back before the next one), and a
	# relaxing arm drop there is at most a hop, not a fall.
	var credit := 0.0
	if mode == Mode.GROUNDED:
		var wi := wing_input.state
		if wi.onset_l or wi.onset_r:
			credit = wi.onset_strength
	else:
		credit = _completed_flap()
	if not controls_enabled:
		credit = 0.0
	if mode == Mode.GROUNDED:
		if credit >= 0.35:
			_takeoff_strokes.append(_time)
		while not _takeoff_strokes.is_empty() and _time - _takeoff_strokes[0] > 1.2:
			_takeoff_strokes.pop_front()
		var need := 2 if p.mass >= 0.9 * FlightParams.species_mass(&"pigeon") else 1
		if _takeoff_strokes.size() >= need:
			_takeoff_strokes.clear()
			_leave_perch_with_head(h, ws_scale)
			_launch(maxf(credit, 0.5))
		return
	if credit >= 0.35:
		_leave_perch_with_head(h, ws_scale)
		_launch(credit)


## The credit (0 = none) of a flap completed this tick, the only way off a
## perch (FLIGHT_SPEC §10.2, fix round 4): a credited downstroke
## (onset credit >= 0.35) that ENDS with the wing still out (the arm at or
## above the fold line, not folded in), or that ended low (a deep stroke) and
## rises back out within 0.8 s: the stroke's recovery. Letting the arms fall
## to your sides on a branch is a downstroke too, often a brisk one after
## holding them out, but it ends folded and stays there: that is the rest
## pose, never a launch. The bird leaves at the bottom of the stroke (or at
## a deep stroke's recovery): the onset alone could not tell the two apart.
## Either wing's stroke counts (a one-wing flap launches too).
func _completed_flap() -> float:
	var out := 0.0
	var cal := wing_input.calibration
	var fold_hi := deg_to_rad(-55.0) if cal.seated else cal.fold_elevation
	for i in 2:
		var d: FlapDetector = wing_input.detectors[i]
		if d.onset and d.onset_strength >= 0.35:
			_launch_pend[i] = d.onset_strength
			_launch_low[i] = -1.0
		if _launch_pend[i] <= 0.0:
			continue
		var wing_out := wing_input.elevation[i] >= fold_hi and wing_input.ext_raw[i] >= 0.5
		if _launch_low[i] < 0.0:
			if d.omega < FlapDetector.W_DN:
				# The downstroke has ended: a flap if the wing is still out;
				# ended low, it is a flap only if the arm comes back out.
				if wing_out:
					out = maxf(out, _launch_pend[i])
					_launch_pend[i] = 0.0
				else:
					_launch_low[i] = 0.0
		else:
			_launch_low[i] += _dt
			if wing_out:
				out = maxf(out, _launch_pend[i])
				_launch_pend[i] = 0.0
			elif _launch_low[i] > 0.8:
				_launch_pend[i] = 0.0     # folded and staying down: resting
	return out


func _collect_perch_colliders() -> void:
	_launch_exclude.clear()
	var space := _space()
	if space == null or perch == null:
		return
	var q := PhysicsShapeQueryParameters3D.new()
	var sph := SphereShape3D.new()
	sph.radius = model.params.r_body * 1.5
	q.shape = sph
	q.transform = Transform3D(Basis.IDENTITY, perch.position)
	q.collision_mask = LAYER_WORLD | LAYER_PERCH
	for hit in space.intersect_shape(q, 8):
		_launch_exclude.append(hit["rid"])


## Leaving the perch: the body moves to where the (leashed) head is, swept,
## so the view does not jump.
func _leave_perch_with_head(h: Vector3, ws_scale: float) -> void:
	_collect_perch_colliders()
	var off := Basis(Vector3.UP, rig_yaw) * ((h - _h_ref) * ws_scale)
	var from := model.position
	model.displace(off)
	_h_ref = h
	_ignore_perch_t = 0.4
	_sweep(from, model.position)


func _launch(credit: float) -> void:
	var p := model.params
	var heading := model.heading()
	var f := FlightMath.yaw_forward(heading)
	# The surface the bird leaves: the ground under its feet, or level (a
	# branch, a spawn).
	var from_ground := mode == Mode.GROUNDED
	var n := _ground_n if from_ground else Vector3.UP
	_release_perch()
	mode = Mode.FLYING
	_ignore_perch_t = 0.4
	var v := f * 0.6 * p.v_min
	if _run_v != Vector3.ZERO:
		# A take-off during the touchdown's run-out keeps the run's speed
		# (fix round 5): no step back to 0.6 V_min.
		v = _run_v + f * maxf(0.0, 0.6 * p.v_min - _run_v.dot(f))
		_run_v = Vector3.ZERO
	# Off a slope (fix round 6): the launch never points into the ground (it
	# runs up along a slope the bird faces, at the same speed) and the kick
	# is along the surface normal. Round 5 launched level and straight up:
	# facing up any slope above 20-25 deg the launch drove the bird into the
	# slope, which touched it down again on the next tick.
	var into := v.dot(n)
	if into < 0.0:
		var sp := v.length()
		v -= n * into
		if v.length() > 1e-4:
			v *= sp / v.length()
	model.reset(model.position, v + n * 0.35 * p.v_min * credit, heading)
	_ground_n = Vector3.UP
	_takeoff_t = 0.0 if from_ground else -1.0
	if credit > 0.0 and has_node(^"/root/Events"):
		Events.player_took_off.emit()


## The take-off hold (fix round 6): a bird launched off the ground is not
## touched down again while it keeps flapping, or for take_off_hold_s after
## the launch, until it is clear of the ground (two spans off the surface
## below, along its normal: on a slope the height straight down overstates
## it). Touching the ground meanwhile is its feet scrambling (a silent
## contact): birds run up a slope they cannot yet out-climb, flapping.
## Round 5 touched such a bird down again on the next tick facing up a
## slope, and every later stroke launched it and landed it again.
func _update_takeoff_hold(dt: float) -> void:
	if _takeoff_t < 0.0:
		return
	_takeoff_t += dt
	# Still flapping: a stroke began within the take-off window (the same
	# 1.2 s the ground launch counts strokes in; the activity low-pass
	# decays below any threshold between the first slow strokes).
	var flapping := _time - _last_stroke_t <= tuning.take_off_hold_gap and controls_enabled
	var clear := env.agl * clampf(env.ground_normal.y, 0.0, 1.0) > 2.0 * model.params.span
	if mode != Mode.FLYING or clear or (_takeoff_t >= tuning.take_off_hold_s and not flapping):
		_takeoff_t = -1.0


func _takeoff_holding() -> bool:
	return _takeoff_t >= 0.0 and mode == Mode.FLYING


# ---- collisions (§12) --------------------------------------------------------

func _collision_mask() -> int:
	return LAYER_WORLD | (LAYER_PERCH if _ignore_perch_t <= 0.0 else 0)


func _apply_exclusions() -> void:
	_shape_q.exclude = _launch_exclude if _ignore_perch_t > 0.0 else ([] as Array[RID])


func _sweep(from: Vector3, to: Vector3) -> void:
	var space := _space()
	if space == null:
		return
	var p := model.params
	_sphere.radius = p.r_body
	_shape_q.collision_mask = _collision_mask()
	_apply_exclusions()
	var pos := from
	var motion := to - from
	# The feet first (fix round 6): a bird slow enough to land reaches for
	# the ground with its legs, and a floor the feet meet along this tick's
	# path is the touchdown. The body then settles onto it (along the
	# normal, swept) and the legs take the speed into it over their reach
	# plus their flex (_touch_down), where round 5 met the ground with the
	# belly and had the flex alone.
	if _feet_ok():
		var ft := _feet_contact(pos, motion)
		if not ft.is_empty():
			var f := float(ft["frac"])
			var n: Vector3 = ft["n"]
			pos += motion * f
			_shape_q.collision_mask = _collision_mask()
			var drop := -n * float(ft["reach"])
			var rr := _cast(pos, drop)
			pos += drop * float(rr[0]) + n * 0.0005    # the sweep's 0.5 mm skin
			model.position = pos
			contacts["land"] += 1
			last_contact = Contact.LAND
			_touch_down(n, float(ft["reach"]) * float(rr[0]))
			_leg_dt = (1.0 - f) * _dt
			# The rest of the tick's motion carries on along the ground.
			var rem := motion * (1.0 - f)
			motion = rem - n * minf(0.0, rem.dot(n))
			_apply_exclusions()
	for it in 3:
		if motion.length() < 1e-7:
			break
		_shape_q.transform = Transform3D(Basis.IDENTITY, pos)
		_shape_q.motion = motion
		var res := space.cast_motion(_shape_q)
		if res.size() < 2 or res[1] >= 1.0:
			pos += motion
			break
		var safe := res[0]
		var unsafe := res[1]
		# Contact at the first unsafe position. For a sphere the true normal
		# is centre minus contact point; the engine's reported normal is
		# unreliable in grazing contact (a flat wall once read (0.98, 0.21, 0)).
		var hit_pos := pos + motion * unsafe
		_shape_q.transform = Transform3D(Basis.IDENTITY, hit_pos)
		_shape_q.motion = Vector3.ZERO
		var info := space.get_rest_info(_shape_q)
		if info.is_empty():
			# Grazing: the cast stopped the sphere a hair short of a surface
			# that the rest query at the same radius does not reach (sliding
			# down a wall). Look again with a 2 mm margin. Never guess the
			# normal from the motion (round 3 did): a fall along a wall then
			# read as a floor hit at the full fall speed, and stunned.
			_sphere.radius = p.r_body + 0.002
			info = space.get_rest_info(_shape_q)
			_sphere.radius = p.r_body
		pos += motion * safe
		if info.is_empty():
			# Still nothing to touch: stop at the safe point, no response.
			break
		var n: Vector3 = info["normal"]
		# Perch geometry (a branch, layers 1 + 2) is never ground to land on
		# (_classify): a slow bird that meets the top of a branch away from its
		# grip point slides on it, and the capture takes it at the grip.
		var col: Object = instance_from_id(int(info["collider_id"])) if info.has("collider_id") else null
		_hit_perch = col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & LAYER_PERCH) != 0
		var from_point: Vector3 = hit_pos - info["point"]
		if from_point.length() > 1e-5:
			n = from_point.normalized()
		# The arena's lid (an invisible slab whose underside is World.ceiling,
		# soaring_world._build_boundary): whatever body makes it, a surface met
		# from below at the ceiling is the sky's end, not a wall.
		var w := _find_world()
		_hit_lid = w != null and n.y < -0.5 and (info["point"] as Vector3).y >= w.ceiling - 0.05
		_hit_water = w != null and n.y > 0.7 and w.is_water(info["point"])
		if debug_contacts:
			print("[flight] sweep hit_pos=%s point=%s normal=%s safe=%.4f unsafe=%.4f motion=%s" % [hit_pos, info["point"], info["normal"], safe, unsafe, motion])
		var legs_were := _legs.active()
		# The contact happens here: a touchdown reads the ground from (and
		# reports) this point, not the tick's unswept end.
		model.position = pos
		_touch_wall(n)
		var kind := _classify(n)
		# Keep a 0.5 mm skin so the next (tangential) cast does not start in contact.
		pos += n * 0.0005
		var remaining := motion * (1.0 - safe)
		if kind == Contact.STUN:
			break
		if kind == Contact.LAND or (not legs_were and _legs.active()):
			# A touchdown keeps the rest of the tick's motion along the ground
			# (round 4 dropped it: a 3 m/s dip of the view's speed for one tick),
			# and the legs take the rest of its fall (_apply_rig).
			_leg_dt = (1.0 - safe) * _dt
		# Slide: continue with the tangential part of the remaining motion.
		motion = remaining - n * minf(0.0, remaining.dot(n))
	model.position = pos
	_depenetrate()


## A bird that could land now reaches for the ground with its feet: flying,
## at or below the touchdown speed, and not taking off.
func _feet_ok() -> bool:
	return mode == Mode.FLYING and tuning.leg_reach > 0.0 and not _takeoff_holding() \
		and model.airspeed() <= tuning.touchdown_speed * model.params.v_min


## The feet's first touchdown along this tick's motion (fix round 6): the
## legs reach leg_reach body radii beyond the body, modelled as a sphere of
## r_body + reach round the body's centre (landing birds swing their feet
## toward the surface they land on, so the reach is along its normal).
## Returns {} when nothing the feet may stand on is met, or when the meeting
## is no touchdown (too hard: the body's own contact decides); else
## {"frac": motion fraction at the meeting, "n": the surface normal,
## "reach": the body's height above its resting distance there (m)}.
## Jolt's cast_motion ignores shapes the sphere starts in, so a rest query
## at the start comes first (feet already on the ground: the bird slowed to
## landing speed low over it).
func _feet_contact(from: Vector3, motion: Vector3) -> Dictionary:
	var space := _space()
	if space == null:
		return {}
	var p := model.params
	var reach := tuning.leg_reach * p.r_body
	var rf := p.r_body + reach
	_sphere.radius = rf
	_shape_q.transform = Transform3D(Basis.IDENTITY, from)
	_shape_q.motion = Vector3.ZERO
	var frac := 0.0
	var at := from
	var info := space.get_rest_info(_shape_q)
	if info.is_empty():
		if motion.length() < 1e-7:
			_sphere.radius = p.r_body
			return {}
		_shape_q.motion = motion
		var res := space.cast_motion(_shape_q)
		if res.size() < 2 or res[1] >= 1.0:
			_sphere.radius = p.r_body
			return {}
		frac = res[0]
		at = from + motion * res[1]
		_shape_q.transform = Transform3D(Basis.IDENTITY, at)
		_shape_q.motion = Vector3.ZERO
		_sphere.radius = rf + 0.002
		info = space.get_rest_info(_shape_q)
	_sphere.radius = p.r_body
	if info.is_empty():
		return {}
	var d: Vector3 = at - info["point"]
	var n: Vector3 = d.normalized() if d.length() > 1e-5 else info["normal"]
	var col: Object = instance_from_id(int(info["collider_id"])) if info.has("collider_id") else null
	var on_perch := col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & LAYER_PERCH) != 0
	# Only a floor the feet can stand on (a wall, an edge from the side, a
	# branch or water is the body's contact to classify), met at landing
	# speed and not too hard (a touchdown, _classify's rule).
	var w := _find_world()
	if n.y <= 0.7 or on_perch or (w != null and w.is_water(info["point"])):
		return {}
	var vn := -model.velocity.dot(n)
	if vn < 0.0 or vn > tuning.touchdown_vn * p.v_min:
		return {}
	var pos := from + motion * frac
	var h := (pos - (info["point"] as Vector3)).dot(n) - p.r_body
	return {"frac": frac, "n": n, "reach": clampf(h, 0.0, reach)}


func _depenetrate() -> void:
	var space := _space()
	if space == null:
		return
	_shape_q.transform = Transform3D(Basis.IDENTITY, model.position)
	_shape_q.motion = Vector3.ZERO
	for it in 4:
		var info := space.get_rest_info(_shape_q)
		if info.is_empty():
			return
		var pt: Vector3 = info["point"]
		var d := model.position - pt
		var n: Vector3 = d.normalized() if d.length() > 1e-6 else info["normal"]
		var depth := model.params.r_body - d.length()
		if depth <= 0.001:
			return
		_touch_wall(n)
		model.position += n * (depth + 0.0005)
		_shape_q.transform = Transform3D(Basis.IDENTITY, model.position)


func _classify(n: Vector3) -> int:
	var p := model.params
	var v := model.velocity
	var vn := -v.dot(n)
	if debug_contacts:
		print("[flight] contact n=%s v=%s vn=%.2f pos=%s mode=%s" % [n.snapped(Vector3.ONE * 0.01), v.snapped(Vector3.ONE * 0.01), vn,
			model.position.snapped(Vector3.ONE * 0.001), mode_name()])
	if vn <= 0.0:
		return Contact.SILENT
	var speed := v.length()
	var v_stun := maxf(0.35 * p.v_c, 2.0)
	var incidence := asin(clampf(vn / maxf(speed, 1e-6), 0.0, 1.0))
	var floor_hit := n.y > 0.7
	var kind := Contact.SLIDE
	# Touchdown (fix round 5): on the ground a wing at or below the touchdown
	# speed (1.2 V_min) touching it has landed, and runs out (_touch_down).
	# Round 4 needed 0.7 V_min: a bird between 0.7 and 1 V_min slid along the
	# grass "flying" for up to 15 s. Never on perch geometry (a branch top is
	# not a meadow: at 1.2 V_min a slow sparrow once "landed" on a branch
	# 0.2 m from the grip and ran off it).
	# Fix round 6: the speed into the surface may be up to touchdown_vn (1
	# V_min; round 5 capped it at the perch capture speed, 0.8 V_min, and a
	# slow bird flying into a 44 deg roof was stunned), and a bird taking off
	# does not touch down again (_update_takeoff_hold): its feet scramble on
	# the ground while its wings lift it off (a silent contact, no friction).
	var soft_floor := floor_hit and not _hit_perch and not _hit_water and vn <= tuning.touchdown_vn * p.v_min and mode == Mode.FLYING
	var scramble := soft_floor and _takeoff_holding()
	if scramble:
		# A scramble that no longer makes way up or along the slope (a big bird
		# facing up a slope steeper than it can climb, its launch spent) is the
		# feet holding on again: it stands (a touchdown), never slides back
		# down the slope on its belly.
		var f := FlightMath.yaw_forward(model.heading())
		f = (f - n * f.dot(n)).normalized()
		if v.dot(f) < 0.05 * p.v_min:
			scramble = false
	if _hit_water and floor_hit and mode != Mode.CAUGHT:
		# Water is no ground (integration round 1): whatever the speed into
		# it, the bird splashes and hops off - no touchdown, no stun, no
		# stand - and flaps on or glides away.
		contacts["water"] += 1
		last_contact = Contact.SLIDE
		model.velocity += n * (vn + maxf(WATER_HOP, 0.35 * vn))
		if mode == Mode.STUNNED:
			mode = Mode.FLYING
		# (The hops that follow - a bird that does not flap bounces on the
		# water - are not collisions for the ear and the hands.)
		if vn > WATER_HOP * 1.25 and has_node(^"/root/Events"):
			Events.player_collided.emit(vn, n)
		return Contact.SLIDE
	if _hit_lid:
		# The arena's lid never stuns (integration fix): the thin air below it
		# (FlightEnv.thin_air) stops every climb short of it, so only momentum
		# (a zoom) can reach it, and then the bird slides along it gently,
		# its upward speed taken, whatever the impact. Round 6 stunned a
		# flapping sparrow there five or six times in 40 s.
		contacts["lid"] += 1
		kind = Contact.SILENT if vn < 0.5 else Contact.SLIDE
	elif soft_floor and not scramble and model.airspeed() <= tuning.touchdown_speed * p.v_min:
		kind = Contact.LAND
	elif scramble or vn < 0.5:
		kind = Contact.SILENT
	elif vn < v_stun or (incidence < deg_to_rad(25.0) and vn < 0.7 * p.v_c) or mode == Mode.STUNNED or mode == Mode.CAUGHT:
		kind = Contact.SLIDE
	else:
		kind = Contact.STUN
	last_contact = kind
	match kind:
		Contact.SILENT:
			# Grazing or resting contact: remove the inward speed, no friction
			# against walls (sliding along a wall must not bleed 8% of the speed
			# every tick). On the ground the belly or feet pressed onto it skid
			# (fix round 5): Coulomb friction takes mu x the normal impulse from
			# the speed along the ground, which is (1 - lift / weight) mu g for a
			# bird its wings no longer hold up. Round 4 had none, and a bird below
			# stall speed slid on for 7-15 s.
			contacts["silent"] += 1
			if vn > 0.0:
				model.velocity += n * vn
				if floor_hit and not scramble:
					var vt := model.velocity - n * model.velocity.dot(n)
					var st := vt.length()
					if st > 1e-6:
						model.velocity -= vt * minf(1.0, tuning.ground_friction * vn / st)
		Contact.SLIDE:
			contacts["slide"] += 1
			# A scrape too fast to perch locks the capture out for 0.5 s (no
			# grabbing a branch the bird is skidding off). A slow bird brushing
			# the branch it is landing on can still grab it (fix round 5): a
			# sparrow crabbing into a 2.64 m/s crosswind brushed the branch from
			# below, then hung within reach of the grip, locked out, and fell.
			if _landing_speed() > _v_cap():
				_no_capture_t = 0.5
			model.apply_contact(n, FlightModel.Contact.SLIDE)
			if floor_hit and not _hit_perch and vn * _dt <= maxf(tuning.leg_flex, 0.05) * p.r_body:
				# A belly skid on the ground (too fast to land): the legs take the
				# speed into it for the view too (fix round 6), when their bend can
				# spread the stop over two ticks or more (v_n <= flex / dt: a
				# sparrow's 2 m/s). A harder skid would stop the camera within about
				# a tick anyway, and a stop split unevenly across the tick boundary
				# can read as more jerk than the body's own (the fixture's comfort
				# rule); there the view stops with the body, as in round 5.
				_legs_absorb(n, vn)
			if has_node(^"/root/Events"):
				Events.player_collided.emit(vn, n)
		Contact.LAND:
			contacts["land"] += 1
			_touch_down(n)
		Contact.STUN:
			contacts["stun"] += 1
			_no_capture_t = 0.5
			model.apply_contact(n, FlightModel.Contact.BOUNCE, tuning.floor_restitution if floor_hit else 0.25, _stun_turn(n))
			mode = Mode.STUNNED
			stun_left = clampf(0.6 + 0.8 * (vn - v_stun) / p.v_c, 0.6, 1.4)
			_controls_fade = 0.0
			if has_node(^"/root/Events"):
				Events.player_collided.emit(vn, n)
	return kind


## Touchdown on the ground (fix round 5; along slopes, fix round 6):
## GROUNDED, but the body keeps its speed along the ground and runs out
## (_run_out) instead of stopping in one tick. Round 4 zeroed the velocity on
## the touchdown tick: the whole landing speed in one tick (a 17.8 m/s
## perceived stop for a sparrow), where a perch capture has eased in since
## round 1 (P9). Only the speed into the ground is taken, by the legs.
## `n`: the surface normal met. `reach`: how far the camera still is above
## where the body rests (the feet met the ground first, _feet_contact).
## Round 5 flattened the run to horizontal and bent the legs vertically: on
## an upslope the run's uphill part and the speed into the slope stopped in
## one tick (0.5-0.9 x the touchdown speed; the round-6 experience verifier).
func _touch_down(n: Vector3, reach := 0.0) -> void:
	# The surface's own normal where the contact's (centre minus contact
	# point, a hair off inside a face) agrees with it: the run then keeps
	# exactly to the plane from the first tick.
	var space := _space()
	if space != null:
		_ray_q.from = model.position
		_ray_q.to = model.position - n * (model.params.r_body + 0.02)
		_ray_q.collision_mask = LAYER_WORLD
		var hit := space.intersect_ray(_ray_q)
		if not hit.is_empty() and (hit["normal"] as Vector3).dot(n) > 0.95:
			n = hit["normal"]
	var v := model.velocity
	var vn := maxf(-v.dot(n), 0.0)
	_run_v = v + n * vn            # the part along the ground (v - n (v.n))
	_ground_n = n
	_legs_start(n, reach, vn)
	model.velocity = _run_v
	model.airspeed_v = 0.0
	# On the ground the heading follows the view: nothing more is owed, and
	# the rig's own turn brakes to rest inside the comfort caps.
	view_turn.reset()
	mode = Mode.GROUNDED
	perched = true
	_takeoff_strokes.clear()
	_takeoff_t = -1.0
	if has_node(^"/root/Events"):
		Events.player_perched.emit(model.position - n * model.params.r_body)


## The legs take `vn` (m/s) into the surface of normal `n` (fix rounds 5-6):
## the camera, `reach` above where the body rests, carries on along -n and
## stops within the reach plus the flex (tuning.leg_flex body radii below
## rest, at most), then comes back to rest; the view never stops in one
## tick. Two phases (_legs_step):
##  1. The bend: a constant deceleration, the gentlest that fits: a stop
##     exactly at rest (no dip) when that takes up to 2 g, else a dip, at
##     2 g or what stopping within the whole travel needs. A settle slower
##     than 1 g (a slow bird whose feet reach the ground) is instead the
##     follower's 1 g move straight down to rest, which never stops short.
##  2. The stand: from the bottom back to rest, time-optimally at no more
##     than 2 g (round 5 came back at the bend's own deceleration, up to
##     15 g for a sparrow, so the view shot back up as hard as it stopped).
## The worst per-tick change of the view's velocity is the bend's
## deceleration x dt.
func _legs_start(n: Vector3, reach: float, vn: float) -> void:
	if _legs.active():
		# Already bending (a skid on the ground a tick ago): the camera stays
		# where it is. The body's drop onto the ground adds to the bend, and
		# so does the new speed into it.
		_legs.debt -= reach * maxf(n.dot(_leg_n), 0.0)
		_legs_absorb(n, vn)
		return
	var g := FlightMath.G
	var flex := maxf(tuning.leg_flex, 0.05) * model.params.r_body
	_legs.reset()
	_leg_n = n
	_leg_bend = false
	if vn <= 1e-3 and reach <= 1e-5:
		return
	_legs.max_rate = 1e3
	_legs.debt = -reach
	_legs.rate = -vn
	var a_rest := vn * vn / (2.0 * reach) if reach > 1e-5 else INF
	if a_rest < g:
		_legs.max_acc = g
		return
	_leg_bend = true
	_legs.max_acc = a_rest if a_rest <= 2.0 * g else maxf(2.0 * g, vn * vn / (2.0 * (reach + flex)))


## More speed into the ground while the legs work (a skid, then the
## touchdown; the run-out meeting a steeper slope): it adds to the bend
## along the legs' axis, and the bend's deceleration grows to stop it
## within the flex.
func _legs_absorb(n: Vector3, vn: float) -> void:
	if not _legs.active():
		_legs_start(n, 0.0, vn)
		return
	if vn <= 0.0:
		return
	_legs.rate -= vn * maxf(n.dot(_leg_n), 0.0)
	var flex := maxf(tuning.leg_flex, 0.05) * model.params.r_body
	var room := maxf(flex - _legs.debt, 1e-4)
	if _legs.rate < 0.0:
		_legs.max_acc = maxf(_legs.max_acc, _legs.rate * _legs.rate / (2.0 * room))
		_leg_bend = true


## One tick of the legs (see _legs_start); returns nothing, the camera's
## offset along _leg_n is -_legs.debt.
func _legs_step(dt: float) -> void:
	if not _leg_bend:
		_legs.step(dt)
		return
	# The bend: the camera's velocity along the legs rises by a dt a tick
	# until it stops (discrete, like the follower: one velocity per tick).
	var a := _legs.max_acc
	var v := minf(_legs.rate + a * dt, 0.0)
	_legs.debt -= v * dt
	_legs.acc = (v - _legs.rate) / dt
	_legs.rate = v
	if v >= 0.0:
		# At the bottom: stand back up to rest from rest, gently.
		_leg_bend = false
		_legs.max_acc = minf(a, 2.0 * FlightMath.G)
		if absf(_legs.debt) < 1e-6:
			_legs.reset()


## One tick of the touchdown run-out (fix round 5; along slopes, fix round
## 6): the run keeps to the ground's plane. The feet brake it at mu g on the
## normal force (g cos slope) plus gravity along the run, and at least at
## run_brake_min x mu g (a steep downhill would speed it up; the feet grip).
## It is swept along the plane: a steeper floor ahead turns the run onto it
## (its legs take the speed into it), a wall turns it along the wall. Then
## it settles onto the ground below with a ray (exact, no jitter). Running
## off an edge, over a ridge (the ground falls away by more than 20 deg) or
## onto ground too steep to stand on is flying again. Round 5 ran level,
## stepping up 0.3 body radii a tick: on an upslope steeper than ~11 deg
## (sparrow) the step-up could not follow and the slope stopped the run in
## one tick.
func _run_out(dt: float) -> void:
	var sp := _run_v.length()
	if sp <= 0.0:
		return
	var g := FlightMath.G
	var mu_g := tuning.ground_friction * g
	var dir := _run_v / sp
	var a := maxf(mu_g * _ground_n.y + g * dir.y, tuning.run_brake_min * mu_g)
	var sp1 := maxf(0.0, sp - a * dt)
	var dist := 0.5 * (sp + sp1) * dt
	_run_v = dir * sp1
	var space := _space()
	if space == null:
		model.position += dir * dist
		return
	var p := model.params
	_sphere.radius = p.r_body
	_shape_q.collision_mask = LAYER_WORLD
	_shape_q.exclude = [] as Array[RID]
	var pos := model.position
	var motion := dir * dist
	for it in 2:
		var r := _cast(pos, motion)
		pos += motion * float(r[0])
		var nw: Vector3 = r[1]
		if nw == Vector3.ZERO:
			break
		pos += nw * 0.0005
		if nw.y > 0.7 and not _cast_perch:
			# A steeper floor ahead (a hillside, a roof from the ground): the
			# run turns onto it and the legs take the speed into it.
			var vn := -_run_v.dot(nw)
			if vn > 0.0:
				_run_v += nw * vn
				_legs_absorb(nw, vn)
			_ground_n = nw
		else:
			# An obstacle: the run carries on along it (on the ground's plane).
			var nh := Vector3(nw.x, 0.0, nw.z)
			if nh.length() > 1e-3:
				nh = nh.normalized()
				_run_v -= nh * minf(0.0, _run_v.dot(nh))
				_run_v -= _ground_n * _run_v.dot(_ground_n)
		var rem := motion * (1.0 - float(r[0]))
		motion = rem - nw * minf(0.0, rem.dot(nw))
		if _run_v.length() < 1e-6 or motion.length() < 1e-7:
			break
	# Settle onto the ground with a ray straight down from the centre: the
	# resting centre is exact (a sphere cast's safe fraction jitters by a
	# millimetre a tick, 0.1-0.2 m/s of vertical noise in the view).
	_ray_q.from = pos
	_ray_q.to = pos + Vector3.DOWN * (dist + p.r_body / 0.7 + 0.002)
	_ray_q.collision_mask = LAYER_WORLD
	var hit := space.intersect_ray(_ray_q)
	var ng: Vector3 = hit["normal"] if not hit.is_empty() else Vector3.ZERO
	var col: Object = hit.get("collider") if not hit.is_empty() else null
	var on_perch := col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & LAYER_PERCH) != 0
	if hit.is_empty() or ng.y <= 0.7 or on_perch or ng.dot(_ground_n) < cos(deg_to_rad(20.0)):
		# No ground to stand on here: flying again, stepping off the way the
		# bird faces (on the feet the heading follows the torso; a run
		# velocity that points elsewhere would snap the flying heading onto
		# it, a forced view turn), with the run's climb or descent.
		model.position = pos
		var vh := Vector2(_run_v.x, _run_v.z).length()
		var v := FlightMath.yaw_forward(model.heading()) * vh + Vector3.UP * _run_v.y
		_run_v = Vector3.ZERO
		_ground_n = Vector3.UP
		_release_perch()
		mode = Mode.FLYING
		model.reset(model.position, v, model.heading())
		return
	if not ng.is_equal_approx(_ground_n):
		# A gentle change of slope (terrain facets): the run follows it.
		_run_v = (_run_v - ng * _run_v.dot(ng)).normalized() * _run_v.length() if _run_v.length() > 1e-6 else Vector3.ZERO
		_ground_n = ng
	model.position = Vector3(pos.x, float(hit["position"].y) + (p.r_body + 0.0005) / ng.y, pos.z)


## Sphere cast (radius r_body, the query's mask) from `from` along `motion`:
## [safe fraction, contact normal or ZERO when nothing was hit]. Sets
## _cast_perch when the surface met is perch geometry.
func _cast(from: Vector3, motion: Vector3) -> Array:
	_cast_perch = false
	var space := _space()
	if space == null or motion.length() < 1e-7:
		return [1.0, Vector3.ZERO]
	_shape_q.transform = Transform3D(Basis.IDENTITY, from)
	_shape_q.motion = motion
	var res := space.cast_motion(_shape_q)
	if res.size() < 2 or res[1] >= 1.0:
		return [1.0, Vector3.ZERO]
	var hit_pos := from + motion * res[1]
	_shape_q.transform = Transform3D(Basis.IDENTITY, hit_pos)
	_shape_q.motion = Vector3.ZERO
	var r0 := _sphere.radius
	_sphere.radius = r0 + 0.002
	var info := space.get_rest_info(_shape_q)
	_sphere.radius = r0
	if info.is_empty():
		return [res[0], -motion.normalized()]
	var col: Object = instance_from_id(int(info["collider_id"])) if info.has("collider_id") else null
	_cast_perch = col is CollisionObject3D and ((col as CollisionObject3D).collision_layer & LAYER_PERCH) != 0
	var d: Vector3 = hit_pos - info["point"]
	return [res[0], d.normalized() if d.length() > 1e-5 else (info["normal"] as Vector3)]


## The turn (rad, + = left) a stun off a wall gives the body: the short way
## toward leaving the wall at stun_exit_deg to its plane, which FlightModel
## caps at contact_turn_max_deg (40 deg): a hit at 20 deg or less leaves the
## wall, a head-on hit turns 40 deg and the player turns the rest. The view
## follows that small step smoothly (ViewTurn); the velocity is what the
## contact deflects. History: round 2 turned a head-on stun 180 deg, round 3
## 110 deg (incidence + 20), both without any input from the player (fix
## round 4, lead direction: the view must not swing that far on its own).
## NAN: floors and ceilings, or a heading already leaving the wall.
func _stun_turn(n: Vector3) -> float:
	var nh := Vector3(n.x, 0.0, n.z)
	if nh.length() < 0.5:
		return NAN
	nh = nh.normalized()
	var psi := model.heading()
	var f := FlightMath.yaw_forward(psi)
	var into := -f.dot(nh)
	var rot := asin(clampf(into, -1.0, 1.0)) + deg_to_rad(tuning.stun_exit_deg)
	if into <= 0.0 or rot <= 0.0:
		return NAN
	# The side of the mirror image; straight in, the side it drifts to.
	var d := FlightMath.wrap_angle(FlightMath.yaw_of(f + 2.0 * into * nh) - psi)
	var side := signf(d)
	if absf(d) > PI - 0.05 or side == 0.0:
		var rgt := Vector3(cos(psi), 0.0, -sin(psi))
		side = -1.0 if model.velocity.dot(rgt) > 0.0 else 1.0
	return side * rot


## Wingtip rays (layers 1+2): a brush nudges the bank away and is reported,
## but wings never stop the bird.
func _wing_brush(dt: float) -> void:
	var space := _space()
	if space == null:
		return
	var p := model.params
	var spread := wing_input.state.mean_extension()
	var rgt := Basis(Vector3.UP, model.heading()) * Basis(Vector3.BACK, -model.phi) * Vector3.RIGHT
	for side in 2:
		var sig := -1.0 if side == 0 else 1.0
		_ray_q.from = model.position
		_ray_q.to = model.position + rgt * sig * 0.5 * p.span * maxf(spread, 0.3)
		_ray_q.collision_mask = LAYER_WORLD | LAYER_PERCH
		var hit := space.intersect_ray(_ray_q)
		var touching := not hit.is_empty()
		if touching:
			var f: float = (hit["position"] - model.position).length() / (0.5 * p.span * maxf(spread, 0.3))
			# Bank away from the touching wing, at most 10 deg/s.
			model.phi -= sig * deg_to_rad(10.0) * (1.0 - clampf(f, 0.0, 1.0)) * dt
			if not _brush_prev[side]:
				contacts["brush"] += 1
				if has_node(^"/root/Events"):
					Events.player_collided.emit(0.0, hit["normal"])
		_brush_prev[side] = touching


# ---- rig (§10.3) -------------------------------------------------------------

func _apply_rig(dt: float) -> void:
	var ws_scale := _world_scale()
	var p := model.params
	# Heave: the camera removes the wingbeat of steady flapping from the
	# body's motion. It is fitted on the model's velocity, which physical
	# head motion never touches, so the player's own head still moves the
	# view 1:1; the arms' stroke rate tells it when the wingbeat stops.
	heave.enabled = heave_smoothing and (mode == Mode.FLYING or mode == Mode.STUNNED or mode == Mode.CAUGHT)
	var off := heave.offset
	if dt > 0.0:
		var wst := wing_input.state
		off = heave.update(model.velocity.y, dt, wst.stroke_period, wst.onset_l or wst.onset_r,
			p.span * tuning.heave_clamp_spans, 0.5 * (wst.omega_l + wst.omega_r))
	if _legs.active() and dt > 0.0:
		# The touchdown's leg flex (see _touch_down): the first step is the
		# part of the touchdown tick after the contact.
		var ldt := _leg_dt if _leg_dt >= 0.0 else dt
		_leg_dt = -1.0
		if ldt > 0.0:
			_legs_step(ldt)
	# The legs bend along the surface they met (fix round 6; vertical on
	# flat ground, as in round 5), the heave is vertical.
	var off_v := _safe_offset(Vector3.UP * off - _leg_n * _legs.debt)
	_view_off = off_v
	_heave_off = off_v.y
	global_transform = Transform3D(Basis(Vector3.UP, rig_yaw), model.position)
	if origin != null:
		# The origin is PlayerBird's child (which is yawed): the world-space
		# offset in its frame.
		origin.transform = Transform3D(Basis.IDENTITY, -_h_ref * ws_scale + Basis(Vector3.UP, -rig_yaw) * off_v)
	for i in 2:
		if i < wing_anchors.size():
			wing_anchors[i].transform = (left_hand if i == 0 else right_hand).transform


## The camera's offset from the body (heave, legs) never puts it inside
## geometry (PB-09).
func _safe_offset(off: Vector3) -> Vector3:
	if off.length() < 1e-4:
		return off
	var space := _space()
	if space == null:
		return off
	var r := maxf(0.04 * _world_scale(), 0.005)
	_sphere.radius = r
	_shape_q.collision_mask = LAYER_WORLD
	_shape_q.transform = Transform3D(Basis.IDENTITY, model.position)
	_shape_q.motion = off
	var res := space.cast_motion(_shape_q)
	_sphere.radius = model.params.r_body
	if res.size() >= 2 and res[0] < 1.0:
		return off * res[0]
	return off


func _drive_world_scale(dt: float) -> void:
	var span := model.params.span
	var arm := wing_input.calibration.arm_span
	world_scale_target = clampf(pow(span / (arm + 0.20), tuning.world_scale_exponent), 0.05, 5.0)
	var cur := log(_world_scale())
	var want := log(world_scale_target)
	var step := tuning.world_scale_ramp * dt
	var ws_new := world_scale_target if tick_count <= 1 or yaw_flagged else exp(cur + clampf(want - cur, -step, step))
	var ws_old := origin.world_scale
	origin.world_scale = ws_new
	camera.near = maxf(0.001, NEAR_PER_WORLD_SCALE * ws_new)
	if ws_old > 0.0 and absf(ws_new - ws_old) > 1e-9:
		# This tick's rig was placed at the old scale, and the XR server writes
		# the tracked nodes with the new one only at its next update: rescale
		# the rig now (the tracked nodes, the origin's offset, the wing
		# anchors), as the next tick and the server will, so every reader (the
		# pose source, the wings, the UI rays, the camera) sees one consistent
		# rig in between. Round 4 left them at the old scale: the lab's first
		# XR tick read the head 1.04 m off the body after the start-up snap to
		# 0.388 (round-5 verifiers).
		var k := ws_new / ws_old
		for n: Node3D in [camera, left_hand, right_hand, left_aim, right_aim]:
			n.position *= k
		origin.transform = Transform3D(Basis.IDENTITY, -_h_ref * ws_new + Basis(Vector3.UP, -rig_yaw) * _view_off)
		for i in mini(2, wing_anchors.size()):
			wing_anchors[i].transform = (left_hand if i == 0 else right_hand).transform


# ---- events and telemetry ------------------------------------------------------

func _emit_events() -> void:
	if not has_node(^"/root/Events"):
		wing_input.flapped_events().clear()
		model.drain_events()
		return
	for e in wing_input.flapped_events():
		if controls_enabled and mode != Mode.CAUGHT:
			Events.player_flapped.emit(int(e[0]), float(e[1]))
	for ev in model.drain_events():
		if ev == "stall":
			Events.player_stalled.emit()


## The camera heave offset applied this tick (m, world): the vertical part
## of view_offset().
func heave_offset() -> float:
	return _heave_off


## The camera's offset from the body this tick (m, world): the heave
## (vertical) plus the legs' bend at a touchdown, along the surface normal
## (fix round 6). The camera is at the body plus this.
func view_offset() -> Vector3:
	return _view_off


## Built at most once per tick, when first read (fix round 5: building the
## ~60-key dictionary every tick whether anyone read it or not was ~8 % of
## the player tick). The same Dictionary is updated in place.
func telemetry() -> Dictionary:
	if _tel_tick != tick_count or _telemetry.is_empty():
		_cache_telemetry()
	return _telemetry


func _cache_telemetry() -> void:
	_tel_tick = tick_count
	var m := model
	var p := m.params
	var w := wing_input.state
	var agl := INF
	var world := _find_world()
	if world != null:
		agl = m.position.y - world.ground_height(m.position.x, m.position.z)
	elif is_finite(env.ground_distance):
		agl = env.ground_distance
	var t := _telemetry
	t["airspeed"] = m.airspeed()
	t["groundspeed"] = Vector2(m.velocity.x, m.velocity.z).length()
	t["vertical_speed"] = m.velocity.y
	t["altitude_agl"] = agl if is_finite(agl) else m.position.y
	t["aoa"] = m.alpha
	t["bank"] = m.phi
	t["stalled"] = m.stalled
	t["flapping"] = w.flapping
	t["wing_extension"] = w.mean_extension()
	# The tuck means "dive" only in flight; perched or grounded, folded arms
	# are the rest pose (the HUD, audio and onboarding must not read a dive).
	t["tucked"] = w.tucked and mode != Mode.PERCHED and mode != Mode.GROUNDED
	t["perched"] = mode == Mode.PERCHED or mode == Mode.GROUNDED
	t["in_updraft"] = maxf(0.0, m.wind.y)
	t["g_load"] = m.g_load
	t["lift"] = m.lift_n
	t["drag"] = m.drag_n
	# extras (§10.7)
	t["mode"] = MODE_NAMES[mode]
	t["heading"] = m.heading()
	t["rig_yaw"] = rig_yaw
	t["body_yaw"] = w.body_yaw
	t["yaw_rate"] = m.yaw_rate
	t["rig_yaw_rate"] = rig_yaw_rate
	t["sideslip"] = m.dpsi
	t["pitch"] = m.theta
	t["gamma"] = m.gam
	t["speed_ratio"] = m.airspeed() / p.v_c
	t["stall_warning"] = m.stall_warning
	t["pitch_input"] = w.pitch
	t["roll_input"] = _roll_input
	t["flap_l"] = w.flap_l
	t["flap_r"] = w.flap_r
	t["up_l"] = w.up_l
	t["up_r"] = w.up_r
	t["extension_l"] = w.ext_l
	t["extension_r"] = w.ext_r
	t["twist_l"] = w.twist_l
	t["twist_r"] = w.twist_r
	t["flap_force"] = m.flap_n
	t["flap_power"] = m.flap_power
	t["endurance"] = minf(m.endurance_l, m.endurance_r)
	t["soar_lock"] = w.soar_lock
	t["tracking"] = w.tracking
	t["calibrated"] = w.calibrated
	t["perch_candidate"] = perch_candidate_dist
	t["stun_left"] = maxf(stun_left, 0.0)
	t["world_scale"] = _world_scale()
	t["perceived_speed"] = m.airspeed() / _world_scale()
	t["heave_offset"] = _heave_off
	# The rotation still owed to the view after a bounce and its current
	# rate (rad, rad/s): a forced view turn the VR vignette may cover.
	t["view_turn"] = view_turn.debt
	t["view_turn_rate"] = view_turn.rate
	# The wind at each wingtip (half a span out along the level right axis):
	# a thermal edge under one wing, for haptics.
	if world != null:
		var right_dir := Basis(Vector3.UP, m.heading()) * Vector3.RIGHT
		env.wind_l = world.get_wind(m.position - right_dir * 0.5 * p.span)
		env.wind_r = world.get_wind(m.position + right_dir * 0.5 * p.span)
	t["wind_l_y"] = env.wind_l.y
	t["wind_r_y"] = env.wind_r.y
	t["size_x"] = p.x
	t["species"] = species
	t["body_steer_share"] = _body_share
	t["contacts"] = contacts["slide"] + contacts["stun"]
	t["tick_ms"] = tick_us / 1000.0
	if t["perched"]:
		# A gripping or standing bird has no airflow: the model's last
		# in-flight aerodynamics (a flare's 13 deg and 0.4 g) must not reach
		# the HUD, audio or haptics as if it were still flying.
		t["aoa"] = 0.0
		t["g_load"] = 1.0
		t["lift"] = 0.0
		t["drag"] = 0.0
		t["stalled"] = false
		t["stall_warning"] = 0.0
		t["flap_force"] = 0.0
		t["flap_power"] = 0.0
		t["sideslip"] = 0.0
		t["gamma"] = 0.0


func _log_line() -> void:
	var t := telemetry()
	print("[flight] t=%.1f mode=%s V=%.1f vz=%.2f agl=%.1f bank=%.0f aoa=%.1f flap=%.2f ext=%.2f pitch_in=%.2f roll_in=%.2f yaw=%.0f rig=%.0f ws=%.3f tick=%.2fms" % [
		_time, t["mode"], t["airspeed"], t["vertical_speed"], t["altitude_agl"], rad_to_deg(t["bank"]),
		rad_to_deg(t["aoa"]), t["flapping"], t["wing_extension"], t["pitch_input"], t["roll_input"],
		rad_to_deg(t["heading"]), rad_to_deg(rig_yaw), t["world_scale"], t["tick_ms"]])


func _input(event: InputEvent) -> void:
	if pose_source != null:
		pose_source.handle_input(event)
