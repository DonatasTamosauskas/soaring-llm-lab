extends TestCase
## VERIFIER PROBE (round 6): geometry sanity of the HUD in the real game:
## where the lesson card's words are from the real head camera, in rig
## space, right after Play and after a few seconds of flight.
##   tools/gd.sh ui_verify --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r6x_real_geom --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")
var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _dump(tag: String) -> Dictionary:
	var m := kit.main
	var ui := m.ui
	var rig := m.player.origin
	var cam := m.player.camera
	var inv := rig.global_basis.orthonormalized().inverse()
	var out := {"tag": tag, "ws": rig.world_scale, "cam_local": cam.position, "cam_global": cam.global_position,
		"hud_panel_global": ui.hud_panel.global_position, "hud_panel_basis_scale": ui.hud_panel.global_basis.get_scale(),
		"hud_rig_is_player_rig": ui.hud_panel.rig == rig, "hud_cam_is_player_cam": ui.hud_panel.camera == cam,
		"ui_camera": str(ui.camera), "player_camera": str(cam), "vr_mode": ui.hud_panel.vr_mode, "distance": ui.hud_panel.distance}
	var eye := cam.global_position
	var fwd := inv * (-cam.global_basis.z)
	out["gaze_rig"] = [snappedf(rad_to_deg(atan2(-fwd.x, -fwd.z)), 0.1), snappedf(rad_to_deg(asin(clampf(fwd.y, -1, 1))), 0.1)]
	var words := []
	for lbl: Label in ui.hud.lesson_labels():
		var r := lbl.get_global_rect()
		for x: float in [r.position.x, r.get_center().x, r.end.x]:
			var wp := ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y))
			var d := inv * (wp - eye)
			words.append([lbl.text.substr(0, 10), snappedf(rad_to_deg(atan2(-d.x, -d.z)), 0.1), snappedf(rad_to_deg(asin(clampf(d.normalized().y, -1, 1))), 0.1), snappedf(d.length(), 0.001)])
	out["words_yaw_el_dist"] = words
	var strip := ui.hud.band_plates(HUD.BAND_STATUS)
	if not strip.is_empty():
		var wp := ui.hud_panel.control_to_world(strip[0])
		var d := inv * (wp - eye)
		out["strip_yaw_el_dist"] = [snappedf(rad_to_deg(atan2(-d.x, -d.z)), 0.1), snappedf(rad_to_deg(asin(clampf(d.normalized().y, -1, 1))), 0.1), snappedf(d.length(), 0.001)]
	print("[ui-verify] geom %s" % JSON.stringify(out))
	return out


func test_geometry_after_play() -> void:
	if not check(booted, "booted"):
		return
	var m := kit.main
	var ui := m.ui
	ui.onboarding.reset()
	_dump("menu")
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	await kit.frames(2)
	var a := _dump("just_after_play")
	await kit.advance(1.0)
	_dump("after_1s_perched")
	kit.fly_bot()
	await kit.frames(2)
	_dump("bot_just_attached")
	await kit.advance(2.0)
	var b := _dump("bot_after_2s")
	metric("geom", [a, b])
	check(true, "dumped")
