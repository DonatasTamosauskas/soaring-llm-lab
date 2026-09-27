extends TestCase
## VERIFIER PROBE (vr, round 1, engineering lens). A recenter re-aims the
## view in one tick (PlayerBird._on_recenter sets rig_yaw = heading -
## body_yaw and flags yaw_flagged), so the XROrigin3D can turn by a large
## angle between two physics ticks without any artificial motion. The
## vignette re-seeds on translation jumps (> 250 m/s) but not on yaw jumps:
## does a recenter flash the vignette?

const DT := 1.0 / 72.0


func make_rig() -> Dictionary:
	var body := Node3D.new()
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	cam.position = Vector3(0, 1.6, 0)
	var v := ComfortVignette.new()
	v.auto_update = false
	cam.add_child(v)
	origin.add_child(cam)
	body.add_child(origin)
	add_child(body)
	v.origin = origin
	v.setting_override = 0.6
	return {"body": body, "origin": origin, "vignette": v}


func test_yaw_jump_on_recenter() -> void:
	XRServer.world_scale = 1.0
	var rig := make_rig()
	var v: ComfortVignette = rig["vignette"]
	var body := rig["body"] as Node3D
	for i in 30:
		v.measure(DT)
		v.update_strength(DT)
	eq(v.strength(), 0.0, "at rest")
	# The recenter: the view is re-aimed by 90 deg in a single tick.
	body.rotate_y(deg_to_rad(90.0))
	var peak := 0.0
	var frames_visible := 0
	for i in 72:
		v.measure(DT)
		v.update_strength(DT)
		peak = maxf(peak, v.strength())
		if v.visible:
			frames_visible += 1
	metric("peak_strength_after_recenter", peak)
	metric("frames_visible_after_recenter", frames_visible)
	lt(peak, 0.01, "a recenter's one-tick yaw jump is not motion (peak strength %.3f, visible %d frames)" % [peak, frames_visible])
	body.queue_free()
