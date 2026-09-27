extends TestCase
## Verifier probe (round 2, needs a real renderer, not --headless): after a
## HUD element is hidden (lesson card on Skip), does the HUD SubViewport's
## texture really lose it? Reads the texture's pixels.
##   tools/gd.sh ui_verify --rendering-method forward_plus --resolution 640x360 \
##       res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r2_stale

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")


func _card_alpha(k: Kit) -> float:
	var vp := k.ui.hud_panel.get_viewport_node()
	var img := vp.get_texture().get_image()
	if img == null:
		return -1.0
	# Centre of the lesson card plate (top 300 px of the HUD, centred).
	var c := Vector2i(UITheme.HUD_SIZE.x / 2 + 200, 150)
	return img.get_pixelv(c).a


func _modes(k: Kit, frames: int) -> Array:
	var out: Array = []
	for i in frames:
		await RenderingServer.frame_post_draw
		out.append(k.ui.hud_panel.get_viewport_node().render_target_update_mode)
	return out


func test_skip_really_removes_the_lesson_card_from_the_hud_texture() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 10)
	check(k.ui.hud.lesson_visible(), "lesson card shown")
	var before := _card_alpha(k)
	# Skip the way a player does: from the pause menu.
	k.ui.onboarding.skip()
	var modes := await _modes(k, 12)
	var after := _card_alpha(k)
	metric("skip_card_alpha", {"before": snappedf(before, 0.01), "after_12_frames": snappedf(after, 0.01),
		"card_visible_prop": k.ui.hud.lesson_visible(), "modes_after_skip": str(modes)})
	print("[ui-verify] card alpha before skip %.2f, 12 frames after %.2f, prop visible=%s, modes=%s" % [before, after, str(k.ui.hud.lesson_visible()), str(modes)])
	gt(before, 0.5, "card drawn before skip")
	check(not k.ui.hud.lesson_visible(), "card hidden (property)")
	lt(after, 0.1, "card gone from the rendered HUD texture after skip")
	k.teardown()
	await wait_frames(2)


func test_pause_menu_skip_by_pointer_then_resume() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 10)
	Events.menu_requested.emit()
	await k.settle(self, 6)
	var skip := k.ui.get_screen(&"pause").get_button(&"skip_tutorial")
	await k.click_control(self, skip)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 12)
	await RenderingServer.frame_post_draw
	var after := _card_alpha(k)
	metric("skip_by_pointer_card_alpha_after_resume", snappedf(after, 0.01))
	print("[ui-verify] after pointer Skip + resume: state %d, card prop %s, texture alpha %.2f" % [Game.state, str(k.ui.hud.lesson_visible()), after])
	eq(Game.state, Game.State.PLAYING, "resumed")
	lt(after, 0.1, "no ghost lesson card after skipping from the pause menu")
	k.teardown()
	await wait_frames(2)
