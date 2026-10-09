extends SceneTree

## Prints the difficulty curve. Asserts nothing — this is the table you read
## when you want to know whether the game is too long, too safe or too cruel,
## and the numbers [ProgressionTests] pins are chosen by looking at it.
##
##   godot --headless --xr-mode off --script res://tests/session_report.gd
##
## Rows are skill levels: 0.25 is someone who has had the headset on for five
## minutes, 0.60 is a competent player who can hold a turn and read a silhouette,
## 0.90 is someone who has played all week.

const RUNS: int = 200


func _initialize() -> void:
	var started: int = Time.get_ticks_msec()
	print("")
	print("=== Soaring session curve (%d simulated runs per skill level) ===" % RUNS)
	print("")
	print("  the ladder:")
	for i in Progression.RANKS.size():
		print("    %d  %-10s from size %.2f" % [
			i, Progression.name_of_rank(i), Progression.size_of_rank(i)
		])
	print("    win at size %.1f, %d lives" % [Progression.APEX_SIZE, Progression.LIVES])
	print("")

	print("  skill   win%%   time to apex (p10/med/p90)     run    catch/min  death/min  catches  deaths")
	for skill: float in [0.25, 0.45, 0.60, 0.75, 0.90]:
		var s: Dictionary = SessionSim.sweep(skill, RUNS)
		print("   %.2f   %3.0f%%     %s / %s / %s   %s     %.2f       %.2f      %5.0f   %5.1f" % [
			skill, s["win_rate"] * 100.0,
			GameSession.clock(s["win_time_p10"]),
			GameSession.clock(s["win_time_median"]),
			GameSession.clock(s["win_time_p90"]),
			GameSession.clock(s["elapsed_median"]),
			s["catch_rate_median"], s["death_rate_median"],
			s["catches_median"], s["deaths_mean"],
		])
	print("")
	print("  measured in the real game by SessionProbe, for comparison:")
	print("    autopilot, break-turns when something commits to it:  0.60 catch/min, 0.24 death/min")
	print("    autopilot, never looks behind it:                    0.83 catch/min, 0.50 death/min")
	print("    (25 min of flight, 121 chases, 15%% conversion — it hunts like a 0.6 and, before")
	print("     it was taught to break-turn, evaded like a 0.2)")

	print("")
	print("  time to each rank (median, competent player at skill 0.60)")
	var mid: Dictionary = SessionSim.sweep(0.60, RUNS)
	var medians: PackedFloat32Array = mid["rank_time_median"]
	var reached: PackedFloat32Array = mid["rank_reached"]
	for i in medians.size():
		print("    %-10s  %s   reached by %3.0f%% of runs" % [
			Progression.name_of_rank(i), GameSession.clock(medians[i]), reached[i] * 100.0
		])

	print("")
	print("  the sky as you climb it")
	print("    size   rank        prey/peer/predator   prey band     predator band")
	for size: float in [0.5, 1.0, 1.6, 2.4, 3.2, 4.5, 6.0, 8.0]:
		var mix: Vector3 = Progression.threat_mix(size)
		var prey_low: float = Progression.size_for_role(size, Progression.Role.PREY, 0.0)
		var prey_high: float = Progression.size_for_role(size, Progression.Role.PREY, 1.0)
		var pred_low: float = Progression.size_for_role(size, Progression.Role.PREDATOR, 0.0)
		var pred_high: float = Progression.size_for_role(size, Progression.Role.PREDATOR, 1.0)
		print("    %4.1f   %-10s  %2.0f/%2.0f/%2.0f%%            %.2f-%.2f     %.2f-%.2f%s" % [
			size, Progression.rank_name(size), mix.x * 100.0, mix.y * 100.0, mix.z * 100.0,
			prey_low, prey_high, pred_low, pred_high,
			"" if Progression.threat_is_possible(size) else "  (nothing can eat you)",
		])

	print("")
	print("  %d ms" % (Time.get_ticks_msec() - started))
	quit(0)
