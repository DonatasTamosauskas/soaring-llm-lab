class_name SizeRules
extends RefCounted
## The size ladder: species, how mass maps to body size, who eats whom, and
## what a meal is worth.
##
## Owned by the game-loop area; flight, AI, art and UI read from here so the
## numbers only live in one place. Values are loosely real-world and tuned
## for play (see docs/areas/GAMELOOP.md for the pacing simulations that set
## them).

## Predator must outweigh prey by this factor to eat it (agar.io style).
## 1.25 keeps the ladder tight: every species can eat the one below it, and a
## player who has grown a third past a species' mass can eat that species.
const EAT_RATIO := 1.25

## Species ordered smallest to largest. mass in kg, span = wingspan in m.
## tier is the index into this list and is what the HUD calls "size".
const SPECIES: Array[Dictionary] = [
	{"id": &"moth", "name": "Moth", "mass": 0.004, "span": 0.08},
	{"id": &"wren", "name": "Wren", "mass": 0.012, "span": 0.16},
	{"id": &"sparrow", "name": "Sparrow", "mass": 0.03, "span": 0.24},
	{"id": &"swallow", "name": "Swallow", "mass": 0.055, "span": 0.33},
	{"id": &"starling", "name": "Starling", "mass": 0.1, "span": 0.40},
	{"id": &"pigeon", "name": "Pigeon", "mass": 0.3, "span": 0.66},
	{"id": &"crow", "name": "Crow", "mass": 0.5, "span": 0.95},
	{"id": &"gull", "name": "Gull", "mass": 0.85, "span": 1.30},
	{"id": &"hawk", "name": "Hawk", "mass": 1.3, "span": 1.60},
	{"id": &"eagle", "name": "Eagle", "mass": 3.0, "span": 2.10},
]

# --- Meals (value, gain and worth) ---------------------------------------
# What a catch is *worth chasing* depends only on the prey/eater mass ratio:
# meal_value = MEAL_CONVERSION x ratio x a smooth diminishing-returns curve
# (prey below MEAL_DUST_RATIO of the eater is worth nothing, above
# MEAL_FULL_RATIO its full conversion). As you grow, a given species' ratio
# falls, so the smallest birds drop off the menu one by one: that is what
# makes the player stop caring about them (is_worthwhile, the highlights,
# the target cue, AI prey choice and the apex count all use it).
# How much the catch actually *grows* you is that value times your mass times
# growth_efficiency(mass): growing gets harder as you grow (metabolic
# scaling, agar.io's big-cell slowdown), which keeps the first tier-ups
# quick and makes pigeon -> eagle the long haul the pacing brief asks for.

## Fraction of the prey's mass a full-value meal adds (at full efficiency).
const MEAL_CONVERSION := 0.8
## prey/eater mass ratio at and below which a meal is worth nothing.
const MEAL_DUST_RATIO := 0.03
## prey/eater mass ratio from which a meal is worth its full conversion.
const MEAL_FULL_RATIO := 0.25
## A catch is "worthwhile" when its meal_value is at least this (a prey of
## roughly a tenth of your mass or more).
const WORTH_MIN := 0.02
## Growth efficiency is GROWTH_GAIN up to GROWTH_REF_MASS and falls as
## (mass / GROWTH_REF_MASS)^-GROWTH_SIZE_EXP above it. Both were tuned on
## whole simulated runs in the shipped valley with the AI's sky and the
## statistical pacing model (docs/areas/GAMELOOP.md, "Pacing"): the gain
## sets how quickly the small tiers pass (time to pigeon), the exponent how
## long the haul from pigeon to eagle is. (In the valley cover protects and
## the modelled player cannot fly through houses: catches are rarer than in
## the AI's test world round 1 was tuned in, so each counts for more.)
## Fix round 4: 1.1 / 0.03 (was 1.62 / 0.012). Two things moved the
## pacing: the threat cue no longer hands attacks to bystanders (the
## modelled players evade a fifth less), and the AI's Ecosystem now stages
## flocks and single birds ahead of the player (its "show"): prey is met far
## more often (at 1.55 / 0.04 the tuning seeds reached pigeon at 3:28 and
## eagle at 16:51 in that sky; at 1.0 / 0.04, 7:06 and 30:07). Chosen on
## tuning seeds alone, with the pacing model fitted on them, for pigeon
## ~6:15 and eagle ~25 min - the middle of the brief (docs/areas/GAMELOOP.md,
## "How the tuning got here").
## Core loop round: 1.15 / 0.32, tuned on the real chain (the competent
## person flying the real PlayerBird in the real game, both quality tiers,
## tuning seeds 101-106 only) once the sky got its moth swarms, the reachable-
## only target cue, the magnet and the danger director: pellets are met all
## the time now, so the exponent does the work of making pigeon -> eagle the
## long haul. (1.5 / 0.35 put both medians on the brief's lower edges -
## pigeon ~5:00-5:50, eagle ~20:30; with 6 g pellets 1.4 / 0.38 gave the
## full tier's pigeon at 4:10 and its eagle at 21:12 - a sparrow to a pigeon
## on ~3.5 catches a minute needs smaller meals - but at 1.1 / 0.31, with
## the sky's first attack on time, the pigeon came at 8:25 / 8:23 (full /
## Quest) and the eagle at 26:51 / 24:08; with the attack respite at 110 s
## 1.3 / 0.36 gave 5:12 / 5:20 and 21:36 / 23:01 - the pigeon on the lower
## edge; docs/areas/GAMELOOP.md, "The evidence".)
## Core loop fix round 1: 1.6 / 0.42. With the murmuration buffet gone (a
## swallow time after each catch, one tier-up per 30 s) and the ring kept on
## the chase, 1.15 / 0.32 put the pigeon at 7:55-10:10 on the tuning seeds
## (eagle 18:31-27:06): the small tiers need more per meal, the haul from
## pigeon to eagle about the same (the efficiency at ~0.1 kg up ~24%, at
## ~1 kg unchanged). Then 1.8 / 0.42 (the full tier 12% more per meal), the
## Quest's sky factor down to x1.06 (GameLoop.SKY_GROWTH_EXP).
const GROWTH_REF_MASS := 0.03
const GROWTH_SIZE_EXP := 0.42
const GROWTH_GAIN := 1.8
## The growth values in effect (the constants above; the pacing tool varies
## them for tuning sweeps - nothing else writes them).
static var growth_gain := GROWTH_GAIN
static var growth_size_exp := GROWTH_SIZE_EXP


static func can_eat(predator_mass: float, prey_mass: float) -> bool:
	return predator_mass >= prey_mass * EAT_RATIO


## Wingspan for a body mass. Exactly each species' listed span at its own
## mass, and continuous and strictly increasing in between (log-log
## interpolation between neighbouring species), so a growing player never
## sees their size jump or shrink at a tier-up. Beyond the ends of the ladder
## it follows isometric scaling (span ~ mass^1/3).
## Hot path (every bird, every frame, several callers): one log, one exp and
## a scan of precomputed log tables.
static func wingspan_for_mass(mass: float) -> float:
	if _log_mass.is_empty():
		_build_tables()
	var lm := log(maxf(mass, 0.0001))
	var n := _log_mass.size()
	if lm <= _log_mass[0]:
		return exp(_log_span[0] + (lm - _log_mass[0]) / 3.0)
	for i in range(1, n):
		if lm <= _log_mass[i]:
			var k := (lm - _log_mass[i - 1]) / (_log_mass[i] - _log_mass[i - 1])
			return exp(_log_span[i - 1] + k * (_log_span[i] - _log_span[i - 1]))
	return exp(_log_span[n - 1] + (lm - _log_mass[n - 1]) / 3.0)


static var _log_mass := PackedFloat64Array()
static var _log_span := PackedFloat64Array()


static func _build_tables() -> void:
	var lm := PackedFloat64Array()
	var ls := PackedFloat64Array()
	for s in SPECIES:
		lm.append(log(float(s["mass"])))
		ls.append(log(float(s["span"])))
	_log_span = ls
	_log_mass = lm


static func body_radius_for_mass(mass: float) -> float:
	return wingspan_for_mass(mass) * 0.16


## Index of the largest species whose mass is <= mass (0 if below all).
static func tier_for_mass(mass: float) -> int:
	var tier := 0
	for i in SPECIES.size():
		if mass >= SPECIES[i]["mass"] * 0.999:
			tier = i
	return tier


static func species_for_mass(mass: float) -> StringName:
	return SPECIES[tier_for_mass(mass)]["id"]


static func species_index(id: StringName) -> int:
	for i in SPECIES.size():
		if SPECIES[i]["id"] == id:
			return i
	return -1


## How worth chasing a prey is, 0.. (independent of the eater's absolute
## size): the growth, as a fraction of its own mass, a full-efficiency
## eater would get. 0 when it cannot eat it.
static func meal_value(eater_mass: float, prey_mass: float) -> float:
	if not can_eat(eater_mass, prey_mass):
		return 0.0
	var r := prey_mass / eater_mass
	return MEAL_CONVERSION * r * meal_efficiency(r)


## True when the eater can eat the prey and it is worth the chase.
static func is_worthwhile(eater_mass: float, prey_mass: float) -> bool:
	return meal_value(eater_mass, prey_mass) >= WORTH_MIN


## Mass (kg) the eater actually gains by catching prey. 0 when it cannot eat it.
static func meal_gain(eater_mass: float, prey_mass: float) -> float:
	return meal_value(eater_mass, prey_mass) * eater_mass * growth_efficiency(eater_mass)


## 0..1 diminishing-returns factor for a prey/eater mass ratio: smoothstep
## from MEAL_DUST_RATIO (0) to MEAL_FULL_RATIO (1).
static func meal_efficiency(ratio: float) -> float:
	return smoothstep(MEAL_DUST_RATIO, MEAL_FULL_RATIO, ratio)


## How much of a meal's value a body of this mass turns into growth
## (GROWTH_GAIN at sparrow size and below, falling with size).
static func growth_efficiency(eater_mass: float) -> float:
	return growth_gain * minf(1.0, pow(maxf(eater_mass, 1e-6) / GROWTH_REF_MASS, -growth_size_exp))


## What a catch actually grows the eater by, as a fraction of its own mass
## (0.1 = +10%). Shrinks both with smaller prey and with a bigger eater.
static func meal_worth(eater_mass: float, prey_mass: float) -> float:
	return meal_gain(eater_mass, prey_mass) / maxf(eater_mass, 0.0001)


## Target flight envelope for a bird of this mass: the single source of
## truth shared by the player's FlightModel (tuned and tested to match it)
## and NPC flight (which uses it directly). Speeds m/s, turn rate rad/s.
##   cruise    level flapping/gliding speed
##   min_speed slowest controllable flight (near stall)
##   max_speed tucked dive limit
##   turn_rate max sustained turn rate at cruise
##   climb     sustained climb rate while flapping hard
##   agility   0..1 relative manoeuvrability (1 = moth/wren, ~0.2 = eagle)
static func performance(mass: float) -> Dictionary:
	var k := mass / 0.03  # relative to a sparrow
	var cruise := cruise_speed(mass)
	return {
		"cruise": cruise,
		"min_speed": cruise * 0.45,
		"max_speed": cruise * 2.6,
		"turn_rate": deg_to_rad(220.0) * pow(k, -0.26),
		"climb": 4.0 * pow(k, -0.09),
		"agility": clampf(pow(k, -0.3), 0.15, 1.0),
	}


## Level cruise speed (m/s) for a body mass: performance()["cruise"] without
## building the whole dictionary (time_scale runs on hot paths).
static func cruise_speed(mass: float) -> float:
	return 9.0 * pow(maxf(mass, 1e-6) / 0.03, 1.0 / 6.0)


## How slow a bird of this mass lives relative to a sparrow: body lengths
## per second fall as birds grow (span grows faster than cruise speed), so
## everything an eagle does takes longer in seconds than a sparrow's version
## (chases, bursts, finding prey). 1.0 for a sparrow (and anything smaller:
## clamped), 1.36 for a starling, 1.87 for a pigeon, 3.56 for a hawk, and the
## 4.0 cap for an eagle (4.06 unclamped).
## Game-loop timers and the simulated pilot scale by it; AI may too.
static func time_scale(mass: float) -> float:
	return clampf((wingspan_for_mass(mass) / 0.24) / (cruise_speed(mass) / 9.0), 1.0, 4.0)


static func species_data(id: StringName) -> Dictionary:
	var i := species_index(id)
	return SPECIES[i] if i >= 0 else {}
