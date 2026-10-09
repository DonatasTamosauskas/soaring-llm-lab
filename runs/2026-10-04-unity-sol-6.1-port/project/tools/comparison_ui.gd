extends Node
# Short version of the existing integration screenshot harness.
const Kit := preload("res://tests/unit/integration/game_kit.gd")
var main: GameMain
var kit: Kit
var output := ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = get_parent() as GameMain
	if not main.is_loaded:
		await main.loaded
	_run.call_deferred()

func shot(id: String) -> void:
	await Capture.save_viewport(get_viewport(), output.path_join(id + ".png"))

func _run() -> void:
	output = OS.get_environment("SOARING_COMPARISON_OUTPUT")
	kit = Kit.new()
	kit.attach(self, main)
	main.ui.set_vr_mode(true)
	kit.left = UIPointerSource.new(&"left_hand")
	kit.right = UIPointerSource.new(&"right_hand")
	main.ui.set_pointer_sources(kit.left, kit.right)
	kit.park_hands()
	main.player.camera.fov = 90.0
	await kit.advance(2.0)
	kit.aim_at(kit.button(&"main", &"play"))
	await kit.frames(6)
	await shot("menu")
	main.ui.onboarding.reset()
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	kit.fly_bot(7)
	kit.orbit_centre = Vector3(WorldLayout.SQUARE.x, 0, WorldLayout.SQUARE.y)
	kit.orbit_radius = 70.0
	kit.set_mode(&"climb")
	await kit.advance(4.0)
	kit.set_mode(&"cruise")
	for i in 80:
		kit.bot.body.head_yaw = deg_to_rad(-18.0)
		kit.bot.body.head_pitch = deg_to_rad(-12.0)
		await kit.advance(0.1)
	await kit.frames(3)
	await shot("flight")
	print("COMPARISON_GODOT_UI_OK state=", Game.state_name())
	main.audio.shutdown()
	get_tree().quit()
