extends TestCase
## A fleeing bird can be caught through the real chain (integration round
## 1; the experience verifier's major finding: no pilot flying the real
## player bird caught a fleeing wren - 0 of 83 chases).
##
## One-on-one in open air over the meadow, the rest of the sky emptied: a
## sparrow flown by the competent chase pilot (integration_chase_pilot.gd:
## a person's 0.22 s tracking delay, an under-led intercept, a glide in the
## last second; it hits 10 of 12 hovering targets) through BotPoseSource,
## WingInput and FlightModel, against a live wren (its own brain, flight,
## flee and jinks), 22-28 m ahead, TRIALS chases of TRIAL_S each, through
## GameLoop's own catch rule with no assist. Before the AI's flee-from-the-
## player rule (NpcBrain.FLEE_PLAYER_REAIM / FLEE_PLAYER_TURN) the wren
## weaved away from every pass: 0 of 12, closest approach median 4.6 m.
##
## Pinned: the median closest approach is under MAX_MEDIAN_M - with the
## rule a competent pilot catches 5 of 12 fleeing wrens at a median of 1.76 m
## (0-3 of 12 at 2.2-2.7 m in other states of the sky before the trials,
## when Play was still clicked with the wall-clock pointer); without the
## rule 0 of 12 at 4.5 m. Catches themselves
## are pinned where they count, in whole-game play (game_catch_test.gd:
## 3-5 in 6 minutes on four seeds). (The diagnostic with options:
## tests/shots/integration_chase_lab_test.gd.)

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")
const TRIALS := 12
const TRIAL_S := 30.0
const MAX_MEDIAN_M := 3.5

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_a_competent_pilot_catches_fleeing_wrens() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	# (Play through the bridge: a pointer click takes a wall-clock number
	# of ticks, and a seed would not be one run; game_catch_test.gd.)
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.ecosystem.max_npcs = 0
	m.ecosystem.reset()
	await kit.advance(0.5)
	m.game_loop.assist_override = 0.0
	var catches := [0]
	var on_caught := func(pred: Bird, _prey: Bird) -> void:
		if pred == m.player:
			catches[0] += 1
	Events.bird_caught.connect(on_caught)
	var start := Vector3(-60.0, 0.0, 380.0)
	start.y = m.world.ground_height(start.x, start.z) + 40.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var closest: Array[float] = []
	var fled := 0
	var caught_n := 0
	for trial in TRIALS:
		m.game_loop.set_protection(m.player, 1e6)
		var yaw := rng.randf_range(-PI, PI)
		m.player.start_flying(start, yaw)
		m.game_loop.teleported(m.player)
		kit.fly_bot(30 + trial, ChasePilot)
		kit.set_mode(&"cruise")
		kit.fly_straight()
		kit.pilot.set(&"heading", yaw)
		await kit.advance(2.5)
		m.game_loop.set_protection(m.player, 0.0)
		var pp := m.player.get_body_position()
		var f := m.player.velocity
		f = Vector3(f.x, 0.0, f.z).normalized()
		var side := Vector3(-f.z, 0.0, f.x)
		var at := pp + f * rng.randf_range(22.0, 28.0) + side * rng.randf_range(-6.0, 6.0) + Vector3.UP * rng.randf_range(-3.0, 3.0)
		var heading := f.rotated(Vector3.UP, rng.randf_range(-1.2, 1.2))
		var b := NpcBird.new()
		b.configure(&"wren", -1.0, 500 + trial, Habitat.for_world(m.world))
		b.name = "FleeingWren_%d" % trial
		m.add_child(b)
		b.global_position = at
		var v0 := heading * b.flight.cruise
		b.flight.set_velocity(v0)
		b.velocity = v0
		b.global_transform = Transform3D(Basis.looking_at(heading, Vector3.UP), at)
		b.energy = 1.0
		(kit.pilot as ChasePilot).chase_prey(b)
		var c0: int = catches[0]
		var best := INF
		var saw_flee := false
		var t := 0.0
		while t < TRIAL_S:
			await kit.advance(1.0 / 72.0)
			t += 1.0 / 72.0
			if int(catches[0]) > c0:
				caught_n += 1
				break
			if not is_instance_valid(b) or not b.alive or b.hidden:
				break
			best = minf(best, b.get_body_position().distance_to(m.player.get_body_position()))
			saw_flee = saw_flee or b.state == NpcBird.State.FLEE
		closest.append(0.0 if int(catches[0]) > c0 else best)
		fled += 1 if saw_flee else 0
		(kit.pilot as ChasePilot).stop_chase()
		kit.cruise()
		if is_instance_valid(b):
			b.alive = false
			b.queue_free()
		await kit.advance(0.2)
	Events.bird_caught.disconnect(on_caught)
	m.game_loop.assist_override = -1.0
	var sorted := closest.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	print("[integration] fleeing wrens: %d of %d caught, %d fled the player; closest approach (0 = caught) %s, median %.2f m" % [
		caught_n, TRIALS, fled, closest.map(func(x: float) -> float: return snappedf(x, 0.01)), median])
	metric("fleeing_wrens", {"caught": caught_n, "trials": TRIALS, "fled": fled, "closest": closest, "median": median})
	gt(float(fled), TRIALS * 0.75, "(setup) the wrens flee the player (%d of %d)" % [fled, TRIALS])
	lt(median, MAX_MEDIAN_M, "median closest approach %.2f m, %d of %d chases of %.0f s caught (without the rule: 4.5 m, none; the verifier: 0 of 83)" % [
		median, caught_n, TRIALS, TRIAL_S])
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
