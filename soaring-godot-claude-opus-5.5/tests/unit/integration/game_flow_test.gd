extends TestCase
## The whole game, end to end, headless (scenes/main.tscn as shipped):
## boot -> main menu -> Play (laser pointer) -> the onboarding lessons flown
## by the bot through the real WingInput -> catches (a moth first) ->
## growth and a tier-up (world_scale, species) -> pause (the rig keeps
## running) -> caught -> respawn -> caught until the run ends -> summary ->
## Fly again (everything reset) -> Quit to menu -> Quit. One game for the
## whole suite, played in order, as a player would.
##
##   tools/gd.sh integ --headless --fixed-fps 72 res://tests/runner.tscn -- --suite=unit/integration/ --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false
var _base_orphans := 0


func before_all() -> void:
	kit = Kit.new()
	_base_orphans = kit.orphans()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_boot_reaches_the_main_menu() -> void:
	if not check(booted, "the game loaded (BOOT -> MENU)"):
		return
	var m := kit.main
	eq(Game.state, Game.State.MENU, "state after loading")
	eq(kit.screen(), &"main", "the main menu is showing")
	check(m.ui.menu_panel.shown, "the menu panel is up")
	# ARCHITECTURE §4 composition, in order, with the right pause modes.
	var names := []
	for c in m.get_children():
		names.append(String(c.name))
	var want := ["World", "Ecosystem", "Player", "GameLoop", "UI", "Audio", "BirdFX"]
	var idx := []
	for n in want:
		idx.append(names.find(n))
	check(not idx.has(-1), "every area is composed: %s in %s" % [want, names])
	var sorted := idx.duplicate()
	sorted.sort()
	eq(idx, sorted, "in the §4 order")
	check(m.world is SoaringWorld and m.world.is_generated, "the real valley generated")
	check(m.ecosystem.count() >= 50, "the sky is populated (%d NPCs)" % m.ecosystem.count())
	check(m.rig_extras != null and m.rig_extras.get_parent() == m.player.origin, "VR rig extras under the XROrigin3D")
	check(m.rig_extras.origin == m.player.origin, "the extras attached to the player's rig")
	eq(m.mirror.source, m.player.camera, "the XR mirror follows the head camera")
	eq(m.player.mode_name(), "perched", "the player waits on the spawn perch")
	check(m.player.global_position.distance_to(m.world.get_player_spawn().origin) < m.player.get_wingspan() * 2.0,
		"at the spawn")
	check(not m.player.auto_process, "the body is still in the menu")
	# Loading report: every step measured, the valley the longest.
	var steps: Array = m.load_report.get("steps", [])
	eq(steps.size(), GameMain.LOAD_STEPS.size(), "every load step reported")
	for s: Dictionary in steps:
		metric("load_%s_ms" % s["name"], s["ms"])
		metric("load_%s_gap_ms" % s["name"], s["max_frame_gap_ms"])
	metric("load_total_ms", m.load_report.get("total_ms", -1))
	metric("load_engine_to_main_ms", m.load_report.get("engine_to_main_ms", -1))
	check(m.load_report.has("first_frames_ms"), "frames were shown before the heavy work")
	eq(kit.log.errors, 0, "no errors while loading: %s" % kit.log.summary())
	eq(kit.log.warnings, 0, "no warnings while loading: %s" % kit.log.summary())


func test_play_from_the_main_menu_with_the_laser_pointer() -> void:
	if not booted:
		return
	var m := kit.main
	# A fresh player: the lessons run (the tutorial is remembered in user://).
	m.ui.onboarding.reset()
	var starts := kit.count("run_started")
	# The longest frame from the pull to the first seconds of flight: the run
	# start resets and repopulates the whole sky (60 NPCs) in one step.
	var gaps := [0]
	var prev := [Time.get_ticks_usec()]
	var watch := func() -> void:
		var now := Time.get_ticks_usec()
		gaps[0] = maxi(gaps[0], now - prev[0])
		prev[0] = now
	m.get_tree().process_frame.connect(watch)
	check(await kit.click(&"main", &"play"), "the pointer hovered Play")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "Play started a run")
	await kit.advance(1.0)
	m.get_tree().process_frame.disconnect(watch)
	metric("play_longest_frame_ms", gaps[0] / 1000.0)
	lt(gaps[0] / 1000.0, 250.0, "starting a run never stalls a frame for long (%.0f ms on this Mac)" % (gaps[0] / 1000.0))
	eq(kit.count("run_started"), starts + 1, "one run_started")
	eq(kit.screen(), &"", "no menu while flying")
	check(m.ui.hud_panel.shown, "the HUD is up")
	check(m.player.auto_process, "the body flies in PLAYING")
	near(m.player.mass, GameLoop.START_MASS, 1e-6, "a new run starts as a sparrow")
	eq(kit.stats()["lives"], GameLoop.MAX_LIVES, "full lives")
	check(m.ui.onboarding.active, "the first-flight lessons started")
	eq(m.ui.onboarding.current().get("id"), &"spread", "lesson 1: spread your wings")
	check(int(m.ui_sounds.played.get(&"confirm", 0)) >= 1, "Play sounded (UI -> AudioDirector)")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_onboarding_lessons_by_flying() -> void:
	if not booted or Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var ob := m.ui.onboarding
	kit.fly_bot()
	var done := {}
	# Lessons already done since Play (spread is held on the perch within a
	# second) were done by doing: a lesson times out only after 45 s.
	for id in ob.progress_store.lessons_done():
		done[StringName(id)] = false
	ob.lesson_completed.connect(func(_i: int, id: StringName, timed_out: bool) -> void: done[id] = timed_out)
	# Each lesson's gesture, flown by the pilot; it climbs first when low.
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var t := 0.0
	var took_off := false
	while t < 90.0 and ob.active and ob.current().get("id") != &"catch":
		var id: StringName = ob.current().get("id", &"")
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
		took_off = took_off or m.player.mode_name() == "flying"
	check(took_off, "the bot took off from the perch by flapping")
	for id in [&"spread", &"flap", &"glide", &"speed", &"turn", &"dive"]:
		check(done.has(id), "lesson %s completed" % id)
		if done.has(id):
			check(not done[id], "lesson %s completed by doing it (not by its timeout)" % id)
	eq(ob.current().get("id"), &"catch", "the last lesson is the catch")
	metric("onboarding_s", t)
	kit.set_mode(&"cruise")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


## A staged catch: prey hovering on the flight path, level with the player
## and BESIDE_SPANS of the player's wingspans to the side of its line, and
## the pass flown by it; the loop's own catch rule at the game's own assist
## (never pinned) decides. Integration hygiene (2026-09-27): the staged
## catches used to pin the assist at full and fly through the bird, three
## passes allowed - a mutant halving the player's catch reach passed the
## whole suite. Now every staged catch must be made on its first pass.
##
## BESIDE_SPANS: a sparrow's reach with no assist is the bodies plus 2.0
## wingspans (CatchRule.player_reach): 2.2 spans centre to centre for a moth
## or a wren; halved it would be 1.2. 1.7 lies between them, 0.10-0.12 m
## from either at a sparrow's size - and the kit holds the bird exactly
## there until the pass reaches it (game_kit.stage_prey), so the bot's aim
## (its wingbeat moves it up to ~0.3 m vertically in the last half metre)
## cannot decide the outcome.
const BESIDE_SPANS := 1.7
## A flown pass came this close (m) to the bird: anything else was not a
## pass (the bot never lined up, e.g. it turned away from terrain) and is
## flown again, up to MAX_ATTEMPTS.
const FLOWN_PASS_M := 1.5
const MAX_ATTEMPTS := 3
var chase_passes := 0
var flown_passes := 0
var staged_catches := 0


func _catch(species: StringName, ahead := 30.0, tries := MAX_ATTEMPTS) -> bool:
	var catches: int = kit.stats()["catches"]
	var passes0 := flown_passes
	var ok := await _catch_passes(species, ahead, tries, catches)
	if ok:
		staged_catches += 1
	# Bounded: the first pass that reaches the bird catches it.
	eq(flown_passes - passes0, 1 if ok else 0, "a staged %s caught on its first pass, at the game's own assist (%.2f)" % [
		species, kit.main.game_loop.rule.player_assist])
	return ok


func _catch_passes(species: StringName, ahead: float, tries: int, catches: int) -> bool:
	var m := kit.main
	for attempt in tries:
		# Roll out onto a straight, level line first, then the prey appears
		# ahead on it.
		kit.fly_straight()
		await kit.advance(1.5)
		await kit.wait_until(func() -> bool:
			return m.player.mode_name() == "flying" and absf(m.player.model.position.y - kit.pilot.h_target) < 1.0 \
				and absf(m.player.velocity.y) < 1.0, 8.0)
		# (The catch lesson's moths wait at the player's height ahead of it
		# since the core loop's fix round 1 - on this straight line: they go,
		# so the pass is the staged bird's alone; and only the staged bird's
		# catch counts.)
		m.game_loop.release_lesson_prey()
		var prey := kit.stage_prey(species, ahead, BESIDE_SPANS * m.player.get_wingspan())
		var got := [false]
		var on_caught := func(pred: Bird, q: Bird) -> void:
			if pred == m.player and q == prey:
				got[0] = true
		Events.bird_caught.connect(on_caught)
		chase_passes += 1
		var passed := false
		var closest := [INF, Vector3.ZERO]
		var track := func() -> void:
			if is_instance_valid(prey):
				var r := prey.global_position - m.player.get_body_position()
				if r.length() < closest[0]:
					closest[0] = r.length()
					closest[1] = r
		m.get_tree().physics_frame.connect(track)
		for i in 40:
			await kit.advance(0.2)
			if got[0] and int(kit.stats()["catches"]) > catches:
				m.get_tree().physics_frame.disconnect(track)
				Events.bird_caught.disconnect(on_caught)
				flown_passes += 1
				kit.cruise()
				return true
			if not is_instance_valid(prey):
				break
			var rel := prey.global_position - m.player.get_body_position()
			if OS.get_cmdline_user_args().has("--trace"):
				print("[integration] chase t=%.1f rel=(%.2f %.2f %.2f)" % [i * 0.2, rel.x, rel.y, rel.z])
			# Behind the bird and going away: this pass missed.
			if rel.dot(m.player.velocity) < 0.0 and rel.length() > 1.5:
				passed = true
				break
		print("[integration] a %s pass missed (%s, closest %.2f m (%s), contact %.2f m, prey alive %s, protected %.1f s, hidden %s, sheltered %s); trying again" % [
			species, "passed" if passed else "timeout", closest[0], closest[1],
			m.game_loop.rule.contact_distance(m.player.get_body_radius(), m.player.get_wingspan(), true, prey.get_body_radius() if is_instance_valid(prey) else 0.0),
			is_instance_valid(prey) and prey.alive, m.game_loop.protection_left(prey) if is_instance_valid(prey) else -1.0,
			is_instance_valid(prey) and prey.hidden, is_instance_valid(prey) and m.game_loop.is_sheltered(prey, m.player.get_wingspan())])
		m.get_tree().physics_frame.disconnect(track)
		Events.bird_caught.disconnect(on_caught)
		if is_instance_valid(prey):
			kit.release(prey)
		kit.cruise()
		if closest[0] < FLOWN_PASS_M:
			# A pass that reached the bird and missed: no second chance.
			flown_passes += 1
			return false
	return false


func test_catch_a_moth_first_and_grow() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var ob := m.ui.onboarding
	await kit.advance(1.0)
	var mass0 := m.player.mass
	var grew := kit.count("player_grew")
	var bursts := m.fx.bursts
	var burst_at := []
	var on_catch := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player:
			burst_at.append(prey.get_body_position())
	Events.bird_caught.connect(on_catch)
	var cues := []
	m.audio.cue.connect(func(n: StringName, _i: Dictionary) -> void: cues.append(n))
	check(await _catch(&"moth"), "caught the moth through the catch rule")
	var caught: Array = kit.last.get("bird_caught", [])
	check(caught.size() == 2 and caught[0] == m.player, "Events.bird_caught with the player as predator")
	check(caught.size() == 2 and is_instance_valid(caught[1]) and (caught[1] as Bird).species == &"moth", "the prey was the moth")
	var gain := SizeRules.meal_gain(mass0, SizeRules.species_data(&"moth")["mass"])
	near(m.player.mass, mass0 + gain, 1e-5, "grew by exactly the meal's gain")
	eq(kit.count("player_grew"), grew + 1, "Events.player_grew once")
	Events.bird_caught.disconnect(on_catch)
	gt(m.fx.bursts, bursts, "feather bursts (BirdFXDirector)")
	var near_catch := 0
	for c in m.get_children():
		if c is FeatherBurst and not burst_at.is_empty() and (c as Node3D).global_position.distance_to(burst_at[0]) < 1.0:
			near_catch += 1
	eq(near_catch, 1, "one feather burst where the moth was caught")
	await kit.advance(0.2)
	check(cues.has(&"catch") or cues.has(&"crunch"), "audio played the catch (%s)" % [cues])
	check(await kit.wait_until(func() -> bool: return not ob.active, 3.0), "the catch lesson completed the tutorial")
	check(ob.is_done(), "the tutorial is remembered as done")
	eq(kit.stats()["catches_by_species"].get(&"moth", 0), 1, "run stats count the moth")
	metric("moth_gain_g", gain * 1000.0)


func test_grow_to_the_next_species() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var ws0 := m.player.origin.world_scale
	var tier0 := SizeRules.tier_for_mass(m.player.mass)
	var tiers := kit.count("player_tier_changed")
	var n := 0
	while SizeRules.tier_for_mass(m.player.mass) == tier0 and n < 8:
		if await _catch(&"wren"):
			n += 1
		else:
			break
	metric("wrens_to_tier_up", n)
	eq(SizeRules.tier_for_mass(m.player.mass), tier0 + 1, "a tier up")
	eq(kit.count("player_tier_changed"), tiers + 1, "Events.player_tier_changed once")
	var sp := SizeRules.species_for_mass(m.player.mass)
	eq(m.player.species, sp, "the player's species follows its mass")
	eq(sp, &"swallow", "a sparrow grows into a swallow")
	# The glue (integration round 2: mutants that broke these passed the
	# whole-game suite): the celebration the HUD actually shows...
	check(m.ui.hud.toast_active(), "the HUD shows the tier-up celebration")
	check(m.ui.hud.toast_text().contains("Swallow"), "...naming the new species: '%s'" % m.ui.hud.toast_text())
	await kit.advance(0.5)
	# ...and the flight model flying the new mass (bigger birds fly faster
	# and turn wider: the growth must reach FlightModel's parameters).
	near(m.player.model.params.mass, m.player.mass, 1e-6, "the flight model flies the new mass")
	near(m.player.model.params.span, SizeRules.wingspan_for_mass(m.player.mass), 0.02 * SizeRules.wingspan_for_mass(m.player.mass),
		"...and the new wingspan")
	# Growth is world_scale (VR's WorldScaleDriver ramps it), never node scale.
	await kit.advance(3.0)
	var want := WorldScaleDriver.target_scale(m.player.mass, m.rig_extras.world_scale_driver.arm_span())
	near(m.player.origin.world_scale, want, 0.01 * want, "world_scale followed the new wingspan")
	gt(m.player.origin.world_scale, ws0 * 1.2, "the world shrank around the player")
	vnear(m.player.origin.scale, Vector3.ONE, 1e-6, "the rig is never scaled")
	vnear(m.player.scale, Vector3.ONE, 1e-6, "the player node is never scaled")
	eq(m.rig_extras.wings.species_shown, &"swallow", "the first-person wings wear the swallow's colours")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_pause_freezes_play_but_not_the_rig() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	# The menu button (either controller, or Escape) arrives as this event.
	Events.menu_requested.emit()
	await kit.frames(2)
	eq(Game.state, Game.State.PAUSED, "the menu button paused")
	check(m.get_tree().paused, "the tree is paused")
	eq(kit.screen(), &"pause", "the pause screen is up")
	# Everything under the XROrigin3D keeps processing (head, hands, wings,
	# vignette, calibration, UI aim pointers): a frozen head pose is nauseating.
	var frozen := []
	for n in m.player.origin.find_children("*", "", true, false):
		if not n.can_process():
			frozen.append(n.name)
	check(m.player.origin.can_process() and frozen.is_empty(), "the whole rig processes while paused (frozen: %s)" % [frozen])
	check(m.ui.can_process() and m.audio.can_process(), "UI and audio run while paused")
	for n: Node in [m.player, m.ecosystem, m.game_loop, m.world]:
		check(not n.can_process(), "%s is paused" % n.name)
	# ...and gameplay really stands still.
	var pos := m.player.global_position
	var npcs := {}
	for b in m.ecosystem.get_npcs():
		npcs[b] = b.global_position
	var t_run := Game.run_time
	var probe := Node.new()
	probe.process_mode = Node.PROCESS_MODE_ALWAYS
	m.player.origin.add_child(probe)
	var rig_frames := [0]
	var count_rig := func() -> void:
		if m.player.origin.can_process():
			rig_frames[0] += 1
	m.get_tree().process_frame.connect(count_rig)
	await kit.frames(30)
	m.get_tree().process_frame.disconnect(count_rig)
	vnear(m.player.global_position, pos, 1e-6, "the player does not move while paused")
	var moved := 0
	for b in npcs:
		if is_instance_valid(b) and b.global_position.distance_to(npcs[b]) > 1e-6:
			moved += 1
	eq(moved, 0, "no NPC moves while paused")
	near(Game.run_time, t_run, 1e-6, "the run clock stops")
	gt(rig_frames[0], 25, "the rig kept processing frames")
	probe.queue_free()
	# Resume with the menu button again (a real second press: the UI ignores
	# two reports of one press within 250 ms of wall time).
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 300:
		await kit.frames(1)
	Events.menu_requested.emit()
	await kit.frames(2)
	eq(Game.state, Game.State.PLAYING, "the menu button resumed")
	await kit.advance(0.5)
	check(m.player.global_position.distance_to(pos) > 0.5, "flight goes on after resuming")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


## A predator strikes at the player along a straight line (the real catch
## rule on the player). Returns whether the player was caught.
func _get_caught(species := &"hawk") -> bool:
	var m := kit.main
	# The run's respawn protection is real; tests do not wait it out.
	if m.game_loop.protection_left(m.player) > 0.0:
		m.game_loop.set_protection(m.player, 0.0)
	kit.fly_straight()
	await kit.advance(1.0)
	var n := kit.count("player_caught")
	kit.stage_strike(species, 30.0, 12.0)
	var ok := await kit.wait_until(func() -> bool: return kit.count("player_caught") > n, 8.0)
	kit.free_staged()
	return ok


func test_caught_then_respawned_on_the_perch() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var lives: int = kit.stats()["lives"]
	# What the loop did, read the moment it did it.
	var penalty := {}
	var on_mass := func(old: float, new: float, reason: StringName) -> void:
		if reason == &"penalty":
			# (a lambda's captured locals are copies: fill the dictionary)
			penalty.merge({"old": old, "new": new, "want": maxf(GameLoop.START_MASS, old * (1.0 - m.game_loop.death_penalty()))}, true)
	var at_respawn := {}
	var spawn := m.world.get_player_spawn().origin
	var spawn_perch: Perch = null
	for pr in m.world.get_perches():
		if pr.position.distance_to(spawn) < 0.05:
			spawn_perch = pr
	# Who sat on the spawn perch just before the respawn looked for it.
	var sitter := {}
	var on_mass2 := func(_o: float, _n: float, reason: StringName) -> void:
		if reason == &"penalty" and spawn_perch != null:
			sitter.merge({"occupant": spawn_perch.occupant}, true)
	m.game_loop.player_mass_changed.connect(on_mass2)
	var on_respawn := func(protection: float) -> void:
		at_respawn.merge({"protection": protection, "left": m.game_loop.protection_left(m.player), "mode": m.player.mode_name(),
			"pos": m.player.global_position, "state": Game.state}, true)
	m.game_loop.player_mass_changed.connect(on_mass)
	m.game_loop.player_respawned.connect(on_respawn)
	check(await _get_caught(), "a hawk caught the player")
	eq(Game.state, Game.State.CAUGHT, "CAUGHT: the dramatic beat")
	var by: Array = kit.last.get("player_caught", [])
	check(by.size() >= 1 and is_instance_valid(by[0]) and (by[0] as Bird).species == &"hawk", "caught by the hawk")
	eq(kit.stats()["lives"], lives - 1, "a life lost")
	eq(kit.screen(), &"caught", "the caught screen")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, GameLoop.CAUGHT_BEAT_S + 1.0), "respawned after the beat")
	m.game_loop.player_mass_changed.disconnect(on_mass)
	m.game_loop.player_mass_changed.disconnect(on_mass2)
	m.game_loop.player_respawned.disconnect(on_respawn)
	check(not at_respawn.is_empty(), "GameLoop.player_respawned")
	check(Vector3(at_respawn.get("pos", Vector3.INF)).distance_to(spawn) < 1.0, "back at the spawn")
	# On the spawn perch: it is the player's (integration round 1: the AI's
	# Habitat.find_perches never offers it to an NPC; before, an NPC sitting
	# there left the player hovering beside it after a respawn).
	var occ: Variant = sitter.get("occupant")
	var taken: bool = occ != null and is_instance_valid(occ) and occ != m.player
	metric("respawn_perch_taken_by_npc", taken)
	check(not taken, "no NPC on the spawn perch at the respawn (%s)" % [occ])
	var mode: String = at_respawn.get("mode", "")
	eq(mode, "perched", "on the spawn perch at the respawn (mode %s)" % mode)
	gt(float(at_respawn.get("left", 0.0)), 0.0, "with brief protection (%.1f s)" % float(at_respawn.get("protection", 0.0)))
	check(not penalty.is_empty(), "a death penalty on the mass")
	if not penalty.is_empty():
		lt(float(penalty["new"]), float(penalty["old"]), "lost some size (%.4f -> %.4f kg)" % [penalty["old"], penalty["new"]])
		near(float(penalty["new"]), float(penalty["want"]), 1e-6, "by GameLoop.death_penalty()")
	eq(kit.screen(), &"", "no menu after the respawn")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_caught_until_the_run_ends() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var ended := kit.count("run_ended")
	var guard := 0
	while Game.state != Game.State.ENDED and guard < 6:
		guard += 1
		# Off the perch first (a completed downstroke launches).
		kit.set_mode(&"climb")
		await kit.advance(3.0)
		kit.set_mode(&"cruise")
		if not await _get_caught():
			break
		await kit.wait_until(func() -> bool: return Game.state != Game.State.CAUGHT, GameLoop.CAUGHT_BEAT_S + 1.0)
	eq(Game.state, Game.State.ENDED, "the run ended when the lives ran out")
	eq(kit.count("run_ended"), ended + 1, "Events.run_ended once")
	var summary: Dictionary = kit.last.get("run_ended", [{}])[0]
	eq(summary.get("reason"), &"caught", "ended by being caught")
	gt(float(summary.get("catches", 0)), 2.5, "the summary counts the catches")
	eq(summary.get("peak_species"), &"swallow", "and the peak size")
	gt(float(summary.get("score", 0)), 0.0, "a score")
	await kit.frames(3)
	eq(kit.screen(), &"summary", "the run summary is showing")
	check(not m.player.auto_process, "the body is still behind the summary")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_fly_again_resets_everything() -> void:
	if Game.state != Game.State.ENDED:
		fail("needs an ended run")
		return
	var m := kit.main
	var starts := kit.count("run_started")
	var eco_before: Dictionary = m.ecosystem.stats()
	check(await kit.click(&"summary", &"again"), "the pointer hovered Fly again")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "a new run")
	eq(kit.count("run_started"), starts + 1, "one run_started")
	var st := kit.stats()
	near(m.player.mass, GameLoop.START_MASS, 1e-6, "back to a sparrow")
	eq(m.player.species, &"sparrow", "the sparrow's species")
	eq(st["lives"], GameLoop.MAX_LIVES, "full lives")
	eq(st["catches"], 0, "no catches")
	eq(st["times_caught"], 0, "never caught")
	eq((st["catches_by_species"] as Dictionary).size(), 0, "no catches by species")
	# (The run ended at ~1 min of play; a few frames have passed since Play.)
	lt(float(st["run_time"]), 0.5, "the run clock restarted (%.2f s)" % float(st["run_time"]))
	lt(Game.run_time, 0.5, "Game.run_time restarted (%.2f s)" % Game.run_time)
	eq(st["peak_tier"], SizeRules.tier_for_mass(GameLoop.START_MASS), "peak size reset")
	var spawn := m.world.get_player_spawn().origin
	check(m.player.global_position.distance_to(spawn) < 1.0, "at the spawn")
	# VR's growth snaps back to the sparrow's world_scale at a run start.
	await kit.advance(0.1)
	var want := WorldScaleDriver.target_scale(GameLoop.START_MASS, m.rig_extras.world_scale_driver.arm_span())
	near(m.player.origin.world_scale, want, 0.001 * want, "world_scale snapped back to a sparrow's")
	eq(m.rig_extras.wings.species_shown, &"sparrow", "sparrow wings again")
	# The sky is rebuilt from the same seed.
	var eco: Dictionary = m.ecosystem.stats()
	check(int((eco["despawned"] as Dictionary).get("reset", 0)) == 0, "the ecosystem's stats restarted")
	await kit.wait_until(func() -> bool: return m.ecosystem.count() >= 50, 2.0)
	check(m.ecosystem.count() >= 50, "the sky repopulated (%d)" % m.ecosystem.count())
	eq(kit.screen(), &"", "no menu")
	check(m.ui.hud_panel.shown, "HUD up")
	check(not m.ui.onboarding.active, "no lessons for a player who finished them")
	check(m.game_loop.protection_left(m.player) > 0.0, "start protection")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
	metric("eco_spawned_before_restart", eco_before.get("spawned", 0))


## Restarts measured (integration round 2: four let a leak of 1 node and 3
## objects a restart through - the engineering verifier's mutant
## leak_small; the game is exactly flat in nodes and within +-3 objects from
## the second restart on).
const RESTARTS := 6
const NODE_SLACK := 0
const OBJECT_SLACK := 6
## The most objects the last restart may have gained on the second (NPC
## count corrected): a leak of 2 a restart gains 8 over the four between.
const OBJECT_TREND := 6
## Generous: an NPC's objects (its nodes, brain, flight, model resources).
const NPC_OBJECTS := 40


static func _subtree_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _subtree_nodes(ch)
	return c


## Nodes of the feather bursts still within their own lifetime (+0.5 s): the
## sky's NPCs catch each other ~10 times a minute near the player, and each
## catch's burst (BirdFXDirector, 2 nodes, 2.3 s) could cover a whole 1.5 s
## sample (a +2 node flake in the final round-2 run). A burst past its
## lifetime is not excluded: one that never frees itself is a leak.
static func _live_burst_nodes(root: Node) -> int:
	var c := 0
	for ch in root.get_children():
		if ch is FeatherBurst and (ch as FeatherBurst).age < (ch as FeatherBurst).lifetime + 0.5:
			c += _subtree_nodes(ch)
	return c


func test_restarts_leak_nothing() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	# Play a little (a catch: feathers, growth, a freed NPC), restart from
	# the pause menu (a 0.8 s hold), RESTARTS times; nodes, objects and
	# orphans must come back to the same level.
	var samples := []
	for i in RESTARTS:
		kit.fly_bot(30 + i)
		kit.set_mode(&"climb")
		await kit.advance(2.0)
		kit.set_mode(&"cruise")
		await _catch(&"moth", 30.0, 1)
		# (A staged moth the pass missed is the kit's, not the game's.)
		kit.free_staged()
		Events.menu_requested.emit()
		await kit.frames(2)
		eq(kit.screen(), &"pause", "paused (%d)" % i)
		check(await kit.hold(&"pause", &"restart"), "the pointer held Restart run (%d)" % i)
		check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0), "restarted (%d)" % i)
		# Let freed birds, feather bursts (2.3 s) and timers go.
		await kit.advance(2.6)
		# The least over 1.5 s: a bird caught a moment ago waits 0.5 s to be
		# freed (2 nodes), a burst lives 2.3 s - transients, not leaks; a
		# leak is there in every frame.
		var nmin := 1 << 30
		var omin := 1 << 30
		for f in 27:
			await kit.advance(1.0 / 18.0)
			nmin = mini(nmin, kit.nodes() - _live_burst_nodes(m))
			omin = mini(omin, kit.objects())
		samples.append([nmin, omin, kit.orphans(), m.ecosystem.count()])
	print("[integration] restart samples (nodes, objects, orphans, npcs): ", samples)
	# Tight bounds (integration round 1: a 5 % band let a leak of 20 nodes
	# per restart through; round 2: +-6 nodes and +-30 objects over four
	# restarts let 1 node and 3 objects a restart through). From the second
	# restart on, every sample has exactly the second one's nodes and stays
	# within OBJECT_SLACK objects of it, and the last within OBJECT_TREND,
	# plus what a different number of NPCs in the sky accounts for (one
	# NPC's own nodes, NPC_OBJECTS objects), so a steady leak of a node or
	# two objects per restart fails.
	var per_npc := _subtree_nodes(m.ecosystem.get_npcs()[0]) if m.ecosystem.count() > 0 else 0
	var n0: int = samples[1][0]
	var o0: int = samples[1][1]
	var k0: int = samples[1][3]
	for i in range(2, samples.size()):
		var dk: int = absi(int(samples[i][3]) - k0)
		lt(absf(samples[i][0] - n0), NODE_SLACK + per_npc * dk + 0.5, "nodes steady across restarts (%d vs %d; %d vs %d NPCs of %d nodes)" % [
			samples[i][0], n0, samples[i][3], k0, per_npc])
		lt(absf(samples[i][1] - o0), OBJECT_SLACK + NPC_OBJECTS * dk + 0.5, "objects steady across restarts (%d vs %d)" % [samples[i][1], o0])
	var last: Array = samples[samples.size() - 1]
	var dk_last: int = absi(int(last[3]) - k0)
	lt(float(last[1] - o0), OBJECT_TREND + NPC_OBJECTS * dk_last + 0.5, "objects do not creep over %d restarts (%d -> %d)" % [
		RESTARTS - 1, o0, last[1]])
	var orph: Array = samples.map(func(s: Array) -> int: return s[2])
	eq(orph.max(), orph.min(), "orphan nodes do not accumulate: %s" % [orph])
	metric("restart_nodes", samples.map(func(s: Array) -> int: return s[0]))
	metric("restart_objects", samples.map(func(s: Array) -> int: return s[1]))
	metric("restart_orphans", orph)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_quit_to_menu_then_quit() -> void:
	if Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	Events.menu_requested.emit()
	await kit.frames(2)
	check(await kit.hold(&"pause", &"quit_menu"), "the pointer held Quit to menu")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.MENU, 2.0), "back in the menu")
	eq(kit.screen(), &"main", "the main menu")
	check(not m.get_tree().paused, "not paused in the menu")
	check(not m.player.auto_process, "the body is still")
	check(m.player.global_position.distance_to(m.world.get_player_spawn().origin) < 1.0, "waiting on the spawn perch")
	var quits := [0]
	m.quit_started.connect(func() -> void: quits[0] += 1)
	check(await kit.click(&"main", &"quit"), "the pointer hovered Quit")
	await kit.frames(12)
	eq(quits[0], 0, "a single pull on the main menu's Quit does not quit (round 2: the resting laser lies on it)")
	check(await kit.hold(&"main", &"quit"), "the pointer held Quit")
	await kit.frames(12)
	eq(quits[0], 1, "Quit started the game's quit (audio shutdown, then quit)")
	check(not m.audio.is_processing(), "every sound stopped before quitting")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
	eq(kit.log.warnings, 0, "no warnings in the whole game: %s" % kit.log.summary())
	# For the record: every staged catch of the game on its first pass.
	metric("staged_catches", staged_catches)
	metric("staged_flown_passes", flown_passes)
