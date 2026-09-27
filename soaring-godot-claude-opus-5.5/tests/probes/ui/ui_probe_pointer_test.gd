extends TestCase
## Verifier probes (round 1) for U2/U7: pointer edge cases a player hits in
## the first five minutes. Written by the independent verifier.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 6)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func _btn(screen: StringName, id: StringName) -> Button:
	return k.ui.get_screen(screen).get_button(id)


func test_trigger_held_when_pause_opens_is_not_a_click() -> void:
	# Players clench the trigger while flapping. If they pause with it held,
	# letting go must not click whatever the ray happens to cross.
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	k.right.trigger_value = 1.0
	await k.settle(self, 3)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 2)
	eq(k.ui.current_screen_id(), &"pause", "pause open")
	# The hand drifts over "Restart run" while still squeezing, then lets go.
	k.aim_at_control(k.right, _btn(&"pause", &"restart"))
	await k.settle(self, 4)
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	metric("phantom", {"restarts": k.gl.restarts, "starts": k.gl.starts, "clicks": k.ui.pointer.click_count})
	eq(k.gl.restarts, 0, "releasing a trigger held since before the menu opened does not restart the run")
	eq(Game.state, Game.State.PAUSED, "still paused")


func test_trigger_held_when_summary_appears_is_not_a_click() -> void:
	# The run ends mid-flap (last life): the summary appears on its own. A
	# trigger that was already squeezed must not fire "Main menu"/"Fly again".
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	k.gl.fake_end({"score": 500, "max_mass": 0.05})
	await k.settle(self, 3)
	eq(k.ui.current_screen_id(), &"summary", "summary open")
	k.aim_at_control(k.right, _btn(&"summary", &"menu"))
	await k.settle(self, 3)
	k.right.trigger_value = 0.0
	await k.settle(self, 3)
	eq(Game.state, Game.State.ENDED, "summary still showing after releasing a pre-held trigger")


func test_press_on_one_button_release_on_another_is_no_click() -> void:
	var settings := _btn(&"main", &"settings")
	var quit := _btn(&"main", &"quit")
	k.aim_at_control(k.right, settings)
	await k.settle(self, 2)
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	k.aim_at_control(k.right, quit)
	await k.settle(self, 2)
	k.right.trigger_value = 0.0
	await k.settle(self, 2)
	eq(k.quits, 0, "sliding off Settings onto Quit and releasing does not quit")
	eq(k.ui.current_screen_id(), &"main", "and does not open Settings either")


func test_press_in_the_sky_release_on_button_is_no_click() -> void:
	k.aim(k.right, k.rig.global_transform * Vector3(3, 1.6, 1.0))
	await k.settle(self, 2)
	k.right.trigger_value = 1.0
	await k.settle(self, 2)
	k.aim_at_control(k.right, _btn(&"main", &"play"))
	await k.settle(self, 2)
	k.right.trigger_value = 0.0
	await k.settle(self, 2)
	eq(Game.state, Game.State.MENU, "a press that began off the panel does not click Play")


func test_ray_from_behind_the_panel_is_ignored() -> void:
	var play := _btn(&"main", &"play")
	var target := k.ui.menu_panel.control_to_world(play)
	var normal := k.ui.menu_panel.global_transform.basis.z.normalized()
	var behind := target - normal * 0.8
	k.right.aim_at(behind, target + (target - behind))
	await k.click(self, k.right)
	eq(Game.state, Game.State.MENU, "a ray hitting the back of the panel clicks nothing")
	check(k.ui.pointer.last_hit.is_empty(), "no hit from behind")


func test_hand_tremor_click_and_render_rate() -> void:
	# Real hands shake ~0.3-0.5 deg. Hover must stay stable (few re-renders)
	# and a pull must land on the button aimed at.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	await k.click_control(self, _btn(&"main", &"settings"))
	await k.settle(self, 3)
	var ss := k.ui.get_screen(&"settings") as SettingsScreen
	var left_btn := ss.get_hand().get_option_button("left")
	var centre := k.ui.menu_panel.control_to_world(left_btn)
	var hand := k.rig.global_transform * Vector3(0.22, 1.25, -0.25)
	var base_dir := (centre - hand).normalized()
	var r0 := k.ui.menu_panel.render_requests
	var frames := 180
	for i in frames:
		var jitter := Basis(Vector3.UP, deg_to_rad(rng.randfn(0.0, 0.4))) * Basis(Vector3.RIGHT, deg_to_rad(rng.randfn(0.0, 0.4)))
		k.right.aim_at(hand, hand + jitter * base_dir)
		if i == 90:
			k.right.trigger_value = 1.0
		if i == 100:
			k.right.trigger_value = 0.0
		await wait_frames(1)
	var renders := k.ui.menu_panel.render_requests - r0
	metric("tremor", {"renders_in_180_frames": renders, "handedness": Settings.get_value("handedness")})
	eq(Settings.get_value("handedness"), "left", "tremoring pull on 'Left' lands")
	lt(float(renders), 30.0, "tremor over a button does not stream re-renders (%d in 180 frames)" % renders)
