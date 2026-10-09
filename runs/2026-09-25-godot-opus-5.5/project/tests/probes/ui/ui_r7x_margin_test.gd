extends TestCase
## VERIFIER PROBE (round 7, experience lens). Not part of the UI suite.
##
## Live, the lesson card moved to the other side of the view after "three
## crossings" that were one: seed 21 fades at 5.69 s (0.15 s long) and 6.28 s
## (0.01 s, one frame), moves at 6.31 s; seed 5 fades at 5.63 s (0.01 s) and
## 5.67 s, moves at 5.88 s (ui_r7x_live_test). HUD.MOVE_AFTER_ENTRIES counts
## every frame the "covered" test turns true; nothing debounces it. The
## design says a crossing never moves the card, only something that STAYS
## (1 s) or KEEPS COMING BACK (3 crossings in 8 s: "a flight path drifted
## into their column sweeps through with every flap cycle").
##
## Here the flight path (Bird.velocity, the only input) sits on the card's
## fade margin, jittering by a few tenths of a degree the way a flapping
## bird's velocity does frame to frame, for well under a second, then
## leaves. That is one crossing.
##
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r7x_margin

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SDT := 1.0 / 72.0

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


func _frame() -> void:
	k.ui.hud_panel.follow(SDT)
	k.ui.indicators.step(SDT)
	k.ui.hud.make_way(k.ui.hud_protected_directions(), SDT)
	k.ui.hud.advance(SDT)


## Direction (world, the rig at the identity) at azimuth `az` deg right of
## -Z and elevation `el` deg.
static func _dir(az: float, el: float) -> Vector3:
	var a := deg_to_rad(az)
	var e := deg_to_rad(el)
	return Vector3(sin(a) * cos(e), sin(e), -cos(a) * cos(e))


func _covered_at(az: float, el: float) -> bool:
	k.player.velocity = _dir(az, el) * 8.0
	var level: Array[Vector3] = [k.ui.hud_panel.level_direction(k.player.velocity.normalized())]
	var hud := k.ui.hud
	return not bool(hud.call(&"_clear", level, k.ui.hud_panel.band_offset(HUD.BAND_NOTICE), hud.notice_rects(), HUD.FADE_MARGIN_DEG))


func test_one_jittery_crossing_of_the_margin_moves_the_card() -> void:
	k.ui.onboarding.reset()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.indicators.set_process(false)
	k.ui.onboarding.auto_step = false
	var hud := k.ui.hud
	check(hud.lesson_visible(), "a lesson card is up")
	for i in 72:
		_frame()
	var el := HUD.NOTICE_PITCH
	# The card's fade boundary on its inner (centre-line) side at the band's
	# middle height: scan from the centre line outwards.
	var az_b := NAN
	var az := 0.0
	while az < 20.0:
		if _covered_at(az, el):
			az_b = az
			break
		az += 0.05
	check(is_finite(az_b), "found the card's fade margin (%.2f deg right)" % az_b)
	if not is_finite(az_b):
		return
	print("[ui-verify] the card's fade margin starts %.2f deg right of the centre line at +%.0f deg" % [az_b, el])
	# Control: a smooth pass through the margin and out again (no jitter) is
	# one crossing and no move; then the same with jitter.
	for amp: float in [0.0, 0.1, 0.3, 0.6]:
		k.player.velocity = Vector3(0, 0, -8)
		for i in int(6.0 / SDT):
			_frame()
		var moves0 := hud.move_count
		var entries_max := 0
		var fades := 0
		var was := false
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		# 0.4 s on the margin with frame-to-frame jitter, then clear away.
		for i in int(0.4 / SDT):
			# The path eases 1 deg into the margin and back out over the 0.4 s,
			# with frame-to-frame jitter of +-amp on top.
			var base := az_b - 0.5 + 1.0 * sin(PI * i * SDT / 0.4)
			k.player.velocity = _dir(base + rng.randf_range(-amp, amp), el + rng.randf_range(-amp, amp)) * 8.0
			_frame()
			var st: bool = hud.see_through[HUD.BAND_NOTICE]
			if st and not was:
				fades += 1
			was = st
			entries_max = maxi(entries_max, (hud.get(&"_entries") as Array).size())
		k.player.velocity = _dir(-5.0, -10.0) * 8.0
		for i in int(3.0 / SDT):
			_frame()
		var moved := hud.move_count - moves0
		var r := {"jitter_deg": amp, "crossing_s": 0.4, "entries_counted": entries_max, "fade_onsets": fades, "moves": moved, "side_after": hud.notice_side}
		print("[ui-verify] one 0.4 s crossing of the margin with +-%.1f deg jitter: %s" % [amp, JSON.stringify(r)])
		metric("one_crossing_jitter_%s" % str(amp), r)
		metric("fades_%s" % str(amp), fades)
		lt(entries_max, 2, "+-%.1f deg jitter, one 0.4 s crossing counts as one crossing (%d)" % [amp, entries_max])
		eq(moved, 0, "+-%.1f deg jitter, one 0.4 s crossing never moves the card (%d moves)" % [amp, moved])
		# Put the card back home for the next case.
		hud.set(&"_since_move", 100.0)
		if hud.notice_side != 1:
			k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)
			hud.call(&"_rest_at", Vector2.ZERO)
		for i in int(1.0 / SDT):
			_frame()
