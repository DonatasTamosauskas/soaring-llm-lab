class_name FlightEnv
extends RefCounted
## Per-tick environment input to FlightModel (FLIGHT_SPEC §7.10).
##
## Built by PlayerBird (or an NPC) every tick. Wind is sampled through
## wind_fn at every Heun evaluation, so a thermal lifts the bird smoothly
## (World.get_wind must stay C1-smooth).

## (pos: Vector3) -> Vector3 air velocity; empty = still air.
var wind_fn: Callable = Callable()
## Wind sampled at the wingtips: haptics/telemetry only, not physics.
var wind_l := Vector3.ZERO
var wind_r := Vector3.ZERO
## Distance to the ground below (layer 1, ray <= 2 spans), for the ground
## cushion, ground effect and AGL. INF = none in range.
var ground_distance := INF
var ground_normal := Vector3.UP
## Height of the belly above the ground below (m; the World's terrain, and
## the ray above when closer). INF = unknown. The stall guard reads it.
var agl := INF
## Thin air under the arena's lid: the air density ratio (0..1). Every
## aerodynamic force scales with it: lift, drag and (integration fix) the
## flap force. PlayerBird sets it from thin_air(); 1 = normal air.
var lift_scale := 1.0
## Assist accelerations (perch assist steering), world m/s^2.
var accel := Vector3.ZERO
## Assist AoA bias (perch auto-flare), rad, bounded +-3 deg by the caller.
var alpha_bias := 0.0
## Assist CD increment (landing configuration), 0..0.4.
var drag_bonus := 0.0


func clear_assists() -> void:
	accel = Vector3.ZERO
	alpha_bias = 0.0
	drag_bonus = 0.0


## The thin air's density ratio for a body whose top is `gap` metres below
## the lid (World.ceiling): 1 from `band` metres down, easing out to 0 at
## `floor_gap` metres below it as 1 - (1 - u)^2 (u = 1 at the band's start,
## 0 at its floor). The fade starts with zero slope (no kink where normal air
## ends) and is gentlest where flapping birds level off (density 0.6-0.8).
## Every force a bird makes fades with it, flap thrust included, so a climb
## levels off smoothly where the thinned air just carries its weight
## (density ratio = 1 / the bird's force-to-weight ratio): the harder it
## flaps, the higher, but never into the last floor_gap metres. Air that
## carries nothing cannot lift a bird either, so neither can a thermal: only
## momentum (a zoom climb) crosses them. (Integration fix; FLIGHT.md §2.)
## Smoothstep was tried: its steeper middle stopped the same climbs harder
## (stroke-mean up to 2.0 vs 1.8 m/s^2) and 5-8 m lower.
static func thin_air(gap: float, band: float, floor_gap: float) -> float:
	if not is_finite(gap) or gap >= band:
		return 1.0
	var u := clampf((gap - floor_gap) / maxf(band - floor_gap, 1e-3), 0.0, 1.0)
	return u * (2.0 - u)


## Uniform wind helper for tests.
static func uniform(w: Vector3) -> FlightEnv:
	var e := FlightEnv.new()
	e.wind_fn = func(_p: Vector3) -> Vector3: return w
	return e
