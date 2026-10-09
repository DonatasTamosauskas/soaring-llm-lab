class_name RunStats
extends RefCounted
## Everything that happened in one run, for the HUD, the run summary and
## the persisted records. Filled in by GameLoop; no game logic lives here.

## Score: peak mass in grams (the agar.io "biggest you got"), plus a bonus per
## worthwhile catch (rewards hunting over farming dust), plus a victory bonus
## that shrinks with the run's length (rewards a clean, fast climb).
const POINTS_PER_WORTHWHILE_CATCH := 25
const VICTORY_BONUS := 3000
const VICTORY_TIME_BONUS_MAX := 3000
const VICTORY_TIME_BONUS_ZERO_S := 3600.0

var start_mass := 0.03
var run_time := 0.0
var catches := 0
var worthwhile_catches := 0
## species id (StringName) -> count, for the player's catches.
var catches_by_species := {}
var mass_gained := 0.0
var biggest_prey_mass := 0.0
var biggest_prey := &""
var times_caught := 0
## species id -> times that species caught the player.
var caught_by := {}
var streak := 0
var best_streak := 0
## Attack runs on the player that missed (GameLoop's escape grace).
var escapes := 0
## Attacks on the player (a predator's threat reached attack strength), and
## how many the danger director called (GameLoop._direct_danger).
var attacks := 0
var attacks_sent := 0
var peak_mass := 0.0
var peak_tier := 0
## tier index -> run_time (s) when first reached this run.
var tier_reached_at := {}
## Seconds spent at each tier (index = tier).
var time_in_tier := PackedFloat64Array()
## Catches between NPCs the ecosystem produced during the run (liveliness).
var npc_catches := 0
var apex_reached_at := -1.0
var reign_time := 0.0
var apex_catches := 0
var victory := false


func reset(p_start_mass: float) -> void:
	start_mass = p_start_mass
	run_time = 0.0
	catches = 0
	escapes = 0
	attacks = 0
	attacks_sent = 0
	worthwhile_catches = 0
	catches_by_species = {}
	mass_gained = 0.0
	biggest_prey_mass = 0.0
	biggest_prey = &""
	times_caught = 0
	caught_by = {}
	streak = 0
	best_streak = 0
	peak_mass = p_start_mass
	peak_tier = SizeRules.tier_for_mass(p_start_mass)
	tier_reached_at = {peak_tier: 0.0}
	time_in_tier = PackedFloat64Array()
	time_in_tier.resize(SizeRules.SPECIES.size())
	time_in_tier.fill(0.0)
	npc_catches = 0
	apex_reached_at = -1.0
	reign_time = 0.0
	apex_catches = 0
	victory = false


func tick(dt: float, tier: int) -> void:
	run_time += dt
	if tier >= 0 and tier < time_in_tier.size():
		time_in_tier[tier] += dt


func on_player_ate(prey_species: StringName, prey_mass: float, gain: float, worthwhile: bool) -> void:
	catches += 1
	if worthwhile:
		worthwhile_catches += 1
	catches_by_species[prey_species] = int(catches_by_species.get(prey_species, 0)) + 1
	mass_gained += gain
	if prey_mass > biggest_prey_mass:
		biggest_prey_mass = prey_mass
		biggest_prey = prey_species
	streak += 1
	best_streak = maxi(best_streak, streak)


func on_player_caught(by_species: StringName) -> void:
	times_caught += 1
	caught_by[by_species] = int(caught_by.get(by_species, 0)) + 1
	streak = 0


## Called whenever the player's mass changes; records peaks and first-reach times.
func on_player_mass(mass: float) -> void:
	peak_mass = maxf(peak_mass, mass)
	var t := SizeRules.tier_for_mass(mass)
	if t > peak_tier:
		peak_tier = t
	if not tier_reached_at.has(t):
		tier_reached_at[t] = run_time


func score() -> int:
	var s := roundi(peak_mass * 1000.0) + POINTS_PER_WORTHWHILE_CATCH * worthwhile_catches
	if victory:
		s += VICTORY_BONUS
		s += roundi(VICTORY_TIME_BONUS_MAX * clampf(1.0 - run_time / VICTORY_TIME_BONUS_ZERO_S, 0.0, 1.0))
	return s


## Ordered milestones [{tier, species, name, at}] for the summary timeline.
func tier_timeline() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tiers := tier_reached_at.keys()
	tiers.sort()
	for t: int in tiers:
		var s: Dictionary = SizeRules.SPECIES[t]
		out.append({"tier": t, "species": s["id"], "name": s["name"], "at": float(tier_reached_at[t])})
	return out
