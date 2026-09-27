extends Node3D
## Audio dev scene: the AudioDirector on its own, with a mock world, a mock
## player and mock NPCs, and a live mixer HUD.
##
##   tools/gd.sh audio --rendering-method forward_plus res://scenes/dev/audio_dev.tscn
##   ... -- --tour                 fly the scripted tour (default when --autoquit)
##   ... -- --shots=6,16,27 --out=audio_dev   screenshots at those seconds
##   ... -- --seconds=40           quit cleanly after 40 s (via AudioDirector.shutdown)
##
## Keys (manual): W/S airspeed, T tuck, X stall, U updraft, F flap (Q/E one
## wing), C catch, G caught, L tier-up, 1-5 threat 0..1, P pause, M menu,
## Enter play, B bump. The tour: glide over the meadow, a tucked dive, a
## stall and recovery, an updraft, a hawk closing in, a catch, a tier-up,
## the forest at cruise (the ambience ducked under the wind), slowing to a
## crawl over the lake (the zone comes back in full), the village, then a
## pause.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")

var player: Fixture.MockPlayer
var director: AudioDirector
var world: Fixture.MockWorld
var cam: Camera3D
var npcs: Array[Bird] = []
var hawk: Bird
var hud: Label
var meters: Control
var t := 0.0
var tour := false
var shots: Array = []
var shot_dir := ""
var _log_t := 0.0
var _events_done := {}
var _pos := Vector3(-300, 18, 0)
var _yaw := 0.0
var _threat := 0.0
var _quit_at := -1.0
var _quitting := false
## A screenshot is waiting for its frame: the tour clock holds still until
## it is written (on a busy machine a frame can take seconds, and the shot
## must show the moment it was taken for, not a later one).
var _capturing := false

const LANDMARKS := [
	{"name": "meadow", "kind": "meadow", "position": Vector3(-300, 0, 0), "radius": 120.0, "color": Color("#b9c86a")},
	{"name": "forest", "kind": "forest", "position": Vector3(0, 0, -250), "radius": 110.0, "color": Color("#3f6b3a")},
	{"name": "lake", "kind": "lake", "position": Vector3(250, 0, -80), "radius": 100.0, "color": Color("#4f86b8")},
	{"name": "village", "kind": "town", "position": Vector3(180, 0, 200), "radius": 90.0, "color": Color("#b98b62")},
	{"name": "church_spire", "kind": "landmark", "position": Vector3(180, 25, 200), "radius": 4.0, "color": Color()},
]


func _ready() -> void:
	# The tour itself pauses the game; its driver must keep running.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := Paths.user_args()
	tour = args.has("tour") or args.has("seconds") or args.has("shots")
	_quit_at = float(args.get("seconds", "-1"))
	shot_dir = Paths.artifacts(String(args.get("out", "audio_dev")).replace("audio_dev", "audio/dev"))
	for s in String(args.get("shots", "")).split(",", false):
		shots.append(float(s))
	_build_world()
	player = Fixture.MockPlayer.new()
	player.name = "MockPlayer"
	player.mass = 0.03
	add_child(player)
	cam = Camera3D.new()
	cam.far = 3000.0
	add_child(cam)
	cam.make_current()
	_spawn_npcs()
	director = (load(Fixture.DIRECTOR) as PackedScene).instantiate() as AudioDirector
	director.async_build = true
	add_child(director)
	_build_hud()
	Game.set_state(Game.State.PLAYING)
	print("[audio] dev scene: %s" % ("scripted tour" if tour else "manual (keys in the header comment)"))


func _build_world() -> void:
	world = Fixture.MockWorld.new()
	var marks: Array[Dictionary] = []
	for lm in LANDMARKS:
		marks.append(lm)
	world.marks = marks
	add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#a9c8e8")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#c9d6e0")
	e.fog_enabled = true
	e.fog_light_color = Color("#bcd2e6")
	e.fog_density = 0.0015
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1400, 1400)
	ground.mesh = pm
	ground.material_override = _mat(Color("#8fa65a"))
	add_child(ground)
	# Flat-shaded low-poly markers for each zone.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	for lm in LANDMARKS:
		if lm["kind"] == "landmark":
			continue
		var disc := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = lm["radius"]
		cyl.bottom_radius = lm["radius"]
		cyl.height = 0.3
		cyl.radial_segments = 12
		disc.mesh = _flat(cyl)
		disc.material_override = _mat(lm["color"])
		disc.position = lm["position"] + Vector3(0, 0.1, 0)
		add_child(disc)
		var n := 30 if lm["kind"] == "forest" else (8 if lm["kind"] == "town" else 0)
		for i in n:
			var a := rng.randf() * TAU
			var r := sqrt(rng.randf()) * float(lm["radius"]) * 0.9
			var p: Vector3 = lm["position"] + Vector3(cos(a) * r, 0, sin(a) * r)
			var mi := MeshInstance3D.new()
			if lm["kind"] == "forest":
				var cone := CylinderMesh.new()
				cone.top_radius = 0.0
				cone.bottom_radius = rng.randf_range(4, 7)
				cone.height = rng.randf_range(12, 22)
				cone.radial_segments = 6
				mi.mesh = _flat(cone)
				mi.material_override = _mat(Color("#2f5530"))
				mi.position = p + Vector3(0, cone.height * 0.5, 0)
			else:
				var box := BoxMesh.new()
				box.size = Vector3(rng.randf_range(8, 14), rng.randf_range(6, 10), rng.randf_range(8, 12))
				mi.mesh = _flat(box)
				mi.material_override = _mat(Color("#d9c3a0"))
				mi.position = p + Vector3(0, box.size.y * 0.5, 0)
			add_child(mi)
	var spire := MeshInstance3D.new()
	var sp := CylinderMesh.new()
	sp.top_radius = 0.0
	sp.bottom_radius = 4.0
	sp.height = 30.0
	sp.radial_segments = 4
	spire.mesh = _flat(sp)
	spire.material_override = _mat(Color("#8a7f78"))
	spire.position = Vector3(180, 15, 200)
	add_child(spire)


## Flat-shaded (faceted) copy of a primitive mesh: every triangle gets its
## own vertices, so generated normals are per face (the project's low-poly look).
func _flat(mesh: Mesh) -> Mesh:
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.deindex()
	st.generate_normals()
	return st.commit()


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m


func _spawn_npcs() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12
	var plan := [[&"sparrow", 8, Vector3(-300, 8, 0)], [&"wren", 5, Vector3(0, 6, -250)], [&"starling", 6, Vector3(0, 20, -230)],
		[&"swallow", 5, Vector3(-280, 15, 40)], [&"gull", 4, Vector3(250, 25, -80)], [&"crow", 3, Vector3(-60, 30, -150)],
		[&"pigeon", 5, Vector3(180, 14, 200)], [&"moth", 3, Vector3(-300, 18, -40)], [&"eagle", 1, Vector3(250, 60, 0)]]
	for spec in plan:
		for i in spec[1]:
			var b := Fixture.MockNpc.new()
			b.species = spec[0]
			b.mass = float(SizeRules.species_data(spec[0])["mass"])
			add_child(b)
			b.global_position = spec[2] + Vector3(rng.randf_range(-25, 25), rng.randf_range(-3, 5), rng.randf_range(-25, 25))
			var mi := MeshInstance3D.new()
			var pm := PrismMesh.new()
			var span := SizeRules.wingspan_for_mass(b.mass) * 3.0
			pm.size = Vector3(span, 0.2 * span, span * 0.6)
			mi.mesh = _flat(pm)
			mi.rotation_degrees = Vector3(-90, 0, 0)
			mi.material_override = _mat(Color.from_hsv(SizeRules.species_index(b.species) / 10.0, 0.5, 0.8))
			b.add_child(mi)
			npcs.append(b)
	hawk = Fixture.MockNpc.new()
	hawk.species = &"hawk"
	hawk.mass = 1.3
	add_child(hawk)
	hawk.global_position = Vector3(-200, 60, -100)
	npcs.append(hawk)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.98, 0.98, 0.97, 0.88)
	panel.position = Vector2(12, 12)
	panel.size = Vector2(500, 620)
	layer.add_child(panel)
	hud = Label.new()
	hud.position = Vector2(24, 20)
	hud.add_theme_color_override("font_color", Color("#0b0b0b"))
	hud.add_theme_font_size_override("font_size", 15)
	layer.add_child(hud)
	meters = Control.new()
	meters.position = Vector2(24, 440)
	meters.size = Vector2(460, 180)
	meters.draw.connect(_draw_meters)
	layer.add_child(meters)


## Live peak meters per bus (AudioServer's own meters).
func _draw_meters() -> void:
	var buses := [AudioBuses.MASTER, AudioBuses.WIND, AudioBuses.BODY, AudioBuses.CALLS, AudioBuses.DANGER, AudioBuses.SFX, AudioBuses.AMBIENCE, AudioBuses.MUSIC, AudioBuses.UI]
	var font := ThemeDB.fallback_font
	meters.draw_string(font, Vector2(0, 0), "BUS PEAKS (dBFS)", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#0b0b0b"))
	for i in buses.size():
		var bi := AudioBuses.index(buses[i])
		var y := 8.0 + i * 18.0
		var db := -80.0
		if bi >= 0:
			db = maxf(AudioServer.get_bus_peak_volume_left_db(bi, 0), AudioServer.get_bus_peak_volume_right_db(bi, 0))
		var w := clampf((db + 60.0) / 60.0, 0.0, 1.0) * 300.0
		meters.draw_string(font, Vector2(0, y + 12), String(buses[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#52514e"))
		meters.draw_rect(Rect2(80, y + 2, 300, 12), Color("#e6e5e0"))
		meters.draw_rect(Rect2(80, y + 2, w, 12), Color("#e34948") if db > -3.0 else Color("#2a78d6"))
		meters.draw_string(font, Vector2(386, y + 12), "%.0f" % db if db > -79.0 else "-inf", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#52514e"))


func _process(delta: float) -> void:
	if _capturing:
		return
	t += delta
	if _quit_at > 0.0 and t >= _quit_at and not _quitting:
		_quitting = true
		print("[audio] dev scene: %.0f s, shutting down" % t)
		await director.shutdown()
		get_tree().quit()
		return
	if tour:
		_run_tour(delta)
	else:
		_manual(delta)
	player.global_position = _pos
	var fwd := Vector3(sin(_yaw), 0, -cos(_yaw))
	player.velocity = fwd * float(player.tel["airspeed"])
	cam.global_position = _pos
	cam.look_at(_pos + fwd * 10.0 - Vector3(0, 1.5, 0), Vector3.UP)
	# NPCs drift so the 3D calls move.
	for i in npcs.size():
		var b := npcs[i]
		if b == hawk:
			continue
		b.global_position += Vector3(sin(t * 0.5 + i), 0.0, cos(t * 0.4 + i * 1.3)) * delta * 2.0
	_update_hud()
	meters.queue_redraw()
	for s in shots:
		if t >= float(s) and not _events_done.has("shot%s" % s):
			_events_done["shot%s" % s] = true
			var path := shot_dir.path_join("audio_dev_%02d.png" % int(s))
			print("[audio] shot at %.1f s (paused %s)" % [t, get_tree().paused])
			_capturing = true
			await Capture.save_viewport(get_viewport(), path)
			_capturing = false
	_log_t += delta
	if _log_t >= 2.0:
		_log_t = 0.0
		var d := director.debug_snapshot()
		print("[audio] t=%.0f %s x=%.2f body=%.0f edge=%.0f flutter=%.0f hum=%.0f threat=%.2f voices=%d zones=%s perf=%.3f ms" % [
			t, d["state"], d["x"], d["body_db"], d["edge_db"], d["flutter_db"], d["hum_db"], d["threat"], d["voices"], d["zones"], d["perf_ms"]])


func _once(key: String, at: float) -> bool:
	if t >= at and not _events_done.has(key):
		_events_done[key] = true
		return true
	return false


## A 40 s scripted flight that touches every sound.
func _run_tour(delta: float) -> void:
	var tel := player.tel
	var cruise := FlightSoundMap.cruise(player.mass)
	var speed := cruise
	var tuck := false
	var stalled := false
	var lift := 0.0
	var y := 18.0
	if t < 5.0:  # glide over the meadow, a few flaps
		speed = cruise
		if fmod(t, 1.2) < delta:
			Events.player_flapped.emit(0, 0.8)
	elif t < 9.0:  # tucked dive
		var k := (t - 5.0) / 4.0
		speed = cruise * lerpf(1.0, 2.6, k)
		tuck = true
		y = lerpf(18.0, 6.0, k)
	elif t < 11.0:  # pull up, bleed speed
		speed = cruise * lerpf(2.6, 0.5, (t - 9.0) / 2.0)
		y = 6.0 + (t - 9.0) * 3.0
	elif t < 13.5:  # stall, then recover with hard flaps
		speed = cruise * 0.45
		stalled = t < 12.8
		y = 12.0
		if t > 12.8 and fmod(t, 0.4) < delta:
			Events.player_flapped.emit([-1, 1][int(t * 5) % 2], 1.0)
	elif t < 18.0:  # circling in an updraft
		speed = cruise * 0.9
		lift = 3.5 * sin(PI * (t - 13.5) / 4.5)
		y = 12.0 + (t - 13.5) * 4.0
		_yaw += delta * 0.8
	elif t < 23.0:  # a hawk closes in; a catch; a tier-up
		speed = cruise * 1.2
		y = 30.0
		_threat = clampf((t - 18.0) / 3.0, 0.0, 1.0) if t < 21.5 else maxf(0.0, _threat - delta)
		hawk.global_position = _pos + Vector3(0, 8, 40.0 * (1.0 - _threat) + 6.0)
		Events.threat_changed.emit(_threat, hawk if _threat > 0.0 else null)
		if _once("catch", 21.6):
			Events.bird_caught.emit(player, npcs[0])
		if _once("tier", 22.3):
			Events.player_tier_changed.emit(2, 3)
	elif t < 36.0:  # the forest, the lake, the village, low
		# Cruise over the forest; a slow glide over the lake (the speed duck
		# lets the zone back in); cruise on to the village.
		speed = cruise
		if t > 29.0 and t < 33.5:
			speed = cruise * 0.35
		y = 8.0
		if _once("threat0", 23.0):
			Events.threat_changed.emit(0.0, null)
		if fmod(t, 1.5) < delta:
			Events.player_flapped.emit(0, 0.6)
		var k2 := (t - 23.0) / 13.0
		var way := [Vector3(-220, 0, -120), Vector3(0, 0, -250), Vector3(250, 0, -80), Vector3(180, 0, 200)]
		var seg := minf(k2 * 3.0, 2.999)
		var p := (way[int(seg)] as Vector3).lerp(way[int(seg) + 1], seg - int(seg))
		var to := Vector3(p.x, y, p.z) - _pos
		if to.length() > 0.1:
			_yaw = atan2(to.x, -to.z)
		_pos = _pos.lerp(Vector3(p.x, y, p.z), 1.0 - exp(-delta * 2.0))
	elif t < 38.0:
		if _once("pause", 36.0):
			Game.set_state(Game.State.PAUSED)
	else:
		if _once("play", 38.0):
			Game.set_state(Game.State.PLAYING)
	if t < 23.0:
		var fwd := Vector3(sin(_yaw), 0, -cos(_yaw))
		_pos += fwd * speed * delta * 0.4
		_pos.y = lerpf(_pos.y, y, 1.0 - exp(-delta * 3.0))
	tel["airspeed"] = speed
	tel["tucked"] = tuck
	tel["wing_extension"] = 0.1 if tuck else 1.0
	tel["stalled"] = stalled
	tel["in_updraft"] = maxf(0.0, lift)


func _manual(delta: float) -> void:
	var tel := player.tel
	var cruise := FlightSoundMap.cruise(player.mass)
	var v: float = tel["airspeed"]
	if Input.is_physical_key_pressed(KEY_W):
		v += cruise * delta
	if Input.is_physical_key_pressed(KEY_S):
		v -= cruise * delta
	tel["airspeed"] = clampf(v, 0.0, cruise * 2.8)
	tel["tucked"] = Input.is_physical_key_pressed(KEY_T)
	tel["wing_extension"] = 0.1 if tel["tucked"] else 1.0
	tel["stalled"] = Input.is_physical_key_pressed(KEY_X)
	tel["in_updraft"] = 3.0 if Input.is_physical_key_pressed(KEY_U) else 0.0
	_yaw += (float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))) * delta
	_pos += Vector3(sin(_yaw), 0, -cos(_yaw)) * float(tel["airspeed"]) * delta


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_F:
			Events.player_flapped.emit(0, 1.0)
		KEY_Q:
			Events.player_flapped.emit(-1, 1.0)
		KEY_E:
			Events.player_flapped.emit(1, 1.0)
		KEY_C:
			Events.bird_caught.emit(player, npcs[0])
		KEY_G:
			Events.player_caught.emit(hawk)
		KEY_L:
			Events.player_tier_changed.emit(2, 3)
		KEY_B:
			Events.player_collided.emit(6.0, Vector3.UP)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var lv := (k.physical_keycode - KEY_1) / 4.0
			hawk.global_position = _pos + Vector3(0, 8, 40.0 * (1.0 - lv) + 6.0)
			Events.threat_changed.emit(lv, hawk if lv > 0.0 else null)
		KEY_P:
			Game.set_state(Game.State.PAUSED if Game.state != Game.State.PAUSED else Game.State.PLAYING)
		KEY_M:
			Game.set_state(Game.State.MENU)
		KEY_ENTER:
			Game.set_state(Game.State.PLAYING)


func _update_hud() -> void:
	var d := director.debug_snapshot()
	var tel := player.tel
	var z: Dictionary = d["zones"]
	var zs := ""
	for k in z:
		zs += "%s %.2f  " % [k, z[k]]
	hud.text = "AUDIO DEV  t=%.1f s  %s%s\n\nairspeed %.1f m/s (x %.2f cruise)\ntucked %s   stalled %s   updraft %.1f m/s\nthreat %.2f   heart %.0f bpm (fixed pitch)\n\nwind body  %6.1f dB   cut-off %5.0f Hz  high-pass %3.0f Hz\nwind edge  %6.1f dB\nbuffet     %6.1f dB\nupdraft    %6.1f dB\n\nvoices %d/8   crowd %.1f dB   calls speed duck %.1f dB\nzones  %s\nambience speed duck %.1f dB\nduck sfx %.1f / ambience %.1f dB   music %.1f dB\nbank %s   cost %.3f ms/frame" % [
		t, d["state"], "  (tour)" if tour else "", tel["airspeed"], d["x"], tel["tucked"], tel["stalled"], tel["in_updraft"], d["threat"], d["heart_bpm"],
		d["body_db"], d["cutoff"], d["highpass"], d["edge_db"], d["flutter_db"], d["hum_db"],
		d["voices"], director.voices.crowd_db, director.voices.speed_duck_db, zs, d["amb_speed_duck_db"], d["duck_db"], d["amb_duck_db"], d["music_db"],
		"ready" if d["bank_ready"] else "synthesizing...", d["perf_ms"]]
