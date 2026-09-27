extends TestCase
## Round-4 engineering verifier probe (independent; no UI source touched).
##
##   tools/gd.sh ui_verify2 --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes --suite=probes/ui/ui_r4eng
##
## 1. Do the round-3 "notices step aside" plates cover the peripheral cue
##    chevrons? make_way protects the *birds'* directions, not the cues that
##    point at them, and the HUD panel (render_priority 9, plate alpha 0.95)
##    draws over the chevrons (render_priority 8).
## 2. What does a near-worst make_way search really cost (the suite's
##    "search frame" number finds a placement after a few candidates)?

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")


static func _dir(yaw_deg: float, elev_deg: float) -> Vector3:
	return Basis(Vector3.UP, deg_to_rad(yaw_deg)) * Basis(Vector3.RIGHT, deg_to_rad(elev_deg)) * Vector3.FORWARD


## Is the centre of a cue chevron (as drawn now) under an opaque notice plate?
func _cue_under_notice(k: Kit, which: StringName) -> bool:
	var cue := k.ui.indicators.cue_mesh(which)
	if not cue.visible:
		return false
	if k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE) < 0.6:
		return false
	var eye := k.cam.global_position
	var hit := k.ui.hud_panel.intersect_ray(eye, (cue.global_position - eye).normalized())
	if hit.is_empty():
		return false
	for p: Control in k.ui.hud.band_plates(HUD.BAND_NOTICE):
		if p.get_global_rect().has_point(hit["pixel"]):
			return true
	return false


func test_cues_are_not_hidden_under_notices_that_stepped_aside() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	check(k.ui.hud.lesson_visible(), "a lesson card is up (first flight)")
	var cruise := SizeRules.cruise_speed(0.03)
	var rows := {}
	var covered_cases := 0
	var cases := 0
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	for climb: float in [0.0, 8.0, 12.0, 16.0]:
		var a := deg_to_rad(climb)
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * cruise
		# Prey above and ahead, 30-40 deg off the view centre: its cue is drawn
		# on the upper arc of the 24 deg ring.
		for spec: Vector2 in [Vector2(0.0, 32.0), Vector2(10.0, 36.0), Vector2(-12.0, 34.0), Vector2(0.0, 40.0)]:
			var eye := k.cam.global_position
			prey.global_position = eye + _dir(spec.x, spec.y) * 12.0
			Events.target_changed.emit(prey)
			await wait_seconds(0.8)
			var n := 0
			var hidden := 0
			for i in 20:
				await wait_frames(1)
				if k.ui.indicators.cue_mesh(&"target").visible:
					n += 1
					if _cue_under_notice(k, &"target"):
						hidden += 1
			var key := "climb %d, prey yaw %d el %d" % [int(climb), int(spec.x), int(spec.y)]
			rows[key] = {"cue_frames": n, "cue_under_opaque_notice": hidden,
				"notice_offset_deg": str(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE)),
				"notice_alpha": snappedf(k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE), 0.01)}
			cases += 1
			if hidden > 0:
				covered_cases += 1
			Events.target_changed.emit(null)
			await wait_seconds(0.3)
	metric("cue_under_notice", rows)
	metric("cases_with_cue_hidden", "%d of %d" % [covered_cases, cases])
	print("[ui-verify] cue under notice: %d of %d cases" % [covered_cases, cases])
	for key: String in rows:
		print("[ui-verify]   %s -> %s" % [key, str(rows[key])])
	eq(covered_cases, 0, "no prey cue is drawn under an opaque notice plate (render priority 9 > 8)")
	prey.queue_free()
	k.teardown()
	await wait_frames(2)


func test_threat_cue_is_not_hidden_under_a_notice() -> void:
	# A hawk stooping from above and behind while the player climbs through a
	# lesson or a celebration: its (double, coral) cue points up, on the upper
	# arc of the ring (24-33 deg out). Its bird is behind the eye, so make_way
	# has nothing on the band to protect.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	var cruise := SizeRules.cruise_speed(0.03)
	var hawk := Bird.new()
	hawk.mass = 1.3
	add_child(hawk)
	var rows := {}
	var covered_cases := 0
	var cases := 0
	for climb: float in [0.0, 10.0, 14.0]:
		var a := deg_to_rad(climb)
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * cruise
		for spec: Vector3 in [Vector3(0.0, 8.0, 12.0), Vector3(2.0, 10.0, 6.0), Vector3(-1.5, 12.0, 9.0)]:
			var eye := k.cam.global_position
			hawk.global_position = eye + spec
			Events.threat_changed.emit(0.8, hawk)
			await wait_seconds(0.8)
			var n := 0
			var hidden := 0
			for i in 20:
				await wait_frames(1)
				if k.ui.indicators.cue_mesh(&"threat").visible:
					n += 1
					if _cue_under_notice(k, &"threat"):
						hidden += 1
			var key := "climb %d, hawk at %s" % [int(climb), str(spec)]
			rows[key] = {"cue_frames": n, "cue_under_opaque_notice": hidden,
				"notice_offset_deg": str(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE))}
			cases += 1
			if hidden > 0:
				covered_cases += 1
			Events.threat_changed.emit(0.0, null)
			await wait_seconds(0.3)
	metric("threat_cue_under_notice", rows)
	print("[ui-verify] threat cue under notice: %d of %d cases" % [covered_cases, cases])
	for key: String in rows:
		print("[ui-verify]   %s -> %s" % [key, str(rows[key])])
	eq(covered_cases, 0, "no threat cue is drawn under an opaque notice plate")
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)


func test_how_much_of_the_cue_rings_the_lesson_card_covers() -> void:
	# Pure geometry of what is drawn: sample the target ring (24 deg) and the
	# threat's outer ring (up to 33 deg) every 2 deg of ring angle and ask the
	# real band (UIPanel.intersect_ray) whether an opaque notice plate lies on
	# that line of sight, with the card at home and stepped up / aside.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	check(k.ui.hud.lesson_visible(), "lesson card up")
	k.ui.set_process(false)
	var panel := k.ui.hud_panel
	var cam := k.cam.global_transform
	var rows := {}
	for off: Vector2 in [Vector2.ZERO, Vector2(0, 5), Vector2(0, 7), Vector2(0, 11), Vector2(0, 16), Vector2(24, 0), Vector2(-30, 0)]:
		panel.set_band_offset(HUD.BAND_NOTICE, off)
		await wait_frames(1)
		var row := {}
		for ecc: float in [24.0, 28.0, 33.0]:
			var hit_angles: Array[int] = []
			for i in 180:
				var theta := deg_to_rad(i * 2.0)
				var p := HudMath.ring_point(theta, deg_to_rad(ecc), 1.0)
				var d := (cam.basis * p).normalized()
				var hit := panel.intersect_ray(cam.origin, d)
				if hit.is_empty():
					continue
				for pl: Control in k.ui.hud.band_plates(HUD.BAND_NOTICE):
					if pl.get_global_rect().has_point(hit["pixel"]):
						hit_angles.append(i * 2)
						break
			row["ring %d deg" % int(ecc)] = "%d of 360 deg covered %s" % [hit_angles.size() * 2, _ranges(hit_angles)]
		rows["card offset %s" % str(off)] = row
	panel.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)
	metric("ring_cover", rows)
	for key: String in rows:
		print("[ui-verify] %s -> %s" % [key, str(rows[key])])
	k.ui.set_process(true)
	k.teardown()
	await wait_frames(2)


static func _ranges(a: Array[int]) -> String:
	if a.is_empty():
		return ""
	var out: Array[String] = []
	var start := a[0]
	var prev := a[0]
	for v in a.slice(1):
		if v != prev + 2:
			out.append("%d..%d" % [start, prev])
			start = v
		prev = v
	out.append("%d..%d" % [start, prev])
	return "(ring angles " + ", ".join(out) + ")"


func test_make_way_near_worst_search_cost() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.set_process(false)
	var hud := k.ui.hud
	Events.player_tier_changed.emit(3, 4)
	await k.settle(self, 2)
	# A climb (14 deg), a threat 30 deg up ahead and prey right: no step up
	# clears both the path and the threat, the right side is blocked, so the
	# search walks almost every candidate before the left side clears.
	var dirs: Array[Vector3] = [_dir(0.0, 14.0), _dir(0.0, 30.0), _dir(-27.0, 13.0)]
	hud.make_way(dirs, 0.016)
	var t0 := Time.get_ticks_usec()
	for i in 200:
		hud.make_way(dirs, HUD.DODGE_SEARCH_S + 0.001)
	var search_us := (Time.get_ticks_usec() - t0) / 200.0
	var cands := hud.placement_candidates()
	var idx := -1
	for i in cands.size():
		if (cands[i][0] as Vector2) == hud.dodge_target:
			idx = i
	# Stuck: nothing in reach clears (3 real directions cannot do this, so
	# use 4: the full candidate list is scanned every search).
	var stuck_dirs: Array[Vector3] = [_dir(0.0, 14.0), _dir(0.0, 30.0), _dir(-27.0, 13.0), _dir(27.0, 13.0)]
	hud.make_way(stuck_dirs, 0.016)
	t0 = Time.get_ticks_usec()
	for i in 200:
		hud.make_way(stuck_dirs, HUD.DODGE_SEARCH_S + 0.001)
	var stuck_us := (Time.get_ticks_usec() - t0) / 200.0
	metric("make_way_near_worst", {"search_us": snappedf(search_us, 0.1), "placement": str(hud.dodge_target),
		"candidate_index": idx, "candidates": cands.size(), "stuck": hud.dodge_stuck, "stuck_search_us": snappedf(stuck_us, 0.1)})
	print("[ui-verify] make_way near-worst search %.1f us (candidate %d of %d, %s); stuck search %.1f us (stuck=%s)" % [search_us, idx, cands.size(), str(hud.dodge_target), stuck_us, str(hud.dodge_stuck)])
	# The builder's own budget.
	lt(search_us, 600.0, "a near-worst search frame < 0.6 ms on the dev Mac")
	lt(stuck_us, 600.0, "a stuck search frame < 0.6 ms on the dev Mac")
	k.ui.set_process(true)
	k.teardown()
	await wait_frames(2)
