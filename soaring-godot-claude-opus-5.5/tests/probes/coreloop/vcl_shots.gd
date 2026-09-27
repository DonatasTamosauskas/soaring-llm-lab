extends Node
## Head-view screenshots of the core loop round's features in the real game
## (scenes/main.tscn, the competent person flying the real chain):
##  * the catch lesson's moth swarm ahead, ringed (core_lesson.png);
##  * a swarm of the sky's pellets close up as the person flies into it
##    (core_swarm.png), and the moment a moth is caught (core_catch.png);
##  * an attack: the attacker marked as danger (core_attack.png);
##  * the murmuration in view, NOT marked (core_murmuration.png).
## Each shot also lists what is in view (the birds within 60 m inside the
## camera's frustum, their species, highlight and whether they hunt the
## player): artifacts/gameloop/core_shots.json.
##
##   tools/gd.sh gl_core_shots --rendering-method forward_plus --resolution 1280x960 \
##       res://tests/shots/gameloop_core_shots.tscn -- --fresh-settings [--seed=7] [--quality=quest]

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const Person := preload("res://tests/unit/integration/integration_person.gd")
const MAX_S := 600.0

var kit: Kit
var main: GameMain
var person: RefCounted
var out := {"shots": []}
var _taken := {}
var _t := 0.0
var _caught_at := -1.0
var _caught_what := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		print("[gameloop] core shots: boot failed")
		get_tree().quit(1)
		return
	main = kit.main
	main.player.camera.fov = 90.0
	main.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	main.ui.onboarding.skip()
	person = Person.new(kit, int(Paths.arg("seed", "7")))
	main.game_loop.player_mass_changed.connect(func(_o: float, _n: float, r: StringName) -> void:
		if r == &"meal" and _caught_at < 0.0 and _t > 60.0:
			_caught_at = _t
			_caught_what = String(r))
	var lesson: Array[Bird] = []
	var dt := 1.0 / 72.0
	while _t < MAX_S and _taken.size() < 7 and Game.state != Game.State.ENDED:
		_t += dt
		await kit.advance(dt)
		person.call(&"step", dt)
		var p := main.player
		if not p.alive:
			continue
		if _caught_at > 0.0 and not _taken.has("catch") and _t - _caught_at > 0.08:
			await _shot("catch", "just after a catch (%s)" % _caught_what)
		if not _taken.has("chase") and _t > 90.0:
			var tc := main.game_loop.watch.target
			if tc != null and not (tc is SwarmMoth) and tc.get_body_position().distance_to(p.get_body_position()) < 9.0 and not main.player.camera.is_position_behind(tc.get_body_position()):
				await _shot("chase", "a chase, straight-ahead head view, ringed %s at %.1f m" % [String(tc.species), tc.get_body_position().distance_to(p.get_body_position())])
		if lesson.is_empty() and _t > 3.0:
			lesson = main.game_loop.request_lesson_prey()
		# The lesson's swarm, ringed, a moment after it was put up.
		if not _taken.has("lesson") and _t > 5.0 and not lesson.is_empty():
			var tg := main.game_loop.watch.target
			if tg != null and lesson.has(tg):
				_look_at(tg.get_body_position())
				await kit.frames(2)
				await _shot("lesson", "the catch lesson's moth swarm ahead of the player, the ring on one")
				main.game_loop.release_lesson_prey()
				_look(0.0, 0.0)
		# A swarm close up: the ringed moth within 8 m.
		if not _taken.has("swarm") and _taken.has("lesson"):
			var tg2 := main.game_loop.watch.target
			if tg2 is SwarmMoth and tg2.get_body_position().distance_to(p.get_body_position()) < 8.0:
				_look_at(tg2.get_body_position())
				await kit.frames(2)
				await _shot("swarm", "flying into a swarm of pellets (the ringed moth within 8 m)")
				_look(0.0, 0.0)
		# An attack: a bird hunting the player, at attack strength, in view.
		if not _taken.has("attack"):
			var w := main.game_loop.watch
			if w.predator != null and is_instance_valid(w.predator) and IntegratedSim.hunts(w.predator, p) \
					and w.level >= 0.55:
				_look_at(w.predator.get_body_position())
				await kit.frames(2)
				await _shot("attack", "an attack: the hunter marked as danger (level %.2f)" % w.level)
				_look(0.0, 0.0)
		# The murmuration in view within 50 m, no attack on.
		if not _taken.has("murmuration") and main.game_loop.watch.level < 0.1:
			for fl in main.ecosystem.get_flocks():
				if fl.kind != "murmuration" or fl.members.is_empty():
					continue
				var c := fl.centroid()
				if c.distance_to(p.get_body_position()) < 50.0:
					_look_at(c)
					await kit.frames(2)
					await _shot("murmuration", "the murmuration close by, not hunting the player: no danger marks")
					_look(0.0, 0.0)
					break
	# The catch moment, from a new flight if none came before (a moth caught
	# by the player: the feathers where it was).
	print("[gameloop] core shots: %s at %.0f s" % [_taken.keys(), _t])
	var f := FileAccess.open(Paths.artifacts("coreloop/verify").path_join("shots_%s.json" % Paths.arg("seed","7")), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, " "))
		f.close()
	person.call(&"release")
	await kit.teardown()
	get_tree().quit()


func _look_at(pos: Vector3) -> void:
	if kit.bot == null:
		return
	var cam := main.player.camera.global_position
	var d := pos - cam
	var yaw_world := atan2(-d.x, -d.z)
	var rel := wrapf(yaw_world - main.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI)
	kit.bot.body.head_yaw = clampf(rel, deg_to_rad(-80.0), deg_to_rad(80.0))
	kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))


func _look(yaw_deg: float, pitch_deg: float) -> void:
	if kit.bot != null:
		kit.bot.body.head_yaw = deg_to_rad(yaw_deg)
		kit.bot.body.head_pitch = deg_to_rad(pitch_deg)


func _shot(name: String, what: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("coreloop/verify").path_join("shot_%s_%s.png" % [Paths.arg("seed","7"), name])
	img.save_png(path)
	_taken[name] = true
	var cam := main.player.camera
	var seen: Array = []
	for b in Birds.all():
		if b == main.player or not b.alive:
			continue
		var bp := b.get_body_position()
		if bp.distance_to(cam.global_position) > 60.0 or cam.is_position_behind(bp):
			continue
		var sp := cam.unproject_position(bp)
		var vs := get_viewport().get_visible_rect().size
		if sp.x < 0 or sp.y < 0 or sp.x > vs.x or sp.y > vs.y:
			continue
		var m: Variant = b.get(&"model")
		seen.append({"species": String(b.species), "d": snappedf(bp.distance_to(cam.global_position), 0.1),
			"highlight": int((m as Object).get(&"highlight")) if m is Object else 0,
			"hunting_player": IntegratedSim.hunts(b, main.player), "swarm": b is SwarmMoth,
			"murmuration": b is NpcBird and (b as NpcBird).flock != null and (b as NpcBird).flock.kind == "murmuration",
			"target": b == main.game_loop.watch.target, "named": b == main.game_loop.watch.predator})
	out["shots"].append({"name": name, "what": what, "t": snappedf(_t, 0.1), "species": String(main.player.species),
		"in_view": seen})
	print("[gameloop] shot %s at %.1f s: %s (%d birds in view)" % [name, _t, what, seen.size()])
