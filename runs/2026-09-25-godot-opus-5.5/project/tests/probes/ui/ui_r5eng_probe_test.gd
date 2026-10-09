extends TestCase
## Verifier probe (round 5, engineering lens) for the ui area. Not part of
## the area's suite; run with:
##   tools/gd.sh ui_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r5eng
##
## 1. The player rig is never touched: through a whole VR session (menu,
##    play with growth, tier-up, pause, settings, recenter, caught, ended,
##    menu) the XROrigin3D keeps its transform and unit scale (Quest rule 1),
##    and with the rig's own LeftAim/RightAim present the UI adds no nodes
##    under it.
## 2. Per-frame CPU cost of the UI's own scripts in VR play (HUD with a
##    lesson card, both cues, make_way every frame) and in a menu with the
##    pointer on it, timed around each UI node's frame callback.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit
## Mean us per frame per UI node, from the last _time_ui().
var last_breakdown := {}


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func _names(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		out.append(String(c.name))
	return out


func test_rig_is_never_touched_through_a_session() -> void:
	# A rig like flight's: LeftHand/RightHand (grip) and LeftAim/RightAim (aim).
	for spec: Array in [["LeftHand", &"left_hand", &"grip"], ["RightHand", &"right_hand", &"grip"],
			["LeftAim", &"left_hand", &"aim"], ["RightAim", &"right_hand", &"aim"]]:
		var c := XRController3D.new()
		c.name = spec[0]
		c.tracker = spec[1]
		c.pose = spec[2]
		k.rig.add_child(c)
	k.rig.global_transform = Transform3D(Basis(Vector3.UP, 0.7), Vector3(12.0, 30.0, -4.0))
	# Real XR sources on this rig (as in the headset).
	k.ui._custom_sources = false
	k.ui._aim_rig = null
	k.ui.attach_rig(k.rig, k.cam)
	await k.settle(self, 3)
	var xf0 := k.rig.global_transform
	var children0 := _names(k.rig)
	var hawk := UIStandInBird.new()
	add_child(hawk)
	var steps: Array[Callable] = [
		func() -> void: k.gl.start_run(),
		func() -> void: k.set_world_scale(0.6),
		func() -> void: Events.player_tier_changed.emit(2, 3),
		func() -> void: k.set_world_scale(1.3),
		func() -> void: Events.menu_requested.emit(),
		func() -> void: k.ui.push_screen(&"settings"),
		func() -> void: k.ui._on_action(&"recenter", &"settings"),
		func() -> void: k.ui.resume(),
		func() -> void: k.gl.fake_caught(hawk),
		func() -> void: Game.set_state(Game.State.PLAYING),
		func() -> void: k.gl.fake_end({"score": 10}),
		func() -> void: Game.set_state(Game.State.MENU),
	]
	var worst_pos := 0.0
	var worst_basis := 0.0
	var scales_ok := true
	for i in steps.size():
		if i == 4:
			await wait_seconds(0.3)
		steps[i].call()
		for f in 10:
			await get_tree().process_frame
			worst_pos = maxf(worst_pos, k.rig.global_transform.origin.distance_to(xf0.origin))
			var db := k.rig.global_transform.basis
			for ax in 3:
				worst_basis = maxf(worst_basis, (db[ax] - xf0.basis[ax]).length())
			scales_ok = scales_ok and k.rig.scale.is_equal_approx(Vector3.ONE)
	metric("rig_drift", {"pos_m": worst_pos, "basis": worst_basis})
	near(worst_pos, 0.0, 1e-9, "the UI never moves the rig")
	near(worst_basis, 0.0, 1e-9, "the UI never rotates or scales the rig")
	check(scales_ok, "rig scale stays ONE at every frame (Quest rule 1)")
	eq(_names(k.rig), children0, "no node added to or removed from the rig (LeftAim/RightAim reused)")
	hawk.queue_free()


## Mean and 99th percentile (µs) of `samples`.
func _stats(samples: PackedFloat64Array) -> Dictionary:
	var s := Array(samples)
	s.sort()
	var total := 0.0
	for v: float in s:
		total += v
	return {"mean_us": snappedf(total / s.size(), 0.1), "p99_us": snappedf(s[int(s.size() * 0.99)], 0.1), "max_us": snappedf(s[-1], 0.1)}


## Time every UI node's own frame callback for `frames` frames (the engine
## also runs them; these calls only measure).
func _time_ui(frames: int) -> PackedFloat64Array:
	var nodes: Array[Node] = [k.ui, k.ui.menu_panel, k.ui.hud_panel, k.ui.hud, k.ui.indicators, k.ui.pointer]
	var out := PackedFloat64Array()
	var dt := 1.0 / 72.0
	var per := {}
	for f in frames:
		await get_tree().process_frame
		var t0 := Time.get_ticks_usec()
		for n in nodes:
			var t1 := Time.get_ticks_usec()
			n.call(&"_process", dt)
			per[String(n.name)] = float(per.get(String(n.name), 0.0)) + float(Time.get_ticks_usec() - t1)
		k.ui.onboarding.call(&"_physics_process", dt)
		out.append(float(Time.get_ticks_usec() - t0))
	for key: String in per:
		per[key] = snappedf(float(per[key]) / frames, 0.1)
	last_breakdown = per
	return out


func test_ui_frame_cost_in_play_and_in_menus() -> void:
	# Play: lesson card up, a prey bird and a real threat cued, the player
	# moving (flight path protected), make_way every frame.
	var prey := UIStandInBird.new()
	add_child(prey)
	prey.global_position = Vector3(-20.0, 5.0, -10.0)
	var hawk := UIStandInBird.new()
	add_child(hawk)
	hawk.global_position = Vector3(8.0, 3.0, 25.0)
	k.gl.start_run()
	k.player.velocity = Vector3(0.0, 1.0, -9.0)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.6, hawk)
	await k.settle(self, 10)
	check(k.ui.hud.lesson_visible(), "lesson card up")
	var play := _stats(await _time_ui(300))
	metric("ui_frame_cost_play", play)
	metric("ui_frame_cost_play_by_node", last_breakdown)
	print("[ui] r5eng play by node %s" % last_breakdown)
	# Menu with the pointer on a button.
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 4)
	k.aim_at_control(k.right, k.ui.get_screen(&"pause").get_button(&"settings"))
	var menu := _stats(await _time_ui(300))
	metric("ui_frame_cost_menu", menu)
	metric("ui_frame_cost_menu_by_node", last_breakdown)
	print("[ui] r5eng menu by node %s" % last_breakdown)
	print("[ui] r5eng frame cost play %s menu %s" % [play, menu])
	# 72 Hz gives 13.9 ms per frame for everything; the UI's scripts should
	# be a small slice even on Quest (roughly 3-4x slower than this Mac).
	lt(play["mean_us"], 250.0, "UI scripts in play: mean %.1f us per frame" % play["mean_us"])
	lt(menu["mean_us"], 250.0, "UI scripts in a menu: mean %.1f us per frame" % menu["mean_us"])
	prey.queue_free()
	hawk.queue_free()

