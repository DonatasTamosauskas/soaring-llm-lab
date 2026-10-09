extends TestCase
## V10: controller mapping. The left menu button pauses (Events.menu_requested,
## once per press), a long B press pauses for right-handed players (only
## while flying), a long A/X press recenters, a long Y press recalibrates;
## trigger and grip are exposed with hysteresis. Also runs the real tracker
## read path with a registered XRControllerTracker.

const DT := 1.0 / 90.0

var inputs := {}
var menu_count := 0
var recenter_count := 0
var _autoload_tick := true


func before_all() -> void:
	# The autoload's own VRControls would also see the fake tracker below.
	_autoload_tick = VR.controls.auto_tick
	VR.controls.auto_tick = false
	Events.menu_requested.connect(_on_menu)
	Events.recenter_requested.connect(_on_recenter)


func after_all() -> void:
	VR.controls.auto_tick = _autoload_tick
	Events.menu_requested.disconnect(_on_menu)
	Events.recenter_requested.disconnect(_on_recenter)


func before_each() -> void:
	inputs.clear()
	menu_count = 0
	recenter_count = 0


func _on_menu() -> void:
	menu_count += 1


func _on_recenter() -> void:
	recenter_count += 1


func _read(hand: StringName, action: StringName) -> Variant:
	return inputs.get("%s/%s" % [hand, action], null)


func make() -> VRControls:
	var c := VRControls.new()
	c.auto_tick = false
	c.reader = _read
	add_child(c)
	return c


func hold(c: VRControls, key: String, value: Variant, seconds: float) -> void:
	inputs[key] = value
	for i in int(round(seconds / DT)):
		c.tick(DT)


# -----------------------------------------------------------------------------

func test_menu_button_requests_the_menu_once_per_press() -> void:
	var c := make()
	hold(c, "left_hand/menu_button", true, 1.0)
	eq(menu_count, 1, "one press (held 1 s) = one menu request")
	hold(c, "left_hand/menu_button", false, 0.1)
	hold(c, "left_hand/menu_button", true, 0.05)
	eq(menu_count, 2, "a second press = a second request")
	hold(c, "left_hand/menu_button", false, 0.1)
	check(not c.is_pressed(&"left_hand", &"menu_button"), "released")
	c.queue_free()


func test_right_b_long_press_pauses_only_while_flying() -> void:
	var c := make()
	var old := Game.state
	Game.state = Game.State.PLAYING
	hold(c, "right_hand/by_button", true, 0.5)
	hold(c, "right_hand/by_button", false, 0.1)
	eq(menu_count, 0, "a short B press is UI's Back, not a pause")
	hold(c, "right_hand/by_button", true, 0.75)
	eq(menu_count, 0, "not before 0.8 s")
	hold(c, "right_hand/by_button", true, 1.0)
	eq(menu_count, 1, "held 0.8 s while flying -> one pause request")
	hold(c, "right_hand/by_button", false, 0.1)
	Game.state = Game.State.CAUGHT
	hold(c, "right_hand/by_button", true, 1.0)
	eq(menu_count, 2, "while caught (still play) a long B press pauses too")
	hold(c, "right_hand/by_button", false, 0.1)
	for st in [Game.State.PAUSED, Game.State.MENU, Game.State.ENDED, Game.State.BOOT]:
		Game.state = st
		hold(c, "right_hand/by_button", true, 1.5)
		hold(c, "right_hand/by_button", false, 0.1)
	eq(menu_count, 2, "outside play (paused, menu, ended, boot) a long B press never requests the menu")
	Game.state = old
	c.queue_free()


func test_ax_long_press_recenters() -> void:
	var c := make()
	var before := VR.recenter_count
	var got := [0]
	var cb := func() -> void: got[0] += 1
	VR.recentered.connect(cb)
	hold(c, "right_hand/ax_button", true, 0.9)
	eq(recenter_count, 0, "not before 1 s")
	hold(c, "right_hand/ax_button", true, 0.3)
	eq(recenter_count, 1, "A held 1 s -> Events.recenter_requested")
	eq(VR.recenter_count, before + 1, "the VR autoload recentered")
	eq(got[0], 1, "VR.recentered emitted once")
	hold(c, "right_hand/ax_button", true, 2.0)
	eq(recenter_count, 1, "holding longer does not repeat")
	hold(c, "right_hand/ax_button", false, 0.1)
	hold(c, "left_hand/ax_button", true, 1.2)
	eq(recenter_count, 2, "X works too")
	VR.recentered.disconnect(cb)
	c.queue_free()


func test_y_hold_recalibrates() -> void:
	var c := make()
	var got := [0]
	c.recalibrate_requested.connect(func() -> void: got[0] += 1)
	hold(c, "left_hand/by_button", true, 1.3)
	eq(got[0], 0, "not before 1.5 s")
	hold(c, "left_hand/by_button", true, 0.4)
	eq(got[0], 1, "Y held 1.5 s -> recalibrate_requested")
	eq(menu_count, 0, "Y-hold never pauses")
	c.queue_free()


func test_trigger_and_grip_hysteresis() -> void:
	var c := make()
	var changes: Array = []
	c.grip_changed.connect(func(hand: StringName, down: bool) -> void: changes.append(["grip", hand, down]))
	c.trigger_changed.connect(func(hand: StringName, down: bool) -> void: changes.append(["trigger", hand, down]))
	hold(c, "right_hand/grip", 0.5, 0.05)
	near(c.grip(&"right_hand"), 0.5, 1e-6, "analog grip exposed")
	check(not c.is_grip_down(&"right_hand"), "0.5: not yet a grip")
	hold(c, "right_hand/grip", 0.65, 0.05)
	check(c.is_grip_down(&"right_hand"), "0.65: gripping (on at 0.6)")
	hold(c, "right_hand/grip", 0.5, 0.05)
	check(c.is_grip_down(&"right_hand"), "0.5: still gripping (off at 0.4)")
	hold(c, "right_hand/grip", 0.35, 0.05)
	check(not c.is_grip_down(&"right_hand"), "0.35: released")
	eq(changes.size(), 2, "exactly two grip transitions (no chatter)")
	hold(c, "left_hand/trigger_click", true, 0.05)
	check(c.is_trigger_down(&"left_hand"), "trigger click counts as a full trigger")
	near(c.trigger(&"left_hand"), 1.0, 1e-6, "trigger value from the click")
	hold(c, "left_hand/trigger_click", false, 0.05)
	hold(c, "left_hand/trigger", 0.8, 0.05)
	near(c.trigger(&"left_hand"), 0.8, 1e-6, "analog trigger exposed")
	eq(c.trigger(&"nobody"), 0.0, "unknown hand reads 0")
	c.queue_free()


func test_real_tracker_read_path() -> void:
	# The default reader goes through XRServer's controller trackers, exactly
	# as with a headset: register one and press its menu button.
	var t := XRControllerTracker.new()
	t.name = &"left_hand"
	t.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(t)
	var c := VRControls.new()
	c.auto_tick = false
	add_child(c)
	t.set_input(&"menu_button", true)
	t.set_input(&"grip", 0.9)
	c.tick(DT)
	eq(menu_count, 1, "menu button on a real tracker -> Events.menu_requested")
	check(c.is_grip_down(&"left_hand"), "grip read from the tracker")
	t.set_input(&"menu_button", false)
	c.tick(DT)
	# The controller goes away (asleep, out of batteries) with Y and the
	# grip held: everything reads released, and stays so (fix round 5: a
	# hand without a tracker is skipped once it reads released).
	t.set_input(&"by_button", true)
	c.tick(DT)
	check(c.is_pressed(&"left_hand", &"by_button"), "(setup) Y held")
	XRServer.remove_tracker(t)
	c.tick(DT)
	check(not c.is_pressed(&"left_hand", &"menu_button"), "a missing tracker reads as released")
	check(not c.is_pressed(&"left_hand", &"by_button"), "a button held when the tracker went reads released")
	check(not c.is_grip_down(&"left_hand"), "and so does the grip")
	eq(c.grip(&"left_hand"), 0.0, "grip value 0")
	for i in int(2.0 / DT):
		c.tick(DT)
	check(not c.is_pressed(&"left_hand", &"by_button"), "still released 2 s later (no recalibration from a vanished Y)")
	# Back again, the button still down on it: read at once.
	XRServer.add_tracker(t)
	c.tick(DT)
	check(c.is_pressed(&"left_hand", &"by_button"), "the tracker back: its held Y reads pressed again")
	t.set_input(&"by_button", false)
	c.tick(DT)
	XRServer.remove_tracker(t)
	c.queue_free()
