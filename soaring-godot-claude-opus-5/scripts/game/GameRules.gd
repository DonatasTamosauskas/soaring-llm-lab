class_name GameRules
extends RefCounted

## The agar.io half of the game, isolated as pure functions so the progression
## can be tested and balanced without spawning a single bird.

## How much bigger you must be to take another bird. The margin is what makes
## near-equal encounters a standoff instead of a coin flip decided by whoever's
## floating-point size happened to be larger.
const CATCH_MARGIN: float = 1.12

## How much mass a catch is worth, as a multiple of the victim's. A pacing
## constant, not a physical one — the sky is repopulated relative to the player's
## size rather than out of a conserved pool, so there is no ecosystem here whose
## mass could fail to balance.
##
## What it actually sets is how long a run is, and the arithmetic is unforgiving.
## [SessionProbe] measures a competent hunter catching about one bird a minute,
## and prey cannot be drawn much above 0.8 of your own size or it simply outruns
## you. At the original 0.85 that is 4 % of length per catch: the climb to
## SOVEREIGN took over an hour of flapping, and being caught even occasionally
## made the whole loop run backwards. At 1.35 a catch is worth 12 % of your
## length, a death costs about the same as one catch, and a good player's run is
## ten to fifteen minutes.
const DIGESTION: float = 1.35

const MIN_SIZE: float = 0.35
const MAX_SIZE: float = 8.0


## Mass is what actually adds up when one bird eats another; size is the cube
## root of it. That is what produces agar.io's signature curve — early catches
## are transformative, late ones are barely felt — without any hand-tuned table.
static func mass_of(size: float) -> float:
	return pow(maxf(size, 0.0), 3.0)


static func size_of_mass(mass: float) -> float:
	return pow(maxf(mass, 0.0), 1.0 / 3.0)


static func grown_size(size: float, prey_size: float) -> float:
	var total: float = mass_of(size) + mass_of(prey_size) * DIGESTION
	return clampf(size_of_mass(total), MIN_SIZE, MAX_SIZE)


static func can_catch(hunter_size: float, prey_size: float) -> bool:
	return hunter_size > prey_size * CATCH_MARGIN


## Distance at which a catch registers. Generous relative to the visual body so
## that a fast pass counts — at 40 m/s a strict hitbox would be a lottery decided
## by which physics tick you happened to land on.
##
## Widened from 0.55/0.55/0.9, and given a speed term, after [SessionProbe] flew
## an hour of real hunting and measured where the passes actually land.
##
## The old radius was 1.8 m. A bird flying at 25 m/s cannot turn inside a 20 m
## radius — that is what [FlightModel] gives you at a 72-degree bank — so an
## aiming error of a few metres at close range is not correctable, and a 1.8 m
## sphere converted almost nothing: an autopilot with a real speed advantage and
## a solved intercept caught one bird in five minutes and passed within 4 m
## twice. A strike window has to be commensurate with the turning circle the
## flight model actually affords.
##
## The speed term is the important half. What matters is not how big the sphere
## is but how long a strike is inside it: two birds converging at 40 m/s spend a
## third of the time in a fixed sphere that two closing at 12 m/s do. Scaling
## with the closing speed does not make that dwell constant — [GameRulesTests]
## measures it falling from 1.05 s to 0.33 s between 12 and 60 m/s — but it
## leaves nearly twice the dwell a fixed radius would at the top of the range,
## which is the difference between a stoop being a strike and being a lottery.
## A slow drift-by still has to be accurate.
## [param closing_speed] defaults to zero, which is the honest answer when the
## caller does not know it.
static func catch_distance(
	hunter_size: float, prey_size: float, closing_speed: float = 0.0
) -> float:
	var speed: float = closing_speed if is_finite(closing_speed) else 0.0
	return 1.5 * hunter_size + 1.0 * prey_size + 2.8 + 0.15 * clampf(speed, 0.0, 60.0)


## How far off the nose a strike may be: about 44 degrees.
##
## The cone is what lets the radius above be generous without turning into a
## vacuum. A bird you dived at and connected with is inside it; a bird you
## happened to slide past sideways at nine metres is not. Without the cone, the
## radius that makes hunting convert also makes every near miss a free meal,
## which is the thing [GameRulesTests] means by "never an auto-win vacuum".
const STRIKE_COSINE: float = 0.72

## Slowest a hunter may be going and still be striking, in m/s.
##
## A bird that is not flying is not hunting. Without this, the direction test
## has no direction to work with, and the honest-looking fallback — "no
## meaningful heading, so allow it" — is a vacuum: a player sitting on a branch
## ate every smaller bird that came within the full catch radius from any
## bearing, and roosting NPCs did the same to each other inside the communal
## roosts [Flock] deliberately builds. This is well under a stall (the slowest
## the flight model will fly a bird is about 11 m/s) and well over the residual
## drift of a perched bird, so it excludes exactly the case it means to.
const MIN_STRIKE_SPEED: float = 1.0


## The catch test as the game actually applies it: close enough, going fast
## enough to be going anywhere, and going for it. Vectors, but still pure
## arithmetic — no scene, no nodes.
static func within_strike(
	hunter_position: Vector3, hunter_velocity: Vector3, hunter_size: float,
	prey_position: Vector3, prey_velocity: Vector3, prey_size: float
) -> bool:
	var offset: Vector3 = prey_position - hunter_position
	if not offset.is_finite() or not hunter_velocity.is_finite():
		return false
	if not is_finite(hunter_size) or not is_finite(prey_size):
		# A NaN reach compares false against every distance, so without this the
		# range check silently passes and a bird of no particular size eats.
		return false
	var speed: float = hunter_velocity.length()
	if speed < MIN_STRIKE_SPEED:
		return false
	var distance: float = offset.length()
	var closing: float = (hunter_velocity - prey_velocity).length()
	if distance > catch_distance(hunter_size, prey_size, closing):
		return false
	if distance < 0.001:
		# Occupying the same point: there is no direction left to test, and a
		# flying bird that is exactly on top of its prey has caught it.
		return true
	return hunter_velocity.dot(offset) / (speed * distance) >= STRIKE_COSINE


## What a player drops back to after being caught. Losing everything after a
## ten-minute climb is a reason to take the headset off, so a caught bird keeps
## two thirds of its mass and rejoins immediately.
##
## Two thirds, not the 35 percent this started at, because the two rates have to
## be compatible: [SessionProbe] measures a competent hunter catching about one
## bird every hundred seconds and being caught about once every four minutes, and
## at 35 percent a death erased five catches — the loop ran backwards no matter
## how well it was flown. A death now costs a little over one catch. It is still
## the worst thing that can happen to you, because it also takes your streak,
## your position and one of your five lives.
static func size_after_being_caught(size: float) -> float:
	return clampf(size_of_mass(mass_of(size) * 0.65), MIN_SIZE, MAX_SIZE)


static func score_for_catch(prey_size: float) -> int:
	return int(round(10.0 * mass_of(prey_size)))
