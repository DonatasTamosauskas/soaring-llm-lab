extends "res://tests/unit/ai/ai_sim.gd"
## A3 Fleeing: prey notice an approaching predator only inside their
## awareness radius and act on it after their reaction time; they head for
## cover the predator cannot follow into; they ignore birds that cannot eat
## them; alarm spreads through a flock faster than each bird could see.

var _open: World


func before_all() -> void:
	_open = await make_open_world()


func after_all() -> void:
	await clear_sim()
	if is_instance_valid(_open):
		_open.queue_free()


func after_each() -> void:
	for b in loose.duplicate():
		despawn(b)
	checker = null
	await wait_frames(1)


## Head-on approach by a hunter targeting the prey: flee starts no earlier
## than reaction_s after the hunter enters the awareness radius and no later
## than reaction_s + one think interval.
func test_reaction_within_awareness_and_reaction_time() -> void:
	var pairs := [[&"sparrow", &"hawk"], [&"starling", &"crow"], [&"pigeon", &"hawk"], [&"gull", &"eagle"], [&"moth", &"swallow"]]
	var table := {}
	for pr in pairs:
		var prey := spawn(pr[0], Vector3(0, 40, 0), Vector3(0, 0, -SizeRules.performance(SizeRules.species_data(pr[0])["mass"])["cruise"]), _open)
		prey.can_hunt = false
		prey.home = Vector3(0, 0, -2000)
		var prof := SpeciesProfile.of(pr[0])
		var aw: float = prof["awareness_m"]
		var react: float = prof["reaction_s"]
		var hunter := spawn(pr[1], Vector3(0.5, 40.5, -aw * 1.8 - 10.0), Vector3(0, 0, 12), _open)
		hunter.can_flee = false
		hunter.hunger = 1.0
		hunter.brain._pending_prey = prey
		hunter.brain._enter(NpcBird.State.HUNT)
		var m := {"enter": -1.0, "flee": -1.0, "early": false}
		run(12.0, func(i: int) -> bool:
			var d := prey.global_position.distance_to(hunter.global_position)
			var t := (i + 1) * DT
			if m["enter"] < 0.0 and d <= aw:
				m["enter"] = t
			if prey.state == NpcBird.State.FLEE and m["flee"] < 0.0:
				m["flee"] = t
				if m["enter"] < 0.0:
					m["early"] = true
			return m["flee"] >= 0.0)
		check(not m["early"], "%s did not flee before %s was within awareness" % [pr[0], pr[1]])
		check(m["flee"] >= 0.0, "%s fled from %s" % [pr[0], pr[1]])
		var lat: float = m["flee"] - m["enter"]
		# Upper bound: reaction time + one think interval (the threat is noticed
		# at the next think after it enters awareness) + tick quantisation
		# (senses run before the move, the test measures after it).
		between(lat, react - DT, react + NpcBrain.THINK_S[0] + 3.0 * DT, "%s reaction latency (s)" % pr[0])
		eq(prey.threat, hunter, "%s knows who it flees" % pr[0])
		table["%s<%s" % [pr[0], pr[1]]] = {"latency_s": snappedf(lat, 0.001), "reaction_s": react, "awareness_m": aw}
		despawn(prey)
		despawn(hunter)
	metric("reaction", table)


## Birds that cannot eat the prey never trigger a flight, however close -
## even one charging straight at it in full hunting mode (state HUNT, the
## prey its target): only the size rule (Bird.can_eat) can keep the prey
## calm here, so the test fails if that rule is dropped from threat sensing.
func test_ignores_birds_that_cannot_eat_it() -> void:
	var cases := [[&"sparrow", &"sparrow"], [&"sparrow", &"moth"], [&"starling", &"sparrow"], [&"hawk", &"gull"], [&"pigeon", &"starling"], [&"crow", &"crow"]]
	for cs in cases:
		var prey := spawn(cs[0], Vector3(0, 40, 0), Vector3(0, 0, -8), _open)
		prey.can_hunt = false
		prey.home = Vector3(0, 0, -2000)
		var other := spawn(cs[1], Vector3(0.3, 40.2, -30.0), Vector3(0, 0, 9), _open)
		other.can_flee = false
		other.can_hunt = false
		prey.brain._goal = Vector3(0, 40, -600.0)
		prey.brain._goal_t = 0.0
		prey.brain._goal_life = 999.0
		prey.brain._goal_free = true
		var m := {"fled": false, "min_d": INF, "charging": 0}
		run(6.0, func(_i: int) -> bool:
			# Charge: hunting, the prey its target (its brain drops a target it
			# cannot eat at its next think; the test keeps putting it back).
			other.state = NpcBird.State.HUNT
			other.target = prey
			m["charging"] += 1
			m["min_d"] = minf(m["min_d"], prey.global_position.distance_to(other.global_position))
			if prey.state == NpcBird.State.FLEE or prey.threat != null:
				m["fled"] = true
			return false)
		check(not m["fled"], "%s ignores a %s that cannot eat it, even charging at it" % [cs[0], cs[1]])
		lt(m["min_d"], float(SpeciesProfile.of(cs[0])["awareness_m"]) * 0.4, "the %s came well inside the %s's awareness" % [cs[1], cs[0]])
		other.target = null
		despawn(prey)
		despawn(other)
	# The same charge by a bird that CAN eat it is fled (the control).
	var ctrl := spawn(&"sparrow", Vector3(0, 40, 0), Vector3(0, 0, -8), _open)
	ctrl.can_hunt = false
	var starling := spawn(&"starling", Vector3(0.3, 40.2, -30.0), Vector3(0, 0, 9), _open)
	starling.can_flee = false
	starling.can_hunt = false
	var c := {"fled": false}
	run(6.0, func(_i: int) -> bool:
		starling.state = NpcBird.State.HUNT
		starling.target = ctrl
		if ctrl.state == NpcBird.State.FLEE:
			c["fled"] = true
		return c["fled"])
	check(c["fled"], "control: a sparrow flees a starling charging at it")
	starling.target = null
	despawn(ctrl)
	despawn(starling)


## A predator merely cruising past (not hunting) is only fled when it comes
## uncomfortably close; one hunting the bird is fled on sight.
func test_intent_matters() -> void:
	var prey := spawn(&"sparrow", Vector3(0, 40, 0), Vector3(0, 0, -8), _open)
	prey.can_hunt = false
	prey.home = Vector3(0, 0, -2000)
	var aw: float = SpeciesProfile.of(&"sparrow")["awareness_m"]
	# Cruising hawk passing at 0.7 x awareness, not hunting.
	var hawk := spawn(&"hawk", Vector3(aw * 0.7, 40.0, -60.0), Vector3(0, 0, 17), _open)
	hawk.can_hunt = false
	hawk.can_flee = false
	hawk.brain._goal = Vector3(aw * 0.7, 40, 400)
	hawk.brain._goal_t = 0.0
	hawk.brain._goal_life = 999.0
	hawk.brain._goal_free = true
	var m := {"fled": false}
	run(6.0, func(_i: int) -> bool:
		if prey.state == NpcBird.State.FLEE:
			m["fled"] = true
		return false)
	check(not m["fled"], "a hawk cruising past at 0.7 x awareness is watched, not fled")


## In the AI test world, prey near a hedge dive into it; the hawk cannot
## follow (span 1.6 > 0.3) and gives up.
func test_prey_take_cover_the_hunter_cannot_enter() -> void:
	var w := AiTestWorld.new()
	w.with_visuals = false
	w.with_environment = false
	add_child(w)
	await wait_physics(3)
	var h := Habitat.for_world(w)
	var hedge_refuges: Array = []
	for r in h.refuges:
		if float(r["max_span"]) <= 0.3:
			hedge_refuges.append(r)
	gt(hedge_refuges.size(), 2, "test world has hedge refuges")
	var results := {"hid": 0, "caught": 0, "hunter_gave_up_refuge": 0, "headed": 0, "hid_while_hunted": 0}
	var trials := 8
	for t in trials:
		var r: Dictionary = hedge_refuges[t % hedge_refuges.size()]
		var rp: Vector3 = r["position"]
		var a := TAU * t / trials
		var start := rp + Vector3(cos(a) * 14.0, 5.0, sin(a) * 14.0)
		var prey := spawn(&"sparrow", start, Vector3(-sin(a), 0, cos(a)) * 9.0, w)
		prey.can_hunt = false
		prey.energy = 0.9
		var hawk := spawn(&"hawk", start + Vector3(cos(a) * 45.0, 18.0, sin(a) * 45.0), -Vector3(cos(a), 0, sin(a)) * 17.0, w)
		hawk.can_flee = false
		hawk.hunger = 1.0
		hawk.brain._pending_prey = prey
		hawk.brain._enter(NpcBird.State.HUNT)
		make_checker()
		var m := {"hid": false, "gave_up": "", "headed": false, "hunted_at_hide": false}
		run(20.0, func(_i: int) -> bool:
			if prey.state == NpcBird.State.FLEE and not prey.refuge.is_empty() and prey.velocity.length() > 1.0:
				var to_r: Vector3 = prey.refuge["position"] - prey.global_position
				if prey.velocity.normalized().dot(to_r.normalized()) > 0.8:
					m["headed"] = true
			if prey.hidden and not m["hid"]:
				m["hid"] = true
				m["hunted_at_hide"] = hawk.target == prey
			if hawk.state != NpcBird.State.HUNT and hawk.state != NpcBird.State.STOOP and m["gave_up"] == "":
				m["gave_up"] = hawk.brain.give_up_reason
			return not prey.alive or (m["hid"] and m["gave_up"] != ""))
		if not prey.alive:
			results["caught"] += 1
		if m["hid"]:
			results["hid"] += 1
		if m["headed"]:
			results["headed"] += 1
		if m["hunted_at_hide"]:
			results["hid_while_hunted"] += 1
			if m["gave_up"] == "refuge":
				results["hunter_gave_up_refuge"] += 1
		despawn(prey)
		despawn(hawk)
		await wait_frames(1)
	metric("cover", results)
	gt(results["headed"], trials * 0.75, "fleeing prey head straight for the refuge")
	gt(results["hid"], trials * 0.6, "most prey reach cover")
	lt(results["caught"], trials * 0.4, "cover saves most of them")
	eq(results["hunter_gave_up_refuge"], results["hid_while_hunted"], "every prey that hid with the hawk still after it made the hawk give up (refuge)")
	w.queue_free()
	await wait_frames(1)


## Refuge choice: fits the bird, is too small for the pursuer, and is not
## through the predator.
func test_refuge_choice_fits_and_avoids_the_predator() -> void:
	var h := Habitat.new(null)
	h.refuges = [
		{"position": Vector3(10, 1, 0), "radius": 1.0, "max_span": 0.3},
		{"position": Vector3(-25, 1, 0), "radius": 1.0, "max_span": 0.3},
		{"position": Vector3(0, 1, 40), "radius": 2.0, "max_span": 0.8},
	]
	var me := Vector3(0, 5, 0)
	# Predator east, beyond the east hedge: the west hedge is the way out.
	var pick := h.pick_refuge(me, 0.24, Vector3(20, 8, 0), 60.0)
	vnear(pick["position"], Vector3(-25, 1, 0), 0.01, "sparrow avoids the hedge behind which the hawk is")
	# Predator west: the near east hedge is fine.
	pick = h.pick_refuge(me, 0.24, Vector3(-30, 8, 0), 60.0)
	vnear(pick["position"], Vector3(10, 1, 0), 0.01, "sparrow takes the near hedge away from the hawk")
	# A pigeon (span 0.66) does not fit a hedge; the barn it does.
	pick = h.pick_refuge(me, 0.66, Vector3(-30, 8, 0), 60.0)
	vnear(pick["position"], Vector3(0, 1, 40), 0.01, "pigeon picks the barn, not a hedge it cannot enter")
	pick = h.pick_refuge(me, 1.6, Vector3(-30, 8, 0), 60.0)
	check(pick.is_empty(), "nothing fits a hawk")
	# Too small for the pursuer (the brief): a sparrow fleeing a starling
	# (span 0.40) may take the hedges (0.3) but not the barn (0.8), which the
	# starling could follow it into; fleeing a hawk (1.6) either will do.
	h.refuges = [
		{"position": Vector3(10, 1, 0), "radius": 1.0, "max_span": 0.8},
		{"position": Vector3(-25, 1, 0), "radius": 1.0, "max_span": 0.3},
	]
	pick = h.pick_refuge(me, 0.24, Vector3(0, 8, 40), 60.0, [], 0.40)
	vnear(pick["position"], Vector3(-25, 1, 0), 0.01, "sparrow fleeing a starling takes the hedge the starling cannot follow into, not the nearer barn")
	pick = h.pick_refuge(me, 0.24, Vector3(0, 8, 40), 60.0, [], 1.6)
	vnear(pick["position"], Vector3(10, 1, 0), 0.01, "fleeing a hawk the nearer barn will do")
	pick = h.pick_refuge(me, 0.66, Vector3(0, 8, 40), 60.0, [], 0.95)
	vnear(pick["position"], Vector3(10, 1, 0), 0.01, "a pigeon fleeing a crow (0.95) fits the barn (0.8) and the crow does not")
	pick = h.pick_refuge(me, 0.95, Vector3(0, 8, 40), 60.0, [], 1.3)
	check(pick.is_empty(), "a crow fleeing a gull has no cover here too small for the gull: it flees in the open")


## A hawk hunting the tail bird of a long, straight-flying flock: birds
## far ahead - beyond their own awareness radius from the hawk, so they
## cannot have seen it - still bolt, because the alarm runs up the flock.
func test_alarm_spreads_through_the_flock() -> void:
	var fl := FlockGroup.new(7, &"starling", "loose", Vector3(0, 0, -400), Habitat.for_world(_open), 3)
	var birds: Array[NpcBird] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 16:
		var b := spawn(&"starling", Vector3(rng.randf_range(-2, 2), 40 + rng.randf_range(-1, 1), -i * 3.0), Vector3(0, 0, -10.8), _open)
		b.flock = fl
		b.can_hunt = false
		fl.members.append(b)
		b.set_state(NpcBird.State.FLOCK)
		birds.append(b)
	var tail := birds[0]
	var hawk := spawn(&"hawk", tail.global_position + Vector3(0, 10, 40), Vector3(0, -0.2, -1).normalized() * 18.0, _open)
	hawk.can_flee = false
	hawk.hunger = 1.0
	hawk.brain._pending_prey = tail
	hawk.brain._enter(NpcBird.State.HUNT)
	var aw: float = SpeciesProfile.of(&"starling")["awareness_m"]
	var m := {"fled": {}, "unseen": 0, "t": 0.0, "wave": []}
	run(5.0, func(i: int) -> bool:
		m["t"] = i * DT
		# The flock's goal runs straight ahead.
		fl.anchor = Vector3(0, 40, -60.0 - m["t"] * 10.8)
		for b in birds:
			if b.state == NpcBird.State.FLEE and not m["fled"].has(b):
				m["fled"][b] = true
				var d := b.global_position.distance_to(hawk.global_position)
				m["wave"].append([snappedf(m["t"], 0.01), snappedf(d, 0.1)])
				if d > aw:
					m["unseen"] += 1
		return false)
	gt(m["fled"].size(), 12, "the alarm swept most of the flock")
	gt(m["unseen"], 3, "birds beyond sight of the hawk fled on the alarm wave")
	metric("alarm", {"fled": m["fled"].size(), "fled_beyond_sight": m["unseen"], "wave_t_dist": m["wave"]})


## Integration round 1 (engineering finding): a flock mate that bolted from
## a hunter still holds it in `threat` when the hunter is freed; its calm
## mates read that alarm in their own think before the bolted bird's tick
## drops it. Reading a freed instance into a typed variable raised "Trying
## to assign invalid previously freed instance" (npc_brain.gd, _sense) on
## every such think. The mates must skip the dead alarm without an error.
func test_alarm_from_a_freed_hunter_raises_nothing() -> void:
	var WarningLog := load("res://tests/unit/ai/warning_log.gd")
	# No side effects on the tests after this one: spawn() advances a shared
	# seed, and the barn-door test below is seed-sensitive (3-6 of its 6
	# pigeons reach the barn over seeds, tests/shots/integration_diag_barn).
	var seed_before := _seed
	var fl := FlockGroup.new(9, &"starling", "loose", Vector3(0, 0, -400), Habitat.for_world(_open), 5)
	var mates: Array[NpcBird] = []
	for i in 6:
		var b := spawn(&"starling", Vector3(i * 2.5, 40, 0), Vector3(0, 0, -10.8), _open)
		b.flock = fl
		b.can_hunt = false
		fl.members.append(b)
		b.set_state(NpcBird.State.FLOCK)
		mates.append(b)
	var tail := mates[0]
	var hawk := spawn(&"hawk", tail.global_position + Vector3(0, 8, 30), Vector3(0, 0, -15), _open)
	hawk.can_flee = false
	# The tail has just bolted from the hawk (a fresh FLEE: the alarm wave).
	tail.threat = hawk
	tail.set_state(NpcBird.State.FLEE)
	# The hawk leaves the sky (despawned or eaten) and is really freed.
	despawn(hawk)
	await wait_frames(2)
	check(not is_instance_valid(tail.threat), "(setup) the tail still holds the freed hawk")
	var log: Logger = WarningLog.install()
	# The calm mates think now, before the tail's own tick.
	for b in mates:
		if b != tail:
			b.brain._force_think_at = 0.0
			b.tick(DT)
	var errors: int = log.errors
	var samples: Array = log.samples.duplicate()
	log.uninstall()
	eq(errors, 0, "no error from a mate's freed threat: %s" % [samples])
	for b in mates:
		if b != tail:
			check(b.threat == null, "a calm mate did not take the freed hawk as its threat")
	tail.tick(DT)
	check(tail.threat == null, "the bolted bird dropped the freed hawk on its own tick")
	# Leave no birds behind: the next tests share the bird registry (six
	# starlings left flying here drew the barn test's hawk off its pigeon).
	for b in mates:
		despawn(b)
	await wait_frames(1)
	_seed = seed_before


## Cover behind an opening (the barn door): the prey lines up outside the
## door and flies straight in - crossing the wall plane inside the door
## rectangle - and never touches a wall on the way.
func test_prey_enter_cover_through_its_opening() -> void:
	const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
	var w := AiTestWorld.new()
	w.with_visuals = false
	w.with_environment = false
	add_child(w)
	await wait_physics(3)
	var h := Habitat.for_world(w)
	# The barn (16 x 8 m front wall, the first big refuge the arena builds;
	# the field sheds come later).
	var barn := {}
	for r in h.refuges:
		if float(r["max_span"]) >= 0.7:
			barn = r
			break
	check(barn.has("entry"), "the barn refuge is linked to its door opening")
	var entry: Dictionary = barn["entry"]
	var door: Vector3 = entry["through"]
	var out: Vector3 = entry["out"]
	vnear(out, Vector3.FORWARD, 0.01, "approach from outside the door (-Z)")
	var results := {"hid": 0, "through_door": 0, "contacts": 0}
	var trials := 6
	for t in trials:
		var a := -0.9 + 1.8 * t / (trials - 1)
		var start := door + Vector3(sin(a) * 16.0, 4.0, -cos(a) * 16.0)
		var prey := spawn(&"pigeon", start, Vector3(-sin(a), 0, cos(a)) * 12.0, w)
		prey.can_hunt = false
		var hawk := spawn(&"hawk", start + Vector3(sin(a) * 45.0, 15.0, -cos(a) * 45.0), Vector3(-sin(a), 0, cos(a)) * 17.0, w)
		hawk.can_flee = false
		hawk.hunger = 1.0
		hawk.brain._pending_prey = prey
		hawk.brain._enter(NpcBird.State.HUNT)
		var safety := Safety.new(w)
		var m := {"crossed_ok": false, "crossed_bad": false, "prev_z": prey.global_position.z}
		run(15.0, func(_i: int) -> bool:
			safety.step(DT, [prey, hawk])
			var p := prey.global_position
			# Crossing the door wall plane (z = door.z) going in (+Z).
			# Crossing the barn's front wall (16 m wide, 8 m tall) going in:
			# fine inside the door rectangle, a penetration anywhere else.
			if m["prev_z"] <= door.z and p.z > door.z and absf(p.x - door.x) < 8.2 and p.y < door.y + 5.8:
				var ok := absf(p.x - door.x) < float(entry["width"]) * 0.5 and absf(p.y - door.y) < float(entry["height"]) * 0.5
				m["crossed_ok" if ok else "crossed_bad"] = true
			m["prev_z"] = p.z
			return prey.hidden or not prey.alive)
		if prey.hidden:
			results["hid"] += 1
		if m["crossed_ok"] and not m["crossed_bad"]:
			results["through_door"] += 1
		results["contacts"] += safety.counts["inside"]
		despawn(prey)
		despawn(hawk)
		await wait_frames(1)
	metric("barn", results)
	gt(results["hid"], trials * 0.6, "most pigeons made it into the barn")
	eq(results["through_door"], results["hid"], "every one that hid went in through the door")
	eq(results["contacts"], 0, "no wall contacts on the way in")
	w.queue_free()
	await wait_frames(1)


## Hiding is an event, not a place to live: a bird in cover comes out soon
## after the danger has gone (a breather of 2-4 s, then a quiet second), and
## even with a hunter pressing just outside it bolts after at most 20 s
## (NpcBrain.HIDE_MAX_S) - it is not left invisible in a hedge for good.
func test_hiding_is_bounded() -> void:
	var w := AiTestWorld.new()
	w.with_visuals = false
	w.with_environment = false
	add_child(w)
	await wait_physics(3)
	var h := Habitat.for_world(w)
	var hedge := {}
	for r in h.refuges:
		if float(r["max_span"]) <= 0.3 and r.has("entry"):
			hedge = r
			break
	check(not hedge.is_empty(), "(setup) a hedge refuge with an opening")
	var times := {}
	for pressed in [false, true]:
		var b := spawn(&"sparrow", hedge["position"], Vector3(0, 0, -1), w)
		b.can_hunt = false
		b.brain._refuge_entry = Vector3.FORWARD
		b.hide_in(hedge)
		b.brain._start_hiding()
		var hawk: NpcBird = null
		if pressed:
			hawk = spawn(&"hawk", hedge["position"] + Vector3(8, 4, 0), Vector3(0, 0, -15), w)
			hawk.can_flee = false
			hawk.can_hunt = false
		var m := {"out": -1.0}
		run(30.0, func(i: int) -> bool:
			if hawk != null:
				# Circling just outside, after it: pressing danger throughout.
				var a := i * DT * 1.5
				hawk.global_position = hedge["position"] + Vector3(cos(a) * 8.0, 4.0, sin(a) * 8.0)
				hawk.velocity = Vector3(-sin(a), 0, cos(a)) * 12.0
				hawk.state = NpcBird.State.HUNT
				hawk.target = b
			if not b.hidden and m["out"] < 0.0:
				m["out"] = i * DT
				return true
			return false)
		times[pressed] = m["out"]
		if hawk != null:
			hawk.target = null
			despawn(hawk)
		despawn(b)
		await wait_frames(1)
	# (Design values - a 2-4 s breather, a quiet second, 20 s at most -
	# stated here, not read back from NpcBrain.)
	between(times[false], 2.0, 5.5, "with no danger about, out after a short breather (s)")
	gt(times[true], 10.0, "a hunter pressing outside keeps it in cover (s)")
	between(times[true], 0.0, 20.5, "but never longer than 20 s (s)")
	metric("hide_s", {"quiet": snappedf(times[false], 0.01), "pressed": snappedf(times[true], 0.01)})
	w.queue_free()
	await wait_frames(1)


## A quarry that hides is out of the chase, whatever the cover: too small
## for the hunter ("refuge"), or one the hunter would fit but cannot fly
## into by pursuit and where GameLoop's rule keeps it out of play anyway
## ("hid"). (Hunters used to press on at cover they fitted and fly at the
## walls round it: half the birds that hit walls in front of a chasing
## player in the round-3 verifier's probe.)
func test_a_hunter_gives_up_a_quarry_that_hides() -> void:
	var table := {}
	for ms: float in [0.5, 3.0]:
		var prey := spawn(&"pigeon", Vector3(0, 40, 0), Vector3(0, 0, -9), _open)
		prey.can_hunt = false
		prey.can_flee = false
		var hawk := spawn(&"hawk", Vector3(0, 45, 40), Vector3(0, 0, -15), _open)
		hawk.can_flee = false
		hawk.hunger = 1.0
		hawk.brain._pending_prey = prey
		hawk.brain._enter(NpcBird.State.HUNT)
		run(0.5)
		check(hawk.target == prey, "(setup) the hawk is after the pigeon (cover %.1f m)" % ms)
		prey.hide_in({"position": prey.global_position, "radius": 1.0, "max_span": ms})
		var m := {"t": -1.0}
		run(2.0, func(i: int) -> bool:
			if hawk.target != prey and m["t"] < 0.0:
				m["t"] = i * DT
			return m["t"] >= 0.0)
		table[str(ms)] = {"gave_up_s": snappedf(m["t"], 0.01), "reason": hawk.brain.give_up_reason}
		between(m["t"], 0.0, 0.3, "cover %.1f m (hawk span 1.6): the hawk gives the hidden quarry up at its next thought (s)" % ms)
		eq(hawk.brain.give_up_reason, "refuge" if ms < 1.6 else "hid", "cover %.1f m: the reason" % ms)
		despawn(prey)
		despawn(hawk)
	metric("hidden_quarry", table)
