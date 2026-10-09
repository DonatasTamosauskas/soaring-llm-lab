extends TestCase
## VERIFIER PROBE (integration round 1, engineering lens). Not part of the
## shipped suites. Boots the real scenes/main.tscn through the integration kit
## and checks ARCHITECTURE §3/§4/§7 facts the whole-game suites do not pin:
## singleton groups, one XR rig/camera after boot, static process modes,
## the rig and its ancestors never scaled at every species, camera near/far,
## pause during CAUGHT -> Quit to menu -> Play, the respawn with the spawn
## perch taken, and the AI's freed-threat error through the Ecosystem's own
## removal path.
##
##   tools/gd.sh v1probe --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=v1_composition --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _count_type(root: Node, cls: String) -> int:
	var n := 0
	for c in root.find_children("*", cls, true, false):
		n += 1
	return n


func test_groups_rigs_cameras() -> void:
	if not check(booted, "booted"):
		return
	var m := kit.main
	for g in [&"world", &"player_rig", &"player", &"ecosystem", &"game_loop", &"ui_root", &"audio_director"]:
		var nodes := m.get_tree().get_nodes_in_group(g)
		eq(nodes.size(), 1, "exactly one node in group %s (%s)" % [g, nodes])
	eq(m.get_tree().get_first_node_in_group(&"player_rig"), m.player.origin, "player_rig is the player's XROrigin3D")
	var root := m.get_tree().root
	eq(_count_type(root, "XROrigin3D"), 1, "one XROrigin3D in the tree after boot (the boot rig is gone)")
	eq(root.get_viewport().get_camera_3d(), m.player.camera, "the viewport's camera is the player's head")
	check(m.player.origin.current, "the player's origin is current")
	eq(_count_type(root, "WorldEnvironment"), 1, "one WorldEnvironment (boot sky replaced by the world's)")
	eq(Birds.all().size(), m.ecosystem.count() + 1, "Birds registry = NPCs + the player")
	metric("xr_origins", _count_type(root, "XROrigin3D"))


func test_static_process_modes() -> void:
	if not booted:
		return
	var m := kit.main
	eq(m.player.origin.process_mode, Node.PROCESS_MODE_ALWAYS, "XROrigin3D ALWAYS")
	var not_always := []
	for n in m.player.origin.find_children("*", "", true, false):
		if n.process_mode != Node.PROCESS_MODE_ALWAYS and n.process_mode != Node.PROCESS_MODE_INHERIT:
			not_always.append("%s=%d" % [n.name, n.process_mode])
	check(not_always.is_empty(), "nothing under the rig overrides ALWAYS: %s" % [not_always])
	eq(m.ui.process_mode, Node.PROCESS_MODE_ALWAYS, "UI ALWAYS")
	eq(m.audio.process_mode, Node.PROCESS_MODE_ALWAYS, "Audio ALWAYS")
	eq(VR.process_mode, Node.PROCESS_MODE_ALWAYS, "VR autoload ALWAYS")
	for n: Node in [m.world, m.ecosystem, m.player, m.game_loop, m.fx]:
		check(n.process_mode != Node.PROCESS_MODE_ALWAYS, "%s pausable (mode %d)" % [n.name, n.process_mode])


func _ancestor_scales() -> Array:
	var bad := []
	var n: Node = kit.main.player.origin
	while n != null:
		if n is Node3D:
			var s := (n as Node3D).transform.basis.get_scale()
			if not s.is_equal_approx(Vector3.ONE):
				bad.append("%s %s" % [n.name, s])
		n = n.get_parent()
	var gs := kit.main.player.origin.global_basis.get_scale()
	if not gs.is_equal_approx(Vector3.ONE):
		bad.append("origin global %s" % gs)
	return bad


func test_rig_never_scaled_at_any_size() -> void:
	if not booted:
		return
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play hovered")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "PLAYING")
	eq(_ancestor_scales(), [], "no scale on the rig or its ancestors (sparrow)")
	var rows := []
	for sp: Dictionary in SizeRules.SPECIES:
		var id: StringName = sp["id"]
		if SizeRules.species_index(id) < SizeRules.species_index(&"sparrow"):
			continue
		m.game_loop.set_protection(m.player, 1e6)
		m.game_loop._set_player_mass(m.player, float(sp["mass"]) * 1.02, &"meal")
		await kit.advance(4.0)
		var ws: float = m.player.origin.world_scale
		var near: float = m.player.camera.near
		rows.append([String(id), snappedf(ws, 0.001), snappedf(near, 0.0001), snappedf(near / ws, 0.0001), m.player.camera.far])
		eq(_ancestor_scales(), [], "no scale on the rig or its ancestors (%s)" % id)
		check(near / ws >= 0.019 and near / ws <= 0.051, "near %.4f = %.3f x world_scale %.3f (%s)" % [near, near / ws, ws, id])
		check(m.player.camera.far <= 3000.0, "far %.0f <= 3000 (%s)" % [m.player.camera.far, id])
		eq(m.player.species, id, "species follows the mass (%s)" % id)
	print("[integration-verify] species, world_scale, near, near/ws, far: ", rows)
	metric("scale_rows", rows)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func _strike() -> bool:
	var m := kit.main
	m.game_loop.set_protection(m.player, 0.0)
	m.game_loop._respite_until = -1.0
	kit.fly_bot(5)
	kit.set_mode(&"climb")
	await kit.advance(2.0)
	kit.set_mode(&"cruise")
	kit.fly_straight()
	await kit.advance(1.0)
	var n := kit.count("player_caught")
	kit.stage_strike(&"eagle", 30.0, 14.0)
	var ok := await kit.wait_until(func() -> bool: return kit.count("player_caught") > n, 8.0)
	kit.free_staged()
	return ok


func test_pause_in_caught_quit_to_menu_then_play() -> void:
	if not booted or Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	# Back to a sparrow so an eagle can take it.
	m.game_loop._set_player_mass(m.player, GameLoop.START_MASS, &"reset")
	await kit.advance(0.5)
	check(await _strike(), "an eagle caught the player")
	eq(Game.state, Game.State.CAUGHT, "CAUGHT")
	Events.menu_requested.emit()
	await kit.frames(2)
	eq(Game.state, Game.State.PAUSED, "paused mid-beat")
	check(await kit.hold(&"pause", &"quit_menu"), "held Quit to menu")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.MENU, 2.0), "MENU")
	check(not m.player.auto_process, "body still in the menu")
	check(m.player.global_position.distance_to(m.world.get_player_spawn().origin) < 1.0, "at the spawn in the menu")
	# Wait longer than the caught beat: nothing from the abandoned run fires.
	var states := []
	var on_state := func(s: int, _o: int) -> void: states.append(Game.state_name(s))
	Events.game_state_changed.connect(on_state)
	await kit.advance(GameLoop.CAUGHT_BEAT_S + 1.5)
	eq(states, [], "no state change from the abandoned beat while in the menu")
	check(await kit.click(&"main", &"play"), "Play hovered")
	check(await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0), "a new run")
	Events.game_state_changed.disconnect(on_state)
	eq(kit.stats()["lives"], GameLoop.MAX_LIVES, "full lives")
	check(m.player.alive, "the player is alive")
	check(m.player.auto_process, "the body flies")
	await kit.advance(GameLoop.CAUGHT_BEAT_S + 1.0)
	eq(Game.state, Game.State.PLAYING, "still PLAYING a beat later")
	eq(kit.stats()["lives"], GameLoop.MAX_LIVES, "still full lives")
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_respawn_with_the_spawn_perch_taken() -> void:
	if not booted or Game.state != Game.State.PLAYING:
		fail("needs a run")
		return
	var m := kit.main
	var spawn := m.world.get_player_spawn().origin
	var perch: Perch = null
	for pr in m.world.get_perches():
		if pr.position.distance_to(spawn) < 0.05:
			perch = pr
	if not check(perch != null, "the spawn is a perch"):
		return
	check(await _strike(), "caught")
	# An NPC sits on the spawn perch when the respawn looks for it.
	var sitter := kit.stage_bird(&"wren", perch.position + Vector3(0, 0.05, 0), Vector3.FORWARD)
	perch.occupant = sitter
	var at := {}
	var on_resp := func(_p: float) -> void:
		at.merge({"mode": m.player.mode_name(), "pos": m.player.global_position}, true)
	m.game_loop.player_respawned.connect(on_resp)
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, GameLoop.CAUGHT_BEAT_S + 1.0)
	m.game_loop.player_respawned.disconnect(on_resp)
	print("[integration-verify] respawn with the spawn perch taken: ", at)
	metric("respawn_taken_mode", at.get("mode", "?"))
	await kit.advance(2.0)
	metric("respawn_taken_mode_2s", m.player.mode_name())
	metric("respawn_taken_drop_2s", Vector3(at.get("pos", Vector3.ZERO)).y - m.player.global_position.y)
	print("[integration-verify] 2 s later: mode %s, dropped %.2f m" % [m.player.mode_name(), Vector3(at.get("pos", Vector3.ZERO)).y - m.player.global_position.y])
	check(true, "recorded")
	perch.occupant = null
	kit.free_staged()


## Last: provokes the AI defect through the Ecosystem's own removal path.
func test_freed_threat_through_ecosystem_remove() -> void:
	if not booted:
		return
	var m := kit.main
	kit.log.clear()
	# A flock whose members are fleeing a hunter; the hunter is then removed
	# the way the Ecosystem removes any bird (despawn, caught).
	# One bird of every flock has just bolted from the hunter (FLEE, fresh);
	# its mates, still calm, read that alarm in NpcBrain._sense.
	var flocks := []
	for b in m.ecosystem.get_npcs():
		if b.flock != null and b.flock.size() >= 3 and not flocks.has(b.flock):
			flocks.append(b.flock)
	if not check(not flocks.is_empty(), "flocks exist (%d)" % flocks.size()):
		return
	var hunter: NpcBird = null
	for b in m.ecosystem.get_npcs():
		if b.flock == null and b.can_eat((flocks[0] as FlockGroup).members[0]):
			hunter = b
			break
	if not check(hunter != null, "a hunter exists"):
		return
	var set_n := 0
	for fl: FlockGroup in flocks:
		var m0: NpcBird = fl.members[0]
		if is_instance_valid(m0) and hunter.can_eat(m0):
			m0.threat = hunter
			m0.state = NpcBird.State.FLEE
			m0.state_time = 0.1
			set_n += 1
	metric("flocks_alarmed", set_n)
	m.ecosystem._remove(hunter, &"far")
	for i in 90:
		# Keep the bolted birds' alarms fresh for the mates' next thinks.
		for fl: FlockGroup in flocks:
			var m0: Variant = fl.members[0] if fl.members.size() > 0 else null
			if m0 != null and is_instance_valid(m0) and m0.state == NpcBird.State.FLEE:
				m0.state_time = 0.1
		await kit.advance(1.0 / 72.0)
	metric("freed_threat_errors", kit.log.errors)
	print("[integration-verify] errors after the Ecosystem removed a fled-from hunter: %s" % kit.log.summary())
	eq(kit.log.errors, 0, "no SCRIPT ERROR after a fled-from hunter is removed: %s" % kit.log.summary())
	kit.log.clear()
