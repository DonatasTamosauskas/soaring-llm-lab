extends "res://tests/unit/game/game_fixture.gd"
## G5 — the loop shifts with size: at each tier the set of species worth
## hunting moves up, tiny prey stop being targets/highlighted once below the
## worth threshold, and the threat set moves up too. Checked on the rules
## (species sets) and on the live loop (highlights and targets on real birds).

const DT := 1.0 / 72.0


func _sets(m: float) -> Dictionary:
	var worth: Array[int] = []
	var edible: Array[int] = []
	var danger: Array[int] = []
	for i in SizeRules.SPECIES.size():
		var q: float = SizeRules.SPECIES[i]["mass"]
		if SizeRules.can_eat(m, q):
			edible.append(i)
			if SizeRules.is_worthwhile(m, q):
				worth.append(i)
		elif SizeRules.can_eat(q, m):
			danger.append(i)
	return {"worth": worth, "edible": edible, "danger": danger}


func _ids(idx: Array[int]) -> Array[StringName]:
	var out: Array[StringName] = []
	for i in idx:
		out.append(SizeRules.SPECIES[i]["id"])
	return out


func test_species_sets_move_up_the_ladder() -> void:
	var start := SizeRules.species_index(&"sparrow")
	var prev_lo_worth := -1
	var prev_hi_worth := -1
	var prev_lo_danger := -1
	var lo_worth_rises := 0
	var table := {}
	for t in range(start, SizeRules.SPECIES.size()):
		var m: float = SizeRules.SPECIES[t]["mass"]
		for f in [1.0, 1.3]:  # at the tier threshold and a third of the way up
			var mm: float = m * f
			if mm > GameLoop.MAX_PLAYER_MASS:
				continue
			var s := _sets(mm)
			var worth: Array[int] = s["worth"]
			var danger: Array[int] = s["danger"]
			check(not worth.is_empty(), "%.3f kg: always something worth hunting" % mm)
			var lo: int = worth.min()
			var hi: int = worth.max()
			check(lo >= prev_lo_worth, "%.3f kg: smallest worthwhile species never moves down" % mm)
			check(hi >= prev_hi_worth, "%.3f kg: largest worthwhile species never moves down" % mm)
			if lo > prev_lo_worth and prev_lo_worth >= 0:
				lo_worth_rises += 1
			prev_lo_worth = lo
			prev_hi_worth = hi
			if not danger.is_empty():
				check(danger.min() >= prev_lo_danger, "%.3f kg: smallest threat never moves down" % mm)
				prev_lo_danger = danger.min()
				check(danger.min() > hi, "%.3f kg: threats are all bigger than any prey" % mm)
			table["%s x%.1f" % [SizeRules.SPECIES[t]["id"], f]] = {
				"worth": _ids(worth), "danger": _ids(danger),
				"edible_not_worth": _ids(s["edible"].filter(func(i: int) -> bool: return not worth.has(i)))}
	gt(float(lo_worth_rises), 4.0, "the bottom of the menu moves up at least 5 times from sparrow to eagle")
	metric("sets_by_size", table)
	# Headline cases from the brief.
	var sp := _sets(SizeRules.species_data(&"sparrow")["mass"])
	check(sp["worth"].has(0), "a sparrow hunts moths")
	var eg := _sets(SizeRules.species_data(&"eagle")["mass"])
	check(not eg["worth"].has(SizeRules.species_index(&"sparrow")), "an eagle ignores sparrows")
	check(eg["danger"].is_empty(), "nothing threatens an eagle")
	check(eg["worth"].has(SizeRules.species_index(&"hawk")), "an eagle hunts hawks")
	var sp_d: Array[int] = sp["danger"]
	eq(sp_d.min(), SizeRules.species_index(&"swallow"), "a fresh sparrow already fears swallows")


func test_each_species_is_dropped_in_ladder_order() -> void:
	# Sweep the player's mass up continuously: record at which mass each
	# species stops being worth hunting. Smaller species must drop first.
	var drop := {}
	var m := GameLoop.START_MASS
	while m <= GameLoop.MAX_PLAYER_MASS:
		for i in SizeRules.SPECIES.size():
			var q: float = SizeRules.SPECIES[i]["mass"]
			if SizeRules.can_eat(m, q) and not SizeRules.is_worthwhile(m, q) and not drop.has(i):
				drop[i] = m
		m *= 1.01
	var ordered := true
	var prev := 0.0
	var dropped: Array = []
	for i in SizeRules.SPECIES.size():
		if not drop.has(i):
			continue
		dropped.append(SizeRules.SPECIES[i]["id"])
		if float(drop[i]) < prev:
			ordered = false
		prev = drop[i]
	check(ordered, "species leave the menu smallest-first: %s" % str(drop))
	gt(float(dropped.size()), 5.0, "at least six species become beneath notice during a run")
	var named := {}
	for i: int in drop:
		named[SizeRules.SPECIES[i]["id"]] = snappedf(drop[i], 0.001)
	metric("ignored_from_mass", named)


## One NPC of every species in a fan ahead of the player (all outside reach,
## inside highlight range); returns them indexed by species.
func _fan(p: SimBird) -> Array[SimBird]:
	var out: Array[SimBird] = []
	var span := p.get_wingspan()
	for i in SizeRules.SPECIES.size():
		var ang := deg_to_rad(-60.0 + 120.0 * float(i) / float(SizeRules.SPECIES.size() - 1))
		var d := span * 14.0
		var pos := p.get_body_position() + Vector3(sin(ang), 0.0, -cos(ang)) * d
		var b := make_bird(SizeRules.SPECIES[i]["mass"], pos, Vector3.RIGHT, false, true)
		b.name = String(SizeRules.SPECIES[i]["id"])
		# The fan is dense at small player sizes: keep the NPCs from eating
		# each other so every species stays on show.
		loop.set_protection(b, 600.0)
		out.append(b)
	return out


func test_live_highlights_and_targets_follow_the_player_size() -> void:
	var report := {}
	for t in range(SizeRules.species_index(&"sparrow"), SizeRules.SPECIES.size()):
		var pm: float = float(SizeRules.SPECIES[t]["mass"]) * 1.1
		make_loop()
		var p := make_bird(pm, Vector3.ZERO, Vector3.FORWARD, true)
		loop.start_run()
		p.mass = pm
		loop.set_protection(p, 600.0)
		var fan := _fan(p)
		start_logging()
		for k in 3:
			loop.step(DT)
		var s := _sets(pm)
		var wrong: Array[String] = []
		var hl := []
		for i in fan.size():
			var want := 0
			if (s["worth"] as Array).has(i):
				want = 1
			elif (s["danger"] as Array).has(i):
				want = 2
			var got: int = fan[i].model.highlight
			hl.append(got)
			if got != want:
				wrong.append("%s got %d want %d" % [fan[i].name, got, want])
		check(wrong.is_empty(), "%s-sized player: highlights %s" % [SizeRules.SPECIES[t]["id"], ", ".join(wrong)])
		var tg := loop.watch.target
		check(tg != null, "%s: has a target" % SizeRules.SPECIES[t]["id"])
		if tg:
			check(SizeRules.is_worthwhile(pm, tg.mass), "%s: target %s is worth eating" % [SizeRules.SPECIES[t]["id"], tg.name])
		# Every target the loop ever announced was worthwhile.
		for e in events("target"):
			if e[1] != null:
				check(SizeRules.is_worthwhile(pm, e[1].mass), "announced target worthwhile")
		report[String(SizeRules.SPECIES[t]["id"])] = {"highlights": hl, "target": tg.name if tg else ""}
		await cleanup()
	metric("highlights_by_player_species", report)


func test_growing_mid_hunt_drops_a_target_that_became_dust() -> void:
	# A starling targets a wren; after growing into a pigeon the wren is no
	# longer worth it: its highlight goes and the target moves on.
	make_loop()
	var p := make_bird(0.09, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.09
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var wren := make_bird(0.012, p.get_body_position() + Vector3(0, 0, -6 * span), Vector3.RIGHT, false, true)
	loop.step(DT)
	eq(loop.watch.target, wren, "starling targets the wren")
	eq(wren.model.highlight, 1, "wren highlighted")
	p.mass = 0.4
	start_logging()
	loop.step(DT)
	check(loop.watch.target != wren, "pigeon-sized player drops the wren")
	eq(wren.model.highlight, 0, "wren no longer highlighted")
	eq(count("target"), 1, "one target_changed")
