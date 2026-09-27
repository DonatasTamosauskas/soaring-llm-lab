extends TestCase
## Verifier probes (round 1) for U1: strings the builder's worst-case context
## does not reach (apex headline + New best badge, vowel species), checked
## with the same geometry rules the builder uses. Independent verifier.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_all() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_all() -> void:
	k.teardown()
	await wait_frames(2)


func _show(id: StringName, patch: Dictionary) -> UIScreen:
	var s := k.ui.get_screen(id)
	k.ui.stack = [id]
	k.ui._show_top()
	var ctx := k.ui.context()
	ctx.merge(patch, true)
	s.refresh(ctx)
	await k.settle(self, 4)
	return s


func _visible_texts(root: Node) -> Array:
	var out := []
	for n in root.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		if c is Label and not (c as Label).text.is_empty():
			out.append((c as Label).text)
	return out


func _all_inside(tag: String, s: UIScreen) -> int:
	var inner := Rect2(Vector2(20, 20), Vector2(UITheme.MENU_SIZE) - Vector2(40, 40))
	var outside := 0
	for n in s.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree() or c is FacetBackground or c is MarginContainer or c.size == Vector2.ZERO:
			continue
		var r := c.get_global_rect()
		if not inner.grow(1.0).encloses(r):
			outside += 1
			check(false, "%s: %s outside the panel margins (%s)" % [tag, c.name, r])
	return outside


func test_apex_summary_with_new_best_fits() -> void:
	var s := await _show(&"summary", {
		"new_best": true, "best_score": 1234567,
		"summary": {"score": 1234567, "time": 5999.0, "max_mass": 3.2, "max_tier": 9,
			"catches_by_species": {&"hawk": 12, &"gull": 30, &"crow": 45, &"pigeon": 99, &"starling": 120, &"swallow": 3}},
	})
	var texts := _visible_texts(s)
	metric("apex_texts", texts)
	var n := _all_inside("apex summary", s)
	metric("controls_outside", n)
	# The headline label itself must not be squeezed narrower than its text.
	var head := s.find_child("Headline", true, false) as Label
	var w := head.get_theme_font("font").get_string_size(head.text, HORIZONTAL_ALIGNMENT_LEFT, -1, head.get_theme_font_size("font_size")).x
	metric("headline", {"text": head.text, "text_w": snappedf(w, 1), "label_w": snappedf(head.size.x, 1),
		"label_end_x": snappedf(head.get_global_rect().end.x, 1)})
	check(w <= head.size.x + 1.0, "apex headline fits its label (%.0f <= %.0f)" % [w, head.size.x])


func test_species_starting_with_a_vowel_read_correctly() -> void:
	# "Eagle" is the only vowel species; players at hawk/eagle see these.
	var eagle := SizeRules.SPECIES[9]
	var hawk := SizeRules.SPECIES[8]
	var cs := await _show(&"caught", {"predator_name": eagle["name"], "stats": {"lives": 2, "lives_max": 3}})
	var caught_texts := _visible_texts(cs)
	var ps := await _show(&"pause", {"player_mass": float(hawk["mass"]) * 1.05})
	var pause_hawk := _visible_texts(ps)
	ps = await _show(&"pause", {"player_mass": float(eagle["mass"]) * 1.05})
	var pause_eagle := _visible_texts(ps)
	metric("caught_by_eagle", caught_texts)
	metric("pause_at_hawk", pause_hawk)
	metric("pause_at_eagle", pause_eagle)
	check(not "by a Eagle" in caught_texts, "caught screen does not say 'by a Eagle'")
	check(not "Growing into a Eagle" in pause_hawk, "pause does not say 'Growing into a Eagle'")
	check(not "You are a Eagle" in pause_eagle, "pause does not say 'You are a Eagle'")
