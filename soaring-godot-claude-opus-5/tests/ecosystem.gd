extends SceneTree

## Runs the sky with nobody in it and reports what happened.
##
##   godot --headless --xr-mode off --script res://tests/ecosystem.gd -- --minutes=5
##   godot --headless --xr-mode off --script res://tests/ecosystem.gd -- --minutes=10 --birds=40
##
## Asserts nothing. It is the instrument every number in [AITests] was chosen
## from, and the answer to "does the world still look alive when the player is
## not in it" — which cannot be answered by playing, because playing puts a
## player in it.


func _initialize() -> void:
	var minutes: float = 5.0
	var count: int = 26
	var sim_seed: int = 20260813
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() != 2:
			continue
		match parts[0]:
			"minutes":
				minutes = parts[1].to_float()
			"birds":
				count = parts[1].to_int()
			"seed":
				sim_seed = parts[1].to_int()

	var started: int = Time.get_ticks_msec()
	var world := WorldBuilder.new()
	world.world_seed = sim_seed
	world.build()

	var sim := EcosystemSim.new()
	sim.setup(world, count, sim_seed)
	sim.run(minutes * 60.0)
	var wall: int = Time.get_ticks_msec() - started

	_report(sim, wall)
	sim.release()
	world.free()
	quit(0)


const STATE_NAMES: Array[String] = [
	"wander", "hunt", "flee", "perch", "stalk", "soar", "land"
]


func _states(counts: Dictionary) -> String:
	var parts: PackedStringArray = []
	for key: int in counts:
		parts.append("%s %d" % [STATE_NAMES[key], counts[key]])
	return "(%s)" % ", ".join(parts)


func _report(sim: EcosystemSim, wall: int) -> void:
	var s: Dictionary = sim.summary()
	print("")
	print("=== Soaring ecosystem: %.1f minutes of %d birds, nobody watching ===" % [
		s["minutes"], s["birds"]
	])
	print("  simulated in %.1f s of wall clock (%.0fx real time)" % [
		wall / 1000.0, (s["minutes"] as float) * 60000.0 / maxf(float(wall), 1.0)
	])
	print("")
	print("  the pecking order")
	print("    npc-vs-npc catches     %d  (%.2f per minute)" % [
		s["catches"], s["catches_per_min"]
	])
	print("    biggest bird alive     %.2f" % s["size_max"])
	print("")
	print("  roosting")
	print("    landings               %d" % s["landings"])
	print("    birds that ever landed %d of %d" % [s["birds_that_perched"], s["birds"]])
	print("    distinct perches used  %d" % s["perches_used"])
	print("    perches squabbled over %d" % s["evictions"])
	print("    most birds down at once %d" % s["peak_roosting"])
	print("    share of bird-time perched %.1f %%" % [(s["perch_share"] as float) * 100.0])
	print("")
	print("  soaring")
	print("    thermals entered       %d" % s["soars"])
	print("    height won from lift   %.0f m" % s["soar_climb"])
	print("    mean reserves at end   %.2f" % s["energy_mean"])
	print("")
	print("  trouble")
	print("    birds going nowhere    %d %s" % [s["stuck"], _states(sim.stuck_states)])
	print("    longest going-nowhere run %d checks (%.0f s)" % [
		s["stuck_streak"], float(s["stuck_streak"]) * EcosystemSim.STUCK_WINDOW
	])
	print("    approaches given up on %d" % s["giveups"])
	print("    birds outside the world %d" % s["strays"])
	print("    non-finite states      %d" % s["nonfinite"])
	print("    closest pass           %.1f m" % s["closest_pass"])
	print("")
	print("  census (one row per 30 s)")
	print("    time  wander stalk hunt flee soar land perch   size min/mid/max   energy  agl   nn")
	var row: int = 0
	for sample: Dictionary in sim.samples:
		row += 1
		if row % 6 != 1:
			continue
		var states: Dictionary = sample["states"]
		print("   %5.0f  %6d %5d %4d %4d %4d %4d %5d   %4.1f %4.1f %4.1f   %6.2f %4.0f %4.0f" % [
			sample["time"],
			states[BirdNPC.State.WANDER], states[BirdNPC.State.STALK],
			states[BirdNPC.State.HUNT], states[BirdNPC.State.FLEE],
			states[BirdNPC.State.SOAR], states[BirdNPC.State.LAND],
			states[BirdNPC.State.PERCH],
			sample["size_min"], sample["size_mid"], sample["size_max"],
			sample["energy_mean"], sample["altitude_mean"], sample["nearest_mean"],
		])
