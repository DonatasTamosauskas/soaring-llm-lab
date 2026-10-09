extends TestCase
## The Quest quality tier and its frame-rate safety valve (integration).


class _Eco:
	extends Node
	var max_npcs := 60
	var lod_near := 80.0
	var lod_far := 200.0


func test_quest_tier_values() -> void:
	var q := QualityTier.new()
	eq(q.name, &"full", "the Mac / desktop default is the full game")
	eq(q.max_npcs, 60, "60 NPCs in full")
	q.set_quest()
	eq(q.name, &"quest", "quest tier")
	eq(q.max_npcs, QualityTier.QUEST_NPCS, "the Quest's NPC budget")
	lt(float(q.max_npcs), 60.0, "fewer NPCs on the Quest")
	check(q.governor, "the Quest tier carries the frame-rate safety valve")
	var eco := _Eco.new()
	q.apply_ecosystem(eco)
	eq(eco.max_npcs, QualityTier.QUEST_NPCS, "applied to the Ecosystem")
	near(eco.lod_near, 60.0, 1e-6, "LOD near")
	near(eco.lod_far, 140.0, 1e-6, "LOD far")
	eco.free()


## Integration round 1: the tier follows the headset, not only the OS. The
## Meta XR Simulator reports the Quest Pro profile; simulator runs used to
## judge the 60-NPC desktop game, which is not what ships.
func test_the_quest_tier_follows_the_openxr_system() -> void:
	check(QualityTier.is_quest_name("Meta Quest Pro"), "the simulator's system name ('Meta Quest Pro') is a Quest")
	check(QualityTier.is_quest_name("Oculus Quest2"), "an older runtime's name too")
	check(not QualityTier.is_quest_name(""), "no XR system: not a Quest")
	check(not QualityTier.is_quest_name("SteamVR/OpenXR : valve"), "another headset: not a Quest")
	# Headless (no XR interface): the desktop's full game.
	check(not QualityTier.quest_system(), "no OpenXR session here")
	eq(QualityTier.choose().name, &"full", "the desktop keeps the full game (no --quality given)")


func test_governor_lowers_the_budget_only_on_sustained_misses() -> void:
	var eco := _Eco.new()
	eco.max_npcs = 28
	var g := QualityGovernor.new()
	g.ecosystem = eco
	g.floor_npcs = 20
	var fps := [72.0]
	var playing := [true]
	g.fps_source = func() -> float: return fps[0]
	g.refresh_source = func() -> float: return 72.0
	g.playing_source = func() -> bool: return playing[0]
	# On time: nothing changes.
	for i in 40:
		g.step(0.5)
	eq(eco.max_npcs, 28, "steady 72 fps keeps the budget")
	# A short dip (2 s) is not enough.
	fps[0] = 60.0
	for i in 4:
		g.step(0.5)
	fps[0] = 72.0
	g.step(0.5)
	eq(eco.max_npcs, 28, "a 2 s dip does nothing")
	# Sustained misses: one step down, then a cool-down.
	fps[0] = 60.0
	for i in 7:
		g.step(0.5)
	eq(eco.max_npcs, 24, "3 s below 92 %% of the refresh: -%d NPCs" % QualityGovernor.STEP)
	for i in 10:
		g.step(0.5)
	eq(eco.max_npcs, 24, "cool-down: no second step within 10 s")
	for i in 60:
		g.step(0.5)
	eq(eco.max_npcs, 20, "never below the floor")
	# Without a ceiling the budget never rises again.
	fps[0] = 72.0
	for i in 100:
		g.step(0.5)
	eq(eco.max_npcs, 20, "no ceiling: no rise")
	eco.max_npcs = 28
	fps[0] = 30.0
	playing[0] = false
	for i in 20:
		g.step(0.5)
	eq(eco.max_npcs, 28, "slow frames outside a run (loading, menus) change nothing")
	eq(g.steps_taken, 2, "two steps taken in all")
	g.free()
	eco.free()


## Integration round 2 (the Quest and engineering verifiers): the budget
## never came back once lowered - one dip thinned the sky for the rest of
## the session. It recovers after RECOVER_S at the refresh, up to the tier's
## own budget, and a rise the frame rate cannot hold doubles the wait.
func test_governor_recovers_the_budget_without_pulsing() -> void:
	var eco := _Eco.new()
	eco.max_npcs = 28
	var g := QualityGovernor.new()
	g.ecosystem = eco
	g.floor_npcs = 20
	g.ceiling_npcs = 28
	var fps := [60.0]
	g.fps_source = func() -> float: return fps[0]
	g.refresh_source = func() -> float: return 72.0
	g.playing_source = func() -> bool: return true
	for i in 7:
		g.step(0.5)
	eq(eco.max_npcs, 24, "(setup) a sustained miss: 24")
	fps[0] = 72.0
	for i in int(QualityGovernor.RECOVER_S / 0.5) - 2:
		g.step(0.5)
	eq(eco.max_npcs, 24, "not back up before RECOVER_S at the refresh")
	for i in 4:
		g.step(0.5)
	eq(eco.max_npcs, 28, "back to the tier's 28 after RECOVER_S at the refresh")
	for i in 200:
		g.step(0.5)
	eq(eco.max_npcs, 28, "never above the tier's own budget")
	# A rise the frame rate cannot hold: cut again soon after, and the next
	# rise waits twice as long.
	fps[0] = 60.0
	for i in 7:
		g.step(0.5)
	eq(eco.max_npcs, 24, "cut to 24")
	fps[0] = 72.0
	for i in int(QualityGovernor.RECOVER_S / 0.5) + 2:
		g.step(0.5)
	eq(eco.max_npcs, 28, "back up")
	fps[0] = 60.0
	for i in 22:
		g.step(0.5)
	eq(eco.max_npcs, 24, "the rise did not hold: cut within PULSE_S")
	fps[0] = 72.0
	for i in int(QualityGovernor.RECOVER_S / 0.5) + 2:
		g.step(0.5)
	eq(eco.max_npcs, 24, "the next rise waits longer than RECOVER_S")
	for i in int(QualityGovernor.RECOVER_S / 0.5) + 2:
		g.step(0.5)
	eq(eco.max_npcs, 28, "...twice as long")
	# A dip in a menu does nothing; neither does a good frame rate there.
	eq(g.raises_taken, 3, "three rises in all")
	g.free()
	eco.free()
