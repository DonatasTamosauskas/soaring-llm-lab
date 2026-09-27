extends Node
## VERIFIER PROBE (integration verify round 3, player-experience lens). Not a
## game file, not part of any suite.
##
## Plays the shipped scenes/main.tscn as a new player would: the main menu,
## How to fly, Settings (laser pointer, VR form of the UI), Play, the
## first-flight lessons flown by the bot's gestures (nothing skipped), then
## the competent person (integration_person.gd: the game loop's own person
## model flying the real chain) plays the real sky for --play_s seconds.
## Every event a player feels is logged (catches, deaths, tier-ups, cue
## changes, threat levels, lessons); when rendered, head-view screenshots
## are taken at the key moments and every --shot_every seconds.
##
##   tools/gd.sh r3px --rendering-method forward_plus --resolution 1280x960 --fixed-fps 72 \
##     res://tests/probes/integration/r3px_play.tscn -- --fresh-settings --tag=q --quality=quest --play_s=600
##   tools/gd.sh r3pxh --headless --fixed-fps 72 res://tests/probes/integration/r3px_play.tscn -- \
##     --fresh-settings --tag=fullh --play_s=900
## Output: artifacts/integration/verify/r3px/<tag>_play.json, <tag>_*.png

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const Person := preload("res://tests/unit/integration/integration_person.gd")

var kit: Kit
var main: GameMain
var tag := "run"
var render := false
var out := {"events": [], "shots": [], "timeline": [], "lessons": [], "cue": {}, "threat": {}}
var _t := 0.0
var _pending_shots: Array = []
var _target_changes := 0
var _target_changes_by_min := {}
var _threat_max := 0.0
var _threat_hist := {"0.0-0.1": 0, "0.1-0.3": 0, "0.3-0.6": 0, "0.6-1.0": 0}
var _threat_level := 0.0
var _threat_bird: Bird = null
var _look_target: Node3D = null
var _npc_catch_seen := 0
var _npc_catch_near := 0
var _npc_catch_total := 0
var _marks_samples: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _dir() -> String:
	var d := Paths.artifacts("integration").path_join("verify/r3px")
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _ev(kind: String, data: Dictionary) -> void:
	data["t"] = snappedf(_t, 0.1)
	data["kind"] = kind
	out["events"].append(data)
	print("[integration] r3px %s %.1f %s %s" % [tag, _t, kind, data])


func _shot(name: String) -> void:
	if render:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := _dir().path_join("%s_%s.png" % [tag, name])
		img.save_png(path)
	var p := main.player
	var info := {"name": name, "t": snappedf(_t, 0.1), "state": Game.state_name(), "species": String(p.species),
		"world_scale": snappedf(p.origin.world_scale, 0.001), "agl": snappedf(float(p.telemetry()["altitude_agl"]), 0.1),
		"pos": [snappedf(p.global_position.x, 0.1), snappedf(p.global_position.y, 0.1), snappedf(p.global_position.z, 0.1)]}
	info["view"] = _census()
	out["shots"].append(info)
	print("[integration] r3px shot %s" % info)


## What the head camera sees: NPCs on screen within 300 m, their wingspan in
## pixels, their highlight (1 edible ring, 2 danger triangle), the target
## and the named threat (on screen? pixels? distance?).
func _census() -> Dictionary:
	var cam := main.player.camera
	var vp := get_viewport().get_visible_rect()
	var f := vp.size.y / (2.0 * tan(deg_to_rad(cam.fov) * 0.5))
	var n := 0
	var noticeable := 0
	var edible := 0
	var danger := 0
	var big := []
	for b in main.ecosystem.get_npcs():
		if not is_instance_valid(b) or not b.alive:
			continue
		var bp: Vector3 = b.global_position
		if cam.is_position_behind(bp):
			continue
		var sp := cam.unproject_position(bp)
		if not vp.has_point(sp):
			continue
		var d := cam.global_position.distance_to(bp)
		if d > 300.0:
			continue
		n += 1
		var px := b.get_wingspan() * f / maxf(d, 0.01)
		if px >= 4.0:
			noticeable += 1
		var hl := int(ThreatWatch._get_highlight(b))
		if hl == 1:
			edible += 1
		elif hl == 2:
			danger += 1
		if px >= 4.0 or hl != 0:
			big.append("%s:%.0fpx:%.0fm:h%d" % [b.species, px, d, hl])
	var r := {"on_screen": n, "noticeable_4px": noticeable, "edible_marked": edible, "danger_marked": danger, "list": big.slice(0, 14)}
	var tgt: Bird = main.game_loop.watch.target
	if is_instance_valid(tgt):
		var tp := tgt.global_position
		var d2 := cam.global_position.distance_to(tp)
		r["target"] = {"species": String(tgt.species), "d": snappedf(d2, 0.1), "px": snappedf(tgt.get_wingspan() * f / maxf(d2, 0.01), 0.1),
			"on_screen": not cam.is_position_behind(tp) and vp.has_point(cam.unproject_position(tp)),
			"hidden": CatchRule.is_hidden(tgt)}
	return r


## The bot's head looks at a world point (a person looks at what they chase).
func _look_at(q: Vector3) -> void:
	if kit.bot == null:
		return
	var cam := main.player.camera.global_position
	var d := q - cam
	var yaw_world := atan2(-d.x, -d.z)
	var rel := wrapf(yaw_world - main.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI)
	kit.bot.body.head_yaw = clampf(rel, deg_to_rad(-80.0), deg_to_rad(80.0))
	kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))


func _look_ahead() -> void:
	if kit.bot != null:
		kit.bot.body.head_yaw = 0.0
		kit.bot.body.head_pitch = deg_to_rad(-8.0)


func _in_view(q: Vector3, half_deg := 45.0) -> bool:
	var cam := main.player.camera
	var d := (q - cam.global_position).normalized()
	return (-cam.global_basis.z).dot(d) > cos(deg_to_rad(half_deg))


func _on_caught(pred: Bird, prey: Bird) -> void:
	var p := main.player
	if pred == p:
		_ev("catch", {"prey": String(prey.species), "assist": snappedf(main.game_loop.rule.player_assist, 0.001),
			"mass_after": snappedf(p.mass, 0.0001), "species": String(p.species)})
		_pending_shots.append({"at": _t + 0.35, "name": "catch_%d" % _count("catch")})
	elif prey == p:
		pass
	else:
		_npc_catch_total += 1
		var at := prey.global_position
		var dist := at.distance_to(p.get_body_position()) / maxf(p.origin.world_scale, 1e-3)
		var dist_m := at.distance_to(p.get_body_position())
		if dist_m < 40.0:
			_npc_catch_near += 1
			if _in_view(at):
				_npc_catch_seen += 1
				_ev("npc_catch_seen", {"pred": String(pred.species), "prey": String(prey.species), "dist_m": snappedf(dist_m, 0.1),
					"dist_felt": snappedf(dist, 0.1)})


func _count(kind: String) -> int:
	var n := 0
	for e: Dictionary in out["events"]:
		if e["kind"] == kind:
			n += 1
	return n


func _on_player_caught(by: Bird) -> void:
	_ev("caught", {"by": String(by.species) if by != null else "", "lives_after": main.game_loop.lives,
		"species": String(main.player.species)})
	_pending_shots.append({"at": _t + 0.15, "name": "struck_%d" % _count("caught")})
	_pending_shots.append({"at": _t + 1.2, "name": "caught_screen_%d" % _count("caught")})


func _on_tier(o: int, n: int) -> void:
	_ev("tier", {"from_tier": o, "to_tier": n, "species": String(main.player.species)})
	_pending_shots.append({"at": _t + 0.6, "name": "tier_%d" % n})


func _on_target(prey: Bird) -> void:
	_target_changes += 1
	var m := int(_t / 60.0)
	_target_changes_by_min[m] = int(_target_changes_by_min.get(m, 0)) + 1


func _on_threat(level: float, pred: Bird) -> void:
	_threat_level = level
	_threat_bird = pred
	if level > _threat_max:
		_threat_max = level


func _sample() -> void:
	var p := main.player
	var tel: Dictionary = p.telemetry()
	var loop := main.game_loop
	var tgt: Bird = loop.watch.target
	var row := {"t": snappedf(_t, 0.1), "state": Game.state_name(), "species": String(p.species), "mass": snappedf(p.mass, 0.0001),
		"ws": snappedf(p.origin.world_scale, 0.001), "agl": snappedf(float(tel["altitude_agl"]), 0.1),
		"as": snappedf(float(tel["airspeed"]), 0.1), "mode": p.mode_name(), "lives": loop.lives,
		"threat": snappedf(_threat_level, 0.01), "threat_by": String(_threat_bird.species) if is_instance_valid(_threat_bird) else "",
		"person": String(_person.mode) if _person != null else "",
		"npcs": main.ecosystem.stats().get("alive", -1) if main.ecosystem.has_method("stats") else -1}
	var rx: Variant = main.get(&"rig_extras")
	if rx != null and is_instance_valid(rx) and rx.get(&"vignette") != null:
		row["vig"] = snappedf(float(rx.vignette.strength()), 0.01)
	row["yaw_rate"] = snappedf(rad_to_deg(float(tel.get("rig_yaw_rate", 0.0))), 0.1)
	if is_instance_valid(tgt):
		row["target"] = String(tgt.species)
		row["target_d"] = snappedf(tgt.global_position.distance_to(p.get_body_position()), 0.1)
	out["timeline"].append(row)


var _person: RefCounted = null


func _onboarding() -> void:
	var m := main
	var ob := m.ui.onboarding
	kit.fly_bot(11)
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var shot_for := {}
	ob.lesson_completed.connect(func(_i: int, id: StringName, timed_out: bool) -> void:
		out["lessons"].append({"id": String(id), "timed_out": timed_out, "t": snappedf(_t, 0.1)}))
	var t := 0.0
	while t < 150.0 and ob.active and ob.current().get("id") != &"catch":
		var id: StringName = ob.current().get("id", &"")
		if not shot_for.has(id) and t > 0.0:
			shot_for[id] = true
			# Look along the flight, slightly right and down: the lesson
			# card sits beside the HUD's centre line.
			if kit.bot:
				kit.bot.body.head_yaw = deg_to_rad(-12.0)
				kit.bot.body.head_pitch = deg_to_rad(-10.0)
			await kit.advance(1.2)
			t += 1.2
			_t += 1.2
			await _shot("lesson_%s" % id)
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
		_t += 0.25
	out["onboarding_s"] = snappedf(t, 0.1)
	out["onboarding_current"] = String(ob.current().get("id", &""))
	kit.set_mode(&"cruise")
	await kit.advance(1.0)
	_t += 1.0
	await _shot("lesson_catch")


func _run() -> void:
	tag = Paths.arg("tag", "run")
	render = DisplayServer.get_name() != "headless"
	kit = Kit.new()
	if not await kit.boot(self, true):
		print("[integration] r3px boot failed")
		get_tree().quit(1)
		return
	main = kit.main
	main.player.camera.fov = 90.0
	out["quality"] = Paths.arg("quality", "auto")
	out["max_npcs"] = main.ecosystem.max_npcs if "max_npcs" in main.ecosystem else -1
	await kit.advance(2.0)
	# --- menus, as a new player meets them ---
	kit.aim_at(kit.button(&"main", &"play"))
	await kit.frames(6)
	await _shot("menu")
	var ok := await kit.click(&"main", &"howto")
	_ev("menu_click", {"button": "howto", "hovered": ok, "screen": String(kit.screen())})
	await kit.frames(6)
	await _shot("howto")
	for tab in ["tab_speed", "tab_turn", "tab_hunt"]:
		ok = await kit.click(&"howto", StringName(tab))
		await kit.frames(6)
		await _shot("howto_%s" % tab)
	ok = await kit.click(&"howto", &"back")
	ok = await kit.click(&"main", &"settings")
	await kit.frames(6)
	await _shot("settings")
	ok = await kit.click(&"settings", &"back")
	await kit.frames(4)
	_ev("menu_back", {"screen": String(kit.screen())})
	# --- Play, a first-time player ---
	main.ui.onboarding.reset()
	ok = await kit.click(&"main", &"play")
	_ev("play_click", {"hovered": ok})
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	_ev("state", {"state": Game.state_name()})
	await kit.advance(1.0)
	await _shot("perch_start")
	Events.bird_caught.connect(_on_caught)
	Events.player_caught.connect(_on_player_caught)
	Events.player_tier_changed.connect(_on_tier)
	Events.target_changed.connect(_on_target)
	Events.threat_changed.connect(_on_threat)
	if Paths.arg("lessons", "1") == "1":
		await _onboarding()
	else:
		main.ui.onboarding.skip()
	# --- the person plays the real sky ---
	var play_s := float(Paths.arg("play_s", "600"))
	var shot_every := float(Paths.arg("shot_every", "40"))
	var seed_v := int(Paths.arg("seed", "13"))
	_person = Person.new(kit, seed_v)
	_target_changes = 0
	_target_changes_by_min = {}
	var next_shot := _t + 5.0
	var next_sample := _t
	var t0 := _t
	var danger_shots := 0
	var ended := false
	while _t - t0 < play_s:
		await kit.advance(1.0 / 72.0)
		_t += 1.0 / 72.0
		_person.step(1.0 / 72.0)
		# Where a person looks: at the bird they chase or flee, else ahead.
		var look: Bird = null
		if String(_person.mode) == "evade" and is_instance_valid(_threat_bird):
			look = _threat_bird
		elif is_instance_valid(_person.prey):
			look = _person.prey
		if look != null and look.global_position.distance_to(main.player.get_body_position()) < 60.0:
			_look_at(look.global_position)
		else:
			_look_ahead()
		var key := "0.0-0.1" if _threat_level < 0.1 else ("0.1-0.3" if _threat_level < 0.3 else ("0.3-0.6" if _threat_level < 0.6 else "0.6-1.0"))
		_threat_hist[key] = int(_threat_hist[key]) + 1
		if _t >= next_sample:
			next_sample += 1.0
			_sample()
		if _threat_level > 0.6 and danger_shots < 3 and is_instance_valid(_threat_bird) and Game.state == Game.State.PLAYING:
			danger_shots += 1
			_look_at(_threat_bird.global_position)
			await kit.frames(1)
			await _shot("danger_%d" % danger_shots)
			_ev("danger", {"by": String(_threat_bird.species), "level": snappedf(_threat_level, 0.01),
				"d": snappedf(_threat_bird.global_position.distance_to(main.player.get_body_position()), 0.1)})
		for ps: Dictionary in _pending_shots.duplicate():
			if _t >= float(ps["at"]):
				_pending_shots.erase(ps)
				await _shot(ps["name"])
		if _t >= next_shot and Game.state == Game.State.PLAYING:
			next_shot += shot_every
			await _shot("play_%03d" % int(_t))
		if Game.state == Game.State.ENDED:
			ended = true
			await kit.advance(1.5)
			await _shot("summary")
			break
	_person.release()
	out["person"] = _person.summary()
	out["target_changes"] = _target_changes
	out["target_changes_per_min"] = snappedf(_target_changes / maxf((_t - t0) / 60.0, 0.01), 0.01)
	out["target_changes_by_min"] = _target_changes_by_min
	out["threat_hist_ticks"] = _threat_hist
	out["threat_max"] = snappedf(_threat_max, 0.01)
	out["npc_catches_total"] = _npc_catch_total
	out["npc_catches_within_40m"] = _npc_catch_near
	out["npc_catches_seen_within_40m"] = _npc_catch_seen
	out["run_stats"] = main.game_loop.get_run_stats()
	out["eco_stats"] = main.ecosystem.stats() if main.ecosystem.has_method("stats") else {}
	out["ended"] = ended
	out["play_s"] = snappedf(_t - t0, 0.1)
	out["errors"] = kit.log.errors
	out["log"] = kit.log.summary()
	var f := FileAccess.open(_dir().path_join("%s_play.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  ", false))
		f.close()
	print("[integration] r3px %s done: catches %d deaths %d tiers %d target changes %.2f/min; %s" % [tag, _count("catch"),
		_count("caught"), _count("tier"), out["target_changes_per_min"], kit.log.summary()])
	await kit.teardown()
	get_tree().quit()
