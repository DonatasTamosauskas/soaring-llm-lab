class_name GameRules
extends RefCounted

## The agar.io half of the game, isolated as pure functions so the progression
## can be tested and balanced without spawning a single bird.

## How much bigger you must be to take another bird. The margin is what makes
## near-equal encounters a standoff instead of a coin flip decided by whoever's
## floating-point size happened to be larger.
const CATCH_MARGIN: float = 1.12

## Fraction of a victim's mass you actually keep. Below 1 so the world does not
## inflate: every chase costs the ecosystem a little mass, and the spawner tops
## it back up with small birds.
const DIGESTION: float = 0.85

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
## that a fast pass counts — at 40 m/s a strict hitbox would be a lottery
## decided by which physics tick you happened to land on.
static func catch_distance(hunter_size: float, prey_size: float) -> float:
	return 0.55 * hunter_size + 0.55 * prey_size + 0.9


## What a player drops back to after being caught. Losing everything after a
## five-minute climb is a reason to take the headset off, so a caught bird keeps
## a share of its mass and rejoins immediately.
static func size_after_being_caught(size: float) -> float:
	return clampf(size_of_mass(mass_of(size) * 0.35), MIN_SIZE, MAX_SIZE)


static func score_for_catch(prey_size: float) -> int:
	return int(round(10.0 * mass_of(prey_size)))
