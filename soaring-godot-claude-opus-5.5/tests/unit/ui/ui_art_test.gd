extends TestCase
## The procedural illustrations (how-to cards, HUD lesson art, icons,
## emblem) draw quickly at every size and animation phase: they redraw at up
## to 30 fps inside a VR panel, so a slow or runaway draw is a real bug.


class ArtProbe:
	extends Control
	var art: StringName
	var t := 0.0
	var ms := 0.0

	func _draw() -> void:
		var t0 := Time.get_ticks_usec()
		GestureArt.draw(self, art, Rect2(Vector2.ZERO, size), t)
		ms = (Time.get_ticks_usec() - t0) / 1000.0


func test_every_illustration_draws_fast_at_every_size_and_phase() -> void:
	var probe := ArtProbe.new()
	add_child(probe)
	var worst := 0.0
	# Full how-to card, HUD lesson thumbnail, and a degenerate tiny rect.
	for sz: Vector2 in [Vector2(900, 380), Vector2(210, 250), Vector2(12, 8)]:
		probe.size = sz
		for id: StringName in GestureArt.IDS:
			for k in 8:
				probe.art = id
				probe.t = k * 0.37
				probe.queue_redraw()
				await wait_frames(1)
				worst = maxf(worst, probe.ms)
				check(probe.ms < 25.0, "%s at %s t=%.2f drew in %.1f ms" % [id, sz, probe.t, probe.ms])
	metric("worst_draw_ms", snappedf(worst, 0.01))
	probe.queue_free()


func test_screens_draw_without_hanging() -> void:
	# Building and drawing every widget once (emblem, bars, icons) completes.
	var root := Control.new()
	root.size = Vector2(1360, 900)
	add_child(root)
	var t0 := Time.get_ticks_msec()
	for w: Control in [Emblem.new(), FacetBackground.new(), SegmentBar.new(), FacetBar.new(), BirdIcon.new()]:
		w.size = Vector2(600, 300)
		root.add_child(w)
	await wait_frames(3)
	lt(float(Time.get_ticks_msec() - t0), 2000.0, "widgets build and draw in well under 2 s")
	root.queue_free()


class IconProbe:
	extends Control
	var sp: StringName
	var ms := 0.0

	func _draw() -> void:
		var t0 := Time.get_ticks_usec()
		BirdIcon.draw_species(self, size * 0.5, size.x, sp, UITheme.PREY)
		ms = (Time.get_ticks_usec() - t0) / 1000.0


func test_every_species_has_its_own_silhouette() -> void:
	# Shape says which bird it is (colour says what it is to you): every
	# species on the ladder needs its own, distinct outline parameters.
	var seen := {}
	for sp: Dictionary in SizeRules.SPECIES:
		var id: StringName = sp["id"]
		if id == &"moth":
			continue
		check(BirdIcon.SHAPES.has(id), "%s has a silhouette" % id)
		var key := str(BirdIcon.SHAPES.get(id, {}))
		check(not seen.has(key), "%s's silhouette differs from %s" % [id, seen.get(key, "")])
		seen[key] = id
	# Signature features the brief names: forked swallow tail, fingered
	# broad wings on the big hunters, the gull's bent wing.
	eq(BirdIcon.SHAPES[&"swallow"]["tail"], "fork", "swallow: forked tail")
	eq(BirdIcon.SHAPES[&"eagle"]["tip"], "fingers", "eagle: fingered wing tips")
	gt(BirdIcon.SHAPES[&"gull"]["bend"], 0.05, "gull: bent wing")
	# And each draws quickly at ladder, chip and headline sizes.
	var probe := IconProbe.new()
	add_child(probe)
	var worst := 0.0
	for sz: float in [30.0, 80.0, 220.0]:
		probe.size = Vector2(sz, sz * BirdIcon.ASPECT)
		for sp: Dictionary in SizeRules.SPECIES:
			probe.sp = sp["id"]
			probe.queue_redraw()
			await wait_frames(1)
			worst = maxf(worst, probe.ms)
	metric("worst_icon_draw_ms", snappedf(worst, 0.01))
	lt(worst, 5.0, "every icon draws in under 5 ms")
	probe.queue_free()
