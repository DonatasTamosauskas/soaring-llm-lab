extends RefCounted
## Helpers for the birds shot scripts: an isolated lit stage (SubViewport
## with its own World3D, sky-ish background, sun, fill light) and capture.
## Preload it: const Stage := preload("res://tests/shots/birds_stage.gd").

const BG := Color(0.86, 0.89, 0.92)


## A SubViewport stage under `parent`. ortho_size > 0 gives an orthographic
## camera of that size, else a perspective camera with `fov`.
static func make(parent: Node, size: Vector2i, bg: Color = BG, ortho_size: float = 1.2, fov: float = 40.0) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = size
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(vp)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = bg
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.82, 0.9)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.light_energy = 1.25
	sun.rotation_degrees = Vector3(-52, -35, 0)
	vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.75, 0.82, 1.0)
	fill.light_energy = 0.35
	fill.rotation_degrees = Vector3(40, 150, 0)
	vp.add_child(fill)
	var cam := Camera3D.new()
	cam.name = "Cam"
	if ortho_size > 0.0:
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = ortho_size
	else:
		cam.fov = fov
	cam.near = 0.01
	cam.far = 500.0
	vp.add_child(cam)
	cam.current = true
	return vp


static func cam(vp: SubViewport) -> Camera3D:
	return vp.get_node("Cam") as Camera3D


## Points the stage camera: view = "top", "bottom", "side", "front", "behind",
## "above_behind" (35 deg up), "three_q", "three_q_below".
static func aim(vp: SubViewport, view: String, target: Vector3 = Vector3.ZERO, dist: float = 4.0) -> void:
	var c := cam(vp)
	match view:
		"top":
			c.position = target + Vector3(0, dist, 0)
			c.look_at(target, Vector3.FORWARD)
		"bottom":
			c.position = target + Vector3(0, -dist, 0)
			c.look_at(target, Vector3.FORWARD)
		"side":
			c.position = target + Vector3(-dist, 0, 0)
			c.look_at(target, Vector3.UP)
		"front":
			c.position = target + Vector3(0, 0, -dist)
			c.look_at(target, Vector3.UP)
		"behind":
			c.position = target + Vector3(0, 0, dist)
			c.look_at(target, Vector3.UP)
		"above_behind":
			c.position = target + Vector3(0, sin(deg_to_rad(35.0)), cos(deg_to_rad(35.0))) * dist
			c.look_at(target, Vector3.UP)
		"three_q":
			c.position = target + Vector3(-0.75, 0.45, -0.7).normalized() * dist
			c.look_at(target, Vector3.UP)
		"three_q_below":
			c.position = target + Vector3(-0.6, -0.5, -0.75).normalized() * dist
			c.look_at(target, Vector3.UP)


## Renders the stage (birds sync right before drawing) and returns the image.
static func grab(vp: SubViewport) -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


## Pixels of a stage frame that differ from the stage background (a cell with
## almost none means no bird was drawn: a shader that failed to compile, a
## model that never attached).
static func bird_px(img: Image, bg: Color = BG) -> int:
	var d := img.get_data()
	var n := 0
	var b := [bg.r8, bg.g8, bg.b8]
	for i in range(0, d.size(), 4):
		if absi(d[i] - b[0]) + absi(d[i + 1] - b[1]) + absi(d[i + 2] - b[2]) > 40:
			n += 1
	return n


static func save(img: Image, name: String) -> String:
	var path := Paths.artifacts("birds").path_join(name)
	img.save_png(path)
	print("[birds] wrote ", path)
	return path


## Draws text labels over an image (via a 2D SubViewport) and returns the
## result. labels: [[text, Vector2 pos, font size, Color]].
static func annotate(parent: Node, img: Image, labels: Array) -> Image:
	var vp := SubViewport.new()
	vp.size = img.get_size()
	vp.transparent_bg = false
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(vp)
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.size = Vector2(img.get_size())
	vp.add_child(tr)
	for l in labels:
		var lb := Label.new()
		lb.text = l[0]
		lb.position = l[1]
		lb.add_theme_font_size_override("font_size", l[2])
		lb.add_theme_color_override("font_color", l[3])
		lb.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.8) if (l[3] as Color).get_luminance() < 0.5 else Color(0, 0, 0, 0.8))
		lb.add_theme_constant_override("outline_size", 4)
		vp.add_child(lb)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var out := vp.get_texture().get_image()
	vp.queue_free()
	return out
