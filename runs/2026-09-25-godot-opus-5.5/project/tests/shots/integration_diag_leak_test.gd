extends TestCase
## DIAGNOSTIC (integration round 1, not in the unit suites): which nodes stay
## behind when staged NPCs are freed the way the soak frees them, versus
## through the Ecosystem's own removal. Prints the node classes (by path
## pattern) that grew.
##
##   tools/gd.sh fx_diag --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_diag_leak --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit


func before_all() -> void:
	kit = Kit.new()
	check(await kit.boot(self), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


static func _census(n: Node, out: Dictionary, depth := 0) -> void:
	var key := n.get_class()
	var s: Script = n.get_script()
	if s != null and s.get_global_name() != &"":
		key = String(s.get_global_name())
	var p := n.get_parent()
	var pk := "?"
	if p != null:
		pk = p.get_class()
		var ps: Script = p.get_script()
		if ps != null and ps.get_global_name() != &"":
			pk = String(ps.get_global_name())
	var k := "%s <- %s" % [key, pk]
	out[k] = int(out.get(k, 0)) + 1
	for c in n.get_children():
		_census(c, out, depth + 1)


func _diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var d := {}
	for k in b:
		var dv := int(b[k]) - int(a.get(k, 0))
		if dv != 0:
			d[k] = dv
	for k in a:
		if not b.has(k):
			d[k] = -int(a[k])
	return d


func test_staged_release_leak() -> void:
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	# A hawk-sized player, as in the soak's long cycle.
	m.game_loop._set_player_mass(m.player, 1.4, &"diag")
	kit.fly_bot(11)
	kit.set_mode(&"climb")
	await kit.advance(6.0)
	kit.set_mode(&"cruise")
	await kit.advance(4.0)
	var a := {}
	_census(get_tree().root, a)
	var n0 := kit.nodes()
	var o0 := kit.objects()
	for i in 12:
		var b := kit.stage_prey(&"gull", 30.0)
		kit.chase_bird(b)
		await kit.advance(6.0)
		kit.cruise()
		kit.free_staged()
		await kit.advance(3.0)
	var b2 := {}
	_census(get_tree().root, b2)
	print("[integration] staged release x12: nodes %d -> %d, objects %d -> %d" % [n0, kit.nodes(), o0, kit.objects()])
	print("[integration] grew: ", _diff(a, b2))
	metric("grew", _diff(a, b2))


## The soak's long hawk phase: the real AI hunting a hawk-sized player
## (unprotected strikes are not needed: nodes grew without deaths), staged
## gulls every 15 s, the cue followed; census every 60 s.
func test_hawk_phase_census() -> void:
	var m := kit.main
	if Game.state != Game.State.PLAYING:
		check(await kit.click(&"main", &"play"), "Play")
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.game_loop.set_protection(m.player, 1e6)
	m.game_loop._set_player_mass(m.player, 1.4, &"diag")
	kit.fly_bot(11)
	kit.set_mode(&"cruise")
	await kit.advance(10.0)
	var base := {}
	_census(get_tree().root, base)
	var n0 := kit.nodes()
	for minute in 5:
		for k in 4:
			var b := kit.stage_prey(&"gull", 30.0)
			kit.chase_bird(b)
			await kit.advance(12.0)
			kit.cruise()
			kit.free_staged()
			await kit.advance(3.0)
		var now := {}
		_census(get_tree().root, now)
		print("[integration] minute %d: nodes %d -> %d; grew %s" % [minute + 1, n0, kit.nodes(), _diff(base, now)])


## Does the kit's fly_bot (a new pilot, bot body and pose source each call)
## leave objects behind? The soak calls it once per run.
func test_fly_bot_objects() -> void:
	var m := kit.main
	if Game.state != Game.State.PLAYING:
		check(await kit.click(&"main", &"play"), "Play")
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	kit.fly_bot(1)
	await kit.advance(1.0)
	var o0 := kit.objects()
	for i in 30:
		kit.fly_bot(2 + i)
		await kit.advance(0.2)
	await kit.advance(1.0)
	print("[integration] fly_bot x30: objects %d -> %d (%+d)" % [o0, kit.objects(), kit.objects() - o0])


## Objects and resources over repeated runs (restart_run, a little play in
## between, a staged catch): where does ~4 objects a run go?
func test_objects_per_run() -> void:
	var m := kit.main
	if Game.state != Game.State.PLAYING:
		check(await kit.click(&"main", &"play"), "Play")
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	kit.fly_bot(3)
	var rows := []
	for r in 8:
		m.game_loop.restart_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
		kit.set_mode(&"climb")
		await kit.advance(6.0)
		m.game_loop.assist_override = 1.0
		var b := kit.stage_prey(&"moth", 20.0)
		kit.chase_bird(b)
		await kit.advance(6.0)
		kit.free_staged()
		kit.cruise()
		m.game_loop.assist_override = -1.0
		await kit.advance(3.0)
		rows.append([kit.objects(), int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)), kit.nodes(),
			snappedf(OS.get_static_memory_usage() / 1048576.0, 0.01)])
	print("[integration] per run [objects, resources, nodes, MB]: ", rows)


## Integration round 2: the soak's creep (~3-4 objects a whole run, nodes and
## resources flat, no script-held container growing) - is it the long play
## in the real sky (NPC churn, hunts, the show) alone? --long_s of cruising
## with a person's eyes (no staged prey, no victory, no menus) between
## restarts, --long_runs times; objects at the same moment of every run.
func test_objects_over_long_play() -> void:
	var m := kit.main
	if Game.state != Game.State.PLAYING:
		m.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	var runs := int(Paths.arg("long_runs", "8"))
	var play_s := float(Paths.arg("long_s", "180"))
	var rows := []
	for r in runs:
		m.game_loop.restart_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
		kit.fly_bot(5, preload("res://tests/unit/integration/integration_person_pilot.gd"))
		m.game_loop.set_protection(m.player, 1e6)
		kit.set_mode(&"climb")
		await kit.advance(3.0)
		kit.set_mode(&"cruise")
		kit.cruise()
		await kit.advance(5.0)
		var omin := 1 << 30
		for f in 18:
			await kit.advance(1.0 / 18.0)
			omin = mini(omin, kit.objects())
		rows.append([omin, kit.nodes(), int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)), m.ecosystem.count(),
			snappedf(OS.get_static_memory_usage() / 1048576.0, 0.01), int(m.ecosystem.stats().get("spawned", 0))])
		print("[integration] long play run %d start: %s" % [r, rows[-1]])
		await kit.advance(play_s)
	print("[integration] long play [objects, nodes, resources, npcs, MB, spawned]: ", rows)
	check(rows.size() == runs, "runs done")


## Integration round 2: the soak's "menus" segment grew +2..+4 objects every
## cycle (pause, Settings, back, How to fly, back, resume). The same menu
## round trips, repeated, with no play in between - objects after each
## (--menu_rounds, default 12), and the objects the menus alone keep.
func test_menu_round_trips() -> void:
	var m := kit.main
	if Game.state != Game.State.PLAYING:
		m.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	await kit.advance(2.0)
	var rows := []
	var steps := {}
	for r in int(Paths.arg("menu_rounds", "12")):
		var o0 := kit.objects()
		Events.menu_requested.emit()
		await kit.frames(3)
		var o_pause := kit.objects()
		for pair: Array in [[&"pause", &"settings"], [&"settings", &"back"], [&"pause", &"howto"], [&"howto", &"back"]]:
			var ob := kit.objects()
			await kit.click(pair[0], pair[1])
			await kit.frames(3)
			var k := "%s>%s" % pair
			steps[k] = int(steps.get(k, 0)) + kit.objects() - ob
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 300:
			await kit.frames(1)
		var o_menus := kit.objects()
		Events.menu_requested.emit()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0)
		await kit.frames(30)
		rows.append([o_pause - o0, o_menus - o_pause, kit.objects() - o0, kit.objects()])
	print("[integration] menu round trips [pause, menus, whole round, objects]: ", rows)
	print("[integration] menu steps (sum over rounds): ", steps)
	check(rows.size() > 2, "rounds done")
	metric("menu_rounds", rows)


## Integration round 2: menus are flat (test_menu_round_trips), restarts
## without a victory are flat, long play is flat - what the soak's cycle has
## on top is growth through every tier (the tier-up cards) and the victory
## summary with Fly again. The same, repeated with no play in between:
## objects at the same moment of every run (--victory_runs, default 8).
func test_objects_over_victories() -> void:
	var m := kit.main
	if Game.state != Game.State.PLAYING:
		m.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	kit.fly_bot(7)
	var rows := []
	var tiers := {}
	for r in int(Paths.arg("victory_runs", "8")):
		m.game_loop.set_protection(m.player, 1e6)
		kit.set_mode(&"climb")
		await kit.advance(3.0)
		var omin := 1 << 30
		for f in 18:
			await kit.advance(1.0 / 18.0)
			omin = mini(omin, kit.objects())
		var o_start := omin
		for sd: Dictionary in SizeRules.SPECIES:
			if float(sd["mass"]) <= m.player.mass:
				continue
			var ob := kit.objects()
			var mem0 := OS.get_static_memory_usage() / 1048576.0
			var g0 := _glyph_pages()
			m.game_loop._set_player_mass(m.player, float(sd["mass"]) * 1.01, &"diag")
			await kit.advance(4.0)
			var dm := OS.get_static_memory_usage() / 1048576.0 - mem0
			if absf(dm) > 0.5:
				print("[integration] STEP %+.2f MB at the tier-up to %s (run %d); glyph pages %s -> %s" % [dm, sd["id"], r, g0, _glyph_pages()])
			tiers[sd["id"]] = int(tiers.get(sd["id"], 0)) + kit.objects() - ob
		var o_grown := kit.objects()
		print("[integration] victory run %d grown: mem %.2f MB, glyph pages %s" % [r, OS.get_static_memory_usage() / 1048576.0, _glyph_pages()])
		m.game_loop.end_run(&"victory")
		await kit.advance(2.0)
		var o_summary := kit.objects()
		var again := await kit.click(&"summary", &"again")
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
		rows.append([o_start, o_grown - o_start, o_summary - o_grown, again, m.ecosystem.count()])
		print("[integration] victory run %d: %s" % [r, rows[-1]])
	print("[integration] victories [objects at start, growth, summary, again, npcs]: ", rows)
	print("[integration] per tier-up (sum over runs): ", tiers)
	check(rows.size() > 2, "runs done")
	metric("victory_runs", rows)


## The soak's staged strike (caught screen, a life lost, the respawn),
## repeated: objects at the same moment after every respawn (lives topped
## up so the run goes on; --strikes, default 10).
func test_objects_over_deaths() -> void:
	var m := kit.main
	if Game.state != Game.State.PLAYING:
		m.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop.restart_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	kit.fly_bot(9)
	var rows := []
	var deaths := [0]
	var on_death := func(_by: Variant = null, _a: Variant = null) -> void:
		deaths[0] += 1
	Events.player_caught.connect(on_death)
	for r in int(Paths.arg("strikes", "10")):
		m.game_loop.set_protection(m.player, 0.0)
		m.game_loop._respite_until = 0.0
		kit.set_mode(&"climb")
		await kit.advance(4.0)
		kit.set_mode(&"cruise")
		await kit.advance(2.0)
		var d0: int = deaths[0]
		kit.stage_strike(&"eagle", 30.0, 14.0)
		await kit.wait_until(func() -> bool: return deaths[0] > d0 or kit.strike.is_empty(), 12.0)
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING and m.player.mode_name() != "", 10.0)
		kit.free_staged()
		if "lives" in m.game_loop:
			m.game_loop.set(&"lives", 3)
		await kit.advance(5.0)
		var omin := 1 << 30
		for f in 18:
			await kit.advance(1.0 / 18.0)
			omin = mini(omin, kit.objects())
		rows.append([omin, deaths[0] - d0, m.ecosystem.count(), Game.state_name()])
		print("[integration] death %d: %s" % [r, rows[-1]])
	Events.player_caught.disconnect(on_death)
	print("[integration] deaths [objects after the respawn, died, npcs, state]: ", rows)
	check(rows.size() > 2, "strikes done")
	metric("death_rows", rows)


## Glyph cache pages of the game's font (the UI's Nunito, every size it was
## drawn at): [sizes, textures, texture bytes].
static func _glyph_pages() -> Array:
	var ts := TextServerManager.get_primary_interface()
	var base := load(UITheme.FONT_PATH) as FontFile
	if base == null:
		return [0, 0, 0]
	var sizes := 0
	var tex := 0
	var bytes := 0
	for rid: RID in base.get_rids():
		for sz: Vector2i in ts.font_get_size_cache_list(rid):
			sizes += 1
			var n := ts.font_get_texture_count(rid, sz)
			tex += n
			for i in n:
				var img: Image = ts.font_get_texture_image(rid, sz, i)
				if img != null:
					bytes += img.get_data_size()
	return [sizes, tex, bytes]
