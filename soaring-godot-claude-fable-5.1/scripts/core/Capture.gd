class_name Capture
extends RefCounted

## Photographs a viewport to a PNG. Under XR the main viewport is submitted
## straight to the compositor and reads back black, so the shot is taken through
## a mirror camera pinned to `eye` rendering into its own SubViewport.
static func snapshot(host: Node, path: String, eye: Camera3D, xr_live: bool, size: Vector2i = Vector2i(1280, 720)) -> void:
	var source: Viewport = host.get_viewport()
	var mirror: SubViewport = null
	if xr_live:
		mirror = SubViewport.new()
		mirror.size = size
		mirror.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		host.add_child(mirror)
		var cam := Camera3D.new()
		cam.far = eye.far
		cam.fov = 90.0
		mirror.add_child(cam)
		cam.global_transform = eye.global_transform
		source = mirror
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img: Image = source.get_texture().get_image()
	var err: int = img.save_png(path)
	print("[capture] %s (%d) %dx%d" % [path, err, img.get_width(), img.get_height()])
	if mirror:
		mirror.queue_free()
