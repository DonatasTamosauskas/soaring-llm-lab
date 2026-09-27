class_name PacingModel
extends RefCounted
## The statistical pacing model: chase opportunities by player size and
## skill, and what comes of them, fitted from whole simulated runs
## (IntegratedSim logs them per run) - then thousands of runs in a
## millisecond each, for any growth tuning.
##
## Why it holds: how often a player of mass m gets a chase, how often a
## chase ends in a catch, what the prey weighs relative to the player, and
## how often the player is caught, all depend on the sky around a bird of
## that size (the AI plans its population around the player's mass) and on
## the pilot's skill - not on how fast the player got to that size. The
## growth formula (SizeRules.meal_gain: GROWTH_GAIN, GROWTH_SIZE_EXP) only
## decides how long the player stays at each size. So rates fitted per band
## of mass at one growth tuning predict the pacing at another. That is how
## the shipped growth was chosen (docs/areas/GAMELOOP.md), and the claim is
## tested out of sample: fitted on the calibration runs (another tuning),
## the model must predict the evidence runs' medians (pacing_test).
##
## The run it simulates (Gillespie, rates piecewise constant in mass): at
## mass m, catches arrive at rate chases(m) x success(m) and deaths at
## rate deaths(m); a catch draws a prey/player ratio from those logged at
## that size and grows the player by SizeRules.meal_gain; a death costs a
## life and GameLoop.CAUGHT_MASS_LOSS of mass (cut by the danger assist, kept
## as the loop keeps it); a new peak tier or every GameLoop.LIFE_PER_MEALS-th
## worthwhile catch since the last death gives a life back;
## GameLoop.APEX_CATCHES worthwhile catches as an eagle win. What it leaves out: the
## catch assist and the respites act inside the fitted rates, and the time
## of a run's first minutes (finding the first prey) is in them too.

## Bands of player mass: band 0 starts at the start mass, each is BAND_RATIO
## wide (a sparrow-to-eagle run crosses ~20).
const M0 := 0.03
const BAND_RATIO := 1.25
const N_BANDS := 23
## A band with less exposure than this (s, summed over the fitted runs) is
## pooled with its neighbours until it has it.
const MIN_EXPOSURE_S := 240.0

## Per band (after pooling): exposure (s), chases, catches, deaths, ratios.
var exposure := PackedFloat64Array()
var chase_rate := PackedFloat64Array()
var success := PackedFloat64Array()
var catch_rate := PackedFloat64Array()
var death_rate := PackedFloat64Array()
var ratios: Array = []
var n_runs := 0


static func band_of(m: float) -> int:
	return clampi(floori(log(maxf(m, 1e-6) / M0) / log(BAND_RATIO) + 1e-9), 0, N_BANDS - 1)


## Empty per-run log (IntegratedSim fills it while it runs).
static func new_bands() -> Dictionary:
	var z := []
	z.resize(N_BANDS)
	z.fill(0.0)
	var rs := []
	for i in N_BANDS:
		rs.append([])
	return {"t": z.duplicate(), "chases": z.duplicate(), "deaths": z.duplicate(), "ratios": rs}


static func log_time(b: Dictionary, m: float, dt: float) -> void:
	b["t"][band_of(m)] += dt


static func log_chase(b: Dictionary, m: float) -> void:
	b["chases"][band_of(m)] += 1.0


static func log_catch(b: Dictionary, m: float, prey_m: float) -> void:
	(b["ratios"][band_of(m)] as Array).append(snappedf(prey_m / m, 0.0001))


static func log_death(b: Dictionary, m: float) -> void:
	b["deaths"][band_of(m)] += 1.0


## Sums the per-run logs of `runs` (each with a "bands" entry) into one.
static func pool_runs(runs: Array) -> Dictionary:
	var total := new_bands()
	for r: Dictionary in runs:
		var b: Dictionary = r.get("bands", {})
		if b.is_empty():
			continue
		for i in N_BANDS:
			total["t"][i] += float(b["t"][i])
			total["chases"][i] += float(b["chases"][i])
			total["deaths"][i] += float(b["deaths"][i])
			(total["ratios"][i] as Array).append_array(b["ratios"][i])
	return total


## Fits the rates from pooled logs (pool_runs) of n runs.
func fit(total: Dictionary, runs: int) -> PacingModel:
	n_runs = runs
	exposure.resize(N_BANDS)
	chase_rate.resize(N_BANDS)
	success.resize(N_BANDS)
	catch_rate.resize(N_BANDS)
	death_rate.resize(N_BANDS)
	ratios.clear()
	for i in N_BANDS:
		# Widen the window round band i until it has enough exposure (bands
		# a run crosses quickly, or never reaches, borrow from neighbours).
		var lo := i
		var hi := i
		var t := float(total["t"][i])
		while t < MIN_EXPOSURE_S and (lo > 0 or hi < N_BANDS - 1):
			if lo > 0:
				lo -= 1
				t += float(total["t"][lo])
			if hi < N_BANDS - 1 and t < MIN_EXPOSURE_S:
				hi += 1
				t += float(total["t"][hi])
		var ch := 0.0
		var de := 0.0
		var rs: Array = []
		for k in range(lo, hi + 1):
			ch += float(total["chases"][k])
			de += float(total["deaths"][k])
			rs.append_array(total["ratios"][k])
		exposure[i] = t
		chase_rate[i] = ch / maxf(t, 1e-6)
		catch_rate[i] = rs.size() / maxf(t, 1e-6)
		success[i] = rs.size() / maxf(ch, 1.0)
		death_rate[i] = de / maxf(t, 1e-6)
		ratios.append(rs)
	return self


## Optional extra growth per meal as a function of the player's mass (m ->
## factor), as GameLoop.sky_growth() gives it in a sparser sky (the pacing
## tool's Quest-tier grids; fix round 5). Unset: x1.
var meal_factor: Callable = Callable()


## n simulated runs of at most max_s with the given growth tuning (the
## SizeRules statics are restored after). Returns IntegratedSim.summarize()
## of them, plus the runs themselves under "runs".
func simulate(n: int, seed_: int, max_s: float, growth_gain: float, growth_exp: float) -> Dictionary:
	var keep_gain := SizeRules.growth_gain
	var keep_exp := SizeRules.growth_size_exp
	SizeRules.growth_gain = growth_gain
	SizeRules.growth_size_exp = growth_exp
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var runs: Array = []
	for i in n:
		runs.append(_one_run(rng, max_s))
	SizeRules.growth_gain = keep_gain
	SizeRules.growth_size_exp = keep_exp
	var out := IntegratedSim.summarize(runs)
	out["runs"] = runs
	return out


func _one_run(rng: RandomNumberGenerator, max_s: float) -> Dictionary:
	var apex := SizeRules.SPECIES.size() - 1
	var m := GameLoop.START_MASS
	var t := 0.0
	var lives := GameLoop.MAX_LIVES
	var peak := SizeRules.tier_for_mass(m)
	var tier_at := {peak: 0.0}
	var deaths := 0
	var catches := 0
	var apex_catches := 0
	# The loop's danger assist (it cuts the death penalty) and its eat-to-heal
	# count, as GameLoop keeps them.
	var assist := 0.0
	var meals := 0
	var t_prev := 0.0
	var victory := -1.0
	var reason := "time"
	while true:
		var b := band_of(m)
		var lam := catch_rate[b]
		var mu := death_rate[b]
		var rs: Array = ratios[b]
		if rs.is_empty():
			lam = 0.0
		if lam + mu <= 0.0:
			break
		t += -log(maxf(1.0 - rng.randf(), 1e-12)) / (lam + mu)
		if t >= max_s:
			break
		assist *= exp(-(t - t_prev) / (GameLoop.DANGER_ASSIST_TAU_S * SizeRules.time_scale(m)))
		t_prev = t
		if rng.randf() * (lam + mu) < lam:
			var prey := float(rs[rng.randi() % rs.size()]) * m
			var worthwhile := SizeRules.is_worthwhile(m, prey)
			var tier_before := SizeRules.tier_for_mass(m)
			var f: float = meal_factor.call(m) if meal_factor.is_valid() else 1.0
			m = minf(m + SizeRules.meal_gain(m, prey) * f, GameLoop.MAX_PLAYER_MASS)
			catches += 1
			if worthwhile and lives < GameLoop.MAX_LIVES:
				meals += 1
				if meals >= GameLoop.LIFE_PER_MEALS:
					meals = 0
					lives += 1
			if tier_before >= apex and worthwhile:
				apex_catches += 1
				if apex_catches >= GameLoop.APEX_CATCHES:
					victory = t
					reason = "victory"
					break
		else:
			deaths += 1
			lives -= 1
			meals = 0
			assist = minf(1.0, assist + GameLoop.DANGER_ASSIST_PER_DEATH)
			t += GameLoop.CAUGHT_BEAT_S
			t_prev = t
			if lives <= 0:
				reason = "caught"
				break
			m = maxf(GameLoop.START_MASS, m * (1.0 - GameLoop.CAUGHT_MASS_LOSS * (1.0 - GameLoop.DANGER_ASSIST_PENALTY_CUT * assist)))
		var tier := SizeRules.tier_for_mass(m)
		if tier > peak:
			for k in range(peak + 1, tier + 1):
				tier_at[k] = t
			peak = tier
			lives = mini(lives + 1, GameLoop.MAX_LIVES)
	return {"tier_at": tier_at, "deaths": deaths, "victory_at": victory, "ended_at": minf(t, max_s),
		"end_reason": reason, "catches": catches}


## The fitted model as plain data (evidence files store it).
func to_dict() -> Dictionary:
	return {"n_runs": n_runs, "exposure_s": Array(exposure), "chases_per_min": _per_min(chase_rate),
		"success": Array(success), "catches_per_min": _per_min(catch_rate),
		"deaths_per_min": _per_min(death_rate)}


static func _per_min(a: PackedFloat64Array) -> Array:
	var out := []
	for x in a:
		out.append(snappedf(x * 60.0, 0.001))
	return out
