class_name WingState
extends RefCounted
## The command and measurement contract between WingInput (or an NPC
## autopilot) and FlightModel (FLIGHT_SPEC §4).
##
## Commands are what FlightModel consumes; NPC autopilots write only those.
## Measurements feed visuals, haptics, UI lessons and tests. The model never
## re-derives roll or pitch from the per-wing measurements (double counting).
## Reused in place: allocate once, copy_from() to snapshot.

# ---- commands ----
var pitch := 0.0                 ## -1..1 symmetric AoA command (+ = leading edges up: slower, balloon)
var roll := 0.0                  ## -1..1 bank command (+ = right wing down)
var ext_l := 1.0                 ## 0 tucked .. 1 spread
var ext_r := 1.0
var flap_l := 0.0                ## 0..1.3 credited downstroke effort this tick
var flap_r := 0.0
var up_l := 0.0                  ## 0..1 gated upstroke effort this tick
var up_r := 0.0
var flap_dir_l := Vector3.UP     ## unit, LEVEL body frame (x right, y up, z back)
var flap_dir_r := Vector3.UP
var body_yaw := 0.0              ## rad, torso yaw in tracking space. NPC: 0
var tracking := 1.0              ## 0..1; 0 = both hands lost

# ---- measurements ----
var twist_l := 0.0               ## rad, filtered wrist twist from neutral (+ = LE up)
var twist_r := 0.0
var dihedral_l := 0.0            ## rad, arm elevation (+ = tip up)
var dihedral_r := 0.0
var sweep_l := 0.0               ## rad (+ = forward)
var sweep_r := 0.0
var stroke_phase_l := 0.0        ## 0..1 (0 = top of stroke)
var stroke_phase_r := 0.0
var stroke_period := 1.0         ## s, last measured cycle (0.3..1.5)
var body_yaw_rate := 0.0
var grip_l := 0.0
var grip_r := 0.0
var tucked := false
var soar_lock := false
var calibrated := false
var flapping := 0.0              ## 0..1 activity: LP(0.3 s) of max(flap_l, flap_r)
var omega_l := 0.0               ## rad/s stroke rate (+ = down), diagnostics
var omega_r := 0.0

# ---- one-tick event flags ----
var onset_l := false
var onset_r := false
var onset_strength := 0.0
var detent_l := false
var detent_r := false
var range_l := false
var range_r := false
var soar_lock_changed := false
var t := 0.0


func mean_extension() -> float:
	return 0.5 * (ext_l + ext_r)


## Spread, level, no flap, flap_dir = UP; keeps body_yaw.
func set_neutral() -> void:
	pitch = 0.0
	roll = 0.0
	ext_l = 1.0
	ext_r = 1.0
	flap_l = 0.0
	flap_r = 0.0
	up_l = 0.0
	up_r = 0.0
	flap_dir_l = Vector3.UP
	flap_dir_r = Vector3.UP
	onset_l = false
	onset_r = false
	tucked = false


## Field by field (fix round 6: the reflective set/get loop over _FIELDS
## cost ~20 us a player tick, ~10 % of it). Keep in step with _FIELDS
## (WS-copy in the wing_input suite compares every field).
func copy_from(o: WingState) -> void:
	pitch = o.pitch
	roll = o.roll
	ext_l = o.ext_l
	ext_r = o.ext_r
	flap_l = o.flap_l
	flap_r = o.flap_r
	up_l = o.up_l
	up_r = o.up_r
	flap_dir_l = o.flap_dir_l
	flap_dir_r = o.flap_dir_r
	body_yaw = o.body_yaw
	tracking = o.tracking
	twist_l = o.twist_l
	twist_r = o.twist_r
	dihedral_l = o.dihedral_l
	dihedral_r = o.dihedral_r
	sweep_l = o.sweep_l
	sweep_r = o.sweep_r
	stroke_phase_l = o.stroke_phase_l
	stroke_phase_r = o.stroke_phase_r
	stroke_period = o.stroke_period
	body_yaw_rate = o.body_yaw_rate
	grip_l = o.grip_l
	grip_r = o.grip_r
	tucked = o.tucked
	soar_lock = o.soar_lock
	calibrated = o.calibrated
	flapping = o.flapping
	omega_l = o.omega_l
	omega_r = o.omega_r
	onset_l = o.onset_l
	onset_r = o.onset_r
	onset_strength = o.onset_strength
	detent_l = o.detent_l
	detent_r = o.detent_r
	range_l = o.range_l
	range_r = o.range_r
	soar_lock_changed = o.soar_lock_changed
	t = o.t


func to_dict() -> Dictionary:
	var d := {}
	for p in _FIELDS:
		var v: Variant = get(p)
		d[p] = [v.x, v.y, v.z] if v is Vector3 else v
	return d


static func from_dict(d: Dictionary) -> WingState:
	var w := WingState.new()
	for p in _FIELDS:
		if d.has(p):
			var v: Variant = d[p]
			if v is Array and v.size() == 3:
				w.set(p, Vector3(v[0], v[1], v[2]))
			else:
				w.set(p, v)
	return w


## Flap tilt (deg, + = forward) that the natural wrist gesture gives for a
## symmetric pitch command: the same shaping as a human wrist (§5.8), so an
## autopilot flapping "forward" tilts its stroke exactly like a player.
static func tilt_for_pitch(p: float) -> float:
	var u := clampf(p, -1.0, 1.0)
	return -u * (20.0 if u > 0.0 else 35.0)


## Level-body-frame flap direction for a forward tilt in degrees.
static func dir_for_tilt(tilt_deg: float) -> Vector3:
	var th := deg_to_rad(tilt_deg)
	return Vector3(0.0, cos(th), -sin(th))


## NPC/bot helper: symmetric wings flapping the reference stroke at `effort`
## (0..1.3), sampled from the detector's reference table at size x (so the
## mean force is exactly effort x the §7.7 reference). one_wing: 0 both,
## -1 left only, +1 right only. The flap tilt follows the wrist rule unless
## tilt_override_deg is given.
func set_commands(p_pitch: float, p_roll: float, spread: float, effort: float, stroke_time: float,
		hz := 1.0, one_wing := 0, tilt_override_deg := NAN, size_x := -1.0) -> void:
	pitch = clampf(p_pitch, -1.0, 1.0)
	roll = clampf(p_roll, -1.0, 1.0)
	ext_l = clampf(spread, 0.0, 1.0)
	ext_r = ext_l
	var tilt := tilt_override_deg if not is_nan(tilt_override_deg) else tilt_for_pitch(pitch)
	flap_dir_l = dir_for_tilt(tilt)
	flap_dir_r = flap_dir_l
	var x := size_x if size_x >= 0.0 else FlightParams.size_x_for_species(&"sparrow")
	var f := 0.0
	var u := 0.0
	var e := maxf(effort, 0.0)
	if e > 0.0:
		var tab := FlapDetector.reference_table(x)
		var fl: PackedFloat32Array = tab["flap"]
		var ups: PackedFloat32Array = tab["up"]
		var n := fl.size()
		var ph := fposmod(stroke_time * hz, 1.0) * n
		var i0 := int(floorf(ph)) % n
		var i1 := (i0 + 1) % n
		var k := ph - floorf(ph)
		f = lerpf(fl[i0], fl[i1], k) * e
		u = lerpf(ups[i0], ups[i1], k) * e
	flap_l = f if one_wing <= 0 else 0.0
	flap_r = f if one_wing >= 0 else 0.0
	up_l = u if one_wing <= 0 else 0.0
	up_r = u if one_wing >= 0 else 0.0
	stroke_period = clampf(1.0 / maxf(hz, 0.01), 0.3, 1.5) if e > 0.0 else 0.3
	var ph01 := fposmod(stroke_time * hz, 1.0)
	stroke_phase_l = ph01
	stroke_phase_r = ph01
	tucked = spread < 0.25
	flapping = clampf(e, 0.0, 1.0)


const _FIELDS: PackedStringArray = [
	"pitch", "roll", "ext_l", "ext_r", "flap_l", "flap_r", "up_l", "up_r", "flap_dir_l", "flap_dir_r",
	"body_yaw", "tracking", "twist_l", "twist_r", "dihedral_l", "dihedral_r", "sweep_l", "sweep_r",
	"stroke_phase_l", "stroke_phase_r", "stroke_period", "body_yaw_rate", "grip_l", "grip_r",
	"tucked", "soar_lock", "calibrated", "flapping", "omega_l", "omega_r", "onset_l", "onset_r",
	"onset_strength", "detent_l", "detent_r", "range_l", "range_r", "soar_lock_changed", "t",
]
