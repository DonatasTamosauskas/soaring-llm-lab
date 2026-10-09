extends Node3D
## The aviary: the birds area on its own (no World, no AI).
##
##   tools/gd.sh birds --rendering-method forward_plus res://scenes/dev/birds_dev.tscn
##   (add -- --shot=4 to save artifacts/birds/dev_aviary.png after 4 s and quit;
##   --highlight=1|2 --mode=1..5 --dist=m start in that state and name the
##   file dev_aviary_hl<h>_mode<m>.png)
##
## All ten species circle at true size, a row sits on a branch, a hawk
## stoops with wingtip trails. Keys:
##   1 flap   2 glide   3 half tuck   4 dive tuck   5 all perch
##   H cycle highlights (none / edible / danger)   B banking on/off
##   Space feather burst (catch the nearest bird)  L show LOD tint in log
##   mouse drag orbit, wheel zoom, Esc quit

enum Mode { FLAP, GLIDE, HALF_TUCK, TUCK, PERCH }

var mode := Mode.FLAP
var highlight := 0
var banking := true
var flyers: Array[Node3D] = []
var flyer_models: Array[BirdModel] = []
var perchers: Array[BirdModel] = []
var hawk: Bird
var hawk_model: BirdModel
var trails: WingTrails
var cam: Camera3D
var yaw := 0.4
var pitch := -0.22
var dist := 13.0
var t := 0.0
var _drag := false
var _label: Label
var _shot := -1.0


func _ready() -> void:
	BirdModels.prewarm()
	_environment()
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.far = 2000.0
	add_child(cam)
	cam.current = true
	# Ten species in a ring, each at its true wingspan.
	for i in BirdSpecies.IDS.size():
		var sp: StringName = BirdSpecies.IDS[i]
		var h := Node3D.new()
		add_child(h)
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		h.add_child(m)
		flyers.append(h)
		flyer_models.append(m)
	# A branch with a row of perched birds (feet on the branch top).
	var branch := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.035
	cm.bottom_radius = 0.05
	cm.height = 5.0
	cm.radial_segments = 6
	branch.mesh = cm
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color("6b4f3b")
	branch.material_override = bm
	branch.rotation_degrees = Vector3(0, 0, 90)
	branch.position = Vector3(0, 2.0, 5.0)
	add_child(branch)
	var x := -2.2
	for sp in [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow"]:
		var span: float = SizeRules.species_data(sp)["span"]
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * span
		m.perched = true
		m.wing_fold = 1.0
		add_child(m)
		# The perch grip is the branch top; the body centre sits one body
		# radius (0.16 x span) above it.
		m.position = Vector3(x + span * 0.5, 2.0 + 0.035 + 0.16 * span, 5.0)
		m.rotation.y = PI * 0.5 * (1.0 if int(x * 10) % 2 == 0 else -1.0) * 0.4
		x += span + 0.25
		perchers.append(m)
	# A stooping hawk with trails.
	hawk = Bird.new()
	hawk.mass = 1.3
	hawk.species = &"hawk"
	add_child(hawk)
	hawk_model = BirdModels.create(&"hawk")
	hawk_model.scale = Vector3.ONE * 1.6
	hawk.add_child(hawk_model)
	trails = BirdFX.attach_trails(hawk_model)
	var cl := CanvasLayer.new()
	add_child(cl)
	_label = Label.new()
	_label.position = Vector2(12, 8)
	_label.add_theme_color_override("font_color", Color(0.08, 0.08, 0.1))
	_label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.8))
	_label.add_theme_constant_override("outline_size", 5)
	cl.add_child(_label)
	_shot = float(Paths.arg("shot", "-1"))
	highlight = int(Paths.arg("highlight", "0"))
	mode = int(Paths.arg("mode", "1")) - 1 as Mode
	dist = float(Paths.arg("dist", str(dist)))
	print("[birds] aviary: 1-5 modes, H highlight, B banking, Space feathers, drag to orbit")


func _environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color("5f8fc4")
	sm.sky_horizon_color = Color("b9cfe0")
	sm.ground_horizon_color = Color("b9cfe0")
	sm.ground_bottom_color = Color("6d8a5a")
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color("b9cfe0")
	env.fog_density = 0.002
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 130, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color("86a95a")
	ground.material_override = gm
	add_child(ground)


func _process(delta: float) -> void:
	t += delta
	for i in flyers.size():
		var h := flyers[i]
		var m := flyer_models[i]
		var r := 2.4 + i * 0.55
		var a := t * (0.9 / sqrt(r)) + i * 0.7
		var y := 3.4 + i * 0.3 + sin(t * 0.7 + i) * 0.25
		h.position = Vector3(cos(a) * r, y, sin(a) * r)
		h.rotation = Vector3(0, -a, 0)
		var hz := clampf(3.8 * pow(float(SizeRules.species_data(m.species)["mass"]), -0.22), 2.2, 14.0)
		m.flap_phase = fposmod(m.flap_phase + delta * hz, 1.0)
		match mode:
			Mode.FLAP:
				m.flap_amount = 1.0
				m.wing_fold = 0.0
				m.perched = false
			Mode.GLIDE:
				m.flap_amount = 0.0
				m.wing_fold = 0.0
				m.perched = false
			Mode.HALF_TUCK:
				m.flap_amount = 0.0
				m.wing_fold = 0.5
				m.perched = false
			Mode.TUCK:
				m.flap_amount = 0.0
				m.wing_fold = 1.0
				m.perched = false
			Mode.PERCH:
				m.flap_amount = 0.0
				m.wing_fold = 1.0
				m.perched = true
		# Bank into the circle (positive bank = right wing down), shown
		# steeper than the real coordinated angle so it reads.
		var into := signf(h.global_basis.x.dot(-Vector3(h.position.x, 0.0, h.position.z)))
		m.bank = into * atan(pow(0.9 / sqrt(r), 2.0) * r / 9.81) * 4.0 if banking and mode != Mode.PERCH else 0.0
		m.highlight = highlight if i % 2 == 0 else 0
	for m in perchers:
		m.highlight = highlight
	# The hawk: a repeating stoop from 40 m with trails.
	var ht := fmod(t, 4.0)
	var start := Vector3(-18, 40, -20)
	var v := Vector3(4, -30, 12)
	hawk.velocity = v if ht < 1.3 else Vector3(12, 0, 0)
	hawk.position = start + v * minf(ht, 1.3) + Vector3(12, 0, 0) * maxf(ht - 1.3, 0.0)
	hawk.look_at(hawk.position + hawk.velocity, Vector3.UP)
	hawk_model.wing_fold = 0.9 if ht < 1.3 else 0.0
	hawk_model.flap_amount = 0.0 if ht < 1.3 else 0.8
	hawk_model.flap_phase = fposmod(t * 3.2, 1.0)
	# Orbit camera.
	var c := Vector3(0, 3.6, 1.0)
	cam.position = c + Vector3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw)) * dist
	cam.look_at(c, Vector3.UP)
	_label.text = "Birds aviary  |  mode: %s  highlight: %s  bank: %s  |  60 fps budget: sync %d us for %d birds, %d batches" % [
		Mode.keys()[mode], ["none", "edible", "danger"][highlight], "on" if banking else "off",
		BirdBatch.last_sync_usec, BirdBatch.last_sync_models, BirdBatch.count()]
	if _shot > 0.0 and t >= _shot:
		_shot = -1.0
		_save_shot()


func _save_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var file := "dev_aviary.png"
	if highlight != 0 or mode != Mode.FLAP:
		file = "dev_aviary_hl%d_mode%d.png" % [highlight, mode + 1]
	img.save_png(Paths.artifacts("birds").path_join(file))
	print("[birds] wrote ", file)
	get_tree().quit()


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_1:
				mode = Mode.FLAP
			KEY_2:
				mode = Mode.GLIDE
			KEY_3:
				mode = Mode.HALF_TUCK
			KEY_4:
				mode = Mode.TUCK
			KEY_5:
				mode = Mode.PERCH
			KEY_H:
				highlight = (highlight + 1) % 3
			KEY_B:
				banking = not banking
			KEY_SPACE:
				_burst()
			KEY_ESCAPE:
				get_tree().quit()
	elif e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			_drag = e.pressed
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = maxf(2.0, dist * 0.9)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = minf(80.0, dist * 1.1)
	elif e is InputEventMouseMotion and _drag:
		yaw -= e.relative.x * 0.006
		pitch = clampf(pitch + e.relative.y * 0.006, -1.4, 0.6)


## Feathers from the flyer nearest the camera's view centre.
func _burst() -> void:
	var best: BirdModel = null
	var bd := INF
	for m in flyer_models:
		var d := m.global_position.distance_to(cam.global_position)
		if d < bd:
			bd = d
			best = m
	if best:
		var span: float = SizeRules.species_data(best.species)["span"]
		BirdFX.feather_burst(self, best.global_position, Color(0, 0, 0, 0), span, best.species)
