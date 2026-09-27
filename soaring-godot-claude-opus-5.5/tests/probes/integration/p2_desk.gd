extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## The desktop game as a desktop player gets it (--xr-mode off, the 2D
## overlay UI, keyboard + mouse through DesktopPoseSource): menu, a mouse
## click on Play, the lessons done with the keys the How-to-fly "Buttons"
## tab names (Space, W, S, A/D, Shift), a shot at each lesson card, Escape
## pause, the How to fly Buttons tab, resume. Rendered.
##
##   tools/gd.sh p2desk --rendering-method forward_plus --resolution 1280x800 --fixed-fps 72 res://tests/probes/integration/p2_desk.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var out := {"shots": [], "lessons": []}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func _tap(code: Key) -> void:
	_key(code, true)
	await kit.frames(3)
	_key(code, false)
	await kit.frames(3)


func _mouse_click(c: Control) -> void:
	var at := c.get_screen_transform() * (c.size * 0.5)
	var mv := InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	get_viewport().push_input(mv, true)
	await kit.frames(2)
	for down in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.position = at
		e.global_position = at
		e.pressed = down
		get_viewport().push_input(e, true)
		await kit.frames(2)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(Paths.artifacts("integration").path_join("verify/r2/p2_desk_%s.png" % name))
	out["shots"].append(name)


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, false):
		get_tree().quit()
		return
	main = kit.main
	var m := main
	await kit.frames(10)
	await _shot("menu")
	await _mouse_click(kit.button(&"main", &"play"))
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	out["pose_source_desktop"] = m.player.pose_source is DesktopPoseSource
	await kit.advance(1.0)
	await _shot("play")
	var ob := m.ui.onboarding
	var t := 0.0
	var shot_ids := {}
	# What a desktop player does per lesson with the keys the Buttons tab lists.
	while t < 150.0 and ob.active:
		var id: StringName = ob.current().get("id", &"")
		if not shot_ids.has(id) and ob.celebrating <= 0.0:
			shot_ids[id] = true
			await kit.advance(0.5)
			t += 0.5
			await _shot("lesson_%s" % id)
			out["lessons"].append({"id": String(id), "t": snappedf(t, 0.1)})
		var agl: float = float(m.player.telemetry()["altitude_agl"])
		for k in [KEY_SPACE, KEY_W, KEY_S, KEY_D, KEY_SHIFT]:
			_key(k, false)
		match id:
			&"flap", &"spread", &"catch":
				_key(KEY_SPACE, agl < 30.0)
			&"glide":
				if agl < 15.0:
					_key(KEY_SPACE, true)
			&"speed":
				if agl < 15.0:
					_key(KEY_SPACE, true)
				else:
					_key(KEY_W, true)
			&"turn":
				_key(KEY_D, true)
				_key(KEY_SPACE, agl < 15.0)
			&"dive":
				if agl < 20.0:
					_key(KEY_SPACE, true)
				else:
					_key(KEY_SHIFT, true)
		await kit.advance(0.25)
		t += 0.25
	for k in [KEY_SPACE, KEY_W, KEY_S, KEY_D, KEY_SHIFT]:
		_key(k, false)
	out["onboarding_s"] = t
	out["onboarding_active_at_end"] = ob.active
	# Pause and the Buttons tab.
	await _tap(KEY_ESCAPE)
	await kit.frames(10)
	out["paused"] = Game.state == Game.State.PAUSED
	await _shot("pause")
	var ht := kit.button(&"pause", &"howto")
	if ht:
		await _mouse_click(ht)
		await kit.frames(10)
		var tab := kit.button(kit.screen(), &"tab_controls")
		if tab:
			await _mouse_click(tab)
			await kit.frames(10)
			await _shot("howto_buttons")
	out["errors"] = kit.log.errors
	out["log"] = kit.log.summary()
	print("[integration] p2_desk %s" % [out])
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2/p2_desk.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	await kit.teardown()
	get_tree().quit()
