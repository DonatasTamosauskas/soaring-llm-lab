class_name XRMirror
extends Node
## Screenshots of what the headset sees.
##
## The XR viewport reads back black on macOS, so this renders a plain
## Camera3D that copies the XR camera's pose into its own SubViewport. It
## proves what the scene looks like from the head; it does not read the frames
## submitted to the compositor.
##
## The mirror only renders around a capture (a second full view of the world
## every frame would cost as much as the headset view itself; it sits in
## main.tscn). Set `always_render` for a live mirror.
##
## Add as a child of anything, set `source` to the XRCamera3D. With user arg
## --xrshot=<sec>[,<sec>...] it captures artifacts/xr/<prefix>_<sec>s.png at
## those times; --xrshot_prefix=<name> sets the prefix (default "xr") and
## --xrshot_dir=<area> the artifacts subfolder (default "xr").

@export var source: Camera3D
@export var size := Vector2i(1280, 960)
@export var always_render := false
@export var fov := 90.0

var _vp: SubViewport
var _cam: Camera3D
var _times: Array[float] = []
var _t := 0.0
var _prefix := "xr"
var _dir := "xr"
var _rendering := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_vp = SubViewport.new()
	_vp.size = size
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if always_render else SubViewport.UPDATE_DISABLED
	_vp.world_3d = get_viewport().world_3d
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = fov
	_cam.near = 0.02
	_cam.far = 4000.0
	_vp.add_child(_cam)
	_cam.current = true
	var args := Paths.user_args()
	_prefix = args.get("xrshot_prefix", "xr")
	_dir = args.get("xrshot_dir", "xr")
	if args.has("xrshot"):
		for s in String(args["xrshot"]).split(","):
			_times.append(float(s))
		_times.sort()


func _process(delta: float) -> void:
	_sync_camera()
	_t += delta
	if not _times.is_empty() and _t >= _times[0]:
		var at := _times.pop_front() as float
		capture(Paths.artifacts(_dir).path_join("%s_%ds.png" % [_prefix, int(at)]))


func _sync_camera() -> void:
	if source and is_instance_valid(source):
		_cam.global_transform = source.global_transform
		_cam.near = source.near
		_cam.environment = source.environment
		_cam.cull_mask = source.cull_mask


## Renders the mirror for a couple of frames and writes it as a PNG.
func capture(path: String) -> Error:
	var img := await capture_image()
	if img == null or img.is_empty():
		push_error("[vr] mirror capture failed for " + path)
		return FAILED
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	print("[capture] %s -> %s" % [error_string(err), path])
	return err


## The mirror image of the current head pose (renders on demand).
func capture_image() -> Image:
	_rendering += 1
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Two drawn frames: the first renders with this frame's pose, the second
	# guarantees the texture is resolved before the read-back.
	for i in 2:
		_sync_camera()
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	_rendering -= 1
	if _rendering <= 0 and not always_render:
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return img

