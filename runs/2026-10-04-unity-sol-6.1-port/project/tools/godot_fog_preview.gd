extends Node
# Opt-in override for a playable private copy. Never writes a source resource.
var main: GameMain
var mode := "no-fog"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = get_parent() as GameMain
	mode = Paths.arg("fog-preview", "no-fog")
	assert(mode in ["baseline","no-fog","no-fog-linear"])
	if not main.is_loaded: await main.loaded
	var world := main.world as SoaringWorld
	var environment: Environment = world.environment_node.environment
	if mode != "baseline": environment.fog_enabled = false
	if mode == "no-fog-linear": environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	main.ui.refresh_tonemap()
	print("FOG_PREVIEW_READY mode=",mode," fog=",environment.fog_enabled," tonemap=",environment.tonemap_mode)
	var output := Paths.arg("fog-preview-evidence", "")
	if not output.is_empty():
		main.ui.set_vr_mode(true)
		main.player.camera.fov = 90.0
		await get_tree().create_timer(2).timeout
		await Capture.save_viewport(get_viewport(),output.path_join(mode + "-menu.png"))
		main.audio.shutdown()
		get_tree().quit()
