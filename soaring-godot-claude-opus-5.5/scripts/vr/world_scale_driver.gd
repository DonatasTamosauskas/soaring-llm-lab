class_name WorldScaleDriver
extends Node
## Growth as the player sees it: XROrigin3D.world_scale follows the bird's
## wingspan, smoothly, and the camera's near plane follows the scale.
##
##   target = (span(mass) / (arm_span + 0.20)) ^ exponent        (D12 / §11.4)
## With exponent 1 the feathered wingtips drawn 10 cm past each grip span
## exactly the bird's real wingspan, so "your wings next to theirs" is a true
## size cue. world_scale is animated in log space at <= 0.25 ln/s (a
## tier-up takes 1-3 s) and held while the game is paused (PlayerBird does
## not re-seat the camera then). A new body is not growth: the first size,
## a new run (Events.run_started) and a respawn (Events.player_spawned) snap
## straight to the target (the view is put somewhere else in the same frame:
## a cut, with no fade - integration round 1 corrected this line, which
## promised one; see docs/INTEGRATION.md), so the world never
## inflates for seconds at the start of a run. Runs before PlayerBird's physics tick
## (process_physics_priority -100) so the rig offset of that tick uses the
## new scale and the camera stays on the body during a ramp.
##
## Never node-scales anything: world_scale is XRServer state (the only
## supported way to scale the rig, ARCHITECTURE §7.1).

## ln-units per second: the fastest the world may appear to grow or shrink.
const MAX_RATE := 0.25
## Camera near plane per unit world_scale. 0.06 since integration round 1
## (was 0.03, FLIGHT_SPEC §10.1; ARCHITECTURE §7.5 widened to 0.02-0.065):
## the Quest's Mobile renderer draws into a 24-bit fixed-point depth buffer,
## where one depth step at view depth z is ~z^2 / (near * 2^24), so the
## near plane sets the precision far away (a sparrow's 4 mm near plane put
## the street slab 10 cm over the ground within one step from ~80 m). 0.06
## doubles the precision and still clears every first-person feather in
## view by 1.35x: the nearest, a wing root at the shoulder when looking down
## at a banked wing, is 8.1 cm from the eye (tests/unit/vr/near_plane_test).
const NEAR_K := 0.06
const NEAR_MIN := 0.001
const SCALE_MIN := 0.05
const SCALE_MAX := 5.0
## Wing drawn past each grip on both sides: the drawn span is the bird's.
const TIP_ALLOWANCE := 2.0 * FirstPersonWings.TIP_OVERHANG

var origin: XROrigin3D
var camera: Camera3D
## Supplies the calibrated arm span (else Settings / 1.5 m).
var calibration: VRCalibration
## Tests: fixed mass / span / exponent instead of the player and Settings.
var mass_override := -1.0
var arm_span_override := -1.0
var exponent_override := -1.0
## Where "world_scale_exponent" comes from: anything with get_value (the
## Settings autoload by default; tests pass a private one).
var store: Object = null
@export var enabled := true
## Tests set false and call step(dt).
@export var auto_step := true

var world_scale := 1.0
var target := 1.0
var _initialized := false
var _last_mass := -1.0
var _last_span := -1.0
var _last_exp := -1.0
## A snap was requested this frame: the first tick after it also snaps
## (GameLoop may reset the mass after emitting run_started).
var _snap_pending := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -100
	Events.run_started.connect(snap)
	Events.player_spawned.connect(func(_p: Bird) -> void: snap())


func _physics_process(dt: float) -> void:
	if auto_step:
		var t0 := VRProfile.begin()
		if _snap_pending:
			_snap_pending = false
			_initialized = false
		step(dt)
		VRProfile.add(&"world_scale", t0)


static func target_scale(mass: float, arm_span: float, exponent: float = 1.0) -> float:
	var span := SizeRules.wingspan_for_mass(mass)
	var ratio := span / maxf(arm_span + TIP_ALLOWANCE, 0.5)
	var t := pow(ratio, exponent)
	# Never a non-finite scale, whatever the inputs (NaN/INF mass, span).
	return clampf(t, SCALE_MIN, SCALE_MAX) if is_finite(t) else 1.0


static func near_for(ws: float) -> float:
	return maxf(NEAR_MIN, NEAR_K * ws)


func exponent() -> float:
	if exponent_override > 0.0:
		return exponent_override
	var src: Object = store if store != null else Settings
	var e := float(src.call("get_value", "world_scale_exponent", 1.0))
	# A corrupt settings file or a UI bug must never reach the rig: clampf
	# passes NaN through, and a NaN world_scale / near plane breaks the
	# view until the next snap (a verifier's probe).
	return clampf(e, 0.5, 1.0) if is_finite(e) else 1.0


func arm_span() -> float:
	if arm_span_override > 0.0:
		return arm_span_override
	if calibration != null and calibration.calibrator != null and is_finite(calibration.calibrator.arm_span):
		return calibration.calibrator.arm_span
	return 1.5


func player_mass() -> float:
	if mass_override > 0.0:
		return mass_override
	var p := Birds.player()
	if p == null or not is_finite(p.mass):
		return -1.0
	return p.mass


func step(dt: float) -> void:
	if not enabled or origin == null or not is_instance_valid(origin):
		return
	var mass := player_mass()
	var span := arm_span()
	var ex := exponent()
	# Nothing changed and nothing to ramp: the per-tick cost is these reads
	# (and a foreign write to the scale or the near plane is undone).
	if _initialized and mass == _last_mass and span == _last_span and ex == _last_exp and world_scale == target:
		_apply()
		return
	_last_mass = mass
	_last_span = span
	_last_exp = ex
	if mass <= 0.0 and not _initialized:
		# No player yet: leave the scale alone and start from the real size
		# once there is one (never ramp from an arbitrary 1.0).
		_apply_near(origin.world_scale)
		return
	if mass > 0.0:
		target = target_scale(mass, span, ex)
	if not _initialized:
		# First size of a body: no ramp.
		world_scale = target
		_initialized = true
	elif not (is_inside_tree() and get_tree().paused):
		var cur := log(world_scale)
		var want := log(target)
		var max_step := MAX_RATE * maxf(dt, 0.0)
		world_scale = exp(cur + clampf(want - cur, -max_step, max_step))
	if not is_finite(world_scale) or world_scale <= 0.0:
		world_scale = target if is_finite(target) and target > 0.0 else 1.0
	_apply()


func _apply() -> void:
	if not is_equal_approx(origin.world_scale, world_scale):
		origin.world_scale = world_scale
	_apply_near(world_scale)


func _apply_near(ws: float) -> void:
	if camera != null and is_instance_valid(camera):
		var near := near_for(ws)
		if not is_equal_approx(camera.near, near):
			camera.near = near


## Jump straight to the target (new run, respawn: the view cuts to the new
## place in the same frame).
## The player's new mass may be set after the signal in the same frame, so
## the next tick snaps again if the target moved (still no ramp).
func snap() -> void:
	_initialized = false
	_last_mass = -1.0
	_snap_pending = true
	step(0.0)
