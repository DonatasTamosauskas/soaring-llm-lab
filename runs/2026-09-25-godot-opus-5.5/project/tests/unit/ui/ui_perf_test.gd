extends TestCase
## U7 - SubViewports render only when visible and something changed, and
## never more than two exist / render at once.
##
## Measured on the viewports themselves, not on the UI's own bookkeeping: at
## the start of every frame the tests read each SubViewport's update mode,
## which is what the renderer acted on at the end of the previous frame
## (UPDATE_ONCE = it rendered, UPDATE_DISABLED = it did not; UIPanel resets
## the mode after each one-off render so the property tells the truth). A
## panel left rendering every frame, or a mode left at ONCE, shows up here
## whatever render_requests says. tests/shots/ui_shots.gd checks the same
## thing from rendered pixels with a real renderer.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 6)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func _viewports() -> Array:
	return k.ui.find_children("*", "SubViewport", true, false)


## Watch `frames` frames: per SubViewport, how many frames it rendered, the
## most viewports rendering in one frame, and whether any was ever set to
## render every frame.
func _sample(frames: int) -> Dictionary:
	var per := {k.ui.menu_panel.name: 0, k.ui.hud_panel.name: 0}
	var most := 0
	var always := false
	for i in frames:
		await get_tree().process_frame
		var n := 0
		for p: UIPanel in [k.ui.menu_panel, k.ui.hud_panel]:
			var mode := p.get_viewport_node().render_target_update_mode
			if mode == SubViewport.UPDATE_ALWAYS or mode == SubViewport.UPDATE_WHEN_VISIBLE or mode == SubViewport.UPDATE_WHEN_PARENT_VISIBLE:
				always = true
			if mode != SubViewport.UPDATE_DISABLED:
				per[p.name] += 1
				n += 1
		most = maxi(most, n)
	return {"menu": per[k.ui.menu_panel.name], "hud": per[k.ui.hud_panel.name], "most_at_once": most, "ever_always": always}


func test_only_two_viewports_exist() -> void:
	eq(_viewports().size(), 2, "exactly two SubViewports (menu + HUD)")
	for vp: SubViewport in _viewports():
		check(vp.disable_3d, "UI viewports skip 3D rendering")
		check(vp.size.x * vp.size.y <= 1360 * 900, "viewport no bigger than the menu panel")


func test_idle_menu_does_not_render() -> void:
	var p := k.ui.menu_panel
	await k.settle(self, 10)
	var r0 := p.render_requests
	var s := await _sample(90)
	metric("idle_rendered_frames_90", s)
	eq(s["menu"], 0, "static main menu: its viewport rendered in 0 of 90 frames")
	eq(p.render_requests - r0, 0, "and asked for none")
	check(not s["ever_always"], "never left in an every-frame update mode")
	check(not p.is_rendering_enabled(), "is_rendering_enabled() says idle")


func test_hover_renders_then_stops() -> void:
	var p := k.ui.menu_panel
	await k.settle(self, 10)
	k.aim_at_control(k.right, k.ui.get_screen(&"main").get_button(&"settings"))
	var hover := await _sample(5)
	gt(hover["menu"], 0, "a hover change renders")
	lt(hover["menu"], 4, "a hover costs a render or two, not a stream (%d)" % hover["menu"])
	check(not hover["ever_always"], "a hover is a one-off render (UPDATE_ONCE), never an every-frame mode")
	var still := await _sample(60)
	eq(still["menu"], 0, "holding still over a button: 0 renders in 60 frames")


func test_hidden_panels_never_render() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 10)
	var s := await _sample(90)
	metric("playing_rendered_frames_90", s)
	eq(s["menu"], 0, "hidden menu panel: 0 renders while playing")
	eq(s["hud"], 0, "static HUD: 0 renders")
	eq(k.ui.menu_panel.get_viewport_node().render_target_update_mode, SubViewport.UPDATE_DISABLED, "menu viewport UPDATE_DISABLED")


func test_a_hidden_panel_takes_no_render_requests() -> void:
	# A hidden panel must not book renders at all (mark_dirty, keep_alive,
	# a change to its content): the round-5 engineering verifier's mutation
	# R3 let them through (one-off renders at hide transitions) and nothing
	# noticed.
	var p := k.ui.hud_panel
	check(not p.shown, "the HUD is hidden on the main menu")
	var r0 := p.render_requests
	p.mark_dirty()
	p.keep_alive(1.0)
	k.ui.hud.show_tier_up(2, 3)
	var s := await _sample(20)
	eq(p.render_requests - r0, 0, "a hidden panel books no render (mark_dirty, keep_alive, new content)")
	eq(s["hud"], 0, "and its viewport rendered in 0 of 20 frames")
	k.ui.hud.cancel_toast()


func test_a_keep_alive_ends() -> void:
	# keep_alive(s) renders every frame for s seconds (fades, animated
	# illustrations) and then stops: never a stream that outlives it (the
	# verifier's mutation R1 was caught only by a screenshot pixel probe).
	var p := k.ui.menu_panel
	await k.settle(self, 10)
	p.keep_alive(0.3)
	var during := await _sample(6)
	gt(during["menu"], 4, "while it lasts it renders every frame (%d of 6)" % during["menu"])
	await wait_seconds(0.45)
	var r0 := p.render_requests
	var after := await _sample(30)
	eq(after["menu"], 0, "0.45 s after a 0.3 s keep-alive: 0 renders in 30 frames")
	eq(p.render_requests - r0, 0, "and no requests")


## Mean and 99th-percentile microseconds of `frames` frames of `nodes`'
## own per-frame work (their _process, the lessons' _physics_process),
## called here with a fixed 72 Hz delta; `each(i)` runs between frames.
func _time_frames(nodes: Array[Node], frames: int, each: Callable) -> Dictionary:
	for n in nodes:
		n.set_process(false)
	k.ui.onboarding.set_physics_process(false)
	var us := PackedFloat64Array()
	for i in frames:
		each.call(i)
		var t0 := Time.get_ticks_usec()
		for n in nodes:
			n.call(&"_process", 1.0 / 72.0)
		k.ui.onboarding._physics_process(1.0 / 72.0)
		us.append(float(Time.get_ticks_usec() - t0))
	for n in nodes:
		n.set_process(true)
	k.ui.onboarding.set_physics_process(true)
	var mean := 0.0
	for v in us:
		mean += v
	mean /= maxf(us.size(), 1.0)
	us.sort()
	return {"mean_us": snappedf(mean, 0.1), "p99_us": snappedf(us[int(us.size() * 0.99)], 0.1), "max_us": snappedf(us[us.size() - 1], 0.1)}


func test_the_whole_ui_is_cheap_every_frame() -> void:
	# All of the UI's own script work per frame, in flight with the lesson
	# card up, a target and a real threat (both cues drawn), the HUD making
	# way every frame and following where the body faces: UIRoot, HUD, cues,
	# both panels, the pointer, the lessons. And in a menu with the pointer
	# hovering. Measured on this Mac (M1 Pro); a Quest Pro's CPU is roughly
	# 3x slower, and a 72 Hz frame is 13.9 ms: the bounds keep the UI under
	# ~1 ms there on average.
	k.player.velocity = Vector3(0, 0, -9)
	k.gl.start_run()
	await k.settle(self, 4)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	var head := k.cam.global_transform
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	var hawk := Bird.new()
	hawk.mass = 1.6
	add_child(hawk)
	prey.global_position = head * Vector3(-6, 1, -4)
	hawk.global_position = head * Vector3(3, 2, 8)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.8, hawk)
	await k.settle(self, 20)
	var nodes: Array[Node] = [k.ui, k.ui.hud, k.ui.indicators, k.ui.hud_panel, k.ui.menu_panel, k.ui.pointer]
	var fly := _time_frames(nodes, 400, func(i: int) -> void:
		prey.global_position = head * Vector3(-6.0 + sin(i * 0.05), 1.0, -4.0)
		k.player.velocity = Basis(Vector3.RIGHT, deg_to_rad(20.0 * sin(i * 0.03))) * Vector3(0, 0, -9))
	check(k.ui.indicators.cue_mesh(&"target").visible and k.ui.indicators.cue_mesh(&"threat").visible, "both cues were drawn")
	# The frame a celebration appears and is placed where the player looks.
	k.ui.set_process(false)
	var t0 := Time.get_ticks_usec()
	Events.player_tier_changed.emit(2, 3)
	var appear_us := float(Time.get_ticks_usec() - t0)
	k.ui.set_process(true)
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	prey.queue_free()
	hawk.queue_free()
	# A menu with the pointer on a button.
	Events.menu_requested.emit()
	await k.settle(self, 8)
	k.aim_at_control(k.right, k.ui.get_screen(&"pause").get_button(&"resume"))
	await k.settle(self, 4)
	var menu := _time_frames(nodes, 300, func(_i: int) -> void: pass)
	metric("ui_frame_cost", {"flight_lesson_two_cues": fly, "menu_hover": menu, "celebration_appears_us": appear_us})
	lt(float(fly["mean_us"]), 400.0, "in flight: the whole UI < 0.4 ms a frame on average (%.0f us)" % fly["mean_us"])
	lt(float(fly["p99_us"]), 1500.0, "99 %% of frames < 1.5 ms (%.0f us)" % fly["p99_us"])
	lt(float(menu["mean_us"]), 300.0, "in a menu with the pointer: < 0.3 ms (%.0f us)" % menu["mean_us"])
	lt(appear_us, 4000.0, "the frame a celebration appears (text, fit, placement) < 4 ms (%.0f us)" % appear_us)


func test_never_more_than_two_active_through_a_session() -> void:
	var max_active := 0
	var hawk := Bird.new()
	hawk.mass = 3.0
	add_child(hawk)
	var steps := [
		func() -> void: k.gl.start_run(),
		func() -> void: Events.player_tier_changed.emit(2, 3),
		func() -> void: Events.menu_requested.emit(),
		func() -> void: k.ui.push_screen(&"settings"),
		func() -> void: k.ui.push_screen(&"howto"),
		func() -> void: k.ui.resume(),
		func() -> void: k.gl.fake_caught(hawk),
		func() -> void: Game.set_state(Game.State.PLAYING),
		func() -> void: k.gl.fake_end({"score": 10}),
		func() -> void: Game.set_state(Game.State.MENU),
	]
	var total := {"menu": 0, "hud": 0}
	var frames := 0
	var always := false
	for i in steps.size():
		# Past the menu button's 250 ms debounce, so the press counts.
		if i == 2:
			await wait_seconds(0.26)
		steps[i].call()
		var s := await _sample(30)
		frames += 30
		max_active = maxi(max_active, s["most_at_once"])
		always = always or s["ever_always"]
		total["menu"] += s["menu"]
		total["hud"] += s["hud"]
		check(_viewports().size() == 2, "still two viewports")
	metric("max_rendering_at_once", max_active)
	metric("rendered_frames", {"menu": total["menu"], "hud": total["hud"], "of": frames})
	lt(float(max_active), 2.5, "never more than 2 SubViewports render in one frame")
	check(not always, "no viewport ever left rendering every frame")
	# Transitions render in bursts, not continuously (the celebration is the
	# only multi-second animation in this session).
	lt(float(total["menu"]), frames * 0.5, "menu panel rendered in under half the frames (%d of %d)" % [total["menu"], frames])
	hawk.queue_free()


func test_how_to_animates_at_bounded_rate() -> void:
	k.ui.push_screen(&"howto")
	await k.settle(self, 5)
	var t0 := Time.get_ticks_msec()
	var s := await _sample(90)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	var rate: float = s["menu"] / secs
	metric("howto_renders_per_s", snappedf(rate, 0.1))
	check(not s["ever_always"], "animated, but still one render at a time")
	gt(rate, 5.0, "the gesture card animates")
	lt(rate, 34.0, "animation capped near its 30 fps, not every frame")


func test_desktop_mode_renders_no_viewports() -> void:
	k.teardown()
	await wait_frames(2)
	k = Kit.new()
	k.setup(self, false)
	await k.settle(self, 5)
	k.ui.push_screen(&"howto")
	await wait_frames(30)
	eq(k.ui.menu_panel.render_requests, 0, "desktop overlay draws in the main viewport; no SubViewport renders")
	eq(k.ui.active_viewport_count(), 0, "no active SubViewports on desktop")


func test_colour_compensation_is_live_on_the_real_panels() -> void:
	# The world renders with Filmic (white 6). The real panel materials must
	# switch compensation on with an inverse LUT that lands every palette
	# colour within 1.5/255 of the best the renderer can show (on the Mobile
	# renderer the colour buffer clips at 2.0 before tonemapping, which caps
	# the very brightest creams: UITonemap models it and the contrast tests
	# use the capped values). Pointer and cue colours are pre-compensated too.
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	we.environment = env
	add_child(we)
	await k.settle(self, 2)
	k.ui.refresh_tonemap()
	var p := UITonemap.params(env)
	metric("renderer_ceiling", p["max_input"])
	var worst := 0.0
	var gain := 0.0
	for panel: UIPanel in [k.ui.menu_panel, k.ui.hud_panel]:
		var mat := panel.get_material()
		check(bool(mat.get_shader_parameter(&"compensate")), "%s compensates under Filmic" % panel.name)
		var img := (mat.get_shader_parameter(&"inv_lut") as Texture2D).get_image()
		var scale := float(mat.get_shader_parameter(&"lut_scale"))
		for c: Color in [UITheme.TEXT, UITheme.TEXT_DIM, UITheme.ACCENT, UITheme.PREY, UITheme.THREAT_TEXT, UITheme.PANEL, UITheme.BUTTON, UITheme.INK]:
			var best := UITonemap.apply(UITonemap.compensate(c, p), p)
			var raw := UITonemap.apply(c, p)
			var lin := c.srgb_to_linear()
			var chans := [lin.r, lin.g, lin.b]
			var bests := [best.r, best.g, best.b]
			var raws := [raw.r, raw.g, raw.b]
			var want := [c.r, c.g, c.b]
			for j in 3:
				# Exactly what the shader does: u = sqrt(t), linear filtering.
				var fu := sqrt(float(chans[j])) * (UITonemap.LUT_SIZE - 1)
				var i0 := int(floor(fu))
				var i1 := mini(i0 + 1, UITonemap.LUT_SIZE - 1)
				var x := lerpf(img.get_pixel(i0, 0).r, img.get_pixel(i1, 0).r, fu - i0) * scale
				var shown := UITonemap.forward(minf(x * float(p["exposure"]), float(p["max_input"])), p["mode"], p["white"])
				var shown_srgb := Color(shown, shown, shown).linear_to_srgb().r
				worst = maxf(worst, absf(shown_srgb - float(bests[j])) * 255.0)
				gain = maxf(gain, (absf(float(raws[j]) - float(want[j])) - absf(shown_srgb - float(want[j]))) * 255.0)
	metric("panel_lut_worst_error_255", snappedf(worst, 0.01))
	metric("largest_fidelity_gain_255", snappedf(gain, 0.1))
	lt(worst, 1.5, "every palette channel within 1.5/255 of the reachable colour (%.2f)" % worst)
	gt(gain, 20.0, "and compensation really matters (up to %.0f/255 closer than uncompensated)" % gain)
	for pair: Array in [[k.ui.pointer._col_hit, UITheme.ACCENT, "laser"], [k.ui.indicators._threat_col, UITheme.THREAT, "threat cue"],
			[k.ui.indicators._target_col, UITheme.PREY, "target cue"]]:
		var want_c: Color = UITonemap.apply(UITonemap.compensate(pair[1], p), p)
		var got_c := UITonemap.apply(pair[0], p)
		lt(maxf(maxf(absf(got_c.r - want_c.r), absf(got_c.g - want_c.g)), absf(got_c.b - want_c.b)) * 255.0, 1.0, "%s colour compensated" % pair[2])
	# Negative control: no tonemapping, no compensation.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	k.ui.refresh_tonemap()
	check(not bool(k.ui.menu_panel.get_material().get_shader_parameter(&"compensate")), "linear tonemap: compensation off")
	we.queue_free()


class LateSampler:
	extends Node
	## Runs after every other node's _process: records whether each panel's
	## viewport is set to render when this frame is drawn.
	var panels: Array[UIPanel] = []
	var rows: Array = []

	func _init() -> void:
		process_priority = 1000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_d: float) -> void:
		var row := []
		for p in panels:
			row.append(p.get_viewport_node().render_target_update_mode != SubViewport.UPDATE_DISABLED)
		rows.append(row)


func test_a_change_after_the_draw_is_drawn_next_frame() -> void:
	# A UI change made after this frame's draw began (a frame_post_draw
	# continuation, e.g. right after a screenshot, or a late XR callback) can
	# only be drawn next frame; the panel must not cancel it there (the
	# verifiers saw a hidden lesson card stay on the HUD texture).
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 10)
	var sampler := LateSampler.new()
	sampler.panels = [k.ui.hud_panel]
	add_child(sampler)
	await k.settle(self, 5)
	sampler.rows.clear()
	# Frame N: the draw of N "has begun" (headless has no real draw, so mark
	# it the way RenderingServer.frame_pre_draw does), then the UI changes.
	UIPanel.note_draw_started()
	k.player.mass *= 1.3
	await k.settle(self, 4)
	var seen: Array = sampler.rows.map(func(r: Array) -> bool: return r[0])
	metric("late_change_render_flags", seen)
	UIPanel.clear_draw_started()
	eq(seen.count(true), 1, "the late change is rendered exactly once (%s)" % str(seen))
	check(seen.size() >= 2 and seen[1] == true, "in the next frame's draw, not cancelled before it (%s)" % str(seen))
	sampler.queue_free()


func test_band_fades_cost_no_renders() -> void:
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.onboarding.skip()
	await k.settle(self, 10)
	var r0 := k.ui.hud_panel.render_requests
	for i in 30:
		k.ui.hud_panel.set_band_alpha(HUD.BAND_STATUS, 1.0 - i / 40.0)
		await wait_frames(1)
	eq(k.ui.hud_panel.render_requests, r0, "fading a HUD band is a shader value: 0 SubViewport renders")
	k.ui.hud_panel.set_band_alpha(HUD.BAND_STATUS, 1.0)


func test_notices_moving_cost_no_renders() -> void:
	# The notices move by turning their band's mesh about the eye: a
	# transform, not a new texture.
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.onboarding.skip()
	await k.settle(self, 10)
	var r0 := k.ui.hud_panel.render_requests
	var moving := {"hud": 0}
	for i in 30:
		k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, Vector2(i * 2.0, 0.0))
		moving = await _sample(1)
		eq(moving["hud"], 0, "frame %d of the move: the HUD viewport did not render" % i)
	eq(k.ui.hud_panel.render_requests, r0, "moving a HUD band: 0 SubViewport renders requested")
	k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)


func test_empty_bands_are_not_drawn() -> void:
	# A band with nothing on it (no lesson, no celebration) hides its mesh:
	# no fill cost for a transparent strip of texture.
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	var notice := k.ui.hud_panel.band_mesh(HUD.BAND_NOTICE)
	var strip := k.ui.hud_panel.band_mesh(HUD.BAND_STATUS)
	check(not notice.visible, "no notice: the notice band's mesh is hidden")
	check(strip.visible, "the growth strip is drawn")
	Events.player_tier_changed.emit(2, 3)
	await k.settle(self, 2)
	check(notice.visible, "a celebration: the notice band is drawn")
	k.ui.hud.cancel_toast()
	await k.settle(self, 2)
	check(not notice.visible, "celebration over: hidden again")


func test_making_way_is_cheap_every_frame() -> void:
	# make_way runs every frame in flight with what it really gets: the
	# flight path, a target, a threat and their two cues. A normal frame
	# checks the current placement; the worst frame also checks the other
	# side (something has stayed on the notices and the other side is
	# taken too).
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.onboarding.skip()
	k.ui.set_process(false)
	var hud := k.ui.hud
	Events.player_tier_changed.emit(3, 4)
	await k.settle(self, 2)
	var dirs: Array[Vector3] = [
		(Basis(Vector3.RIGHT, deg_to_rad(15.0)) * Vector3.FORWARD),
		(Basis(Vector3.UP, deg_to_rad(8.0)) * Basis(Vector3.RIGHT, deg_to_rad(22.0)) * Vector3.FORWARD),
		(Basis(Vector3.UP, deg_to_rad(-25.0)) * Basis(Vector3.RIGHT, deg_to_rad(10.0)) * Vector3.FORWARD),
		(Basis(Vector3.UP, deg_to_rad(30.0)) * Basis(Vector3.RIGHT, deg_to_rad(-12.0)) * Vector3.FORWARD),
		(Basis(Vector3.UP, deg_to_rad(-60.0)) * Basis(Vector3.RIGHT, deg_to_rad(4.0)) * Vector3.FORWARD)]
	hud.make_way(dirs, 0.016)
	var t0 := Time.get_ticks_usec()
	for i in 200:
		hud.make_way(dirs, 0.001)
	var normal_us := (Time.get_ticks_usec() - t0) / 200.0
	# Worst: covered on both sides, past the stay time: both placements are
	# checked every call.
	var both: Array[Vector3] = [
		(Basis(Vector3.UP, deg_to_rad(-30.0)) * Basis(Vector3.RIGHT, deg_to_rad(14.0)) * Vector3.FORWARD),
		(Basis(Vector3.UP, deg_to_rad(30.0)) * Basis(Vector3.RIGHT, deg_to_rad(14.0)) * Vector3.FORWARD),
		dirs[0], dirs[2], dirs[4]]
	hud.make_way(both, HUD.MOVE_AFTER_S + 0.1)
	t0 = Time.get_ticks_usec()
	for i in 200:
		hud.make_way(both, 0.016)
	var worst_us := (Time.get_ticks_usec() - t0) / 200.0
	check(hud.dodge_stuck, "the worst case really ran (both sides taken)")
	metric("make_way_us", {"normal_frame": snappedf(normal_us, 0.1), "worst_frame": snappedf(worst_us, 0.1)})
	# Budgets on this Mac (M1 Pro); a Quest's CPU is roughly 3x slower, and
	# a 90 Hz frame is 11 ms.
	lt(normal_us, 100.0, "a normal frame costs < 0.1 ms (%.1f us)" % normal_us)
	lt(worst_us, 200.0, "the worst frame costs < 0.2 ms (%.1f us)" % worst_us)
	k.ui.set_process(true)


func test_an_animation_cut_short_does_not_outlive_its_panel() -> void:
	# The fourth apex catch starts a 3 s celebration; the fifth ends the run
	# at once (the HUD goes). Next time the HUD shows it must be idle, not
	# finish the old celebration's every-frame renders.
	k.ui.onboarding.skip()
	k.player.mass = 3.1
	k.gl.start_run()
	await k.settle(self, 4)
	k.gl.fake_apex_catch()
	await k.settle(self, 2)
	check(k.ui.hud.toast_active(), "a big catch at the top: celebration running")
	# The run ends before the celebration does.
	Game.set_state(Game.State.ENDED)
	await k.settle(self, 4)
	check(not k.ui.hud.toast_active(), "the celebration ends with the HUD")
	Game.set_state(Game.State.MENU)
	k.player.mass = 0.03
	k.gl.start_run()
	await k.settle(self, 6)
	check(not k.ui.hud.toast_active(), "and does not replay into the next flight")
	var s := await _sample(30)
	eq(s["hud"], 0, "a re-shown HUD is idle (%d renders in 30 frames)" % s["hud"])


func test_hide_and_show_in_one_late_frame_still_renders() -> void:
	# CAUGHT -> PLAYING -> PAUSED in one go right after a frame was drawn:
	# the menu panel is asked to render, hidden (which cancels the request),
	# then shown with the pause screen. That last request must stand.
	var sampler := LateSampler.new()
	sampler.panels = [k.ui.menu_panel]
	add_child(sampler)
	await k.settle(self, 8)
	sampler.rows.clear()
	UIPanel.note_draw_started()
	k.ui.menu_panel.mark_dirty()
	k.ui.menu_panel.hide_panel()
	k.ui.menu_panel.show_panel()
	await k.settle(self, 3)
	var seen: Array = sampler.rows.map(func(r: Array) -> bool: return r[0])
	metric("late_hide_show_render_flags", seen)
	UIPanel.clear_draw_started()
	check(seen.size() >= 2 and seen[1] == true, "shown again in a late frame: rendered next frame (%s)" % str(seen))
	sampler.queue_free()
