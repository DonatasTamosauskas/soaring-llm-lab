extends Node3D
## AI dev scene: the ecosystem living around a fly-cam "player".
##
##   tools/gd.sh ai --rendering-method forward_plus res://scenes/dev/ai_dev.tscn
##   ... -- --real_world        use the world area's SoaringWorld instead
##   ... -- --dev_seconds=20    run headless-friendly for N s, print stats, quit
##   ... -- --shot=8            screenshot at 8 s to artifacts/ai/ai_dev.png
##
## Keys: [ / ] player size down/up a species, F follow the nearest NPC (again:
## next one), G free camera, T trails on/off, P pause, R reset the ecosystem,
## I toggle labels over the birds. Catches use the test stand-in rule (the
## real GameLoop is not in this scene).

const CatchChecker := preload("res://tests/unit/ai/catch_checker.gd")
const EcoScene := preload("res://scenes/ai/ecosystem.tscn")

var world: World
var eco: Ecosystem
var player: AiDevPlayer
var checker: RefCounted
var overlay: Label
var follow: NpcBird = null
var trails_on := true
var labels_on := false
var _trail_mesh: MeshInstance3D
var _trail := {}
var _t := 0.0
var _shot_at := -1.0
var _quit_at := -1.0
var _labels: Array[Label3D] = []


func _ready() -> void:
	var args := Paths.user_args()
	if args.has("real_world") and ResourceLoader.exists("res://scenes/world/world.tscn"):
		world = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	else:
		var w := AiTestWorld.new()
		world = w
	add_child(world)
	player = AiDevPlayer.new()
	player.mass = 0.1
	player.species = SizeRules.species_for_mass(player.mass)
	add_child(player)
	var spawn := world.get_player_spawn()
	player.global_position = spawn.origin + Vector3(0, 15, 40)
	eco = EcoScene.instantiate() as Ecosystem
	add_child(eco)
	checker = CatchChecker.new()
	var cl := CanvasLayer.new()
	add_child(cl)
	overlay = Label.new()
	overlay.position = Vector2(12, 10)
	overlay.add_theme_font_size_override("font_size", 16)
	overlay.add_theme_color_override("font_color", Color("#0b0b0b"))
	overlay.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	overlay.add_theme_constant_override("outline_size", 5)
	cl.add_child(overlay)
	_trail_mesh = MeshInstance3D.new()
	_trail_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trail_mesh)
	_shot_at = float(args.get("shot", "-1"))
	_quit_at = float(args.get("dev_seconds", "-1"))
	print("[ai] dev scene: world %s, %d perches" % [world.get_class() if world.get_script() == null else (world.get_script() as Script).resource_path.get_file(), world.get_perches().size()])


func _physics_process(delta: float) -> void:
	checker.step(delta)


func _process(delta: float) -> void:
	_t += delta
	if follow != null and (not is_instance_valid(follow) or not follow.alive):
		follow = null
	if follow != null:
		var fp := follow.global_position
		var back := -follow.velocity.normalized() if follow.velocity.length() > 0.5 else Vector3.BACK
		player.global_position = fp + back * maxf(follow.get_wingspan() * 6.0, 3.0) + Vector3.UP * maxf(follow.get_wingspan() * 2.0, 1.0)
		player.look_at_point(fp)
	if trails_on and Engine.get_process_frames() % 3 == 0:
		_update_trails()
	_update_overlay()
	if labels_on and Engine.get_process_frames() % 10 == 0:
		_update_labels()
	if _shot_at > 0.0 and follow == null and _t >= _shot_at * 0.5:
		_follow_next()
	if _shot_at > 0.0 and _t >= _shot_at:
		_shot_at = -1.0
		Capture.save_viewport(get_viewport(), Paths.artifacts("ai").path_join("ai_dev.png"))
	if _quit_at > 0.0 and _t >= _quit_at:
		_quit_at = -1.0
		print("[ai] dev stats: ", JSON.stringify(eco.stats()))
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_BRACKETRIGHT, KEY_BRACKETLEFT:
			var tier := clampi(SizeRules.tier_for_mass(player.mass) + (1 if event.keycode == KEY_BRACKETRIGHT else -1), 0, SizeRules.SPECIES.size() - 1)
			player.mass = SizeRules.SPECIES[tier]["mass"] * 1.02
			player.species = SizeRules.SPECIES[tier]["id"]
		KEY_F:
			_follow_next()
		KEY_G:
			follow = null
		KEY_T:
			trails_on = not trails_on
			if not trails_on:
				_trail_mesh.mesh = null
				_trail.clear()
		KEY_I:
			labels_on = not labels_on
			if not labels_on:
				for l in _labels:
					l.queue_free()
				_labels.clear()
		KEY_P:
			get_tree().paused = not get_tree().paused
		KEY_R:
			eco.reset()
			_trail.clear()


func _follow_next() -> void:
	var list := eco.get_npcs()
	if list.is_empty():
		return
	var pp := player.get_body_position()
	var sorted := list.duplicate()
	sorted.sort_custom(func(a: NpcBird, b: NpcBird) -> bool: return a.global_position.distance_squared_to(pp) < b.global_position.distance_squared_to(pp))
	var i := sorted.find(follow)
	follow = sorted[(i + 1) % sorted.size()] if i >= 0 else sorted[0]


func _update_trails() -> void:
	for n in eco.get_npcs():
		if not _trail.has(n):
			_trail[n] = PackedVector3Array()
		var t: PackedVector3Array = _trail[n]
		t.append(n.global_position)
		if t.size() > 40:
			t = t.slice(t.size() - 40)
		_trail[n] = t
	for k in _trail.keys():
		if not is_instance_valid(k) or not k.alive:
			_trail.erase(k)
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var n_lines := 0
	for k in _trail:
		var pts: PackedVector3Array = _trail[k]
		var c := _state_color(k)
		for i in range(1, pts.size()):
			var a := float(i) / pts.size()
			im.surface_set_color(Color(c.r, c.g, c.b, a * 0.8))
			im.surface_add_vertex(pts[i - 1])
			im.surface_add_vertex(pts[i])
			n_lines += 1
		# A line from every hunter to its target.
		if k.target != null and is_instance_valid(k.target):
			im.surface_set_color(Color(0.9, 0.1, 0.1, 0.9))
			im.surface_add_vertex(k.global_position)
			im.surface_add_vertex(k.target.get_body_position())
			n_lines += 1
	if n_lines == 0:
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(Vector3.ZERO)
	im.surface_end()
	_trail_mesh.mesh = im


func _state_color(n: NpcBird) -> Color:
	match n.state:
		NpcBird.State.HUNT, NpcBird.State.STOOP:
			return Color("#e34948")
		NpcBird.State.FLEE, NpcBird.State.HIDE:
			return Color("#eda100")
		NpcBird.State.SOAR:
			return Color("#eb6834")
		NpcBird.State.FLOCK:
			return Color("#1baf7a")
		NpcBird.State.PERCH, NpcBird.State.PERCHED:
			return Color("#4a3aa7")
	return Color("#2a78d6")


func _update_labels() -> void:
	for l in _labels:
		l.queue_free()
	_labels.clear()
	var pp := player.get_body_position()
	for n in eco.get_npcs():
		if n.global_position.distance_to(pp) > 60.0:
			continue
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.pixel_size = 0.004
		l.font_size = 24
		l.text = n.debug_text()
		l.position = n.global_position + Vector3.UP * maxf(n.get_wingspan(), 0.4)
		add_child(l)
		_labels.append(l)


func _update_overlay() -> void:
	var st := eco.stats()
	var txt := "AI dev  t=%.0fs  player %s %.2f kg  (caught %d)  %s\n" % [_t, String(player.species), player.mass, player.caught_count, "FOLLOW " + follow.debug_text() if follow else "free cam"]
	txt += "NPCs %d/%d  roles %s  lod %s  tick %.2f ms (p95 %.2f)\n" % [st["npcs"], st["target"], str(st["by_role"]).replace("\"", ""), st["lod"], st["tick_ms_avg"], st["tick_ms_p95"]]
	txt += "states %s\n" % str(st["by_state"]).replace("\"", "")
	txt += "catches %d %s\n" % [checker.catches.size(), str(checker.count_by_predator()).replace("\"", "")]
	txt += "[ ] size   F follow   G free   T trails   I labels   P pause   R reset"
	overlay.text = txt
