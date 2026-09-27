class_name CaughtScreen
extends UIScreen
## You were caught: who got you, lives left, and a countdown back into the
## air. Informational only (no pointer); the menu button still pauses.

var _who: Label
var _icon: BirdIcon
var _lives: HBoxContainer
var _lives_label: Label
var _count: Label
var _last_count := -1


func _init() -> void:
	super()
	interactive = false
	border_color = Color(UITheme.THREAT, 0.95)


func build() -> void:
	var m := margin_box(80, 56)
	var col := vbox(10)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	m.add_child(col)
	var title := make_label("Caught!", &"TitleLabel", 116)
	title.add_theme_color_override("font_color", UITheme.THREAT_TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	_icon = BirdIcon.new()
	_icon.name = "Predator"
	_icon.custom_minimum_size = Vector2(0, 190)
	_icon.setup(BirdIcon.Relation.THREAT)
	col.add_child(_icon)
	_who = make_label("", &"", UITheme.FS_TITLE)
	_who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_who)
	var lives_row := hbox(18)
	lives_row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(lives_row)
	_lives_label = make_label("Lives", &"DimLabel")
	lives_row.add_child(_lives_label)
	_lives = hbox(12)
	lives_row.add_child(_lives)
	col.add_child(spacer())
	_count = make_label("", &"AccentLabel", UITheme.FS_TITLE)
	_count.name = "Countdown"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_count)


func refresh(ctx: Dictionary) -> void:
	var pred: String = ctx.get("predator_name", "")
	_who.text = "by %s" % a_an(pred) if not pred.is_empty() else "by a bigger bird"
	var sp: StringName = ctx.get("predator_species", &"")
	# The silhouette of the bird that got you (a generic big bird if unknown).
	_icon.setup(BirdIcon.Relation.THREAT, 1.0, sp if SizeRules.species_index(sp) >= 0 else &"hawk")
	var stats: Dictionary = ctx.get("stats", {})
	var lives := int(stats.get("lives", -1))
	var lives_max := int(stats.get("lives_max", maxi(lives, 0)))
	for c in _lives.get_children():
		c.queue_free()
	_lives_label.get_parent().visible = lives >= 0
	for i in maxi(lives_max, lives):
		var pip := _Pip.new()
		pip.full = i < lives
		pip.custom_minimum_size = Vector2(56, 56)
		_lives.add_child(pip)
	set_countdown(float(ctx.get("respawn_in", -1.0)), lives)


func set_countdown(seconds: float, lives: int = -1) -> void:
	var n := int(ceil(seconds))
	if n == _last_count and seconds >= 0.0:
		return
	_last_count = n
	if lives == 0:
		_count.text = "Out of lives"
	elif seconds < 0.0:
		_count.text = "Get ready…"
	else:
		_count.text = "Back in the air in %d" % maxi(n, 0) if n > 0 else "Fly!"


func countdown_text() -> String:
	return _count.text


## (full, total) life pips currently shown; total 0 when lives are unknown.
func lives_shown() -> Vector2i:
	if not _lives_label.get_parent().visible:
		return Vector2i.ZERO
	var full := 0
	var total := 0
	for c in _lives.get_children():
		if c.is_queued_for_deletion():
			continue
		total += 1
		if (c as _Pip).full:
			full += 1
	return Vector2i(full, total)


class _Pip:
	extends Control
	## One life: a filled or hollow hexagon.
	var full := true

	func _draw() -> void:
		var pts := PackedVector2Array()
		var r := minf(size.x, size.y) * 0.45
		for i in 6:
			var a := TAU * i / 6.0 + PI / 6.0
			pts.append(size * 0.5 + Vector2(cos(a), sin(a)) * r)
		if full:
			GestureArt.poly(self, pts, UITheme.ACCENT)
		else:
			pts.append(pts[0])
			draw_polyline(pts, UITheme.TEXT_DIM, 5.0)
