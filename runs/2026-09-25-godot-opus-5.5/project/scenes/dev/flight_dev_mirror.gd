extends Node
## The flight lab's own head-view capture (flight owns it; the VR area's
## mirror is its internal). The XR viewport reads back black on macOS, so a
## plain Camera3D copies the XR camera's global pose into a SubViewport of
## the same world and renders only when a capture is due.
##
##   --labshot=<sec>[,<sec>...]   capture artifacts/flight/xr_<prefix>_<sec>s.png
##   --labshot_prefix=<name>      (default "lab")

var source: Camera3D
var size := Vector2i(1280, 960)
var fov := 90.0

var _vp: SubViewport
var _cam: Camera3D
var _times: Array[float] = []
var _t := 0.0
var _prefix := "lab"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_vp = SubViewport.new()
	_vp.size = size
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.world_3d = get_viewport().world_3d
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = fov
	_cam.near = 0.01
	_cam.far = 3000.0
	_vp.add_child(_cam)
	_cam.current = true
	var args := Paths.user_args()
	_prefix = args.get("labshot_prefix", "lab")
	if args.has("labshot"):
		for s in String(args["labshot"]).split(","):
			_times.append(float(s))
		_times.sort()


func _process(delta: float) -> void:
	_t += delta
	if source != null and is_instance_valid(source):
		_cam.global_transform = source.global_transform
		_cam.near = maxf(source.near, 0.005)
	if not _times.is_empty() and _t >= _times[0]:
		var at: float = _times.pop_front()
		capture(Paths.artifacts("flight").path_join("xr_%s_%ds.png" % [_prefix, int(at)]))


func capture(path: String) -> void:
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png(path)
		print("[flight] mirror capture %s" % path)
