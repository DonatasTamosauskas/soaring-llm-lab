class_name DeviceDiagnostic
extends Node

## Periodic on-device state dump, readable with `adb logcat -s godot`.
##
## Exists because a headset is a black box: you cannot attach a debugger to the
## thing on your face, and "I can't see the world" has half a dozen very
## different causes that look identical from the inside. The numbers below are
## chosen to tell those causes apart in one sample:
##
## [br]- Draw calls and primitives near zero means nothing is being rendered.
## [br]- Draw calls high but nothing visible means it is being rendered
##   somewhere the player is not.
## [br]- Player altitude below terrain height means they fell through the world.
## [br]- Camera far from the player body means the rig came apart.

const INTERVAL: float = 2.0
## Stops on its own so a long play session does not spam the log.
const SAMPLES: int = 20

var player: BirdPlayer
var world: WorldBuilder

var _timer: float = 0.0
var _count: int = 0


func start(player_ref: BirdPlayer, world_ref: WorldBuilder) -> void:
	player = player_ref
	world = world_ref
	print("[diag] renderer=%s driver=%s xr=%s" % [
		ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"),
		RenderingServer.get_video_adapter_name(),
		str(player.xr_active)
	])
	_report_scene()


## One-off inventory of what actually got built and whether it is set up to be
## seen: how many meshes exist, how many are flagged visible, and whether there
## is a light and an environment at all.
func _report_scene() -> void:
	var meshes: int = 0
	var visible_meshes: int = 0
	var ranged: int = 0
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			meshes += 1
			var mesh := node as MeshInstance3D
			if mesh.is_visible_in_tree():
				visible_meshes += 1
			if mesh.visibility_range_end > 0.0:
				ranged += 1

	var lights: int = 0
	var envs: int = 0
	stack = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is DirectionalLight3D:
			lights += 1
		if node is WorldEnvironment:
			envs += 1

	print("[diag] meshes=%d visible=%d with_range=%d lights=%d envs=%d" % [
		meshes, visible_meshes, ranged, lights, envs
	])


func _process(delta: float) -> void:
	if player == null or _count >= SAMPLES:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = INTERVAL
	_count += 1
	_sample()
	# One picture from inside the headset, once the world has settled. Worth
	# more than any amount of telemetry when the complaint is "I can't see it".
	if _count == 3:
		var main: Node = get_parent()
		if main.has_method("capture_headset_view"):
			main.capture_headset_view("user://headset.png")


func _sample() -> void:
	var body: Vector3 = player.global_position
	var head: Vector3 = player.head_position()
	var ground: float = world.height_at(body.x, body.z)

	var draw_calls: int = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	)
	var primitives: int = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)
	var objects: int = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME
	)

	print("[diag] body=(%.1f,%.1f,%.1f) head=(%.1f,%.1f,%.1f) ground=%.1f above=%.1f" % [
		body.x, body.y, body.z, head.x, head.y, head.z, ground, body.y - ground
	])
	print("[diag] speed=%.1f perched=%s span=%.2f | draws=%d objs=%d prims=%d fps=%d" % [
		player.airspeed(), str(player.perched), player.command.span,
		draw_calls, objects, primitives, Engine.get_frames_per_second()
	])

	# Is the nearest piece of world actually near? If the closest building is
	# 900 m away the player has been flung off the map, whatever else is true.
	var nearest: float = INF
	var nearest_name: String = "none"
	for child in world.get_children():
		if child is Node3D and child.name.begins_with("Building"):
			var d: float = (child as Node3D).global_position.distance_to(body)
			if d < nearest:
				nearest = d
				nearest_name = child.name
	print("[diag] nearest building %s at %.1f m" % [nearest_name, nearest])
