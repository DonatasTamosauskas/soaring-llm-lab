class_name Progression
extends RefCounted

## The shape of a run: the ladder of ranks you climb, how the sky escalates as
## you climb it, and what a catch is worth.
##
## Pure static functions over plain numbers, exactly like [GameRules], because
## the only honest way to answer "how long does it take to reach the top, and is
## the curve any good?" is to simulate several hundred whole sessions headlessly
## ([SessionSim]) and read the answer off a table. Anything that needed a scene
## could not be simulated, so nothing here touches one.

## Where a run starts. Chosen to sit in the middle of the [b]HUNTER[/b] band so
## a player has room to fall as well as room to climb: the rank below the
## starting rank is what being caught twice looks like.
const START_SIZE: float = 1.0

## Reaching this ends the run as a win.
##
## The number is measured, not chosen. [SessionProbe] flies the real game and
## reports that a hunter with decent technique catches a bird about every 85
## seconds and each catch adds about a tenth of its length, which is 0.088 of
## natural log per minute; a good player roughly doubles that. Every doubling of
## this target is therefore another eight to fifteen minutes of flapping your
## arms, and this is a game you play standing up. 3.2 is a run of ten to fifteen
## minutes — three promotions, three or four brushes with something bigger, and
## an ending.
##
## Well below [constant GameRules.MAX_SIZE] on purpose too: near the cap nothing
## can be spawned big enough to eat you (a predator has to be 1.12x your size and
## spawns clamp at 8.0), so a run that demanded the cap would spend its last
## minutes in a world with no stakes left in it. At 3.2 the eagles are still
## above you. You are the crown of the middle of the sky, not the end of it.
const APEX_SIZE: float = 3.2

## Catches you may lose before the run ends.
##
## Five, because the simulated curve says so rather than because it is a round
## number: at 0.27 deaths a minute for a competent player and a run of a quarter
## of an hour, three lives ended nine runs in ten before they got anywhere, and
## five leaves a good run room for the two or three bad encounters it is going to
## have. It is also what makes the bottom rank reachable — four deaths in a row
## from the starting size is exactly a FLEDGLING.
const LIVES: int = 5

## The ladder. The size thresholds are exactly [constant BirdMesh.CLASS_BOUNDS],
## which is the point: a promotion is never just a word on the HUD, it is the
## moment your own body and your own wings become a visibly different bird, and
## the moment every other bird in the sky can read that off your silhouette.
## [ProgressionTests] asserts that coupling so it cannot silently drift.
const RANKS: Array = [
	{"name": "FLEDGLING", "size": 0.35},
	{"name": "HUNTER", "size": 0.60},
	{"name": "RAIDER", "size": 1.20},
	{"name": "CORSAIR", "size": 2.40},
	{"name": "SOVEREIGN", "size": APEX_SIZE},
]

## What a spawner is being asked for. Kept explicit rather than implied by a
## number so the population guarantee — always something to hunt, always
## something to fear — can be expressed directly.
enum Role { PREY, PEER, PREDATOR }

# --- the escalation ----------------------------------------------------------
#
# Two things get worse as you climb, and they are separate levers: how *often*
# something above you shows up (the mix), and how much *bigger* it is when it
# does (the bands). Early on the sky is mostly lunch. At the top it is mostly
# rivals and monsters, and the lunch is small enough that you need a lot of it.

const PREY_SHARE_START: float = 0.58
const PREY_SHARE_APEX: float = 0.34
const PREDATOR_SHARE_START: float = 0.07
const PREDATOR_SHARE_APEX: float = 0.22

## Relative size bands, as a fraction of the player's size. A prey band that
## reached 1/1.12 would produce birds you cannot legally eat, and a predator
## band that dipped below 1.12 would produce ones that cannot eat you; both ends
## are held clear of the margin so a spawn always means what it looks like.
## The upper end is a measured limit, not a taste. Prey drawn at 0.86 of the
## player's size flies within a few percent of the player's own speed and simply
## cannot be run down: at that band [SessionProbe] converted 4 percent of 77
## chases, against 20 percent at 0.80.
const PREY_BAND_START := Vector2(0.55, 0.82)
const PREY_BAND_APEX := Vector2(0.46, 0.74)
const PEER_BAND := Vector2(0.90, 1.10)
const PREDATOR_BAND_START := Vector2(1.20, 1.75)
const PREDATOR_BAND_APEX := Vector2(1.35, 2.60)

# --- scoring -----------------------------------------------------------------

## Each unbroken catch after the first adds this much multiplier. The streak is
## the only thing being caught takes from you instantly, which is what makes a
## long run of kills something you can feel yourself protecting.
const STREAK_STEP: float = 0.25
const MAX_STREAK_MULTIPLIER: float = 4.0


# --- ranks -------------------------------------------------------------------

static func rank_index(size: float) -> int:
	if not is_finite(size):
		return 0
	var index: int = 0
	for i in RANKS.size():
		if size >= float(RANKS[i]["size"]):
			index = i
	return index


static func rank_name(size: float) -> String:
	return String(RANKS[rank_index(size)]["name"])


static func name_of_rank(index: int) -> String:
	return String(RANKS[clampi(index, 0, RANKS.size() - 1)]["name"])


static func size_of_rank(index: int) -> float:
	return float(RANKS[clampi(index, 0, RANKS.size() - 1)]["size"])


## Size at which the next promotion happens, or INF at the top of the ladder.
static func next_rank_size(size: float) -> float:
	var index: int = rank_index(size)
	if index >= RANKS.size() - 1:
		return INF
	return size_of_rank(index + 1)


## How far through the current rank you are, 0..1. Measured in [i]mass[/i], not
## length, because mass is what a catch actually adds — a bar that moved in
## length would crawl at the start of a rank and leap at the end of it, which is
## precisely backwards from what the player is doing.
static func rank_progress(size: float) -> float:
	if not is_finite(size):
		return 0.0
	var index: int = rank_index(size)
	if index >= RANKS.size() - 1:
		return 1.0
	var low: float = GameRules.mass_of(size_of_rank(index))
	var high: float = GameRules.mass_of(size_of_rank(index + 1))
	return clampf((GameRules.mass_of(size) - low) / maxf(high - low, 1e-6), 0.0, 1.0)


static func is_apex(size: float) -> bool:
	return is_finite(size) and size >= APEX_SIZE


# --- the sky around you ------------------------------------------------------

## How far along the climb the player is, 0 at the starting size and 1 at the
## apex. Falling below the starting size does not make the sky harder than it
## was on the first day — a demoted player is having a bad enough time already.
static func climb_fraction(player_size: float) -> float:
	if not is_finite(player_size):
		return 0.0
	return clampf((player_size - START_SIZE) / (APEX_SIZE - START_SIZE), 0.0, 1.0)


## Fractions of the flock that should be prey, peers and predators, as
## [code]Vector3(prey, peer, predator)[/code].
static func threat_mix(player_size: float) -> Vector3:
	var t: float = climb_fraction(player_size)
	var prey: float = lerpf(PREY_SHARE_START, PREY_SHARE_APEX, t)
	var predator: float = lerpf(PREDATOR_SHARE_START, PREDATOR_SHARE_APEX, t)
	return Vector3(prey, maxf(1.0 - prey - predator, 0.0), predator)


static func role_for_roll(player_size: float, roll: float) -> Role:
	var mix: Vector3 = threat_mix(player_size)
	var r: float = clampf(roll, 0.0, 0.999999) if is_finite(roll) else 0.0
	if r < mix.x:
		return Role.PREY
	if r < mix.x + mix.y:
		return Role.PEER
	return Role.PREDATOR


## Size of a bird spawned in role [param role] near a player of [param
## player_size]. [param roll] is a 0..1 sample; taking it as an argument rather
## than owning an RNG is what lets the distribution be swept exhaustively in a
## test and replayed exactly in a simulation.
static func size_for_role(player_size: float, role: Role, roll: float) -> float:
	var reference: float = player_size if is_finite(player_size) else START_SIZE
	var t: float = climb_fraction(reference)
	var r: float = clampf(roll, 0.0, 1.0) if is_finite(roll) else 0.5
	var band: Vector2 = PEER_BAND
	match role:
		Role.PREY:
			band = PREY_BAND_START.lerp(PREY_BAND_APEX, t)
		Role.PREDATOR:
			band = PREDATOR_BAND_START.lerp(PREDATOR_BAND_APEX, t)
	var relative: float = lerpf(band.x, band.y, r)
	return clampf(reference * relative, GameRules.MIN_SIZE, GameRules.MAX_SIZE)


static func spawn_size(player_size: float, role_roll: float, size_roll: float) -> float:
	return size_for_role(player_size, role_for_roll(player_size, role_roll), size_roll)


## Whether a bird of [param size] can still be a genuine threat to a player of
## [param player_size]. False near the cap, where the clamp on spawn sizes means
## nothing bigger can exist — which is exactly why the run ends at [constant
## APEX_SIZE] rather than at the cap.
static func threat_is_possible(player_size: float) -> bool:
	return GameRules.MAX_SIZE > player_size * GameRules.CATCH_MARGIN


# --- scoring -----------------------------------------------------------------

static func streak_multiplier(streak: int) -> float:
	return clampf(
		1.0 + STREAK_STEP * float(maxi(streak - 1, 0)), 1.0, MAX_STREAK_MULTIPLIER
	)


static func score_for_catch(prey_size: float, streak: int) -> int:
	return int(round(GameRules.score_for_catch(prey_size) * streak_multiplier(streak)))
