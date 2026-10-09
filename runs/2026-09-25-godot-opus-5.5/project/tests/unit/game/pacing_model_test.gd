extends "res://tests/unit/game/game_fixture.gd"
## The statistical pacing model (PacingModel): chase opportunities, success,
## prey sizes and deaths by band of player mass and skill, fitted from whole
## runs, then simulated. Its mechanics are pinned here on hand-checkable
## inputs; that it predicts real runs out of sample is pacing_test's
## test_pacing_model_predicts_out_of_sample.


## Logs as IntegratedSim writes them: `seconds` in every band from the
## start mass to `top`, a chase every `chase_s`, a catch of prey at `ratio`
## of the player every `catch_s`, a death every `death_s` (0 = none).
static func _bands(seconds: float, chase_s: float, catch_s: float, ratio: float, death_s: float = 0.0,
		top: float = 5.0) -> Dictionary:
	var b := PacingModel.new_bands()
	var m := GameLoop.START_MASS
	while m < top:
		var i := PacingModel.band_of(m)
		b["t"][i] += seconds
		b["chases"][i] += seconds / chase_s
		for k in int(round(seconds / catch_s)):
			(b["ratios"][i] as Array).append(ratio)
		if death_s > 0.0:
			b["deaths"][i] += seconds / death_s
		m *= PacingModel.BAND_RATIO
	return b


func test_bands() -> void:
	eq(PacingModel.band_of(GameLoop.START_MASS), 0, "the start mass is band 0")
	eq(PacingModel.band_of(GameLoop.START_MASS * 1.2499), 0, "band 0 is BAND_RATIO wide")
	eq(PacingModel.band_of(GameLoop.START_MASS * 1.2501), 1, "then band 1")
	eq(PacingModel.band_of(GameLoop.MAX_PLAYER_MASS), PacingModel.N_BANDS - 1, "the growth cap is in the last band")
	eq(PacingModel.band_of(0.001), 0, "below the start mass: band 0")
	# Logging, as IntegratedSim does it.
	var b := PacingModel.new_bands()
	PacingModel.log_time(b, 0.05, 2.0)
	PacingModel.log_chase(b, 0.05)
	PacingModel.log_catch(b, 0.05, 0.02)
	PacingModel.log_death(b, 0.05)
	var i := PacingModel.band_of(0.05)
	eq([b["t"][i], b["chases"][i], b["deaths"][i], b["ratios"][i]], [2.0, 1.0, 1.0, [0.4]], "one of each logged in the band")


func test_rates_and_a_hand_checkable_run() -> void:
	# A catch every 20 s at every size, always prey at 0.3 of the player, no
	# deaths: the number of catches to each tier follows from the growth
	# formula alone, and the mean time to it is that number x 20 s.
	var model := PacingModel.new().fit(_bands(600.0, 5.0, 20.0, 0.3), 1)
	near(model.catch_rate[0], 1.0 / 20.0, 1e-9, "catch rate fitted")
	near(model.chase_rate[0], 1.0 / 5.0, 1e-9, "chase rate fitted")
	near(model.success[0], 0.25, 1e-9, "success = catches / chases")
	eq(model.death_rate[0], 0.0, "no deaths")
	var gain := 1.3
	var ex := 0.3
	var keep := [SizeRules.growth_gain, SizeRules.growth_size_exp]
	SizeRules.growth_gain = gain
	SizeRules.growth_size_exp = ex
	var need := {}
	var m := GameLoop.START_MASS
	var n := 0
	while SizeRules.tier_for_mass(m) < SizeRules.SPECIES.size() - 1:
		m = minf(m + SizeRules.meal_gain(m, 0.3 * m), GameLoop.MAX_PLAYER_MASS)
		n += 1
		var t := SizeRules.tier_for_mass(m)
		if not need.has(t):
			need[t] = n
	SizeRules.growth_gain = keep[0]
	SizeRules.growth_size_exp = keep[1]
	var sim := model.simulate(3000, 3, 1e9, gain, ex)
	eq([SizeRules.growth_gain, SizeRules.growth_size_exp], keep, "the growth statics are restored")
	for sp in [&"pigeon", &"eagle"]:
		var t := SizeRules.species_index(sp)
		var sum := 0.0
		for r: Dictionary in sim["runs"]:
			sum += float(r["tier_at"][t])
		var mean: float = sum / (sim["runs"] as Array).size()
		near(mean, float(need[t]) * 20.0, float(need[t]) * 20.0 * 0.04, "%s: mean time = %d catches x 20 s" % [sp, need[t]])
	metric("catches_needed", need)


func test_growth_and_danger_act_as_they_should() -> void:
	var model := PacingModel.new().fit(_bands(600.0, 5.0, 20.0, 0.3), 1)
	var slow := model.simulate(1000, 4, 3000.0, 0.9, 0.3)
	var fast := model.simulate(1000, 4, 3000.0, 1.4, 0.3)
	var steep := model.simulate(1000, 4, 3000.0, 1.4, 0.45)
	var pig := SizeRules.species_index(&"pigeon")
	var eag := SizeRules.species_index(&"eagle")
	lt(float(fast["tiers"][pig]["median"]), float(slow["tiers"][pig]["median"]) * 0.8, "more growth per meal: pigeon sooner")
	lt(float(fast["tiers"][eag]["median"]), float(slow["tiers"][eag]["median"]) * 0.8, "...and eagle sooner")
	gt(float(steep["tiers"][eag]["median"]) - float(steep["tiers"][pig]["median"]),
			(float(fast["tiers"][eag]["median"]) - float(fast["tiers"][pig]["median"])) * 1.2,
			"a steeper size exponent makes the long haul longer")
	eq(float(fast["deaths"]["median"]), 0.0, "no death rate, no deaths")
	var same := model.simulate(1000, 4, 3000.0, 1.4, 0.3)
	eq(JSON.stringify(same["tiers"]), JSON.stringify(fast["tiers"]), "deterministic for a seed")
	# A deadly sky: a death every 60 s of play and three lives (a new tier
	# gives one back): most runs end caught out.
	var deadly := PacingModel.new().fit(_bands(600.0, 5.0, 20.0, 0.3, 60.0), 1)
	var d := deadly.simulate(1000, 5, 3000.0, 1.0, 0.3)
	gt(float(d["ended_caught"]), 0.5, "a deadly sky ends most runs")
	gt(float(d["deaths"]["median"]), 2.5, "...after three or more deaths")


func test_sparse_bands_borrow_from_neighbours() -> void:
	# Exposure only in bands 0-3: the higher bands use the nearest data
	# (pooled until MIN_EXPOSURE_S), not zero rates.
	var b := PacingModel.new_bands()
	for i in 4:
		b["t"][i] = 300.0
		b["chases"][i] = 30.0
		for k in 10:
			(b["ratios"][i] as Array).append(0.3)
	var model := PacingModel.new().fit(b, 1)
	gt(model.catch_rate[10], 0.0, "an empty band borrows a catch rate")
	gt(float(model.ratios[10].size()), 0.0, "...and prey sizes")
	near(model.catch_rate[0], 10.0 / 300.0, 1e-9, "a band with enough exposure keeps its own rate")
