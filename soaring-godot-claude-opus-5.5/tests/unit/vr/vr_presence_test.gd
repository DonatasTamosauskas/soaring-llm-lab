extends TestCase
## V2, fix round 4 (engineering verifier): the VR autoload's `focused`
## follows the headset (user presence) as well as the session. Written
## against the round-3 API only, so the same file shows how round 3 failed
## it (artifacts/vr/old_code_check_round4.log). Session signals are driven
## by calling the autoload's OpenXR handlers directly, as the runtime's
## signals would.

var menu := 0
var unfocused := 0
var focused_sig := 0
var _cbs: Array = []


func before_all() -> void:
	var a := func() -> void: menu += 1
	var b := func() -> void: unfocused += 1
	var c := func() -> void: focused_sig += 1
	Events.menu_requested.connect(a)
	VR.session_unfocused.connect(b)
	VR.session_focused.connect(c)
	_cbs = [a, b, c]


func after_all() -> void:
	Events.menu_requested.disconnect(_cbs[0])
	VR.session_unfocused.disconnect(_cbs[1])
	VR.session_focused.disconnect(_cbs[2])


func before_each() -> void:
	menu = 0
	unfocused = 0
	focused_sig = 0


func after_each() -> void:
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	VR.focused = false
	VR.user_present = true
	VR.presence_supported = false
	VR.session_state = "none"


## Fix round 4 (engineering verifier): `focused` stayed true after the
## headset came off until the runtime also reported session_visible, and
## when Quest sent both the focus loss ran twice. Now presence off clears
## `focused` at once (one pause, one session_unfocused), the following
## session_visible is not a second loss, and putting the headset back on
## (the session still focused) makes it focused again without resuming.
func test_headset_off_clears_focused_once() -> void:
	Game.set_state(Game.State.PLAYING)
	VR._on_session_focused()
	check(VR.focused, "(setup) focused")
	var losses := VR.focus_losses
	VR._on_user_presence_changed(false)
	check(not VR.focused, "headset off: not focused any more")
	eq(Game.state, Game.State.PAUSED, "and paused")
	eq(unfocused, 1, "session_unfocused once")
	eq(menu, 1, "one menu request")
	VR._on_session_visible()
	eq(VR.focus_losses, losses + 1, "the runtime's session_visible that follows is not a second focus loss")
	eq(unfocused, 1, "still one session_unfocused")
	eq(menu, 1, "still one menu request")
	VR._on_session_focused()
	check(not VR.focused, "session focused again but nobody wears the headset: not focused")
	VR._on_user_presence_changed(true)
	check(VR.focused, "headset back on with the session focused: focused")
	eq(focused_sig, 2, "session_focused when the player is back")
	eq(Game.state, Game.State.PAUSED, "never resumed by itself")
	# Presence changes alone (the session stays FOCUSED throughout).
	VR._on_user_presence_changed(false)
	check(not VR.focused, "off again: not focused")
	VR._on_user_presence_changed(true)
	check(VR.focused, "on again: focused (session still focused)")


## A game that is running while nobody wears the headset (it was taken off
## earlier) is paused by any loss signal that arrives, even though `focused`
## is already false (no second focus loss is counted). A verifier's
## focus-chatter probe (r3x_focus_scale) caught the first round-4 draft,
## which only paused on the true -> false transition.
func test_a_running_game_pauses_on_any_loss_signal() -> void:
	VR._on_user_presence_changed(false)
	VR._on_session_focused()
	check(not VR.focused, "(setup) headset off: not focused")
	for sig in ["session_visible", "presence_off", "session_stopping"]:
		Game.set_state(Game.State.BOOT)
		get_tree().paused = false
		Game.set_state(Game.State.PLAYING)
		menu = 0
		unfocused = 0
		var losses := VR.focus_losses
		match sig:
			"session_visible":
				VR._on_session_visible()
			"presence_off":
				VR._on_user_presence_changed(false)
			"session_stopping":
				VR._on_session_stopping()
		eq(Game.state, Game.State.PAUSED, "%s while PLAYING with focus already gone: paused" % sig)
		eq(menu, 1, "%s: one menu request" % sig)
		eq(VR.focus_losses, losses, "%s: not a second focus loss" % sig)
		eq(unfocused, 0, "%s: no second session_unfocused" % sig)
		VR.session_state = "focused"
