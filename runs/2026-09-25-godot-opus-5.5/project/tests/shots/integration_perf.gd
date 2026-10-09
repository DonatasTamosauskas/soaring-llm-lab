extends Node
## Performance of the COMPOSED game (integration), run inside main.tscn:
##
##   # CPU per system, headless (60 NPCs, the bot flying, sparrow/pigeon/eagle):
##   tools/gd.sh integ --headless --fixed-fps 72 res://scenes/main.tscn -- --harness=perf --perf=cpu --fresh-settings
##   # CPU per system and draw calls / primitives from 12 viewpoints, rendered
##   # (Mobile renderer, what the Quest runs; Forward+ adds a depth prepass):
##   tools/gd.sh integ --fixed-fps 72 --resolution 1280x720 res://scenes/main.tscn -- --harness=perf --perf=all --fresh-settings
##   # the Quest quality tier, measured on the Mac:
##   ... -- --harness=perf --perf=cpu --quality=quest
##
## Writes artifacts/integration/perf_<tag>.json and prints a table. Per
## system (ms per frame, one physics tick per frame at 72 Hz):
##   flight     PlayerBird.tick (its own timer)
##   ai         the Ecosystem's step: every NPC's brain and flight
##   gameloop   GameLoop.step (catch rule, threat/target watch)
##   ui         UIRoot and its panels, pointer, HUD, cues, lessons
##   audio      the AudioDirector's frame
##   vr         every VR script (VRProfile: calibration, wings, vignette,
##              world scale, haptics, controls)
##   birds      the birds' draw sync (BirdBatch, frame_pre_draw; headless has
##              no draw, so there it is run once per frame by this probe)
##   world      the world's per-frame work (terrain LOD, wind)
## Subtree costs come from bracket nodes placed right before and after each
## system in the tree (Godot processes nodes of one priority in tree order).

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const SYSTEMS := ["World", "Ecosystem", "Player", "GameLoop", "UI", "Audio"]

var main: GameMain
var kit: Kit
var mode := "cpu"
var tag := ""
var result := {}
var _brackets := {}
var _headless := false


class _Bracket:
	extends Node
	var first := true
	var partner: _Bracket
	var t_proc := 0
	var t_phys := 0
	var proc_us := 0
	var phys_us := 0
	## Span pair only: the end of the last physics callback, and the time
	## from there to the first process callback (the physics server's step
	## and the message queue), accumulated.
	var t_phys_end := 0
	var between_us := 0
	var between_n := 0

	func _init(is_first: bool) -> void:
		first = is_first
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_dt: float) -> void:
		if first:
			t_proc = Time.get_ticks_usec()
			if partner_end != null and partner_end.t_phys_end > 0:
				partner_end.between_us += t_proc - partner_end.t_phys_end
				partner_end.between_n += 1
				partner_end.t_phys_end = 0
		elif partner.t_proc > 0:
			proc_us += Time.get_ticks_usec() - partner.t_proc
			partner.t_proc = 0

	func _physics_process(_dt: float) -> void:
		if first:
			t_phys = Time.get_ticks_usec()
		elif partner.t_phys > 0:
			var now := Time.get_ticks_usec()
			phys_us += now - partner.t_phys
			partner.t_phys = 0
			t_phys_end = now

	## (the span's first bracket knows its last one)
	var partner_end: _Bracket


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = get_parent() as GameMain
	mode = Paths.arg("perf", "cpu")
	_headless = DisplayServer.get_name() == "headless"
	tag = Paths.arg("perf_tag", "%s_%s_%s" % [mode, "headless" if _headless else "rendered", main.quality.name])
	if not main.is_loaded:
		await main.loaded
	await get_tree().process_frame
	_run.call_deferred()


func _run() -> void:
	kit = Kit.new()
	kit.attach(self, main)
	# Headless idles 6.9 ms a frame; measure the work, not the nap.
	OS.low_processor_usage_mode_sleep_usec = 500
	main.ui.set_vr_mode(true)
	kit.left = UIPointerSource.new(&"left_hand")
	kit.right = UIPointerSource.new(&"right_hand")
	main.ui.set_pointer_sources(kit.left, kit.right)
	kit.park_hands()
	_add_brackets()
	VRProfile.enabled = true
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	result = {"tag": tag, "quality": main.quality.describe(), "headless": _headless,
		"load": main.load_report, "machine_load": _load_avg(), "renderer": RenderingServer.get_current_rendering_method()}
	# Start a run the way the menu does.
	main.ui.onboarding.skip()
	main.game_loop.start_run()
	await kit.advance(0.5)
	kit.fly_bot(3)
	if mode == "cpu" or mode == "all":
		result["cpu"] = {}
		var secs := float(Paths.arg("perf_seconds", "30"))
		for sz: Array in [[&"sparrow", 0.03, 2.0 * secs], [&"pigeon", 0.33, secs], [&"eagle", 3.2, secs]]:
			result["cpu"][String(sz[0])] = await _measure_cpu(sz[0], sz[1], sz[2])
	if (mode == "draw" or mode == "all") and not _headless:
		result["views"] = await _measure_views()
	_write()
	print("[integration] perf done at %d ms" % Time.get_ticks_msec())
	# Quit the way the game does (the harness lives inside main: it must not
	# free it).
	if kit.log.errors > 0 or kit.log.warnings > 0:
		print("[integration] perf run logged ", kit.log.summary())
	kit.log.uninstall()
	main.quit_for_real = true
	main.quit_game()


func _add_brackets() -> void:
	# The whole script span (every node's callbacks, autoloads included):
	# first and last by priority, at the root.
	var sa := _Bracket.new(true)
	var sb := _Bracket.new(false)
	sb.partner = sa
	sa.partner_end = sb
	sa.name = "PerfSpanA"
	sb.name = "PerfSpanB"
	sa.process_priority = -100000
	sa.process_physics_priority = -100000
	sb.process_priority = 100000
	sb.process_physics_priority = 100000
	get_tree().root.add_child.call_deferred(sa)
	get_tree().root.add_child.call_deferred(sb)
	_brackets["_span"] = sb
	for sname: String in SYSTEMS:
		var sys := main.get_node_or_null(NodePath(sname))
		if sys == null:
			continue
		var a := _Bracket.new(true)
		var b := _Bracket.new(false)
		b.partner = a
		a.name = "PerfA_" + sname
		b.name = "PerfB_" + sname
		# Same priorities as the system, so they run right around it.
		a.process_priority = sys.process_priority
		b.process_priority = sys.process_priority
		a.process_physics_priority = sys.process_physics_priority
		b.process_physics_priority = sys.process_physics_priority
		main.add_child(a)
		main.move_child(a, sys.get_index())
		main.add_child(b)
		main.move_child(b, sys.get_index() + 1)
		_brackets[sname] = b


func _reset_counters() -> void:
	for b: _Bracket in _brackets.values():
		b.proc_us = 0
		b.phys_us = 0
		b.between_us = 0
		b.between_n = 0
	VRProfile.reset()
	main.audio.reset_perf()


## Flies `seconds` of play at a size and returns ms per frame per system.
func _measure_cpu(species: StringName, mass: float, seconds: float) -> Dictionary:
	print("[integration] perf phase %s at %d ms" % [species, Time.get_ticks_msec()])
	var p := main.player
	if not is_equal_approx(p.mass, mass):
		# (A probe's shortcut: growth goes through GameLoop in the game.)
		p.mass = mass
		p.species = SizeRules.species_for_mass(mass)
	main.game_loop.set_protection(p, 1e6)
	kit.cruise()
	# Let the plan re-balance for the new size and the flight settle.
	await kit.advance(8.0)
	_reset_counters()
	print("[integration] perf measuring %s at %d ms" % [species, Time.get_ticks_msec()])
	var frames := 0
	var flight_us := 0
	var eco_us := 0
	var loop_us := 0
	var birds_us := 0
	var proc_total := 0.0
	var phys_total := 0.0
	var render_cpu := 0.0
	var engaged := 0
	var ticks0: int = p.tick_count
	var n := int(seconds * 72.0)
	var eco_tick_us: Array = []
	for i in n:
		# Chase what the target cue shows, like a player.
		var tgt: Array = kit.last.get("target_changed", [])
		if kit.chase_target == null and tgt.size() > 0 and tgt[0] is NpcBird and is_instance_valid(tgt[0]):
			kit.chase_bird(tgt[0])
		if p.mode_name() != "flying":
			kit.set_mode(&"climb")
		else:
			kit.set_mode(&"cruise")
		await get_tree().process_frame
		frames += 1
		flight_us += int(p.tick_us)
		loop_us += int(main.game_loop.perf.get("total", 0))
		if _headless:
			var t0 := Time.get_ticks_usec()
			BirdBatch.sync_all(1.0 / 72.0)
			birds_us += Time.get_ticks_usec() - t0
		else:
			birds_us += BirdBatch.last_sync_usec
		var pt := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var ph := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		proc_total += pt
		phys_total += ph
		if not _headless:
			render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid()) \
				+ RenderingServer.get_frame_setup_time_cpu()
	var st: Dictionary = main.ecosystem.stats()
	var f := float(frames)
	var ticks := float(p.tick_count - ticks0)
	var vr_us := 0.0
	var rep: Dictionary = VRProfile.report()
	for k in VRProfile.usec:
		vr_us += float(VRProfile.usec[k])
	var b: Dictionary = {}
	for sname in _brackets:
		var br: _Bracket = _brackets[sname]
		b[sname] = {"process_ms": br.proc_us / 1000.0 / f, "physics_ms": br.phys_us / 1000.0 / f}
	var span: Dictionary = b.get("_span", {"process_ms": 0.0, "physics_ms": 0.0})
	var out := {
		"species": species, "frames": frames, "ticks_per_frame": ticks / f,
		"npcs": main.ecosystem.count(), "npc_lod": st.get("lod", []), "npc_states": st.get("by_state", {}),
		"flight_ms": flight_us / 1000.0 / f,
		"ai_ms": float(b.get("Ecosystem", {}).get("physics_ms", 0.0)) + float(b.get("Ecosystem", {}).get("process_ms", 0.0)),
		"ai_eco_tick_ms_avg": st.get("tick_ms_avg", 0.0), "ai_eco_tick_ms_p95": st.get("tick_ms_p95", 0.0),
		"gameloop_ms": loop_us / 1000.0 / f,
		"ui_ms": float(b.get("UI", {}).get("process_ms", 0.0)) + float(b.get("UI", {}).get("physics_ms", 0.0)),
		"audio_ms": float(b.get("Audio", {}).get("process_ms", 0.0)) + float(b.get("Audio", {}).get("physics_ms", 0.0)),
		"audio_director_median_ms": main.audio.perf_stats().get("median", 0.0),
		"vr_ms": vr_us / 1000.0 / f,
		"vr_report": rep,
		"birds_sync_ms": birds_us / 1000.0 / f,
		"world_ms": float(b.get("World", {}).get("process_ms", 0.0)) + float(b.get("World", {}).get("physics_ms", 0.0)),
		"player_subtree_ms": float(b.get("Player", {}).get("process_ms", 0.0)) + float(b.get("Player", {}).get("physics_ms", 0.0)),
		"brackets": b,
		"engine_process_ms": 0.0, "engine_physics_ms": 0.0,
		"render_cpu_ms": render_cpu / f,
		# Every script callback of the frame (all nodes, autoloads), and what
		# the engine spent outside them (physics server step, message queue).
		"scripts_physics_ms": span["physics_ms"], "scripts_process_ms": span["process_ms"],
		"physics_step_ms": (_brackets["_span"] as _Bracket).between_us / 1000.0 / maxf((_brackets["_span"] as _Bracket).between_n, 1.0),
		# (Performance TIME_PROCESS / TIME_PHYSICS_PROCESS are the worst
		# frame of each second, not means.)
		"engine_process_max_per_s_ms": proc_total / f, "engine_physics_max_per_s_ms": phys_total / f,
	}
	out.erase("engine_process_ms")
	out.erase("engine_physics_ms")
	var logic := float(out["flight_ms"]) + float(out["ai_ms"]) + float(out["gameloop_ms"]) + float(out["ui_ms"]) \
		+ float(out["audio_ms"]) + float(out["vr_ms"]) + float(out["birds_sync_ms"]) + float(out["world_ms"])
	out["game_logic_ms"] = logic
	out["quest_estimate_ms"] = [logic * 3.0, logic * 4.0]
	print("[integration] perf %-8s %d NPCs: flight %.3f  ai %.3f  loop %.3f  ui %.3f  audio %.3f  vr %.3f  birds %.3f  world %.3f  = %.2f ms/frame (Quest ~%.1f-%.1f ms); all scripts: physics %.2f + process %.2f; physics step %.2f; render-cpu %.2f" % [
		species, out["npcs"], out["flight_ms"], out["ai_ms"], out["gameloop_ms"], out["ui_ms"], out["audio_ms"], out["vr_ms"],
		out["birds_sync_ms"], out["world_ms"], logic, logic * 3.0, logic * 4.0, out["scripts_physics_ms"], out["scripts_process_ms"],
		out["physics_step_ms"], out["render_cpu_ms"]])
	return out


## Draw calls and primitives from the head camera at twelve places (the
## busiest the game has): the NPC population refilled round the player,
## the UI in its VR form (3D panels, what the headset draws).
func _measure_views() -> Array:
	var w := main.world
	var g := func(x: float, z: float) -> float: return w.ground_height(x, z)
	var fc := WorldLayout.FOREST
	var views := [
		["menu_on_the_spawn_roof", "menu", 0.03, Vector3.INF, 0.0, 0.0],
		["village_street_hud", "hud", 0.03, Vector3(-150, g.call(-150, 30) + 12, 30), deg_to_rad(-90), -0.1],
		["over_the_square_looking_down", "hud", 0.03, Vector3(-60, g.call(-60, 30) + 40, 60), deg_to_rad(-60), -0.6],
		["old_wood_canopy_skim", "hud", 0.5, Vector3(fc.x + 120, g.call(fc.x + 120, fc.y + 40) + 18, fc.y + 40), deg_to_rad(-100), -0.15],
		["inside_the_old_wood", "hud", 0.03, Vector3(fc.x, g.call(fc.x, fc.y) + 5, fc.y), 0.0, 0.0],
		["orchard_and_power_line", "hud", 0.1, Vector3(-60, g.call(-60, 150) + 20, 150), deg_to_rad(150), -0.2],
		["lake_and_bridge", "hud", 0.3, Vector3(60, g.call(60, 120) + 25, 120), deg_to_rad(30), -0.2],
		["cliff_colony", "hud", 0.055, Vector3(-400, 40, 130), deg_to_rad(90), 0.0],
		["canyon", "hud", 1.3, Vector3(135, g.call(135, -300) + 30, -300), deg_to_rad(-10), -0.1],
		["high_over_the_valley", "hud", 3.2, Vector3(0, 280, 0), deg_to_rad(-135), -0.4],
		["pause_menu_over_the_old_wood", "pause", 0.5, Vector3(fc.x + 120, g.call(fc.x + 120, fc.y + 40) + 18, fc.y + 40), deg_to_rad(-100), -0.15],
		["eagle_over_the_village", "hud", 3.2, Vector3(-95, g.call(-95, 30) + 60, 110), deg_to_rad(180), -0.35],
	]
	var out := []
	var p := main.player
	for v: Array in views:
		var vname: String = v[0]
		var ui_state: String = v[1]
		if Game.state == Game.State.PAUSED:
			Events.menu_requested.emit()
			await _wall_ms(300)
		if ui_state == "menu":
			main.game_loop.to_menu()
			await kit.frames(3)
		elif Game.state != Game.State.PLAYING:
			main.game_loop.start_run()
			main.ui.onboarding.skip()
			await kit.frames(3)
			kit.fly_bot(3)
		if ui_state != "menu":
			p.mass = float(v[2])
			p.species = SizeRules.species_for_mass(p.mass)
			main.game_loop.set_protection(p, 1e6)
			p.start_flying(v[3], float(v[4]), 0.0)
		# Freeze the body where it is (the camera looks where we set it) and
		# let the sky refill round it.
		p.auto_process = false
		await kit.advance(7.0)
		_look(float(v[5]))
		if ui_state == "pause":
			Events.menu_requested.emit()
			await kit.frames(6)
		await kit.frames(4)
		var dc_sum := 0.0
		var pr_sum := 0.0
		var dc_max := 0
		var pr_max := 0
		for i in 40:
			await RenderingServer.frame_post_draw
			var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			var pr := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
			dc_sum += dc
			pr_sum += pr
			dc_max = maxi(dc_max, dc)
			pr_max = maxi(pr_max, pr)
		var cam := p.camera
		var in_view := 0
		for b in main.ecosystem.get_npcs():
			if cam.is_position_in_frustum(b.global_position):
				in_view += 1
		var row := {"view": vname, "ui": ui_state, "species": SizeRules.species_for_mass(p.mass),
			"draw_calls_mean": dc_sum / 40.0, "draw_calls_max": dc_max,
			"primitives_mean": pr_sum / 40.0, "primitives_max": pr_max,
			"npcs": main.ecosystem.count(), "npcs_in_view": in_view,
			"cam": [cam.global_position.x, cam.global_position.y, cam.global_position.z]}
		print("[integration] view %-30s draws %3d (max %3d)  primitives %6d (max %6d)  NPCs in view %2d/%d" % [
			vname, int(row["draw_calls_mean"]), dc_max, int(row["primitives_mean"]), pr_max, in_view, row["npcs"]])
		out.append(row)
		p.auto_process = true
		if ui_state == "pause":
			await _wall_ms(300)
			Events.menu_requested.emit()
			await kit.frames(3)
	return out


## Points the desktop head (the camera) down by `pitch` rad (level = 0).
func _look(pitch: float) -> void:
	# The body is frozen: set the head's pitch on the camera directly (the
	# desktop pose source writes the head only while the bird ticks).
	var cam := main.player.camera
	var e := cam.rotation
	cam.rotation = Vector3(pitch, e.y, 0.0)


func _wall_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _load_avg() -> String:
	var out := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], out)
	return String(out[0]).strip_edges() if not out.is_empty() else ""


func _write() -> void:
	var path := Paths.artifacts("integration").path_join("perf_%s.json" % tag)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "  "))
	print("[integration] perf written: ", path)
