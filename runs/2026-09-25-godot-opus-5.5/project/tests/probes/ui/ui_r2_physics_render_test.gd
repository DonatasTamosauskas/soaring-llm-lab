extends TestCase
## Verifier probe (round 2, needs a real renderer): UI changes triggered from
## _physics_process (where GameLoop checks catches, ends runs and where the
## lessons step) and from a frame_post_draw continuation. Does the panel's
## SubViewport texture actually show the change? Pixel-level.
##   tools/gd.sh ui_verify --rendering-method forward_plus --resolution 640x360 \
##       res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r2_physics_render

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")


## Runs a callable once from its _physics_process.
class PhysicsCaller:
	extends Node
	var fn: Callable
	var done := false
	var frames_seen := {}

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _physics_process(_d: float) -> void:
		frames_seen["physics"] = Engine.get_process_frames()
		if fn.is_valid() and not done:
			done = true
			fn.call()

	func _process(_d: float) -> void:
		frames_seen["process"] = Engine.get_process_frames()


func _alpha_at(vp: SubViewport, px: Vector2i) -> Color:
	var img := vp.get_texture().get_image()
	return img.get_pixelv(px) if img else Color(0, 0, 0, 0)


func _wait_draws(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw


func test_frame_counter_between_physics_and_process() -> void:
	var pc := PhysicsCaller.new()
	add_child(pc)
	await _wait_draws(4)
	metric("frame_counter", pc.frames_seen)
	print("[ui-verify] process-frame counter seen in physics %s vs process %s" % [str(pc.frames_seen.get("physics")), str(pc.frames_seen.get("process"))])
	pc.queue_free()
	check(true, "recorded")


func test_lesson_card_hidden_from_physics() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 12)
	var vp := k.ui.hud_panel.get_viewport_node()
	var px := Vector2i(UITheme.HUD_SIZE.x / 2 + 200, 150)
	await _wait_draws(1)
	var before := _alpha_at(vp, px).a
	var pc := PhysicsCaller.new()
	pc.fn = func() -> void: k.ui.onboarding.skip()
	add_child(pc)
	await _wait_draws(20)
	var after := _alpha_at(vp, px).a
	metric("physics_skip", {"before": before, "after_20_draws": after, "prop": k.ui.hud.lesson_visible()})
	print("[ui-verify] physics-phase skip: card alpha %.2f -> %.2f (prop visible=%s)" % [before, after, str(k.ui.hud.lesson_visible())])
	lt(after, 0.1, "lesson card gone from the HUD texture after a physics-phase skip")
	pc.queue_free()
	k.teardown()
	await wait_frames(2)


func test_run_end_from_physics_shows_the_summary() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 10)
	# First open and close the pause menu so the menu texture holds "Paused".
	Events.menu_requested.emit()
	await _wait_draws(6)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await _wait_draws(6)
	var vp := k.ui.menu_panel.get_viewport_node()
	var pc := PhysicsCaller.new()
	pc.fn = func() -> void: k.gl.fake_end({"score": 1234, "max_mass": 0.3, "max_tier": 5})
	add_child(pc)
	await _wait_draws(30)
	eq(k.ui.current_screen_id(), &"summary", "summary is the current screen")
	# The primary "Fly again" button is accent-filled; sample its centre.
	var again := k.ui.get_screen(&"summary").get_button(&"again")
	var c := Vector2i(again.get_global_rect().get_center()) + Vector2i(-150, 0)
	var col := _alpha_at(vp, c)
	var want := UITheme.ACCENT
	var err := absf(col.r - want.r) + absf(col.g - want.g) + absf(col.b - want.b)
	metric("physics_run_end", {"pixel": col.to_html(), "want": want.to_html(), "err": snappedf(err, 0.01)})
	print("[ui-verify] physics-phase run end: 'Fly again' pixel %s (want ~%s), err %.2f" % [col.to_html(), want.to_html(), err])
	lt(err, 0.15, "the rendered menu texture shows the summary's 'Fly again' button after a physics-phase run end")
	pc.queue_free()
	k.teardown()
	await wait_frames(2)


func test_caught_from_physics_shows_the_caught_screen() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 10)
	Events.menu_requested.emit()
	await _wait_draws(6)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await _wait_draws(6)
	var hawk := Bird.new()
	hawk.species = &"hawk"
	hawk.mass = 1.3
	add_child(hawk)
	var vp := k.ui.menu_panel.get_viewport_node()
	var pc := PhysicsCaller.new()
	pc.fn = func() -> void: k.gl.fake_caught(hawk)
	add_child(pc)
	# Sample within the first 0.5 s (before the countdown digit changes).
	await _wait_draws(10)
	eq(k.ui.current_screen_id(), &"caught", "caught screen current")
	# Pause shows a yellow "Resume" button at the top-left; the caught screen
	# has plain background there.
	var resume_px := Vector2i(300, 210)
	var col := _alpha_at(vp, resume_px)
	var acc := UITheme.ACCENT
	var looks_like_pause := absf(col.r - acc.r) + absf(col.g - acc.g) + absf(col.b - acc.b) < 0.15
	metric("physics_caught", {"pixel_at_resume_spot": col.to_html(), "looks_like_old_pause_menu": looks_like_pause})
	print("[ui-verify] physics-phase caught: pixel at Resume spot %s -> old pause texture? %s" % [col.to_html(), str(looks_like_pause)])
	check(not looks_like_pause, "the caught screen is rendered, not the stale pause menu")
	pc.queue_free()
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)
