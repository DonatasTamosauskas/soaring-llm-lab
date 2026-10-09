extends Node3D
## Game-loop dev scene: the real GameLoop running alone with mock birds
## (SimEcosystem) around a player SimBird, a chase camera, and a debug
## overlay that shows what the loop decides: which birds are worthwhile prey
## (green), dangerous (red) or not worth chasing (grey), the current target,
## the threat and its time-to-contact, the player's catch reach, and the run
## stats/HUD numbers.
##
##   tools/gd.sh gameloop --rendering-method forward_plus res://scenes/dev/gameloop_dev.tscn
##
## Keys: Space autopilot on/off, WASD/arrows steer, Shift sprint, R restart,
## P pause/resume, M menu, 1-0 jump to a species' mass, O overlay on/off.
## User args (after --):
##   --tier=<species>   start the run at that species' mass
##   --staged           one bird of every species fanned out in front of the
##                      player (static; shows the loop shift), no ecosystem
##   --shot=<name>      capture artifacts/gameloop/<name>.png at --shot_at s, then quit
##   --shot_at=<s>      default 4
##   --shot_on=catch|tier  capture 0.4 s after the player's first catch (or
##                      tier-up) instead; --shot_at is then the give-up time
##   --seed=<n>         ecosystem seed
##   --autoquit=<s>     handled by the VR autoload

const COL_PREY := Color(0.30, 0.85, 0.40)
const COL_DANGER := Color(0.95, 0.30, 0.25)
const COL_DUST := Color(0.38, 0.40, 0.42)
const COL_PEER := Color(1.0, 1.0, 1.0, 0.8)

var loop: GameLoop
var eco: SimEcosystem
var player: SimBird
var pilot := SimPilot.new(&"competent", 7)
var cam: Camera3D
var overlay: Control
var hud: Label
var autopilot := true
var show_overlay := true
var staged := false
var _target: Bird = null
var _shot := ""
var _shot_at := 4.0
var _shot_on := ""
var _shot_event_t := -1.0
var _t := 0.0
var _events: Array[String] = []


func _ready() -> void:
	var args := Paths.user_args()
	staged = args.has("staged")
	_shot = args.get("shot", "")
	_shot_at = float(args.get("shot_at", "4"))
	_shot_on = args.get("shot_on", "")
	_build_environment()
	loop = GameLoop.new()
	loop.records_path = "user://gameloop_dev_records.json"
	add_child(loop)
	player = SimBird.new()
	player.player_mode = true
	player.name = "Player"
	player.ground_y = 0.0
	player.attach_model()
	add_child(player)
	if not staged:
		eco = SimEcosystem.new()
		eco.with_models = true
		# Tighter than the real Ecosystem so the frame is full of birds.
		eco.home_radius = 18.0
		eco.spawn_min = 6.0
		eco.spawn_max = 26.0
		eco.despawn_radius = 60.0
		eco.seed_rng(int(args.get("seed", "3")))
		add_child(eco)
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.near = 0.02
	cam.far = 3000.0
	add_child(cam)
	cam.current = true
	var layer := CanvasLayer.new()
	add_child(layer)
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_overlay)
	layer.add_child(overlay)
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 17)
	hud.add_theme_color_override("font_color", Color(1, 1, 1))
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	hud.add_theme_constant_override("outline_size", 5)
	layer.add_child(hud)
	Events.bird_caught.connect(func(pred: Bird, prey: Bird) -> void:
		if pred == player:
			_log("caught a %s (+%.0f g)" % [prey.species, SizeRules.meal_gain(player.mass, prey.mass) * 1000.0])
			if _shot_on == "catch" and _shot_event_t < 0.0:
				_shot_event_t = _t)
	Events.player_tier_changed.connect(func(o: int, n: int) -> void:
		_log("TIER %s -> %s" % [SizeRules.SPECIES[o]["name"], SizeRules.SPECIES[n]["name"]])
		if _shot_on == "tier" and _shot_event_t < 0.0 and n > o:
			_shot_event_t = _t)
	Events.player_caught.connect(func(by: Bird) -> void: _log("CAUGHT by a %s!" % by.species))
	Events.run_ended.connect(func(s: Dictionary) -> void: _log("RUN ENDED (%s) score %d" % [s["reason"], s["score"]]))
	loop.start_run()
	var tier: String = args.get("tier", "")
	if not tier.is_empty():
		player.mass = float(SizeRules.species_data(StringName(tier)).get("mass", GameLoop.START_MASS)) * 1.1
	player.global_position = Vector3(0, 40, 0)
	loop.teleported(player)
	if staged:
		loop.auto_step = false
		loop.npc_catches_outside_run = false
		_stage_fan()
		loop.set_protection(player, 1e6)
		for i in 3:
			loop.step(1.0 / 60.0)
	# (The species follows the mass on the loop's next step; name it from the
	# mass so the line is right before that.)
	print("[gameloop] dev scene ready (staged=%s, tier=%s)" % [staged, SizeRules.species_for_mass(player.mass)])


func _log(s: String) -> void:
	_events.push_front(s)
	if _events.size() > 6:
		_events.pop_back()
	print("[gameloop] ", s)


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.30, 0.52, 0.82)
	mat.sky_horizon_color = Color(0.72, 0.82, 0.90)
	mat.ground_horizon_color = Color(0.60, 0.66, 0.55)
	mat.ground_bottom_color = Color(0.35, 0.42, 0.30)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.8, 0.88)
	env.fog_density = 0.0009
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.1
	add_child(sun)
	# Flat-shaded low-poly ground and a few landmarks for scale and motion.
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4000, 4000)
	ground.mesh = pm
	ground.material_override = _flat(Color(0.42, 0.58, 0.32))
	add_child(ground)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 60:
		var h := rng.randf_range(8.0, 30.0)
		var m := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.0
		cyl.bottom_radius = rng.randf_range(3.0, 7.0)
		cyl.height = h
		cyl.radial_segments = 6
		m.mesh = cyl
		m.material_override = _flat(Color(0.20, 0.42, 0.25).lerp(Color(0.35, 0.5, 0.25), rng.randf()))
		m.position = Vector3(rng.randf_range(-400, 400), h * 0.5, rng.randf_range(-400, 400))
		add_child(m)


static func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m


## One bird of every species in an arc in front of the player, all well
## outside catch reach, so the overlay shows how the loop classifies them.
func _stage_fan() -> void:
	player.set_heading(Vector3.FORWARD)
	var span := player.get_wingspan()
	var n := SizeRules.SPECIES.size()
	for i in n:
		var b := SimBird.new()
		var sd: Dictionary = SizeRules.SPECIES[i]
		b.mass = sd["mass"]
		b.species = sd["id"]
		b.name = String(sd["id"])
		b.attach_model()
		add_child(b)
		# Bigger birds further back so nobody hides anybody.
		var ang := deg_to_rad(-54.0 + 108.0 * float(i) / float(n - 1))
		var d := 7.0 * span + 2.2 * b.get_wingspan()
		b.global_position = player.global_position + Vector3(sin(ang) * d, (0.4 + 0.25 * float(i % 2)) * span + 0.3 * b.get_wingspan(), -cos(ang) * d)
		b.set_heading(Vector3.RIGHT.rotated(Vector3.UP, ang))
		loop.set_protection(b, 1e6)


func _unhandled_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_SPACE:
			autopilot = not autopilot
		KEY_R:
			loop.restart_run()
		KEY_P:
			if Game.state == Game.State.PAUSED:
				loop.resume()
			else:
				loop.pause()
		KEY_M:
			loop.to_menu()
		KEY_O:
			show_overlay = not show_overlay
		_:
			if k.keycode >= KEY_0 and k.keycode <= KEY_9:
				var i := (k.keycode - KEY_0 + 9) % 10
				player.mass = float(SizeRules.SPECIES[i]["mass"]) * 1.05


func _physics_process(dt: float) -> void:
	if get_tree().paused:
		return
	if staged:
		return
	eco.step(dt)
	if loop.phase != GameLoop.Phase.PLAYING or not player.alive:
		return
	if autopilot:
		if pilot.aware_of(loop.watch, player):
			pilot.evade(player, pilot.threat, dt)
			_target = null
		else:
			var w := loop.watch.target
			if w != null:
				_target = w
			if _target != null and is_instance_valid(_target) and _target.alive and pilot.wants(player, _target):
				pilot.hunt(player, _target, dt)
			else:
				_target = null
				var seen := _nearest_worthwhile()
				if seen != null:
					pilot.search(player, seen.get_body_position(), dt)
				else:
					pilot.cruise(player, dt)
	else:
		var yaw := Input.get_axis(&"ui_right", &"ui_left") + (float(Input.is_key_pressed(KEY_A)) - float(Input.is_key_pressed(KEY_D)))
		var pitch := Input.get_axis(&"ui_down", &"ui_up") + (float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
		var dir := player.heading.rotated(Vector3.UP, clampf(yaw, -1, 1) * 1.5)
		dir.y = clampf(dir.y + clampf(pitch, -1, 1) * 0.6, -0.8, 0.8)
		var sp := player.cruise_speed() * (1.35 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		player.fly(dir, sp, dt)
	# Stay above the ground.
	if player.global_position.y < 3.0:
		player.global_position.y = 3.0
		player.set_heading(Vector3(player.heading.x, absf(player.heading.y), player.heading.z))


func _process(dt: float) -> void:
	_t += dt
	_update_camera(dt)
	_update_hud()
	overlay.queue_redraw()
	var shoot_now := _t >= _shot_at if _shot_on.is_empty() else (_shot_event_t >= 0.0 and _t >= _shot_event_t + 0.4) or _t >= _shot_at
	if not _shot.is_empty() and shoot_now:
		var shot_name := _shot
		_shot = ""
		await Capture.save_viewport(get_viewport(), Paths.artifacts("gameloop").path_join(shot_name + ".png"))
		get_tree().quit()


func _nearest_worthwhile() -> Bird:
	var best: Bird = null
	var best_d := INF
	for b in Birds.all():
		if b == player or not b.alive or not SizeRules.is_worthwhile(player.mass, b.mass):
			continue
		var d := b.global_position.distance_to(player.global_position)
		if d < best_d:
			best_d = d
			best = b
	return best


func _update_camera(dt: float) -> void:
	var span := player.get_wingspan()
	var h := player.heading
	h.y *= 0.3
	h = h.normalized() if h.length_squared() > 1e-4 else Vector3.FORWARD
	var want: Vector3
	var look: Vector3
	if staged:
		var far := 7.0 * span + 2.2 * SizeRules.wingspan_for_mass(float(SizeRules.SPECIES[-1]["mass"]))
		want = player.global_position + Vector3(0, 2.2 * span + 0.12 * far, 4.5 * span + 0.2 * far)
		look = player.global_position + Vector3(0, 0.1 * far, -0.55 * far)
	else:
		want = player.global_position - h * 6.0 * span + Vector3.UP * 2.0 * span
		look = player.global_position + h * 8.0 * span
	cam.global_position = want if _t < 0.1 else cam.global_position.lerp(want, clampf(dt * 5.0, 0.0, 1.0))
	cam.near = maxf(0.01, span * 0.05)
	cam.look_at(look, Vector3.UP)


## Relationship colour (always), and whether the loop highlights the bird
## (it only does within highlight range): [colour, highlighted].
func _classify(q: Bird) -> Array:
	var hl: int = loop.watch.highlights.get(q.get_instance_id(), 0)
	var col := COL_PEER
	if SizeRules.can_eat(q.mass, player.mass):
		col = COL_DANGER
	elif SizeRules.is_worthwhile(player.mass, q.mass):
		col = COL_PREY
	elif SizeRules.can_eat(player.mass, q.mass):
		col = COL_DUST
	return [col, hl != 0]


func _draw_overlay() -> void:
	if not show_overlay:
		return
	var font := ThemeDB.fallback_font
	var span := player.get_wingspan()
	var cam_pos := cam.global_position
	var cam_fwd := -cam.global_basis.z
	# The player's catch reach (a ring around its body in the view).
	var reach := loop.rule.contact_distance(player.get_body_radius(), span, true, 0.0)
	_draw_world_ring(player.get_body_position(), reach, Color(1, 1, 1, 0.5), 1.5)
	for q in Birds.all():
		if q == player or not q.alive:
			continue
		var p := q.get_body_position()
		if cam_fwd.dot(p - cam_pos) <= 0.1:
			continue
		var sp := cam.unproject_position(p)
		var edge := cam.unproject_position(p + cam.global_basis.x * q.get_wingspan() * 0.6)
		var r := clampf(sp.distance_to(edge), 7.0, 60.0)
		var cls := _classify(q)
		var col: Color = cls[0]
		var lit: bool = cls[1]
		if not lit and col != COL_DUST:
			col.a *= 0.55
		overlay.draw_arc(sp, r, 0, TAU, 28, col, 3.0 if lit else 1.6, true)
		if q == loop.watch.target:
			overlay.draw_arc(sp, r + 6.0, 0, TAU, 32, COL_PREY, 4.0, true)
			overlay.draw_string(font, sp + Vector2(r + 8, -4), "TARGET", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, COL_PREY)
		if q == loop.watch.predator:
			overlay.draw_arc(sp, r + 6.0, 0, TAU, 32, COL_DANGER, 4.0, true)
			var ttc := loop.watch.predator_ttc
			overlay.draw_string(font, sp + Vector2(r + 8, 14), "THREAT %s" % ("%.1fs" % ttc if is_finite(ttc) else "near"),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, COL_DANGER)
		if staged or r > 10.0:
			overlay.draw_string(font, sp + Vector2(-r, -r - 4), String(q.species), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.9))
	# Threat vignette bar along the bottom.
	var vp := overlay.get_viewport_rect().size
	var lv := loop.watch.level
	overlay.draw_rect(Rect2(0, vp.y - 10, vp.x, 10), Color(0, 0, 0, 0.35))
	overlay.draw_rect(Rect2(0, vp.y - 10, vp.x * lv, 10), COL_DANGER.lerp(Color(1, 0.8, 0.2), 1.0 - lv))
	# Legend.
	var y := vp.y - 110.0
	overlay.draw_string(font, Vector2(vp.x - 257, y - 22), "thick ring = highlighted by the loop", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.85))
	for item in [[COL_PREY, "worthwhile prey (highlight 1)"], [COL_DANGER, "can eat you (highlight 2)"],
			[COL_DUST, "edible but not worth it"], [COL_PEER, "neither"]]:
		overlay.draw_arc(Vector2(vp.x - 250, y), 7, 0, TAU, 16, item[0], 2.5, true)
		overlay.draw_string(font, Vector2(vp.x - 236, y + 5), item[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1))
		y += 22.0


func _draw_world_ring(centre: Vector3, radius: float, col: Color, w: float) -> void:
	var pts := PackedVector2Array()
	var basis := Basis(Vector3.UP, 0.0)
	for i in 33:
		var a := TAU * float(i) / 32.0
		var p := centre + (basis.x * cos(a) + basis.z * sin(a)) * radius
		if (-cam.global_basis.z).dot(p - cam.global_position) <= 0.05:
			return
		pts.append(cam.unproject_position(p))
	overlay.draw_polyline(pts, col, w, true)


func _update_hud() -> void:
	var st := loop.get_run_stats()
	var ap: Dictionary = st["apex"]
	var worth: Array = st["worthwhile_species"]
	var danger: Array = st["danger_species"]
	var lines := [
		"GAME LOOP DEV   state %s   %s" % [Game.state_name(), "autopilot (competent)" if autopilot else "manual"],
		("You: %s  %.0f g   tier %d  [%s] %d%% to next" % [st["species_name"], float(st["mass"]) * 1000.0, st["tier"],
			_bar(float(st["tier_progress"])), int(float(st["tier_progress"]) * 100.0)]) if float(st["next_tier_mass"]) > 0.0
			else "You: %s  %.0f g   tier %d  top of the ladder" % [st["species_name"], float(st["mass"]) * 1000.0, st["tier"]],
		"Lives %d/%d   catches %d (%d worthwhile)   score %d   best %d" % [st["lives"], st["max_lives"],
			st["catches"], st["worthwhile_catches"], st["score"], st["best_score"]],
		"Hunt: %s" % ", ".join(worth),
		"Flee: %s" % (", ".join(danger) if not danger.is_empty() else "nobody"),
		"Threat %.2f   catch reach %.2f spans   assist %.0f%%%s" % [st["threat_level"],
			loop.rule.player_reach_spans(), float(st["catch_assist"]) * 100.0,
			("   protected %.1fs" % st["protection_s"]) if float(st["protection_s"]) > 0.0 and float(st["protection_s"]) < 100.0 else ""],
		"Apex: %s %d/%d   time %d:%02d   npc catches %d" % ["reached" if ap["reached"] else "not yet", ap["catches"], ap["needed"],
			int(st["run_time"]) / 60, int(st["run_time"]) % 60, st["npc_catches"]],
	]
	if Game.state == Game.State.CAUGHT:
		lines.append("CAUGHT - respawn in %.1f s" % st["respawn_in"])
	for e in _events:
		lines.append("  " + e)
	hud.text = "\n".join(lines)


static func _bar(f: float) -> String:
	var n := int(round(clampf(f, 0.0, 1.0) * 12.0))
	return "#".repeat(n) + "-".repeat(12 - n)
