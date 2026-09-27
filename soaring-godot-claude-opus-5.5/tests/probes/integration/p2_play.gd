extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## A rendered play-through of the real main.tscn from the head camera (UI in
## its VR form, 90 deg field): menu, How to fly, Settings, Play, the lessons
## flown through the real WingInput (shot at each lesson), a real cue chase
## (no staging) with a shot when the prey is close and one right after the
## catch, the danger cue when a real threat is named, pause, the caught
## screen, growth to pigeon and eagle (world shrink), the run summary.
##
##   tools/gd.sh p2play --rendering-method forward_plus --resolution 1280x960 --fixed-fps 72 res://tests/probes/integration/p2_play.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")

var kit: Kit
var main: GameMain
var out := {"shots": []}
var dir := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	dir = Paths.artifacts("integration").path_join("verify/r2")
	_run.call_deferred()


func _shot(name: String, extra := {}) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(dir.path_join("p2_play_%s.png" % name))
	var st := {"name": name, "state": Game.State.keys()[Game.state], "screen": String(kit.screen()),
		"species": String(main.player.species), "ws": snappedf(main.player.origin.world_scale, 0.001)}
	st.merge(extra)
	out["shots"].append(st)
	print("[integration] p2_play shot %s %s" % [name, st])


func _look_at(p: Vector3) -> void:
	if kit.bot == null:
		return
	var cam := main.player.camera.global_position
	var d := p - cam
	var yaw_world := atan2(-d.x, -d.z)
	var rel := wrapf(yaw_world - main.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI)
	kit.bot.body.head_yaw = clampf(rel, deg_to_rad(-80.0), deg_to_rad(80.0))
	kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))


func _look_ahead() -> void:
	if kit.bot == null:
		return
	kit.bot.body.head_yaw = 0.0
	kit.bot.body.head_pitch = deg_to_rad(-8.0)


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	var m := main
	m.player.camera.fov = 90.0
	await kit.frames(10)
	await _shot("menu")
	# How to fly and Settings
	if await kit.click(&"main", &"howto"):
		await kit.frames(20)
		await _shot("howto")
		var s := m.ui.get_screen(kit.screen())
		out["howto_buttons"] = []
		if s:
			for b in s.find_children("*", "Button", true, false):
				out["howto_buttons"].append([String(b.name), (b as Button).text])
	# back
	var back_ok := false
	for id in [&"back", &"close", &"done"]:
		if kit.button(kit.screen(), id) != null:
			back_ok = await kit.click(kit.screen(), id)
			break
	await kit.frames(20)
	out["after_howto_back_screen"] = String(kit.screen())
	if await kit.click(&"main", &"settings"):
		await kit.frames(20)
		await _shot("settings")
		for id in [&"back", &"close", &"done"]:
			if kit.button(kit.screen(), id) != null:
				await kit.click(kit.screen(), id)
				break
		await kit.frames(20)
	out["screen_before_play"] = String(kit.screen())
	# Play
	var hov := await kit.click(&"main", &"play")
	out["play_hovered"] = hov
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	kit.fly_bot(3)
	_look_ahead()
	await kit.advance(1.0)
	await _shot("play_perched")
	# Lessons
	var ob := m.ui.onboarding
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var lessons := []
	var shot_lessons := {}
	var t := 0.0
	var done := {}
	ob.lesson_completed.connect(func(_i: int, id: StringName, timed_out: bool) -> void:
		done[String(id)] = {"t": snappedf(t, 0.1), "timed_out": timed_out})
	while t < 120.0 and ob.active and ob.current().get("id") != &"catch":
		var id: StringName = ob.current().get("id", &"")
		if not shot_lessons.has(id) and ob.celebrating <= 0.0:
			shot_lessons[id] = true
			await kit.advance(0.6)
			t += 0.6
			await _shot("lesson_%s" % id)
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
	out["lessons_done"] = done
	out["lessons_s"] = t
	out["lesson_now"] = String(ob.current().get("id", &""))
	await _shot("lesson_catch")
	kit.set_mode(&"cruise")
	# A real chase, following the cue (chase pilot), up to 5 minutes.
	var catches0: int = kit.stats()["catches"]
	var pilot := ChasePilot.new(m.player.model.params, null)
	pilot.set(&"world", m.world)
	pilot.set(&"heading", m.player.rig_yaw)
	kit.pilot = pilot
	kit.bot.pilot = pilot
	var cur: NpcBird = null
	var since := 0.0
	var close_shot := false
	var threat_shot := false
	var t2 := 0.0
	var first_catch_t := -1.0
	while t2 < 300.0 and first_catch_t < 0.0:
		await kit.advance(1.0 / 72.0)
		t2 += 1.0 / 72.0
		if Game.state != Game.State.PLAYING:
			continue
		var st: Dictionary = m.game_loop.get_run_stats()
		var tgt: Variant = st.get("target")
		var named: NpcBird = tgt as NpcBird if tgt is NpcBird and is_instance_valid(tgt) else null
		if cur != null and (not is_instance_valid(cur) or not cur.alive or cur.hidden or since > 25.0 or (named != cur and named != null)):
			cur = null
			pilot.stop_chase()
			kit.cruise()
		if cur == null and named != null:
			cur = named
			since = 0.0
			pilot.chase_prey(named)
		if cur != null:
			since += 1.0 / 72.0
			var d := cur.get_body_position().distance_to(m.player.get_body_position())
			_look_at(cur.get_body_position())
			if not close_shot and d < 7.0:
				close_shot = true
				await _shot("chase_close", {"prey": String(cur.species), "dist": snappedf(d, 0.1)})
		else:
			_look_ahead()
		var thr: Variant = st.get("threat")
		if not threat_shot and thr is Bird and is_instance_valid(thr) and float(st.get("threat_level", 0.0)) > 0.3:
			threat_shot = true
			_look_at((thr as Bird).get_body_position())
			await kit.advance(0.1)
			await _shot("threat", {"threat": String((thr as Bird).species), "level": st.get("threat_level"),
				"dist": snappedf((thr as Bird).get_body_position().distance_to(m.player.get_body_position()), 0.1)})
		if int(st["catches"]) > catches0:
			first_catch_t = t2
			await kit.advance(0.25)
			await _shot("after_catch", {"t": snappedf(t2, 0.1)})
			await kit.advance(0.6)
			await _shot("after_catch_later")
	out["first_real_catch_s"] = snappedf(first_catch_t, 0.1)
	out["run_stats_after_chase"] = {"catches": kit.stats()["catches"], "species": String(kit.stats()["species"]), "lives": kit.stats()["lives"]}
	pilot.stop_chase()
	kit.cruise()
	_look_ahead()
	# Pause
	Events.menu_requested.emit()
	await kit.frames(20)
	await _shot("pause")
	await kit.click(&"pause", &"resume")
	await kit.frames(10)
	out["after_resume"] = Game.State.keys()[Game.state]
	# Growth: tier-up to swallow (celebration), then pigeon, then eagle.
	for sp in [["swallow", 0.056], ["pigeon", 0.31], ["eagle", 3.05]]:
		m.game_loop._set_player_mass(m.player, sp[1], &"meal")
		await kit.advance(0.8)
		await _shot("tierup_%s" % sp[0])
		kit.set_mode(&"cruise")
		await kit.advance(8.0)
		_look_ahead()
		await kit.advance(0.2)
		await _shot("cruise_%s" % sp[0])
	# Caught: a staged hawk strike isn't a threat to an eagle; back to sparrow size.
	m.game_loop._set_player_mass(m.player, 0.04, &"probe")
	await kit.advance(3.0)
	m.game_loop.set_protection(m.player, 0.0)
	m.game_loop.set(&"_respite_until", 0.0)
	var hawk := kit.stage_strike(&"hawk", 25.0, 14.0)
	_look_at(hawk.get_body_position())
	await kit.advance(0.8)
	_look_at(hawk.get_body_position())
	await _shot("strike_incoming")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.CAUGHT, 6.0)
	out["strike_state"] = Game.State.keys()[Game.state]
	await kit.advance(0.5)
	await _shot("caught")
	kit.free_staged()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 12.0)
	await kit.advance(0.5)
	await _shot("respawned")
	# End the run -> summary
	m.game_loop.end_run(&"quit")
	await kit.frames(30)
	await _shot("summary")
	out["summary_screen"] = String(kit.screen())
	out["errors"] = kit.log.errors
	out["log"] = kit.log.summary()
	var f := FileAccess.open(dir.path_join("p2_play.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] p2_play done %s" % kit.log.summary())
	await kit.teardown()
	get_tree().quit()
