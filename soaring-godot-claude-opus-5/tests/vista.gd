extends SceneTree

## Photographs the built world from a list of fixed viewpoints.
##
##   godot --xr-mode off --script res://tests/vista.gd -- --out=/tmp/vista
##
## `--capture` only ever shows the spawn point, and the whole question this
## world has to answer is what the *far* edge looks like. This puts a camera
## wherever it needs to be and saves a PNG.

const SETTLE_FRAMES: int = 24

var _world: WorldBuilder
var _camera: Camera3D
var _shots: Array[Dictionary] = []
var _index: int = -1
var _wait: int = 0
var _out: String = "/tmp/vista"


func _process(_delta: float) -> bool:
	if _world == null:
		_setup()
		return false
	if _wait > 0:
		_wait -= 1
		return false
	if _index >= 0:
		var image: Image = get_root().get_texture().get_image()
		image.save_png("%s-%s.png" % [_out, _shots[_index]["name"]])
		print("[vista] %s-%s.png" % [_out, _shots[_index]["name"]])
	_index += 1
	if _index >= _shots.size():
		return true
	var shot: Dictionary = _shots[_index]
	_camera.global_position = shot["at"]
	_camera.look_at(shot["look"], Vector3.UP)
	_wait = SETTLE_FRAMES
	return false


func _setup() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() == 2 and parts[0] == "out":
			_out = parts[1]

	_world = WorldBuilder.new()
	get_root().add_child(_world)
	_world.build()

	_camera = Camera3D.new()
	_camera.fov = 80.0
	_camera.near = 0.05
	_camera.far = 4000.0
	get_root().add_child(_camera)
	_camera.current = true

	var ground: Callable = func(x: float, z: float) -> float:
		return _world.height_at(x, z)

	_shots = [
		_shot("spawn", Vector3(0.0, 95.0, 0.0), Vector3(0.0, 60.0, -400.0)),
		_shot("town-high", Vector3(0.0, 360.0, 300.0), Vector3(0.0, 20.0, -60.0)),
		_shot("greenwood", Vector3(230.0, ground.call(230.0, 90.0) + 110.0, 90.0),
			Vector3(620.0, ground.call(620.0, 40.0) + 60.0, 40.0)),
		_shot("gorge", Vector3(-300.0, ground.call(-300.0, 90.0) + 130.0, 90.0),
			Vector3(-560.0, ground.call(-560.0, 20.0) + 30.0, 20.0)),
		_shot("gorge-inside", Vector3(-430.0, ground.call(-430.0, 40.0) + 30.0, 40.0),
			Vector3(-560.0, ground.call(-560.0, 10.0) + 40.0, 10.0)),
		_shot("spires", Vector3(0.0, 180.0, -300.0), Vector3(0.0, 120.0, -620.0)),
		_shot("downs", Vector3(0.0, 150.0, 380.0), Vector3(0.0, 120.0, 700.0)),
		_shot("rim-outward", Vector3(0.0, 260.0, -560.0), Vector3(0.0, 300.0, -1100.0)),
		_shot("rim-inward", Vector3(0.0, 420.0, -900.0), Vector3(0.0, 0.0, 0.0)),
		_shot("arena-edge", Vector3(430.0, ground.call(430.0, 430.0) + 110.0, 430.0),
			Vector3(760.0, ground.call(760.0, 760.0) + 260.0, 760.0)),
		_shot("far-edge", Vector3(500.0, 620.0, 500.0), Vector3(1000.0, 420.0, 1000.0)),
		_shot("thermal", Vector3(0.0, 120.0, 180.0), Vector3(0.0, 220.0, -120.0)),
	]


func _shot(name: String, at: Vector3, look: Vector3) -> Dictionary:
	return {"name": name, "at": at, "look": look}
