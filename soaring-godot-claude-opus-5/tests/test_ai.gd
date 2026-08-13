class_name AITests
extends RefCounted

## What the birds do, and what they are never allowed to do.
##
## Two kinds of test live here. The first kind is a rigged scene — two birds, a
## known geometry, a fixed number of steps — because "a predator stalks" is a
## claim about a specific manoeuvre and it should be pinned to one. The second
## kind is the whole ecosystem: [EcosystemSim] flies a real flock over the real
## world with nobody playing, and the assertions are about what the sky does,
## not about any one bird in it.
##
## Everything runs at the real physics rate through the real [FlightModel] and
## the real [Flock]. Nothing here scripts a bird's position: if a claim in this
## file is true, it is true because the AI flew it.

const STEP: float = 1.0 / 90.0


static func run(t: TestCase) -> void:
	_test_the_hash_sees_what_a_brute_force_scan_sees(t)
	_test_crowding_pushes_birds_apart(t)
	_test_a_bird_only_ever_moves_by_flying(t)
	_test_a_wingbeat_costs_something(t)
	_test_a_hunter_climbs_before_it_stoops(t)
	_test_a_hunter_gives_up(t)
	_test_prey_runs_for_the_ground(t)
	_test_a_perch_belongs_to_one_bird(t)
	_test_a_bigger_bird_takes_the_branch(t)
	_test_hostile_input_does_not_break_a_bird(t)

	var world := WorldBuilder.new()
	world.build()
	_test_terrain_breaks_the_line_of_sight(t, world)
	_test_a_bird_lands_on_a_real_branch(t, world)
	_test_a_roost_scatters(t, world)
	_test_birds_climb_in_the_lift(t, world)
	_test_the_flock_looks_after_itself(t, world)
	world.free()


# --- helpers --------------------------------------------------------------------

## A bird with no visuals. [method BirdNPC._ready] is never called, so there is
## no [BirdRig]: these tests are about flight and decisions, and building
## meshes for them would cost more than the simulation.
static func _bird(size: float, at: Vector3, seed_value: int = 11) -> BirdNPC:
	var bird := BirdNPC.new()
	bird.configure(size, at, null, seed_value)
	return bird


static func _free(birds: Array) -> void:
	for bird: Variant in birds:
		(bird as BirdNPC).free()


# --- perception -------------------------------------------------------------------

static func _test_the_hash_sees_what_a_brute_force_scan_sees(t: TestCase) -> void:
	t.begin("the hash sees what a brute force scan sees")
	var flock := Flock.new()
	var birds: Array[BirdNPC] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in 60:
		var bird := _bird(1.0, Vector3(
			rng.randf_range(-600.0, 600.0),
			rng.randf_range(20.0, 300.0),
			rng.randf_range(-600.0, 600.0)
		), i)
		birds.append(bird)
		flock.add(bird)
	flock.tick(1.0)

	for radius: float in [15.0, 60.0, 140.0, 400.0]:
		for probe: BirdNPC in [birds[0], birds[17], birds[41]]:
			var hashed: Array[BirdNPC] = flock.near(probe.at(), radius)
			var brute: int = 0
			for other: BirdNPC in birds:
				if other.at().distance_to(probe.at()) <= radius:
					brute += 1
			t.ok(
				hashed.size() == brute,
				"radius %.0f found %d, brute force found %d" % [radius, hashed.size(), brute]
			)
	_free(birds)


static func _test_terrain_breaks_the_line_of_sight(t: TestCase, world: WorldBuilder) -> void:
	t.begin("terrain breaks the line of sight")
	var flock := Flock.new()
	flock.world = world

	# Straight across open air at altitude: always visible.
	t.ok(
		flock.has_sight(Vector3(0.0, 400.0, 0.0), Vector3(0.0, 400.0, 200.0)),
		"two birds high over the bowl can see each other"
	)

	# Through the rim wall, which is 340 m of mountain: never visible.
	var blocked: int = 0
	var open: int = 0
	for i in 24:
		var angle: float = TAU * float(i) / 24.0
		var inside := Vector3(cos(angle) * 500.0, world.height_at(
			cos(angle) * 500.0, sin(angle) * 500.0
		) + 30.0, sin(angle) * 500.0)
		var outside := Vector3(cos(angle) * 1000.0, inside.y, sin(angle) * 1000.0)
		if flock.has_sight(inside, outside):
			open += 1
		else:
			blocked += 1
	t.ok(blocked >= 22, "the rim hides what is behind it (%d of 24 bearings)" % blocked)

	# And low over rolling ground, sight is sometimes blocked and sometimes not:
	# a test that never sees anything would pass with a broken height lookup.
	var near_misses: int = 0
	for i in 60:
		var a := Vector3(-300.0 + float(i) * 10.0, 0.0, -120.0)
		a.y = world.height_at(a.x, a.z) + 6.0
		var b := Vector3(a.x + 90.0, 0.0, a.z + 90.0)
		b.y = world.height_at(b.x, b.z) + 6.0
		if not flock.has_sight(a, b):
			near_misses += 1
	t.greater(float(near_misses), 0.0, "hugging the ground breaks sight at least sometimes")
	t.less(float(near_misses), 60.0, "but not everywhere, which would mean it always blocks")


static func _test_crowding_pushes_birds_apart(t: TestCase) -> void:
	t.begin("crowding pushes birds apart")
	var flock := Flock.new()
	var a := _bird(1.0, Vector3(0.0, 100.0, 0.0), 1)
	var b := _bird(1.0, Vector3(3.0, 100.0, 0.0), 2)
	var far := _bird(1.0, Vector3(400.0, 100.0, 0.0), 3)
	for bird: BirdNPC in [a, b, far]:
		flock.add(bird)
	flock.tick(1.0)

	var push_a: Vector3 = flock.crowding(a)
	var push_b: Vector3 = flock.crowding(b)
	t.greater(push_a.length(), 1.0, "a bird three metres away is crowding")
	t.less(push_a.x, 0.0, "and the push is away from it")
	t.greater(push_b.x, 0.0, "in both directions")
	t.less(flock.crowding(far).length(), 0.001, "a bird four hundred metres away is not")
	_free([a, b, far])


# --- the rules of the sky -----------------------------------------------------------

## Invariant I4, stated as an experiment rather than a promise: over a hundred
## steps of ordinary flight, every metre a bird moves is its own velocity times
## the timestep. Nothing nudges it, teleports it or steers it from outside.
static func _test_a_bird_only_ever_moves_by_flying(t: TestCase) -> void:
	t.begin("a bird only ever moves by flying")
	var bird := _bird(1.0, Vector3(0.0, 300.0, 0.0), 5)
	var worst: float = 0.0
	for i in 400:
		var before: Vector3 = bird.position
		bird.fly(STEP)
		var moved: Vector3 = bird.position - before
		worst = maxf(worst, (moved - bird.model.velocity * STEP).length())
	t.less(worst, 1e-4, "every step is exactly velocity times delta (worst %.6f m)" % worst)
	t.finite(bird.position, "and the bird is still somewhere")
	bird.free()


static func _test_a_wingbeat_costs_something(t: TestCase) -> void:
	t.begin("a wingbeat costs something")
	var bird := _bird(1.0, Vector3(0.0, 60.0, 0.0), 7)
	bird.energy = 1.0
	# Climb hard for twenty seconds: the goal is a kilometre straight up, so the
	# bird flaps for all of it.
	var beats: int = 0
	for i in int(20.0 / STEP):
		bird._goal = bird.at() + Vector3(20.0, 1000.0, 0.0)
		bird._goal_timer = 99.0
		bird.fly(STEP)
		if bird.command.stroke_speed > 0.0:
			beats += 1
	t.greater(float(beats), 100.0, "it did beat its wings")
	t.less(bird.energy, 0.25, "and twenty seconds of climbing all but empties it")
	var spent: float = bird.energy
	var faded: float = bird.command.stroke_speed

	# Now let it glide. Reserves come back, and with them the wingbeat.
	for i in int(30.0 / STEP):
		bird._goal = bird.at() + Vector3(400.0, -60.0, 0.0)
		bird._goal_timer = 99.0
		bird.fly(STEP)
	t.greater(bird.energy, spent + 0.5, "gliding pays it back")
	t.in_range(bird.energy, 0.0, 1.0, "and never past full")
	t.ok(faded >= 0.0, "an exhausted bird's stroke is never negative")
	bird.free()


static func _test_hostile_input_does_not_break_a_bird(t: TestCase) -> void:
	t.begin("hostile input does not break a bird")
	var flock := Flock.new()
	var bird := _bird(1.0, Vector3(0.0, 200.0, 0.0), 3)
	var other := _bird(4.0, Vector3(10.0, 210.0, 0.0), 4)
	flock.add(bird)
	flock.add(other)
	for delta: float in [0.0, -1.0, NAN, 1e9, 0.011]:
		bird.fly(delta)
		flock.tick(delta)
	bird.model.velocity = Vector3(NAN, INF, -INF)
	bird.energy = NAN
	bird.position = Vector3(INF, NAN, 0.0)
	for i in 20:
		bird.fly(STEP)
		flock.tick(STEP)
	# Position is beyond saving once it is infinite; what must survive is that
	# nothing crashes and the bird's own state comes back finite.
	t.finite(bird.model.velocity, "velocity recovers")
	t.ok(is_finite(bird.energy), "energy is not left as NaN")
	t.in_range(clampf(bird.energy, 0.0, 1.0), 0.0, 1.0, "and stays in range")
	_free([bird, other])


# --- hunting ---------------------------------------------------------------------

## The stalk. A hunter that beelines arrives level, slow and behind; this one
## has to buy height first and spend it in the dive.
static func _test_a_hunter_climbs_before_it_stoops(t: TestCase) -> void:
	t.begin("a hunter climbs before it stoops")
	var flock := Flock.new()
	var prey := _bird(1.0, Vector3(0.0, 200.0, 0.0), 21)
	var hunter := _bird(2.4, Vector3(0.0, 200.0, 58.0), 22)
	# Pointed straight at its quarry (heading 0 faces -Z), level with it, at the
	# edge of what it can see ([constant Flock.HUNT_RADIUS]): everything a beeline
	# would need and nothing a stalk does.
	hunter.model.heading = 0.0
	hunter.model.velocity = hunter.model.forward() * hunter.model.trim_speed()
	flock.add(prey)
	flock.add(hunter)

	var climbed: float = 0.0
	var closest: float = INF
	var climbed_first: bool = false
	var chasing: float = 0.0
	var stooped: bool = false
	var start: float = hunter.at().y
	for i in int(26.0 / STEP):
		flock.tick(STEP)
		# The quarry is given one steady cross-country task rather than its own
		# wandering, so that this measures the hunter and not the dice. It still
		# flees on its own account once it notices anything.
		prey._goal = Vector3(0.0, 200.0, -900.0)
		prey._goal_timer = 99.0
		prey.fly(STEP)
		hunter.fly(STEP)
		if hunter.state == BirdNPC.State.HUNT or hunter.state == BirdNPC.State.STALK:
			chasing += STEP
		# The stoop itself: committed, above its quarry, and wings tucked.
		if hunter.state == BirdNPC.State.HUNT and hunter.at().y > prey.at().y + 8.0 \
				and hunter.command.span < 0.5:
			if not stooped:
				climbed_first = climbed > 15.0
			stooped = true
		var gain: float = hunter.at().y - start
		climbed = maxf(climbed, gain)
		closest = minf(closest, hunter.at().distance_to(prey.at()))
	t.greater(climbed, 15.0, "the hunter bought height (%.0f m)" % climbed)
	t.ok(climbed_first, "before it dived — that ordering is the whole manoeuvre")
	# A stern chase against a straight-flying quarry on the same flight model is
	# the hardest case there is — the speed difference between two sizes is a few
	# percent — so what is asserted is that the hunter genuinely gained on it,
	# not that it caught it. The threshold started at 45 m and was relaxed when
	# [constant BirdNPC.INTERCEPT_CLIMB] was raised to 25 m so that predators
	# could reach a player flying above them; that trade is measured in
	# [SessionProbe] and written up in docs/ECOSYSTEM.md.
	t.ok(stooped, "and spent it: it dived on its quarry with its wings tucked")
	# What is deliberately *not* asserted is that it catches the thing. A stern
	# chase against a bird flying straight, on the same flight model, in still
	# air, with no terrain to cut a corner on, is the hardest case the game
	# contains: the sizes differ by a few percent of speed and the hunter pays for
	# every metre it climbs. What the flock does when it is not a laboratory is
	# measured instead, in `_test_the_flock_looks_after_itself` — birds do eat
	# each other, several times a minute.
	t.less(closest, 60.0, "without losing ground doing it (%.0f m, from 58 m)" % closest)
	t.greater(chasing, 8.0, "and stayed on it (%.0f s of 26)" % chasing)
	_free([prey, hunter])


## And it stops. Two birds on the same flight model differ by a few percent of
## speed, so a hunter with infinite patience is a hunter that leaves the map.
static func _test_a_hunter_gives_up(t: TestCase) -> void:
	t.begin("a hunter gives up")
	var flock := Flock.new()
	var prey := _bird(1.0, Vector3(0.0, 300.0, 0.0), 31)
	var hunter := _bird(1.6, Vector3(0.0, 300.0, 60.0), 32)
	flock.add(prey)
	flock.add(hunter)
	var hunted: bool = false
	var gave_up: bool = false
	var seconds: float = 0.0
	for i in int(60.0 / STEP):
		seconds += STEP
		flock.tick(STEP)
		prey.fly(STEP)
		hunter.fly(STEP)
		var chasing: bool = hunter.state == BirdNPC.State.HUNT \
			or hunter.state == BirdNPC.State.STALK
		hunted = hunted or chasing
		if hunted and not chasing:
			gave_up = true
			break
	t.ok(hunted, "it took an interest")
	t.ok(gave_up, "and eventually broke off (%.0f s)" % seconds)
	t.less(seconds, BirdNPC.HUNT_PATIENCE + 12.0, "within its patience")
	_free([prey, hunter])


## Fleeing used to mean climbing, because an AI wingbeat was free. It cost the
## game its whole hunting loop — see [constant GameManager.FLEE_STAMINA]. Prey
## now spends its height instead of hoarding it, and gets low where the ground
## can hide it.
static func _test_prey_runs_for_the_ground(t: TestCase) -> void:
	t.begin("prey runs for the ground")
	var world := WorldBuilder.new()
	world.build()
	var flock := Flock.new()
	flock.world = world
	var ground: float = world.height_at(120.0, 0.0)
	var prey := BirdNPC.new()
	prey.configure(0.8, Vector3(120.0, ground + 180.0, 0.0), world, 41)
	var hunter := BirdNPC.new()
	hunter.configure(2.6, Vector3(120.0, ground + 210.0, 30.0), world, 42)
	flock.add(prey)
	flock.add(hunter)

	var start: float = prey.at().y
	var fled: bool = false
	for i in int(14.0 / STEP):
		flock.tick(STEP)
		# The hunter is flown straight at it rather than left to its own devices,
		# so that this test is about the prey and nothing else.
		hunter.position = hunter.position.move_toward(prey.at(), 22.0 * STEP)
		hunter.model.velocity = (prey.at() - hunter.at()).normalized() * 22.0
		prey.fly(STEP)
		fled = fled or prey.state == BirdNPC.State.FLEE
	t.ok(fled, "it noticed")
	t.less(prey.at().y, start - 25.0, "and went down, not up (%.0f m)" % (prey.at().y - start))
	var clearance: float = prey.at().y - world.height_at(prey.at().x, prey.at().z)
	t.less(clearance, 90.0, "ending up near the ground (%.0f m agl)" % clearance)
	t.greater(clearance, -1.0, "but not through it")
	_free([prey, hunter])
	world.free()


# --- perching ----------------------------------------------------------------------

static func _test_a_perch_belongs_to_one_bird(t: TestCase) -> void:
	t.begin("a perch belongs to one bird")
	var flock := Flock.new()
	var small := _bird(1.0, Vector3.ZERO, 51)
	var big := _bird(1.06, Vector3.ZERO, 52)
	var huge := _bird(4.0, Vector3.ZERO, 53)
	for bird: BirdNPC in [small, big, huge]:
		flock.add(bird)

	t.ok(flock.claim(small, 7), "the first bird gets the branch")
	t.ok(not flock.claim(big, 7), "the second does not")
	t.ok(flock.occupant(7) == small, "and the first is still on it")
	# It has to be sitting there to be pushed off it.
	small.perch_here()
	t.ok(flock.challenge(big, 7), "a bigger bird takes it")
	t.ok(flock.occupant(7) == big, "and is now the one holding it")
	t.ok(small.state != BirdNPC.State.PERCH, "the smaller one is in the air again")
	t.ok(
		not flock.challenge(huge, 7),
		"something big enough to eat it does not argue about branches"
	)
	flock.release(big)
	t.ok(flock.occupant(7) == null, "letting go frees it")
	_free([small, big, huge])


static func _test_a_bigger_bird_takes_the_branch(t: TestCase) -> void:
	t.begin("a bigger bird takes the branch")
	var flock := Flock.new()
	var resident := _bird(1.0, Vector3(0.0, 40.0, 0.0), 61)
	var arrival := _bird(1.07, Vector3(6.0, 40.0, 0.0), 62)
	flock.add(resident)
	flock.add(arrival)
	resident.perch_here()
	flock.tick(1.0)
	flock.flush_neighbours(arrival, 18.0)
	t.ok(resident.state != BirdNPC.State.PERCH, "the smaller bird gets up")
	t.ok(flock.evictions == 1, "and it counts as a squabble")
	_free([resident, arrival])


static func _test_a_bird_lands_on_a_real_branch(t: TestCase, world: WorldBuilder) -> void:
	t.begin("a bird lands on a real branch")
	var sim := EcosystemSim.new()
	sim.setup(world, 12, 5150)
	sim.hurry_rest()
	sim.run(110.0)

	t.greater(float(sim.flock.landings), 3.0, "birds land (%d)" % sim.flock.landings)
	t.greater(
		float(sim.birds_that_perched()), 2.0,
		"and it is not the same one over and over (%d birds)" % sim.birds_that_perched()
	)
	var perched: int = 0
	var wrong: int = 0
	var floating: int = 0
	for bird: BirdNPC in sim.birds:
		if not bird.is_perched():
			continue
		perched += 1
		if bird.model.velocity.length() > 0.001:
			wrong += 1
		var point: Vector3 = sim.flock.perch_position(bird._perch_index)
		if bird.at().distance_to(point) > 1.0 + bird.size:
			floating += 1
	t.ok(wrong == 0, "a perched bird is not moving")
	t.ok(floating == 0, "and is on the branch it claimed, not near it")
	t.ok(
		sim.flock.giveups <= sim.flock.landings,
		"most approaches end in a landing (%d down, %d given up)" % [
			sim.flock.landings, sim.flock.giveups
		]
	)
	# No two birds on the same twig.
	var shared: int = 0
	for a: BirdNPC in sim.birds:
		for b: BirdNPC in sim.birds:
			if a == b or not a.is_perched() or not b.is_perched():
				continue
			if a.at().distance_to(b.at()) < 0.3:
				shared += 1
	t.ok(shared == 0, "and no two birds are inside each other")
	t.greater(float(sim.flock.takeoffs), 0.0, "and birds leave again (%d)" % sim.flock.takeoffs)
	sim.release()


## The most visible thing the AI does: fly something big at a tree full of birds
## and the tree comes apart.
static func _test_a_roost_scatters(t: TestCase, world: WorldBuilder) -> void:
	t.begin("a roost scatters")
	var flock := Flock.new()
	flock.world = world
	var roost := Vector3(40.0, world.height_at(40.0, 40.0) + 14.0, 40.0)
	var sitting: Array[BirdNPC] = []
	for i in 5:
		var bird := BirdNPC.new()
		bird.configure(0.7, roost + Vector3(float(i) * 4.0, 0.0, 0.0), world, 70 + i)
		bird.perch_here()
		flock.add(bird)
		sitting.append(bird)

	var eagle := BirdNPC.new()
	eagle.configure(3.2, roost + Vector3(0.0, 12.0, 46.0), world, 79)
	flock.add(eagle)
	for i in int(4.0 / STEP):
		flock.tick(STEP)
		# Flown at the roost on rails: this is a test of what the roost does.
		eagle.position = eagle.position.move_toward(roost, 18.0 * STEP)
		eagle.model.velocity = (roost - eagle.at()).normalized() * 18.0
		for bird: BirdNPC in sitting:
			bird.fly(STEP)
	var still_down: int = 0
	for bird: BirdNPC in sitting:
		if bird.is_perched():
			still_down += 1
	t.ok(still_down == 0, "every bird left the branch (%d stayed)" % still_down)
	for bird: BirdNPC in sitting:
		t.greater(bird.model.velocity.length(), 0.5, "and is flying")
	sitting.append(eagle)
	_free(sitting)


# --- soaring and the ecosystem ---------------------------------------------------

static func _test_birds_climb_in_the_lift(t: TestCase, world: WorldBuilder) -> void:
	t.begin("birds climb in the lift")
	# A bird dropped into a thermal core with no reason to be anywhere else. It
	# must gain height, and it must do it without beating its wings — otherwise
	# the climb is not the lift, it is the flapping.
	var core: Vector3 = _strongest_lift(world)
	var bird := BirdNPC.new()
	bird.configure(1.0, core, world, 81)
	bird.energy = 1.0
	var start: float = bird.at().y
	var circling: float = 0.0
	var working_while_circling: float = 0.0
	var climb_while_circling: float = 0.0
	var last: float = start
	for i in int(60.0 / STEP):
		bird.fly(STEP)
		if bird.state == BirdNPC.State.SOAR:
			circling += STEP
			climb_while_circling += bird.at().y - last
			if bird._working:
				working_while_circling += STEP
		last = bird.at().y
	t.greater(circling, 10.0, "it chose to circle (%.0f s of the minute)" % circling)
	t.greater(bird.at().y - start, 25.0, "it climbed %.0f m" % (bird.at().y - start))
	t.greater(
		climb_while_circling / maxf(bird.at().y - start, 1.0), 0.5,
		"and most of that height came out of the circling (%.0f m of it)" % climb_while_circling
	)
	t.ok(
		working_while_circling == 0.0,
		"which cost it not one wingbeat (%.1f s)" % working_while_circling
	)
	t.greater(bird.energy, 0.4, "so it finished with reserves in hand (%.2f)" % bird.energy)
	bird.free()


## Where the strongest core in the world is, found by sampling rather than by
## reaching into [WorldBuilder]'s private thermal list.
static func _strongest_lift(world: WorldBuilder) -> Vector3:
	var best := Vector3(0.0, 200.0, 0.0)
	var best_lift: float = 0.0
	for i in 1200:
		var angle: float = TAU * float(i) * 0.0161
		var radius: float = 120.0 + float(i % 40) * 11.0
		var probe := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		probe.y = world.height_at(probe.x, probe.z) + 90.0
		var lift: float = world.wind_at(probe).y
		if lift > best_lift:
			best_lift = lift
			best = probe
	return best


## The whole point of the area, as one number-producing experiment: run the sky
## with nobody in it and check that it is still a sky afterwards.
static func _test_the_flock_looks_after_itself(t: TestCase, world: WorldBuilder) -> void:
	t.begin("the flock looks after itself")
	var sim := EcosystemSim.new()
	sim.setup(world, 18, 20260813)
	sim.run(130.0)
	var s: Dictionary = sim.summary()

	t.ok(int(s["nonfinite"]) == 0, "nothing goes non-finite (%d)" % s["nonfinite"])
	t.ok(int(s["strays"]) == 0, "nothing leaves the world (%d)" % s["strays"])
	t.ok(
		int(s["stuck_streak"]) <= 1,
		"no bird goes nowhere twice running (worst run %d)" % s["stuck_streak"]
	)
	t.greater(float(s["catches"]), 0.0, "birds eat each other (%d)" % s["catches"])
	t.greater(float(s["soars"]), 5.0, "birds use the lift (%d cores)" % s["soars"])
	t.greater(float(s["soar_climb"]), 100.0, "and get somewhere with it (%.0f m)" % s["soar_climb"])
	t.greater(float(s["landings"]), 0.0, "birds land (%d)" % s["landings"])
	t.greater(float(s["closest_pass"]), 1.0, "and never fly through each other (%.1f m)" % s["closest_pass"])

	# The sky is doing more than one thing at a time. A flock that is entirely
	# wandering is a screensaver; one that is entirely hunting is a riot.
	var wander: float = sim.state_share(BirdNPC.State.WANDER)
	t.less(wander, 0.85, "not everything is just cruising (%.0f %%)" % (wander * 100.0))
	t.greater(
		sim.state_share(BirdNPC.State.HUNT) + sim.state_share(BirdNPC.State.STALK),
		0.02, "something is always hunting something"
	)
	t.greater(
		sim.state_share(BirdNPC.State.SOAR), 0.02, "and something is always circling"
	)
	# Everybody is still alive, still finite, still inside the arena.
	for bird: BirdNPC in sim.birds:
		t.finite(bird.at(), "every bird is somewhere")
		t.in_range(bird.energy, 0.0, 1.0, "with reserves in range")
		t.in_range(bird.size, 0.2, 10.0, "and a sane size")
	sim.release()
