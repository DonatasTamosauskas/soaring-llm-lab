class_name AiMirror
extends RefCounted
## A snapshot of the AI area's per-species behaviour numbers
## (scripts/ai/species_profile.gd, 2026-09-25), its prey-awareness rule
## (scripts/ai/npc_brain.gd _sense), its hunting and fleeing rules
## (npc_brain.gd) and its flight envelope and energy (npc_flight.gd,
## npc_bird.gd), so the game-loop's pacing simulations face the same
## wariness, hunting and speeds the real NPCs will have. The mirror is
## validated against the AI area's own measurement: SimBrains duels in the
## AI's duel setup must land on the AI's measured catch rates (DUEL_*,
## tests/unit/game/danger_test.gd). Copied, not
## referenced: the game-loop suite must not depend on another area's
## in-progress code. If the AI area retunes, re-copy and re-run
## tests/shots/gameloop_pacing.tscn (the pacing test checks the table is
## current).
##
##   awareness_m  prey notices a predator coming at it from the front here
##   reaction_s   ...and reacts after this long
##   jink         0..1 how hard it dodges
##   hunt         0..1 hunting drive (0 = never hunts)
##   hunt_range_m a hunter engages prey within this range
##   timeout_s    ...and gives up after this long
##   hunger_rate  hunger per second (hunts above 0.25)

const DATA := {
	&"moth": [9.0, 0.24, 0.9, 0.0, 0.0, 0.0, 0.0],
	&"wren": [20.0, 0.15, 0.85, 0.55, 22.0, 8.0, 0.018],
	&"sparrow": [26.0, 0.18, 0.7, 0.45, 28.0, 9.0, 0.015],
	&"swallow": [30.0, 0.16, 0.9, 0.85, 38.0, 13.0, 0.02],
	&"starling": [32.0, 0.2, 0.75, 0.3, 30.0, 16.0, 0.012],
	&"pigeon": [36.0, 0.28, 0.72, 0.25, 35.0, 10.0, 0.01],
	&"crow": [45.0, 0.28, 0.55, 0.6, 55.0, 14.0, 0.012],
	&"gull": [55.0, 0.32, 0.45, 0.5, 65.0, 14.0, 0.011],
	&"hawk": [60.0, 0.3, 0.35, 0.95, 90.0, 16.0, 0.016],
	&"eagle": [70.0, 0.35, 0.25, 0.9, 120.0, 18.0, 0.014],
}

## Aspect factors of the awareness radius (the AI's rule): an attacker from
## behind is seen late, from behind and above later still.
const BEHIND := 0.65
const BEHIND_ABOVE := 0.55
const ABOVE := 0.75

# --- Flight (scripts/ai/npc_flight.gd, measured 2026-09-25) ------------------
# Level speed at full flapping effort over cruise (NpcFlight.sprint /
# cruise): 1.32 moth, 1.27 sparrow, 1.21 pigeon, 1.185 hawk, 1.17 eagle, a
# power law in mass within 0.01 of every species.
const SPRINT_REF := 1.27
const SPRINT_EXP := -0.0185
## A tucked stoop reaches SizeRules max_speed (2.6 x cruise); spread wings
## cap a dive at about 1.55 x cruise.
const SPREAD_DIVE := 1.55
## Pursuit: heading controller gain (1/s) and proportional-navigation gain.
const HEADING_GAIN := 6.0
const PN_GAIN := 4.0

# --- Energy (scripts/ai/npc_bird.gd _metabolism / effort_cap) ----------------
## Energy drain per second at flapping effort e: 0.008 e + 0.03 e^3
## (a flat-out sprint drains 0.038/s); gliding (e < 0.05) regains 0.012/s,
## perching 0.09/s. Birds spawn with 0.6..1.0 and a meal gives +0.3.
const DRAIN_LIN := 0.008
const DRAIN_CUBE := 0.03
const GLIDE_GAIN := 0.012
const PERCH_GAIN := 0.09
const MEAL_ENERGY := 0.3
## Energy the AI's birds carry (measured with
## tests/shots/gameloop_ai_snapshot.tscn, 2026-09-26, before the AI's fix
## round 1: the AI's Ecosystem in its test world around a mock player,
## 300 s): calm birds mean 0.57-0.60, q10 0.15, median 0.6-0.67, q90 0.96;
## prey start fleeing at a median of 0.54-0.66. The sims have no perches or
## thermals, so their calm birds spawn with that distribution (ENERGY_MEAN /
## ENERGY_SD, clamped) and calm flight adds CALM_RECOVERY on top of the
## flight's own drain, faster (CALM_RECOVERY_LOW) when low (perching).
## Known gap: in the same 300 s setup the mirror's calm birds settle lower
## (median ~0.4, q90 ~0.8), so mirror prey tire sooner than the AI's did.
## The pacing evidence for the brief comes from the AI's real sky
## (docs/areas/GAMELOOP.md); the mirror is the suite's regression.
const ENERGY_MEAN := 0.6
const ENERGY_SD := 0.28
const CALM_RECOVERY := 0.006
const CALM_RECOVERY_LOW := 0.02
const LOW_ENERGY := 0.35


## A spawning / calm bird's energy, from the AI's measured distribution.
static func spawn_energy(rng: RandomNumberGenerator) -> float:
	return clampf(rng.randfn(ENERGY_MEAN, ENERGY_SD), 0.1, 1.0)


static func drain(effort: float) -> float:
	return DRAIN_LIN * effort + DRAIN_CUBE * effort * effort * effort


## Highest flapping effort a bird with this energy can give (tired birds
## cannot sprint but can always hold level flight).
static func effort_cap(energy: float) -> float:
	return clampf(0.35 + energy * 1.5, 0.45, 1.0)


static func sprint_ratio(mass: float) -> float:
	return SPRINT_REF * pow(maxf(mass, 1e-4) / 0.03, SPRINT_EXP)

# --- Hunting and fleeing (scripts/ai/npc_brain.gd) ----------------------------
## Raptors stoop: fold and dive when the prey is at least STOOP_DH m below
## and horizontally within STOOP_HD x that height; the stoop ends when level
## with the prey or once it has passed it (distance growing again from a
## closest approach under STOOP_PASS_M).
const STOOPERS := [&"hawk", &"eagle"]
const STOOP_DH := 10.0
const STOOP_HD := 2.2
const STOOP_PASS_M := 12.0
## Strike: within STRIKE_SPANS wingspans a hunter throws its body at the
## prey sideways at 2.5 sqrt(span) (1 + 0.6 agility) m/s (the lunge).
const STRIKE_SPANS := 1.2
## Hunt give-up rules: failed passes (a pass is getting within 2 x strike
## reach; it ends beyond 3 x that), no progress (closing < 0.3 m/s away from
## a pass for max(3 s, one turning circle + 1.5 s)), too tired, too far
## (1.6 x hunting range), the species' timeout counted from when the prey
## noticed, and before that an approach budget of 2x the straight-away
## intercept time + 6 s (10..40 s; + the timeout when stalking the player).
const PASSES := 3
const TIRED := 0.12
const RANGE_GIVE_UP := 1.6
const GIVE_UP_COOLDOWN_S := 8.0
## Stalking at 80% effort while the prey has not noticed and is further
## than max(25 m, 1.1 x its awareness): the sprint is saved for the chase.
const STALK_EFFORT := 0.8
## Hunt choice: prey score sqrt(ratio) / (1 + intercept time / 5 s), x1.3
## for a stooper with the prey 8 m below, x1.25 for the player
## (PLAYER_INTEREST); the hunt wins over calm flight when
## drive x smoothstep(0.25, 0.75, hunger) x score x 1.6 beats the calm
## utility, and needs hunger > 0.25 and energy > 0.25.
const PLAYER_INTEREST := 1.25
## Searching: a hungry hunter (hunger > SEARCH_HUNGER, energy >
## SEARCH_ENERGY) with nothing to hunt in range heads for the nearest
## worthwhile prey within SEARCH_RANGE x its hunting range (a goal kept up to
## SEARCH_GOAL_S), at most every SEARCH_COOL_S.
const SEARCH_RANGE := 3.0
const SEARCH_HUNGER := 0.5
const SEARCH_ENERGY := 0.35
const SEARCH_COOL_S := 6.0
const SEARCH_GOAL_S := 15.0
const HUNT_UTILITY_MIN := 0.3
## (tools vary it: the calibration against the AI's measured hunting rate)
static var hunt_utility_min := HUNT_UTILITY_MIN
const HUNT_MIN_ENERGY := 0.25
## Fleeing: threat levels. A hunter chasing *me*: 1 + proximity (flee on
## sight); one hunting nearby: proximity + 0.3 if approaching; the player:
## proximity + 0.1 (+0.35 if approaching); flee at 0.45. Alert birds track a
## threat to 2x their awareness and calm down 1.5 s after it has gone.
const FLEE_LEVEL := 0.45
const VIGILANCE := 2.0
const CALM_S := 1.5
## The escape line is re-aimed at the reaction rate, and held during the
## final run (closing, time-to-contact < FINAL_RUN_S).
const FINAL_RUN_S := 1.8
## Jinks: on each attack run (closing, time to strike < JINK_WINDOW_S) the
## prey sees it coming with p = jink skill x (0.55 + 0.45 energy) and breaks
## at time-to-strike 0.38 +- (1.3 - skill) / 2 s, sideways across the
## attacker's path and a little down, for 0.3..0.5 s. A new run starts
## once time to strike exceeds 2.5 s again.
const JINK_WINDOW_S := 1.6
const JINK_AT := 0.38
const JINK_RESET_S := 2.5


## Best glide ratio with wings spread (AI profile "glide_ratio").
const GLIDE := {
	&"moth": 3.0, &"wren": 4.0, &"sparrow": 5.0, &"swallow": 9.0, &"starling": 7.0,
	&"pigeon": 7.0, &"crow": 9.0, &"gull": 14.0, &"hawk": 12.0, &"eagle": 15.0,
}


static func glide_ratio(species: StringName) -> float:
	return float(GLIDE.get(species, 5.0))


## Altitude band above ground (m) the species travels in (AI profile "alt").
const ALT := {
	&"moth": [1.5, 7.0], &"wren": [1.5, 8.0], &"sparrow": [3.0, 16.0], &"swallow": [4.0, 30.0],
	&"starling": [10.0, 60.0], &"pigeon": [6.0, 40.0], &"crow": [10.0, 50.0], &"gull": [25.0, 140.0],
	&"hawk": [25.0, 110.0], &"eagle": [50.0, 190.0],
}


## Calm-flight flutter (AI profile "erratic": moths wobble a few times a
## second while wandering) and the soaring species (style "soar": they glide
## between thermals and flap only when low).
const ERRATIC := {&"moth": 0.8, &"wren": 0.25, &"sparrow": 0.1, &"swallow": 0.05}
const SOARERS := [&"gull", &"hawk", &"eagle"]
## Flocking species (profile "flock" >= 0.5): the AI's Ecosystem spawns them
## as flocks or into existing ones, so in its sky they are all flocked. A
## flocked bird's hunt utility is x FLOCK_HUNT (it stays with the flock), and
## a flocking prey is worth x FLOCK_CONFUSION to a hunter (confusion effect).
const FLOCKING := [&"sparrow", &"swallow", &"starling", &"pigeon"]
const FLOCK_HUNT := 0.4
const FLOCK_CONFUSION := 0.6


static func flocks(species: StringName) -> bool:
	return FLOCKING.has(species)


static func stoops(species: StringName) -> bool:
	return STOOPERS.has(species)


static func erratic(species: StringName) -> float:
	return float(ERRATIC.get(species, 0.0))


static func soars(species: StringName) -> bool:
	return SOARERS.has(species)


static func strike_reach(span: float) -> float:
	return maxf(0.25, span * STRIKE_SPANS)


static func strike_speed(span: float, mass: float) -> float:
	return 2.5 * sqrt(span) * (1.0 + 0.6 * float(SizeRules.performance(mass)["agility"]))


static func of(species: StringName) -> Array:
	return DATA.get(species, DATA[&"sparrow"])


static func awareness_m(species: StringName) -> float:
	return of(species)[0]


static func reaction_s(species: StringName) -> float:
	return of(species)[1]


static func jink(species: StringName) -> float:
	return of(species)[2]


static func hunt_drive(species: StringName) -> float:
	return of(species)[3]


static func hunt_range_m(species: StringName) -> float:
	return of(species)[4]


static func hunt_timeout_s(species: StringName) -> float:
	return of(species)[5]


static func hunger_rate(species: StringName) -> float:
	return of(species)[6]


# --- The AI area's own duel measurement (validation target) -------------------
# tests/unit/ai/hunt_duel_test.gd as reported on 2026-09-25: a hungry hunter
# starts 55-90% of its hunting range from the prey (raptors 25-45 m above in
# every other trial), open air, 24 trials per pair, 30 s at most, catches by
# the strict stand-in rule (bodies touching, no reach margin, no aim cone).
const DUEL_PAIRS := [[&"sparrow", &"moth"], [&"starling", &"sparrow"], [&"crow", &"starling"],
	[&"hawk", &"pigeon"], [&"eagle", &"gull"]]
## Caught fraction vs fleeing prey, per pair (overall 0.50)...
const DUEL_FLEE: Array[float] = [0.458, 0.417, 0.458, 0.625, 0.542]
## ...and vs prey that does not flee (overall 0.98).
const DUEL_CALM: Array[float] = [0.958, 1.0, 1.0, 1.0, 0.958]
const DUEL_TRIALS := 24
const DUEL_MAX_S := 30.0
