extends TestCase
## VERIFIER PROBE (vr, round 2, experience lens), V7 + V2 edge sequences.
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r2x_scale
## V7: a feeding frenzy (a catch every 0.2 s for 12 s, sparrow -> crow), a
## pause mid-ramp, a mid-flight recalibration to a much bigger span, an
## exponent change from the settings menu and absurd masses: the scale never
## steps faster than 0.25 ln/s, the near plane is always 0.03 x ws (>= 1 mm)
## and the scale stays inside its clamp.
## V2: the real-world order of runtime events when a headset comes off and
## goes back on (visible, presence false, stopping-less refocus, presence
## true), with a UI-like listener that toggles on menu_requested with UI's
## 250 ms debounce and pauses on session_unfocused only while playing.

const DT := 1.0 / 72.0

var origin: XROrigin3D
var cam: XRCamera3D
var drv: WorldScaleDriver


func before_each() -> void:
	origin = XROrigin3D.new()
	add_child(origin)
	cam = XRCamera3D.new()
	origin.add_child(cam)
	drv = WorldScaleDriver.new()
	drv.auto_step = false
	add_child(drv)
	drv.origin = origin
	drv.camera = cam
	drv.arm_span_override = 1.5
	drv.exponent_override = 1.0


func after_each() -> void:
	get_tree().paused = false
	drv.queue_free()
	origin.queue_free()
	await wait_frames(1)
	XRServer.world_scale = 1.0


func test_feeding_frenzy_pause_recalibration_and_absurd_masses() -> void:
	var sp := SizeRules.species_data(&"sparrow")
	drv.mass_override = float(sp["mass"])
	drv.step(DT)
	var worst_rate := 0.0
	var worst_near := 0.0
	var prev := origin.world_scale
	var t := 0.0
	var crow_mass := float(SizeRules.species_data(&"crow")["mass"])
	var paused_drift := 0.0
	var steps := int(round(24.0 / DT))
	for i in steps:
		t += DT
		# A catch every 0.2 s for 12 s, mass rising geometrically to a crow.
		if t < 12.0 and fmod(t, 0.2) < DT:
			drv.mass_override = float(sp["mass"]) * pow(crow_mass / float(sp["mass"]), t / 12.0)
		# Pause 4..6 s (menu): the scale must hold.
		get_tree().paused = t >= 4.0 and t < 6.0
		# Recalibration mid-flight at 8 s: span 1.5 -> 1.9 m.
		if absf(t - 8.0) < DT * 0.5:
			drv.arm_span_override = 1.9
		# The player picks exponent 0.8 in the settings at 14 s.
		if absf(t - 14.0) < DT * 0.5:
			drv.exponent_override = 0.8
		drv.step(DT)
		var ws := origin.world_scale
		var rate := absf(log(ws) - log(prev)) / DT
		if get_tree().paused:
			paused_drift = maxf(paused_drift, absf(ws - prev))
		worst_rate = maxf(worst_rate, rate)
		# Absolute error, m: the driver skips writes within is_equal_approx,
		# whose floor is 1e-5 (0.01 mm, invisible).
		worst_near = maxf(worst_near, absf(cam.near - maxf(0.001, 0.03 * ws)))
		prev = ws
	get_tree().paused = false
	print("[vr-verify] frenzy: worst rate %.4f ln/s, near rel err %s, paused drift %s, final ws %.3f target %.3f" % [worst_rate,
		str(worst_near), str(paused_drift), origin.world_scale, drv.target])
	metric("r2x_frenzy", {"worst_rate": worst_rate, "near_err": worst_near, "paused_drift": paused_drift})
	lt(worst_rate, 0.25 + 1e-4, "the world never grows or shrinks faster than 0.25 ln/s")
	lt(worst_near, 2e-5, "near plane = max(1 mm, 0.03 x ws) on every tick (within 0.02 mm)")
	lt(paused_drift, 1e-9, "the scale holds while paused")
	near(origin.world_scale, drv.target, 1e-4, "the ramp arrives at the target")
	# Absurd masses: clamps, finite, near plane >= 1 mm.
	for m in [0.0001, 1e6, 1e12]:
		drv.mass_override = m
		for i in int(round(40.0 / DT)):
			drv.step(DT)
		between(origin.world_scale, WorldScaleDriver.SCALE_MIN - 1e-6, WorldScaleDriver.SCALE_MAX + 1e-6, "mass %s: ws inside its clamp" % str(m))
		gt(cam.near, 0.00099, "mass %s: near plane >= 1 mm" % str(m))


func test_headset_off_and_on_again() -> void:
	var toggles := [0]
	var menu := [0]
	var last := [-100000]
	var ui_toggle := func() -> void:
		menu[0] += 1
		var now := Time.get_ticks_msec()
		if now - int(last[0]) < 250:
			return
		last[0] = now
		toggles[0] += 1
		if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
			Game.set_state(Game.State.PAUSED)
		elif Game.state == Game.State.PAUSED:
			Game.set_state(Game.State.PLAYING)
	var ui_unfocus := func() -> void:
		if Game.state == Game.State.PLAYING:
			Game.set_state(Game.State.PAUSED)
	Events.menu_requested.connect(ui_toggle)
	VR.session_unfocused.connect(ui_unfocus)
	var was_focused := VR.focused
	Game.set_state(Game.State.PLAYING)
	VR._on_session_focused()
	# Headset comes off: the runtime reports visible, then presence false.
	VR._on_session_visible()
	VR._on_user_presence_changed(false)
	eq(Game.state, Game.State.PAUSED, "headset off: paused")
	check(get_tree().paused, "headset off: tree paused")
	eq(toggles[0], 1, "headset off: the pause menu toggled exactly once")
	# Some runtimes send presence false again a moment later.
	await wait_seconds(0.3)
	VR._on_user_presence_changed(false)
	eq(Game.state, Game.State.PAUSED, "a repeated presence(false) keeps it paused (no toggle back to play)")
	# Headset back on: focused, presence true. Never resumes on its own.
	VR._on_session_focused()
	VR._on_user_presence_changed(true)
	eq(Game.state, Game.State.PAUSED, "headset on again: still paused, the player resumes from the menu")
	eq(toggles[0], 1, "no further toggles")
	Events.menu_requested.disconnect(ui_toggle)
	VR.session_unfocused.disconnect(ui_unfocus)
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	VR.focused = was_focused
	VR.user_present = true
	VR.session_state = "none"
