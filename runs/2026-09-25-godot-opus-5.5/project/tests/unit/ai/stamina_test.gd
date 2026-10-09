extends "res://tests/unit/ai/ai_sim.gd"
## Stamina: flapping costs energy, gliding and resting give it back, and a
## tired bird behaves like one - it cannot sprint, it goes to rest, and a
## hunter running out gives up. Endurance grows with size (reserves scale
## with mass, power with mass^0.75: a hawk lasts longer than a sparrow at
## the same effort), which is what decides long chases between near-equals.


func before_all() -> void:
	await make_world(false, 1)


func after_all() -> void:
	await clear_sim()


func after_each() -> void:
	for b in loose.duplicate():
		despawn(b)
	checker = null
	await wait_frames(1)


## Energy change over `seconds` at a fixed flapping effort (or resting).
func _energy_change(sp: StringName, effort: float, seconds: float, resting := false) -> float:
	var b := spawn(sp, Vector3(0, 60, 0))
	b.energy = 0.5
	b.perched = resting
	var e0 := b.energy
	for i in int(seconds / DT):
		b.flight.effort = effort
		b._metabolism(DT)
	var de := b.energy - e0
	b.perched = false
	despawn(b)
	return de


func test_flapping_drains_gliding_and_rest_restore() -> void:
	var rows := {}
	for sp in [&"sparrow", &"pigeon", &"hawk", &"eagle"]:
		var full := _energy_change(sp, 1.0, 5.0)
		var cruise := _energy_change(sp, 0.5, 5.0)
		var glide := _energy_change(sp, 0.0, 5.0)
		var rest := _energy_change(sp, 0.0, 5.0, true)
		rows[String(sp)] = {"full": snappedf(full, 0.001), "half": snappedf(cruise, 0.001), "glide": snappedf(glide, 0.001), "rest": snappedf(rest, 0.001)}
		lt(full, -0.02, "%s: flat-out flapping drains energy" % sp)
		lt(full, cruise, "%s: harder flapping drains faster" % sp)
		gt(glide, 0.0, "%s: gliding recovers a little" % sp)
		gt(rest, glide * 3.0, "%s: resting recovers much faster than gliding" % sp)
	# A sparrow flat out for 25 s is spent (~1.0 in ~26 s); an eagle, with
	# ~3x the reserve per watt, still has most of it.
	var sp_drain := -_energy_change(&"sparrow", 1.0, 10.0) / 10.0
	var ea_drain := -_energy_change(&"eagle", 1.0, 10.0) / 10.0
	between(sp_drain, 0.03, 0.05, "sparrow drains ~4%/s flat out")
	between(sp_drain / ea_drain, 2.5, 4.0, "an eagle lasts ~3x longer flat out (endurance ~ mass^0.25)")
	metric("energy_5s", rows)


func test_a_tired_bird_cannot_sprint() -> void:
	# Level flight at full demand for 8 s: the fresh bird reaches its
	# sprint, the spent one (effort capped by fatigue) is held well below.
	var speeds := {}
	for e in [1.0, 0.05]:
		var b := spawn(&"starling", Vector3(0, 80, 0), Vector3(0, 0, -11))
		b.energy = e
		b.can_hunt = false
		b.can_flee = false
		var top := 0.0
		for i in int(8.0 / DT):
			b.energy = e
			b.flight.step(DT, Vector3(0, 0, -1) * 40.0, 40.0, b.effort_cap(), 0.0)
			top = maxf(top, b.flight.speed)
		speeds[e] = top
		despawn(b)
	var sprint := NpcFlight.new(SizeRules.species_data(&"starling")["mass"], 7.0).sprint
	near(speeds[1.0], sprint, sprint * 0.05, "fresh starling reaches its sprint")
	lt(speeds[0.05], sprint * 0.9, "spent starling cannot sprint")
	metric("sprint", {"fresh": snappedf(speeds[1.0], 0.01), "spent": snappedf(speeds[0.05], 0.01), "book": snappedf(sprint, 0.01)})


func test_tired_bird_rests_on_a_perch_then_flies_on() -> void:
	var wire: Perch = null
	for p in world.get_perches():
		if p.kind == Perch.Kind.WIRE and p.is_free():
			wire = p
			break
	var b := spawn(&"sparrow", wire.position + Vector3(35, 10, 25), Vector3(-7, 0, -6))
	b.energy = 0.12
	b.can_hunt = false
	b.home = Vector3(wire.position.x, 0, wire.position.z)
	var m := {"landed": -1.0, "e_land": 0.0, "left": -1.0, "e_left": 0.0}
	run(90.0, func(i: int) -> bool:
		if b.perched and m["landed"] < 0.0:
			m["landed"] = i * DT
			m["e_land"] = b.energy
		if m["landed"] >= 0.0 and not b.perched and m["left"] < 0.0:
			m["left"] = i * DT
			m["e_left"] = b.energy
		return m["left"] >= 0.0)
	check(m["landed"] >= 0.0, "the tired sparrow went to rest on a perch")
	check(m["left"] >= 0.0, "and flew on once rested")
	gt(float(m["e_left"]), 0.85, "it left rested (energy on leaving)")
	gt(float(m["e_left"]) - float(m["e_land"]), 0.5, "resting restored its energy")
	metric("rest", {"landed_s": snappedf(m["landed"], 0.1), "left_s": snappedf(m["left"], 0.1), "e_land": snappedf(m["e_land"], 0.01), "e_left": snappedf(m["e_left"], 0.01)})


func test_a_hunter_running_out_of_energy_gives_up() -> void:
	# A hawk after a (calm) pigeon it cannot reach quickly: a spent hawk
	# calls it off as "tired"; a fresh one does not.
	var reasons := {}
	for e0 in [0.16, 1.0]:
		var prey := spawn(&"pigeon", Vector3(0, 40, 0), Vector3(0, 0, -13))
		prey.can_flee = false
		prey.can_hunt = false
		prey.brain._goal = Vector3(0, 40, -800)
		prey.brain._goal_t = 0.0
		prey.brain._goal_life = 999.0
		prey.brain._goal_free = true
		var hawk := spawn(&"hawk", Vector3(0, 40, 80), Vector3(0, 0, -17))
		hawk.can_flee = false
		hawk.hunger = 1.0
		hawk.energy = e0
		hawk.brain._pending_prey = prey
		hawk.brain._enter(NpcBird.State.HUNT)
		var r := {"why": "", "t": -1.0}
		run(20.0, func(i: int) -> bool:
			if hawk.state != NpcBird.State.HUNT and hawk.state != NpcBird.State.STOOP:
				r["why"] = hawk.brain.give_up_reason
				r["t"] = i * DT
				return true
			return not prey.alive)
		reasons[e0] = r
		despawn(prey)
		despawn(hawk)
	eq(reasons[0.16]["why"], "tired", "a spent hawk gives up the chase as tired")
	check(reasons[1.0]["why"] != "tired", "a fresh hawk does not give up tired (%s)" % reasons[1.0]["why"])
	metric("give_up", reasons)
