extends Node3D
## Fix round 6 evidence: a bird lands on a village-style pitched roof facing
## the ridge, stands, and takes off over the ridge (the real player rig and
## the scripted arms, flight's own test geometry and the lab's stand-in bird):
##
##   tools/gd.sh flight --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/shots/flight_roof_shots.tscn -- [--species=pigeon] [--pitch=38]
##
## Writes artifacts/flight/r6_roof_<species>_{touchdown,standing,eye,takeoff}.png
## and prints the events. Quits itself.

const PLAYER := preload("res://scenes/player/player.tscn")
const TW := preload("res://tests/unit/flight/flight_test_world.gd")
const LabBird := preload("res://scenes/dev/flight_dev_bird.gd")
const DT := 1.0 / 72.0
const C_ROOF := Color8(170, 86, 62)
const C_GABLE := Color8(226, 206, 170)

var _species := &"pigeon"
var _pitch := 38.0
var _hd := 3.4
var _eave := 5.0
var _ridge := Vector3.ZERO
var world: World
var player: PlayerBird
var bird: Node3D
var src: ScriptedPoseSource
var body: HumanPoseModel
var _phase := 0           # 0 approach, 1 standing, 2 strokes
var _t := 0.0
var _td_t := -1.0
var _flap_t0 := -1.0
var _taken := {}
var _busy := false
var _events := {"perched": 0, "took_off": 0, "collided": 0}
var _out := ""
var _xl := 0.0


func _ready() -> void:
	var args := Paths.user_args()
	_species = StringName(args.get("species", "pigeon"))
	_pitch = float(args.get("pitch", "38"))
	_out = Paths.artifacts("flight")
	_ridge = Vector3(0, _eave + _hd * tan(deg_to_rad(_pitch)), 0)
	_build_scene()
	Events.player_perched.connect(func(_p: Vector3) -> void: _events["perched"] += 1)
	Events.player_took_off.connect(func() -> void: _events["took_off"] += 1)
	Events.player_collided.connect(func(_i: float, _n: Vector3) -> void: _events["collided"] += 1)


func _build_scene() -> void:
	world = TW.new()
	world.visual = true
	add_child(world)
	# The house: walls (8 x 6.8 m, eaves 5 m), the gable roof, the gable ends.
	FlightGeometry.box(world, Vector3(0, 0.5 * _eave, 0), Vector3(8.0, _eave, 2.0 * _hd - 0.4), FlightGeometry.C_WALL, true)
	FlightGeometry.gable_roof(world, _ridge, _pitch, _hd, 9.0, C_ROOF, true)
	for sx: float in [-1.0, 1.0]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_color(C_GABLE)
		var x := 3.99 * sx
		var a := Vector3(x, _eave, _hd - 0.2)
		var b := Vector3(x, _eave, -_hd + 0.2)
		var c := Vector3(x, _ridge.y - 0.15, 0)
		# Both windings: the gable is seen from outside and from the attic.
		for v: Vector3 in [a, b, c, a, c, b]:
			st.add_vertex(v)
		st.generate_normals()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		var m := FlightGeometry.material(C_GABLE)
		mi.material_override = m
		world.add_child(mi)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color8(92, 150, 214)
	sm.sky_horizon_color = Color8(196, 214, 226)
	sm.ground_horizon_color = Color8(170, 186, 160)
	sm.ground_bottom_color = Color8(110, 130, 96)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.8
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 28.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)
	body = HumanPoseModel.new(1)
	src = ScriptedPoseSource.new(body, _drive)
	player = PLAYER.instantiate() as PlayerBird
	player.mass = FlightParams.species_mass(_species)
	player.default_source = &"none"
	player.auto_process = false
	player.use_settings = false
	player.drive_world_scale = true
	add_child(player)
	player.auto_calibrate = false
	player.set_pose_source(src)
	bird = LabBird.new()
	bird.player = player
	add_child(bird)
	# Land 40 % up the front slope (it faces +Z), arriving from +Z toward the
	# ridge at about V_min, a little above the slope.
	var pr := player.model.params
	var th := deg_to_rad(_pitch)
	var zt := 0.6 * _hd
	var yt := _ridge.y - zt * tan(th)
	# Near the gable end (the roof is 9 m wide), so the profile camera off
	# the end sees the bird on the slope's edge line, large in frame.
	_xl = 4.5 - 1.2 * pr.span - 0.3
	var start := Vector3(_xl, yt + pr.r_body + 0.3 * pr.span, zt + 2.0 * pr.span)
	player.start_flying(start, 0.0, 0.0)
	player.model.reset(start, Vector3(0, -0.1, -1.05) * pr.v_min, 0.0)


func _drive(_tick: int, t: float, b: HumanPoseModel) -> void:
	b.set_airplane()
	if _flap_t0 >= 0.0 and t >= _flap_t0:
		ScriptedPoseSource.flap(b, t - _flap_t0 + 0.5, 45.0, 1.3)


func _physics_process(_delta: float) -> void:
	if _busy or player == null:
		return
	player.tick(DT)
	_t += DT
	var pr := player.model.params
	if _td_t < 0.0 and player.mode == PlayerBird.Mode.GROUNDED:
		_td_t = _t
	if _td_t >= 0.0 and not _taken.has("touchdown") and _t >= _td_t + 3.0 * DT:
		_shot("touchdown", _side_cam())
	elif _td_t >= 0.0 and not _taken.has("standing") and _t >= _td_t + 1.2:
		_shot("standing", _side_cam())
	elif _taken.has("standing") and not _taken.has("eye"):
		_shot("eye", player.camera)
		_flap_t0 = src.tick * DT + 0.3
	elif _flap_t0 >= 0.0 and not _taken.has("takeoff") and player.mode == PlayerBird.Mode.FLYING \
			and player.model.position.y > _ridge.y + 0.6 * pr.span:
		_shot("takeoff", _side_cam(true))
	elif _taken.has("takeoff") and not _taken.has("done") and _t > _td_t + 6.0 or _t > 20.0:
		_taken["done"] = true
		print("[flight] roof %s %.0f deg: events %s, mode %s, stuns %d, at %s (ridge %.2f m)" % [_species, _pitch, _events,
			player.mode_name(), player.contacts["stun"], player.model.position.snapped(Vector3.ONE * 0.01), _ridge.y])
		get_tree().quit()


## A camera off the house's gable end, a little above and in front: the
## roof in profile (its slope is the gable's edge line) with the bird on it
## (or, for the take-off, the ridge with the bird above it).
func _side_cam(wide := false) -> Camera3D:
	var pr := player.model.params
	var b := player.model.position
	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.near = 0.02
	cam.far = 2000.0
	add_child(cam)
	var d := (6.5 if wide else 3.2) * pr.span + (1.6 if wide else 0.9)
	var look := Vector3(b.x, b.y, b.z).lerp(Vector3(b.x, _ridge.y, 0.0), 0.3 if wide else 0.1)
	cam.global_position = look + Vector3(d, 0.18 * d, 0.3 * d)
	cam.look_at(look, Vector3.UP)
	return cam


func _shot(name: String, cam: Camera3D) -> void:
	_busy = true
	_taken[name] = true
	var own := cam != player.camera
	var was: Camera3D = get_viewport().get_camera_3d()
	# The eye is inside the stand-in bird: hide it for the first-person view.
	bird.visible = own
	cam.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := _out.path_join("r6_roof_%s_%s.png" % [_species, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("[flight] shot %s: mode %s, body %s, heave/legs offset %s, events %s" % [path, player.mode_name(),
		player.model.position.snapped(Vector3.ONE * 0.001), player.view_offset().snapped(Vector3.ONE * 0.001), _events])
	bird.visible = true
	if own:
		cam.queue_free()
	if was != null and is_instance_valid(was) and was != cam:
		was.current = true
	_busy = false
