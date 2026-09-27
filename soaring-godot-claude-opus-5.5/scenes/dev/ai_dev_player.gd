class_name AiDevPlayer
extends Bird
## Dev-scene stand-in for the player: a free-flying camera that is a Bird
## (is_player() == true), so the Ecosystem centres the sky on it and NPCs
## hunt it / flee it by the size rules. Its mass is changed with [ and ].
##
## Controls: WASD move, Q/E down/up, Shift fast, hold right mouse to look.
## Never caught (on_caught just counts), so you can watch hunts on yourself.

var cam: Camera3D
var speed := 12.0
var caught_count := 0
var _yaw := 0.0
var _pitch := -0.2


func _ready() -> void:
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.near = 0.05
	cam.far = 3000.0
	add_child(cam)
	cam.current = true


func is_player() -> bool:
	return true


func get_view_direction() -> Vector3:
	return -cam.global_basis.z


func get_body_position() -> Vector3:
	return cam.global_position


func on_caught(_by: Bird) -> void:
	caught_count += 1


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= event.relative.x * 0.004
		_pitch = clampf(_pitch - event.relative.y * 0.004, -1.4, 1.4)


func _process(delta: float) -> void:
	var b := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	cam.basis = b
	var mv := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		mv += -b.z
	if Input.is_key_pressed(KEY_S):
		mv += b.z
	if Input.is_key_pressed(KEY_A):
		mv += -b.x
	if Input.is_key_pressed(KEY_D):
		mv += b.x
	if Input.is_key_pressed(KEY_E):
		mv += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		mv += Vector3.DOWN
	var s := speed * (4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	velocity = mv.normalized() * s if mv.length_squared() > 0.0 else Vector3.ZERO
	global_position += velocity * delta


func look_at_point(p: Vector3) -> void:
	var d := (p - cam.global_position).normalized()
	_yaw = atan2(-d.x, -d.z)
	_pitch = asin(clampf(d.y, -1.0, 1.0))
