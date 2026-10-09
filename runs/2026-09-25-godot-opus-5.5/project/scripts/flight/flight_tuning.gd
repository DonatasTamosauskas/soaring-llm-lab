class_name FlightTuning
extends Resource
## The single flight tuning resource (FLIGHT_SPEC §7-§9, table 8.2).
##
## Every constant of the flight physics, the assists and the comfort caps
## lives here as an exported field whose default IS the tuned value (there
## is no separate .tres: FlightTuning.default_tuning() is a fresh instance).
## A designer can save one as a .tres and assign it to PlayerBird.tuning;
## tests record FlightTuning.hash_value() beside the numbers they assert.
##
## Per-size anchors are keyed by SPECIES id rather than by the size scalar x:
## the game loop retunes species masses (SizeRules is theirs), and keying by
## species keeps "the eagle's value" the eagle's value when its mass moves.
## They are resolved to x (FlightParams.size_x) on first use.

## Assist preset: 0 sim, 1 normal (default), 2 novice (§9).
@export_range(0, 2) var preset := 1

@export_group("Air and wing")
@export var rho := 1.225
## Neutral-wrist trim lift coefficient: every bird trims at SizeRules cruise.
@export var cl_n := 0.30
## Lift-curve slope per radian.
@export var lift_slope := 4.6
@export var oswald := 0.85
@export var cl_min := -0.5
## Post-stall lift plateau as a fraction of CL_max.
@export var post_stall_plateau := 0.6
## Separation blend time constant, s.
@export var sep_tau := 0.15
@export var stall_drag := 0.16
## Flat-plate drag coefficient past the stall.
@export var plate_drag := 1.8
## Overspeed "feather flutter" drag starts at this fraction of V_max.
@export var governor_start := 0.85
@export var governor_gain := 31.0
## Thin air under the arena's lid (integration fix; FlightEnv.thin_air):
## lift, drag and the flap force fade together, easing in from this many
## metres below World.ceiling (measured from the top of the body: 255 m
## under the 300 m lid, so all flight below 250 m is untouched) ...
@export var thin_air_band := 45.0
## ... to nothing this many metres below it. Flapping birds level off where
## the thinned air just carries them (17-27 m under the lid, stroke-mean
## deceleration <= 0.19 g arriving from below) and a thermal cannot lift a
## bird past this either. The round-6 fade (lift and drag only, linear over
## the last 20 m, flap force untouched) let every flapping size climb into
## the lid at 4-7 m/s and be stunned there again and again.
@export var thin_air_floor := 5.0

@export_group("Pitch channel")
@export var turn_comp_gain := 0.85
@export var damper_up := 0.4
@export var damper_down := 0.1
## Stall margins, degrees: protected top of the command below alpha_s, stall
## entry above it, exit below it, and the sim preset's top above it.
@export var margin_top_deg := 1.0
@export var margin_enter_deg := 0.5
@export var margin_exit_deg := 3.0
@export var margin_sim_top_deg := 4.0
@export var deliberate_pitch := 0.9
@export var deliberate_hold := 0.35
@export var nose_drop_deg_s := 12.0
@export var forced_recovery := 1.5
@export var wing_drop_deg := 15.0
@export var warn_margin_deg := 6.0
@export var tuck_bias_deg := 2.0

@export_group("Roll and yaw")
@export var roll_kick_deg := 18.0
@export var ext_roll := 0.5
@export var adverse := 0.04
@export var paddle_yaw := 0.35
## Share of each wing's flap-force component across the body (the arm's
## droop or raise mid-stroke) that pushes the body sideways (fix round 4:
## none; one arm stroking shoved the bird toward the stroking wing).
@export_range(0.0, 1.0) var flap_side_share := 0.0
## The one-wing kick (roll kick, paddle yaw) acts on the stroke-mean effort
## asymmetry |l - r| / (l + r) beyond this, rescaled to full at a one-wing
## stroke: natural human asymmetry (arms up to ~25 % unequal) is a symmetric
## stroke (fix round 4).
@export_range(0.0, 0.9) var one_wing_deadzone := 0.15

@export_group("Flapping")
## Playtest levers (1.0 / 0.0 = the tested physics; the game's Settings
## defaults raise them for fun): flap force and climb power, glide
## efficiency (L/D), dive speed limit, roll rate, and the extra flap force
## for a stroke made with the arms fully stretched (WingState.stretch).
@export var flap_power := 1.0
@export var glide_efficiency := 1.0
@export var dive_speed := 1.0
@export var roll_rate_scale := 1.0
@export var stretch_bonus := 0.0
@export var flap_floor_deg := 8.0
@export var p_spec_gain := 1.08
@export var p_spec_offset := 0.40
## Endurance: the stroke-averaged effort may exceed the reference by this.
@export var e_cap := 1.15
## Substep target (h = dt / ceil(dt * substep_hz) <= 1/120 s as the spec
## requires). 144 rather than 120: 72 and 90 Hz ticks get exactly the same
## two substeps (same cost), and a 120 Hz tick gets two instead of one, which
## halves its integration error (FM-24).
@export var substep_hz := 144.0

## Ground cushion peak (g) at the belly touching the ground (G15).
@export var cushion_g := 1.5
## Ground-effect lift gain at the belly touching the ground (G15).
@export var ground_lift_gain := 0.6

@export_group("Ground landing")
## Friction of a bird on the grass (fix round 5): a belly or feet pressed
## onto the ground lose mu x the normal impulse of their speed along it
## (Coulomb), and a touchdown runs out at mu g. Round 4 had no friction:
## a bird below stall speed slid along the grass on its lift alone for
## 7-15 s, and the touchdown then stopped it in one tick.
@export var ground_friction := 0.6
## A floor contact at or below this airspeed (x V_min) is a touchdown: the
## wing can no longer hold the bird up (round 4: 0.7, so a bird between 0.7
## and 1 V_min kept "flying" on its belly).
@export var touchdown_speed := 1.2
## Legs (fix round 5): the speed into the ground at a touchdown is taken up
## by the legs bending over at most this share of the body radius, then
## straightening, instead of stopping the view in one tick. The camera dips
## and comes back (a time-optimal bob, no faster than the fall needs).
@export var leg_flex := 0.75
## The feet's reach (fix round 6, x r_body): a landing bird's legs reach this
## far beyond its body toward the ground, so the feet meet it first and the
## legs take the speed into it over reach + flex (1.75 body radii) instead
## of the flex alone. Round 5 met the ground with the belly: a sparrow's
## 2.9 cm of flex stopped a touchdown onto a 34-44 deg roof, or a steep
## flat one, at 0.5-0.8 x the touchdown speed per tick (the 0.45 bound).
@export var leg_reach := 1.0
## A floor contact at landing speed whose speed into the surface is at most
## this (x V_min) is a touchdown (fix round 6; round 5 used the perch
## capture speed, 0.8 V_min, and a slow bird flying into a 44 deg roof at
## 1.1 V_min, 0.87 V_min into it, was stunned). Up to 1 V_min the legs
## keep the view within 0.45 x the touchdown speed per tick at every size.
@export var touchdown_vn := 1.0
## The run-out's least deceleration (x mu g, fix round 6). Along a slope the
## feet brake at mu g cos(slope) plus gravity along the run: uphill that
## stops a run sooner, and downhill a steep roof would let it speed up;
## the feet still brake at this share of the flat rate.
@export var run_brake_min := 0.5
## Take-off from the ground (fix round 6): a bird launched off the ground
## is not landed again while it keeps flapping (a stroke began within this
## many seconds, the ground launch's own stroke window) or for
## take_off_hold_s after the launch, until it is two spans clear. Round 5
## re-landed it on the next tick facing up any slope above 20-25 deg
## (every stroke launched into the slope and touched down again, firing
## took_off and perched each time).
@export var take_off_hold_gap := 1.2
@export var take_off_hold_s := 0.5
## Landing configuration over the ground (normal and novice presets, fix
## round 5): a slow bird that flares while sinking within this many spans
## of the ground lowers its legs and fans its tail, the perch assist's
## landing configuration (up to +0.4 CD, at most 0.5 g of extra drag). Round
## 4 had it only for perches: a big bird's flare over a meadow zoomed 7 spans
## up and then glided at L/D 14 for 20 s before it could touch down.
@export var landing_config_spans := 4.0
## Stall guard (normal and novice presets, fix round 5): below the height
## a stall needs to recover in, a full flare is the maximum-lift flare, not
## a committed (deliberate) stall. That height is what a held stall falls
## before its forced recovery (0.4 g forced_recovery^2: the stalled bird
## drops at ~0.8 g, 8.8 m in 1.5 s at every size) plus this many V_min^2 / g
## of pull-out: sparrow 9.2 m, pigeon 9.7 m, eagle 10.8 m. (0.5 guarded the
## whole of an eagle's flare zoom, and at maximum lift it porpoised 17 s
## before landing; a quarter lets a big bird stall at the zoom's top, well
## above the ground, as round 4 did.) Round 4 let a
## sparrow's flare from the glide speed zoom 10 spans up and stall there; the
## held stall dived it into the grass at 4.7 m/s (a stun) from every flare
## height tried.
@export var stall_guard_vmin2g := 0.25

@export_group("Player rig and comfort")
@export var comfort_max_yaw_rate_deg := 240.0
@export var comfort_max_yaw_accel_deg := 720.0
## The player's turn-speed comfort choice (Settings "turn_comfort", a
## 4-step bar: 0.25 / 0.5 / 0.75 / 1.0) as the rig's yaw-rate cap, deg/s
## (integration round 2: a sparrow at full input yawed the view at ~205 deg/s
## with no player setting; both verifiers asked for one). The acceleration
## cap scales with it (TURN_COMFORT_ACCEL_PER_RATE: 720 deg/s^2 at 240).
const TURN_COMFORT_RATES: Array[float] = [90.0, 120.0, 180.0, 240.0]
const TURN_COMFORT_NAMES: Array[String] = ["Gentle", "Calm", "Brisk", "Full"]
const TURN_COMFORT_ACCEL_PER_RATE := 3.0


## Index 0..3 of a turn_comfort bar value (0 reads as the gentlest).
static func turn_comfort_step(v: float) -> int:
	return clampi(int(round(v * 4.0)) - 1, 0, TURN_COMFORT_RATES.size() - 1)


static func turn_comfort_rate(v: float) -> float:
	return TURN_COMFORT_RATES[turn_comfort_step(v)]
## A heading change the view cannot follow within the caps in one tick (the
## small turn a contact gives the body) is owed to the view and paid by a
## time-optimal follower inside these limits (ViewTurn, fix round 4): half
## the rate cap and a third of the acceleration cap.
@export var view_turn_rate_deg := 120.0
@export var view_turn_accel_deg := 240.0
## world_scale = (span / (arm_span + 0.20)) ^ exponent. 1.0 = exact scale,
## the VR area's comfort recommendation (VR.md §4, adopted in fix round 4):
## the angular optic flow that drives vection is the same at any exponent,
## and a smaller exponent draws a small player's own wings up to 1.5x too
## wide next to NPCs, off by a tier exactly where eat-or-flee matters. The
## knob stays for the Quest Pro session (FLIGHT_SPEC §17 R1); flight is
## invariant to it.
@export var world_scale_exponent := 1.0
## Max world_scale ramp speed in log space (ln / s).
@export var world_scale_ramp := 0.25
## Camera heave offset limit, in wingspans (FLIGHT_SPEC §11.3, §19 R-4).
## The offset is only the removed wingbeat (the camera follows the flight
## path exactly), so the limit must cover the largest wingbeat bob: a
## sparrow flapping 1.35 s strokes bobs about one span. Beyond this the
## wingbeat is cancelled in part (smooth gain).
@export var heave_clamp_spans := 1.5

@export_group("Collisions")
## A contact deflects the velocity and turns the body as little as it can
## (fix round 4): never more than this in one contact. A stun off a wall
## turns the bird toward leaving it at stun_exit_deg to its plane, the short
## way, but at most this far; the player turns the rest (round 3 turned a
## head-on stun 110 deg with no input from the player).
@export var contact_turn_max_deg := 40.0
@export var stun_exit_deg := 20.0
## Upward bounce of a stun off the ground, as a fraction of the impact
## speed (walls 0.25): a V_max dive into a field hops a few centimetres
## instead of a metre and is not stunned a second time on the way down.
@export var floor_restitution := 0.05

@export_group("Perching")
## Capture below this fraction of V_min (x1.4 while gripping).
@export var perch_capture_speed := 0.8
@export var perch_assist_range_spans := 4.0
## Steering cap (g). Spec 0.4 / novice 0.6: raised to 0.6 / 0.8 because a
## bird at the 0.8 V_min capture speed sinks at ~0.5 g even in a full flare
## (the guidance cancels that sag and steers; a landing flare is nearly a
## parachute).
@export var perch_assist_accel_g := 0.6
## Pigeon and bigger use the novice assist strength by default (spec §17 R4:
## slowing by pitch converts speed to height, so big birds need the help).
@export var perch_assist_big_from_x := 0.6

## Per-size anchors: key -> [[species id, value], ...] (piecewise-linear in x).
@export var curves := {
	"aspect": [["moth", 4.5], ["sparrow", 5.36], ["pigeon", 6.41], ["eagle", 7.5]],
	"ld_max": [["moth", 6.5], ["sparrow", 8.94], ["pigeon", 11.9], ["eagle", 15.0]],
	"tau_alpha": [["moth", 0.08], ["sparrow", 0.112], ["pigeon", 0.150], ["eagle", 0.19]],
	"pitch_rate_deg": [["moth", 400.0], ["sparrow", 320.0], ["pigeon", 222.0], ["eagle", 120.0]],
	"tau_bank": [["moth", 0.12], ["sparrow", 0.186], ["pigeon", 0.266], ["eagle", 0.35]],
	"roll_rate_deg": [["moth", 420.0], ["sparrow", 343.0], ["pigeon", 248.0], ["eagle", 150.0]],
	"flap_force": [["moth", 1.6], ["sparrow", 1.5], ["starling", 1.4], ["pigeon", 1.3], ["eagle", 1.2]],
	"hover_force": [["moth", 1.35], ["sparrow", 1.20], ["starling", 1.02], ["pigeon", 0.80], ["eagle", 0.60]],
	"up_gain": [["moth", 0.30], ["sparrow", 0.30], ["starling", 0.10], ["pigeon", -0.08], ["eagle", -0.08]],
	"flap_tau": [["moth", 0.30], ["sparrow", 0.30], ["pigeon", 0.26], ["eagle", 0.22]],
}

var _curve_cache := {}


## Value of a per-size anchor at size scalar x.
func anchor(key: String, x: float) -> float:
	var c: Array = _curve_cache.get(key, [])
	if c.is_empty():
		c = _resolve(key)
		_curve_cache[key] = c
	return FlightMath.pwl(c[0], c[1], x)


func _resolve(key: String) -> Array:
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var pts: Array = curves.get(key, [])
	var pairs: Array = []
	for pt in pts:
		var k: Variant = pt[0]
		var x: float = FlightParams.size_x_for_species(StringName(k)) if k is String or k is StringName else float(k)
		pairs.append([x, float(pt[1])])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for p in pairs:
		xs.append(p[0])
		ys.append(p[1])
	return [xs, ys]


## Named assists for the current preset (§9). NPCs usually run preset 1.
func assists() -> Dictionary:
	var sim := preset == 0
	var novice := preset == 2
	return {
		&"stall_protect": not sim,
		&"turn_comp": not sim,
		&"damper": not sim,
		# The sim preset keeps only the safety set (governor, attitude limits,
		# stall hysteresis, collisions): no load limit, so a sharp full-up
		# step can over-rotate into a stall like a real wing.
		&"nlimit": not sim,
		&"flap_floor": not sim,
		&"ground_cushion": not sim,
		&"perch_assist": not sim,
		&"body_steer": not sim,
		&"novice": novice,
	}


func turn_comp_value() -> float:
	return 1.0 if preset == 2 else turn_comp_gain


func deliberate_hold_value() -> float:
	return 0.6 if preset == 2 else deliberate_hold


## Dead-zone multiplier for WingInput shaping (novice x1.4, sim x0.8).
func deadzone_scale() -> float:
	match preset:
		0: return 0.8
		2: return 1.4
	return 1.0


## Perch assist reach (spans) and steering cap (g) for a size.
func perch_assist_for(x: float) -> Vector2:
	if preset == 2 or x >= perch_assist_big_from_x:
		return Vector2(8.0, 0.8)
	return Vector2(perch_assist_range_spans, perch_assist_accel_g)


## Stable hash of every tunable, recorded with test metrics.
func hash_value() -> int:
	var parts := []
	for p in get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE and not String(p["name"]).begins_with("_"):
			parts.append(str(get(p["name"])))
	return hash(",".join(parts))


static var _default: FlightTuning = null


## Shared default tuning (the .tres if present, else code defaults).
static func default_tuning() -> FlightTuning:
	if _default == null:
		var path := "res://scripts/flight/flight_tuning_default.tres"
		if ResourceLoader.exists(path):
			_default = load(path) as FlightTuning
		if _default == null:
			_default = FlightTuning.new()
	return _default
