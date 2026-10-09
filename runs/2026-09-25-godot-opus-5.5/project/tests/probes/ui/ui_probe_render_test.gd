extends TestCase
## Verifier probe (needs a real renderer, not --headless): does an idle VR
## panel's SubViewport really stop rendering, measured from its pixels rather
## than from UIPanel.render_requests? A canvas shader driven by TIME changes
## the texture on every render, so a changing pixel = a render happened.
##   tools/gd.sh ui_verify2 --rendering-method forward_plus --resolution 640x360 \
##       res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_probe_render

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func _probe_rect(parent: Control) -> ColorRect:
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(fract(TIME * 7.31), fract(TIME * 3.7), 0.5, 1.0); }\n"
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var r := ColorRect.new()
	r.material = mat
	r.position = Vector2(700, 20)
	r.size = Vector2(40, 40)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	return r


## Number of distinct probe-pixel values over `frames` rendered frames.
func _distinct(vp: SubViewport, frames: int) -> int:
	var seen := {}
	for i in frames:
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		if img == null:
			return -1
		seen[img.get_pixel(720, 40).to_html()] = true
	return seen.size()


func test_idle_panel_really_stops_rendering() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 6)
	var p := k.ui.menu_panel
	var vp := p.get_viewport_node()
	_probe_rect(k.ui.get_screen(&"main"))
	await k.settle(self, 12)
	var r0 := p.render_requests
	var idle := await _distinct(vp, 20)
	metric("idle_distinct_pixels_20_frames", idle)
	metric("idle_render_requests", p.render_requests - r0)
	metric("update_mode_idle", vp.render_target_update_mode)
	check(idle == 1, "idle menu: probe pixel constant over 20 frames (%d distinct) -> no real renders" % idle)
	# Positive control: keep_alive must make the same pixel change.
	p.keep_alive(1.0)
	var live := await _distinct(vp, 20)
	metric("keep_alive_distinct_pixels_20_frames", live)
	check(live > 5, "positive control: rendering every frame changes the pixel (%d distinct)" % live)
	# Let the keep_alive window expire first.
	await wait_seconds(1.3)
	# Hover then hold still: one or two renders, then none.
	k.aim_at_control(k.right, k.ui.get_screen(&"main").get_button(&"settings"))
	await k.settle(self, 10)
	var after := await _distinct(vp, 20)
	metric("after_hover_distinct_pixels_20_frames", after)
	check(after == 1, "after a hover settles: no more real renders (%d distinct)" % after)
	k.teardown()
	await wait_frames(2)
