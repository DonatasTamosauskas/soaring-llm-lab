extends TestCase
## Verifier probe (round 1), sharpened: a trigger already squeezed while the
## ray already rests where a button is about to appear. Letting go must not
## click it: the press began before the menu existed. Independent verifier.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 6)
	k.ui.onboarding.skip()


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func test_pre_squeezed_trigger_over_pause_button() -> void:
	k.gl.start_run()
	await k.settle(self, 3)
	# Learn where "Restart run" appears (same head pose -> same placement).
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	var spot := k.ui.menu_panel.control_to_world(k.ui.get_screen(&"pause").get_button(&"restart"))
	k.ui.resume()
	await k.settle(self, 3)
	eq(Game.state, Game.State.PLAYING, "back in play")
	# Flying, squeezing the trigger, hand happens to point there.
	k.aim(k.right, spot)
	k.right.trigger_value = 1.0
	await k.settle(self, 3)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 4)
	eq(k.ui.current_screen_id(), &"pause", "pause open")
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	metric("pause_phantom", {"restarts": k.gl.restarts, "clicks": k.ui.pointer.click_count, "state": Game.state_name()})
	eq(k.gl.restarts, 0, "releasing a trigger squeezed before the menu opened does not restart the run")


func test_pre_squeezed_trigger_over_summary_button() -> void:
	k.gl.start_run()
	await k.settle(self, 3)
	k.gl.fake_end({"score": 100, "max_mass": 0.05})
	await k.settle(self, 3)
	var spot := k.ui.menu_panel.control_to_world(k.ui.get_screen(&"summary").get_button(&"menu"))
	await k.click_control(self, k.ui.get_screen(&"summary").get_button(&"again"))
	await k.settle(self, 3)
	eq(Game.state, Game.State.PLAYING, "second run")
	k.aim(k.right, spot)
	k.right.trigger_value = 1.0
	await k.settle(self, 3)
	# Last life lost mid-flap: the summary appears under the squeezed trigger.
	k.gl.fake_end({"score": 120, "max_mass": 0.05})
	await k.settle(self, 4)
	eq(k.ui.current_screen_id(), &"summary", "summary open")
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	metric("summary_phantom", {"state": Game.state_name(), "quits": k.gl.quits})
	eq(Game.state, Game.State.ENDED, "the summary is not dismissed by a trigger squeezed before it appeared")
