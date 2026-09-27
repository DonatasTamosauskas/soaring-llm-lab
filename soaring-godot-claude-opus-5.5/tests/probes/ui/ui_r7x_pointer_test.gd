extends TestCase
## VERIFIER PROBE (round 7, experience lens). Not part of the UI suite.
##
## Laser-pointer edge cases a player produces without meaning to:
##  - both triggers pulled at once, each hand on a different button;
##  - a click while the menu is still easing round after a head turn;
##  - the left hand, left-handed setting, a tiny bird (world_scale 0.15).
##
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r7x_pointer

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func test_a_both_triggers_on_two_buttons_is_one_action() -> void:
	var main := k.ui.get_screen(&"main")
	var how := main.get_button(&"howto")
	var set_b := main.get_button(&"settings")
	k.aim_at_control(k.left, how)
	k.aim_at_control(k.right, set_b)
	await k.settle(self, 2)
	await k.wait_clickable(self)
	k.left.trigger_value = 1.0
	k.right.trigger_value = 1.0
	await k.settle(self, 3)
	k.left.trigger_value = 0.0
	k.right.trigger_value = 0.0
	await k.settle(self, 4)
	var top := k.ui.current_screen_id()
	print("[ui-verify] both triggers at once: screen %s, stack %s, clicks %d" % [top, k.ui.stack, k.ui.pointer.click_count])
	check(top == &"howto" or top == &"settings", "one of the two opened (%s)" % top)
	eq(k.ui.stack.size(), 2, "exactly one screen pushed (stack %s)" % [k.ui.stack])


func test_b_click_while_the_menu_eases_round() -> void:
	# Turn the head 60 deg right: the menu (32 deg dead zone) eases after it.
	# Mid-ease, aim at "Settings" where it is NOW and pull: Settings opens,
	# never a neighbour.
	var p := k.ui.menu_panel
	k.set_head(Vector3(0, Kit.EYE, 0), -60.0)
	var frames := 0
	while absf(rad_to_deg(p.yaw_error())) > 30.0 and frames < 200:
		await get_tree().process_frame
		frames += 1
	var moving_err := rad_to_deg(p.yaw_error())
	var set_b := k.ui.get_screen(&"main").get_button(&"settings")
	await k.wait_clickable(self)
	# Re-aim every frame at the button's current place while pulling.
	k.aim_at_control(k.right, set_b)
	await get_tree().process_frame
	k.aim_at_control(k.right, set_b)
	k.right.trigger_value = 1.0
	await get_tree().process_frame
	k.aim_at_control(k.right, set_b)
	await get_tree().process_frame
	k.aim_at_control(k.right, set_b)
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	print("[ui-verify] click during the menu's ease (yaw error %.1f deg): screen %s" % [moving_err, k.ui.current_screen_id()])
	eq(k.ui.current_screen_id(), &"settings", "Settings opened although the panel was moving")


func test_c_left_hand_left_handed_tiny_bird_plays() -> void:
	Settings.set_value("handedness", "left")
	k.set_world_scale(0.15)
	k.ui.menu_panel.snap_to_head()
	k.ui.pointer.world_scale = 0.15
	await k.settle(self, 3)
	var play := k.ui.get_screen(&"main").get_button(&"play")
	k.aim_at_control(k.left, play)
	await k.settle(self, 2)
	eq(k.ui.pointer.hovered(), play, "the left hand's beam hovers Play at world_scale 0.15")
	check(k.ui.pointer.beam_node(0).visible and not k.ui.pointer.beam_node(1).visible, "only the left beam is drawn")
	await k.click(self, k.left)
	eq(Game.state, Game.State.PLAYING, "Play by the left hand started the run")
	check(not k.ui.pointer.beam_node(0).visible and not k.ui.pointer.beam_node(1).visible, "no beam in play")
