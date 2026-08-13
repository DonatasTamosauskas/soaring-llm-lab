class_name BirdPose
extends RefCounted

## The flap cycle, and every other angle a bird holds, as pure maths.
##
## No nodes, no scene, no engine singletons — the same discipline
## [scripts/flight] keeps, and for the same reason: an animation you can only
## judge by staring at it is an animation nobody can hold to anything. Feed this
## the flight command and the delta and it produces angles; [BirdRig] does
## nothing but hang them on nodes.
##
## What makes the result read as a bird rather than as a metronome:
##
## [br]1. [b]The stroke is asymmetric.[/b] The downstroke takes
##    [constant DOWNSTROKE] of the cycle and the recovery takes the rest, so the
##    wing snaps down and drifts back up. A symmetric sine is the single most
##    reliable way to make a bird look like a moth.
## [br]2. [b]The wing folds on the way up.[/b] A wing held flat through the
##    recovery pushes the bird back down again, so real birds flex at the wrist
##    and pull the hand in. This is the detail that costs nothing and sells
##    everything.
## [br]3. [b]A beat is a beat.[/b] Once a stroke starts it finishes, even if the
##    command that asked for it has already stopped. Cutting a wingbeat off
##    halfway is a twitch, and the flight model itself thinks in whole beats.
## [br]4. [b]Everything else is the flight state.[/b] Span folds the wings, bank
##    draws the inner wing in and twists the tail, angle of attack pitches the
##    body and drops the tail as a brake. Nothing here is decorative: what you
##    see is what the bird is commanding.

# --- the beat -----------------------------------------------------------------

## Fraction of the cycle spent going down. Birds spend roughly a third of the
## cycle on the power stroke and the rest recovering.
const DOWNSTROKE: float = 0.38
## How far above and below the shoulder the tip travels, in radians. The wing
## comes up further than it goes down, which is what a bird does and what keeps
## the beat from looking like rowing.
const UP_LIMIT: float = 0.95
const DOWN_LIMIT: float = 0.72
## Wings rest a little above level. Perfectly flat wings read as a paper plane.
const GLIDE_DIHEDRAL: float = 0.07
## How hard the wrist flexes at the middle of the recovery, in radians of
## spanwise bend at the tip.
const RECOVERY_FOLD: float = 0.62
## How hard a fully tucked wing sweeps back and shortens.
const TUCK_BEND: float = 0.95
const TUCK_SWEEP: float = 0.30
const EXTENSION_MIN: float = 0.30
## Fore-and-aft swing: the wing reaches forward on the power stroke and pulls
## back on the recovery. Small, but it is what makes the beat look like it is
## doing work.
const SWEEP_AMP: float = 0.17
## Pronation on the way down, supination on the way up.
const TWIST_DOWN: float = 0.34
const TWIST_UP: float = 0.16
## How much of the commanded angle of attack shows up as wing incidence and as
## body pitch. Full gain looks like a bird permanently falling on its face.
const TWIST_ALPHA: float = 0.65
const BODY_PITCH_GAIN: float = 0.85
## How far the primaries flex up under load, in metres for a size-1.0 bird.
const TIP_LIFT: float = 0.11
const TIP_LIFT_REST: float = 0.25

## The stroke speed a full-amplitude beat corresponds to. [BirdNPC] commands 2.4
## when calm and 3.2 when urgent, and the player's own downstroke peaks near 3,
## so a hurried bird visibly beats harder than a cruising one.
const REFERENCE_STROKE: float = 3.2
## Below this the command is not a wingbeat.
const STROKE_GATE: float = 0.15
## Wings this folded cannot beat — there is nothing left to beat with.
const SPAN_GATE: float = 0.35
## Seconds to ease the beat in and out of the glide pose. The beat itself always
## starts at the top of the stroke, so without this a bird would snap its wings
## up the instant it decided to flap.
const BLEND_TIME: float = 0.12
const EFFORT_RISE: float = 7.0
const EFFORT_FALL: float = 2.2

# --- the turn and the tail ----------------------------------------------------

## In a turn the inner wing draws in and drops a little. It is the clearest
## outside read there is on which way a bird is going.
const BANK_TUCK: float = 0.16
const BANK_DIHEDRAL: float = 0.12
## The tail twists against the roll — that is what it is for, and it is visible
## from a long way behind a bird.
const TAIL_ROLL: float = 0.34
const TAIL_PITCH: float = 0.85
const TAIL_SPREAD_REST: float = 0.62
const TAIL_SPREAD_MIN: float = 0.34
const TAIL_SPREAD_MAX: float = 1.15

## Beats per second at full effort. Set by the rig from the species: small birds
## beat fast, big ones slowly, and the difference is audible in the silhouette.
var beat_rate: float = 2.0

# --- output -------------------------------------------------------------------

## Shoulder angles, in radians, signed for the side they belong to so a rig can
## assign them straight to [member Node3D.rotation].
var left_flap: float = GLIDE_DIHEDRAL
var right_flap: float = GLIDE_DIHEDRAL
var left_sweep: float = 0.0
var right_sweep: float = 0.0
var twist: float = 0.0
## Spanwise bend handed to the shared shader, signed per side.
var left_bend: float = 0.0
var right_bend: float = 0.0
## How much wing there is, 0..1, per side.
var left_extension: float = 1.0
var right_extension: float = 1.0
var tip_lift: float = 0.0
var tail_pitch: float = 0.0
var tail_roll: float = 0.0
var tail_spread: float = TAIL_SPREAD_REST
var body_pitch: float = 0.0

## 0..1 through the current wingbeat; 0 is the top of the stroke.
var phase: float = 0.0
## True while a beat is in progress — including the tail of a beat whose command
## has already stopped.
var beating: bool = false
## Smoothed 0..1 effort, which sets how deep the beat is.
var effort: float = 0.0

var _blend: float = 0.0


func reset() -> void:
	phase = 0.0
	beating = false
	effort = 0.0
	_blend = 0.0
	left_flap = GLIDE_DIHEDRAL
	right_flap = GLIDE_DIHEDRAL
	left_sweep = 0.0
	right_sweep = 0.0
	twist = 0.0
	left_bend = 0.0
	right_bend = 0.0
	left_extension = 1.0
	right_extension = 1.0
	tip_lift = 0.0
	tail_pitch = 0.0
	tail_roll = 0.0
	tail_spread = TAIL_SPREAD_REST
	body_pitch = 0.0


## One frame of animation from one frame of flight state.
##
## Everything is sanitised here, at the boundary, exactly as [FlightModel.step]
## does — a NaN reaching a [member Node3D.rotation] is a bird that vanishes, and
## the flight core is allowed to hand out anything it likes for one frame while
## it repairs itself.
func advance(
	stroke: float, span: float, bank: float, alpha: float, alpha_trim: float, delta: float
) -> void:
	var dt: float = delta if is_finite(delta) else 0.0
	dt = clampf(dt, 0.0, 0.1)
	if dt <= 0.0:
		return
	var effort_target: float = clampf(
		(stroke if is_finite(stroke) else 0.0) / REFERENCE_STROKE, 0.0, 1.0
	)
	var open: float = clampf(span if is_finite(span) else 1.0, 0.0, 1.0)
	var roll: float = clampf(bank if is_finite(bank) else 0.0, -1.6, 1.6)
	var trim: float = alpha_trim if is_finite(alpha_trim) else 0.0
	var incidence: float = clampf(alpha if is_finite(alpha) else trim, -0.6, 0.6)
	var pitch: float = incidence - trim

	_advance_beat(effort_target, open, dt)

	var up: float = _flap_curve(phase)
	var power: float = _hump(phase, 0.0, DOWNSTROKE)
	var recover: float = _hump(phase, DOWNSTROKE, 1.0)
	var depth: float = _blend * lerpf(0.35, 1.0, effort)
	var tuck: float = 1.0 - open

	var swing: float = depth * (up * UP_LIMIT if up > 0.0 else up * DOWN_LIMIT)
	var lean: float = roll * BANK_DIHEDRAL
	left_flap = GLIDE_DIHEDRAL + swing + lean
	right_flap = GLIDE_DIHEDRAL + swing - lean

	var reach: float = depth * SWEEP_AMP * (recover - power) + tuck * TUCK_SWEEP
	right_sweep = -reach
	left_sweep = reach

	twist = pitch * TWIST_ALPHA - depth * TWIST_DOWN * power + depth * TWIST_UP * recover

	var bend: float = depth * RECOVERY_FOLD * recover + tuck * TUCK_BEND
	right_bend = bend
	left_bend = -bend

	tip_lift = TIP_LIFT * (TIP_LIFT_REST + depth * power * 0.9 + absf(roll) * 0.25)

	var base_extension: float = lerpf(EXTENSION_MIN, 1.0, open)
	right_extension = base_extension * (1.0 - maxf(roll, 0.0) * BANK_TUCK)
	left_extension = base_extension * (1.0 - maxf(-roll, 0.0) * BANK_TUCK)

	body_pitch = clampf(incidence, -0.5, 0.5) * BODY_PITCH_GAIN
	# A braking bird drops and spreads its tail; a diving one shuts it and holds
	# it in line with the body.
	tail_pitch = clampf(pitch, -0.5, 0.5) * TAIL_PITCH
	tail_roll = -roll * TAIL_ROLL
	tail_spread = clampf(
		TAIL_SPREAD_REST + effort * 0.45 + maxf(pitch, 0.0) * 1.2 - tuck * 0.55,
		TAIL_SPREAD_MIN, TAIL_SPREAD_MAX
	)


## The beat clock. A stroke that has started always runs to the top of the next
## upstroke before the bird is allowed to settle back into a glide.
func _advance_beat(effort_target: float, open: float, dt: float) -> void:
	var rate: float = EFFORT_RISE if effort_target > effort else EFFORT_FALL
	effort = move_toward(effort, effort_target, dt * rate)

	var wants: bool = effort_target > STROKE_GATE / REFERENCE_STROKE and open > SPAN_GATE
	if wants:
		beating = true
	if beating:
		phase += dt * beat_rate * lerpf(0.7, 1.25, effort)
		while phase >= 1.0:
			phase -= 1.0
			if not wants:
				beating = false
				phase = 0.0
				break
	else:
		phase = 0.0
	_blend = move_toward(_blend, 1.0 if beating else 0.0, dt / BLEND_TIME)


## Where the wing is in the stroke: +1 at the top, −1 at the bottom, with the
## descent squeezed into the first [constant DOWNSTROKE] of the cycle. Both
## halves are half-cosines, so the wing is momentarily still at the top and the
## bottom and fastest in the middle — which is where the thrust is.
static func _flap_curve(p: float) -> float:
	if p < DOWNSTROKE:
		return cos(PI * p / DOWNSTROKE)
	return -cos(PI * (p - DOWNSTROKE) / (1.0 - DOWNSTROKE))


## A 0→1→0 hump over a window of the cycle, and zero outside it.
static func _hump(p: float, from: float, to: float) -> float:
	if p < from or p > to or to <= from:
		return 0.0
	return sin(PI * (p - from) / (to - from))
