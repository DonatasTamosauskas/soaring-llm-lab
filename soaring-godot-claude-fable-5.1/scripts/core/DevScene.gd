class_name DevScene
extends Node3D

## Base for an area's development scene: boots XR if a runtime is present,
## spawns the player bird, and honours the shared test flags:
##   --xr-mode off                 desktop camera (use this for automated shots)
##   --capture=/tmp/x.png          photograph what the player sees
##   --capture_delay=4             ...after this many seconds
##   --quit_after=10               exit the process
##   --spawn=x,y,z                 where the player starts
##   --look=x,y,z                  which way the player faces (heading)
##   --flightlog                   print the flight state every second
## Override `_setup()` to add the area's content, and `_dev_tick(dt)` for logic.

const PLAYER_SCENE: String = "res://scenes/Player.tscn"

var player: BirdPlayer
var xr_live: bool = false

func _ready() -> void:
	xr_live = XRBoot.start(get_viewport())
	player = (load(PLAYER_SCENE) as PackedScene).instantiate() as BirdPlayer
	player.name = "Player"
	add_child(player)
	player.set_xr_active(xr_live)
	var spawn: Vector3 = _vec(Args.value("spawn", "0,60,0"))
	var look: Vector3 = _vec(Args.value("look", "0,0,-1"))
	player.spawn(spawn, look)
	if not xr_live:
		player.camera.current = true
	_setup()
	_maybe_capture()
	var q: String = Args.value("quit_after")
	if q != "":
		get_tree().create_timer(float(q)).timeout.connect(func(): get_tree().quit())
	if Args.flag("flightlog"):
		_log_flight()

func _setup() -> void:
	pass

func _maybe_capture() -> void:
	var path: String = Args.value("capture")
	if path == "":
		return
	await get_tree().create_timer(float(Args.value("capture_delay", "4"))).timeout
	await Capture.snapshot(self, path, player.camera, xr_live)

func _log_flight() -> void:
	while is_inside_tree():
		await get_tree().create_timer(1.0).timeout
		var m := player.model
		print("[flight] t=%.1f pos=%s v=%.1f alpha=%.1f bank=%.1f spread=%.2f flap=%.2f stalled=%s perched=%s" % [
			Time.get_ticks_msec() / 1000.0, m.position.snapped(Vector3.ONE * 0.1), m.airspeed,
			rad_to_deg(m.alpha), rad_to_deg(m.bank), m.spread, player.command.flap, m.stalled, player.perched])

static func _vec(s: String) -> Vector3:
	var p := s.split(",")
	if p.size() != 3:
		return Vector3.ZERO
	return Vector3(float(p[0]), float(p[1]), float(p[2]))
