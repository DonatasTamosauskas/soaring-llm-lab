extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1).
## What happens when the bird glides down onto the lake: does it stand on the
## water like on ground? (Seen in a simulator run: the bird ended "grounded"
## on the river by the bridge, eye at the water line.)
##
##   tools/gd.sh pxv_water --rendering-method forward_plus --resolution 1280x960 --fixed-fps 72 res://tests/probes/integration/px_water.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	var main := kit.main
	main.player.camera.fov = 90.0
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	main.ui.onboarding.skip()
	main.game_loop.set_protection(main.player, 1e6)
	var p := main.player
	var lake := Vector3(WorldLayout.LAKE.x, WorldLayout.WATER_Y, WorldLayout.LAKE.y)
	p.start_flying(lake + Vector3(-40, 4.0, 0), -PI / 2.0, 0.0)
	main.game_loop.teleported(p)
	var out := {"water_y": WorldLayout.WATER_Y, "ground_at_lake": main.world.ground_height(lake.x, lake.z)}
	var grounded_at := -1.0
	for i in int(20.0 * 72.0):
		await get_tree().physics_frame
		if p.mode_name() == "grounded" and grounded_at < 0.0:
			grounded_at = i / 72.0
			out["grounded_after_s"] = grounded_at
			out["grounded_pos"] = [snappedf(p.global_position.x, 0.1), snappedf(p.global_position.y, 0.01), snappedf(p.global_position.z, 0.1)]
			out["ground_height_there"] = snappedf(main.world.ground_height(p.global_position.x, p.global_position.z), 0.01)
			out["contacts"] = p.telemetry()["contacts"]
		if grounded_at >= 0.0 and i / 72.0 > grounded_at + 2.0:
			break
	out["mode_end"] = p.mode_name()
	out["y_end"] = snappedf(p.global_position.y, 0.01)
	out["camera_y"] = snappedf(p.camera.global_position.y, 0.01)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(Paths.artifacts("integration").path_join("verify/px_water_standing.png"))
	# Take off again from the water with a flap.
	var e := InputEventKey.new()
	e.keycode = KEY_SPACE
	e.physical_keycode = KEY_SPACE
	e.pressed = true
	Input.parse_input_event(e)
	await kit.advance(2.0)
	e = e.duplicate()
	e.pressed = false
	Input.parse_input_event(e)
	out["after_flap_mode"] = p.mode_name()
	out["after_flap_y"] = snappedf(p.global_position.y, 0.01)
	out["errors"] = kit.log.errors
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/px_water.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_water %s" % out)
	await kit.teardown()
	get_tree().quit()
