class_name SummaryScreen
extends UIScreen
## End of a run: the biggest bird you became (headline + its silhouette),
## time, score, best, peak size, and what you caught, biggest prey first.
## When this run set the record, the Score's caption becomes "New best!"
## and the Best column (which would repeat the same number) is dropped.
##
## A *victory* (GameLoop's apex goal: summary.victory / reason "victory")
## says so and offers "Keep flying", GameLoop's continue_after_victory()
## (a victory lap in the same run), besides Fly again and Main menu.
##
## Everything is laid out to fit the worst case: the apex headline, a
## seven-digit score and every species caught (tested).

## Species chips shown at most (two columns x three rows); beyond that the
## last cell says "+N more".
const MAX_CHIPS := 6
const CHIP_COLUMNS := 2
## Space either side of the thin rule between stat columns: numbers in
## neighbouring columns must never read as one ("98 765 98 765").
const STAT_GAP := 26
const DIVIDER_W := 3.0

var _icon: BirdIcon
var _title: Label
var _score_caption: Label
var _badge: Label
var _time: Label
var _score: Label
var _best: Label
var _size: Label
var _catches: GridContainer
var _none: Label
var _stat_values: Array[Label] = []
var _stat_cells: Array[Control] = []
var _dividers: Array[Control] = []
var _victory := false


func build() -> void:
	var m := margin_box()
	var col := vbox(16)
	m.add_child(col)
	var top := hbox(16)
	col.add_child(top)
	_icon = BirdIcon.new()
	_icon.name = "PeakBird"
	_icon.custom_minimum_size = Vector2(112, 90)
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon.setup(BirdIcon.Relation.YOU)
	top.add_child(_icon)
	_title = make_label("", &"TitleLabel")
	_title.name = "Headline"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_title)

	var stats := hbox(STAT_GAP)
	stats.name = "Stats"
	col.add_child(stats)
	_time = _stat(stats, "Time")
	_score = _stat(stats, "Score")
	# On a new record the Score's caption turns into the badge.
	_score_caption = _score.get_parent().get_child(0) as Label
	_badge = make_label("New best!", &"AccentLabel")
	_badge.name = "NewBest"
	_score.get_parent().add_child(_badge)
	_score.get_parent().move_child(_badge, 0)
	_best = _stat(stats, "Best")
	_size = _stat(stats, "Peak size")

	col.add_child(make_label("Caught", &"DimLabel"))
	_catches = GridContainer.new()
	_catches.name = "Catches"
	_catches.columns = CHIP_COLUMNS
	_catches.add_theme_constant_override("h_separation", 40)
	_catches.add_theme_constant_override("v_separation", 4)
	_catches.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_catches)
	_none = make_label("Nothing this time. Smaller birds are food!")
	col.add_child(_none)
	col.add_child(spacer())
	var buttons := hbox(24)
	col.add_child(buttons)
	# Only after a victory: carry on in the same run.
	var keep := make_button(&"keep_flying", "Keep flying", 104, true)
	keep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keep.alignment = HORIZONTAL_ALIGNMENT_CENTER
	buttons.add_child(keep)
	var again := make_button(&"again", "Fly again", 104, true)
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again.alignment = HORIZONTAL_ALIGNMENT_CENTER
	buttons.add_child(again)
	var menu := make_button(&"menu", "Main menu", 104)
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.alignment = HORIZONTAL_ALIGNMENT_CENTER
	buttons.add_child(menu)


func _stat(parent: Control, caption: String) -> Label:
	if not _stat_cells.is_empty():
		# A thin rule between columns.
		var rule := ColorRect.new()
		rule.name = "Rule%d" % _dividers.size()
		rule.color = Color(UITheme.TEXT_DIM, 0.3)
		rule.custom_minimum_size = Vector2(DIVIDER_W, 0)
		rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(rule)
		_dividers.append(rule)
	var cell := vbox(0)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(cell)
	_stat_cells.append(cell)
	cell.add_child(make_label(caption, &"DimLabel"))
	var v := make_label("", &"AccentLabel", UITheme.FS_TITLE)
	cell.add_child(v)
	_stat_values.append(v)
	return v


func refresh(ctx: Dictionary) -> void:
	var s: Dictionary = ctx.get("summary", {})
	var max_mass := float(s.get("max_mass", ctx.get("player_mass", 0.0)))
	var tier := int(s.get("max_tier", SizeRules.tier_for_mass(max_mass) if max_mass > 0.0 else -1))
	tier = mini(tier, SizeRules.SPECIES.size() - 1)
	_victory = is_victory(s)
	if _victory:
		_title.text = "Victory! You rule the sky"
	elif tier >= SizeRules.SPECIES.size() - 1:
		_title.text = "Apex! You became the %s" % SizeRules.SPECIES[tier]["name"]
	elif tier >= 0:
		_title.text = "You reached %s" % SizeRules.SPECIES[tier]["name"]
	else:
		_title.text = "Run over"
	_icon.visible = tier >= 0
	if tier >= 0:
		_icon.setup(BirdIcon.Relation.YOU, 1.0, SizeRules.SPECIES[tier]["id"])
	var head_w := UITheme.MENU_SIZE.x - 2.0 * 60.0 - (_icon.custom_minimum_size.x + 16.0 if _icon.visible else 0.0)
	_title.add_theme_font_size_override("font_size",
		fit_size(_title.get_theme_font("font"), _title.text, UITheme.FS_TITLE, UITheme.FS_BODY, head_w))
	_time.text = format_time(float(s.get("time", ctx.get("run_time", 0.0))))
	var score := int(s.get("score", 0))
	var best := int(ctx.get("best_score", s.get("best_score", score)))
	_score.text = format_int(score)
	_best.text = format_int(maxi(best, score))
	_size.text = format_mass(max_mass) if max_mass > 0.0 else "–"
	var nb := bool(ctx.get("new_best", false))
	_badge.visible = nb
	_score_caption.visible = not nb
	# A new record: Best would just repeat Score.
	_best.get_parent().visible = not nb
	_dividers[1].visible = not nb
	get_button(&"keep_flying").visible = _victory
	# One accent button: Keep flying after a victory, else Fly again.
	set_primary(get_button(&"again"), not _victory)
	_fit_stats()
	_fill_catches(s.get("catches_by_species", {}))


## GameLoop's summary marks a won run with victory = true (and reason
## "victory").
static func is_victory(summary: Dictionary) -> bool:
	return bool(summary.get("victory", false)) or StringName(str(summary.get("reason", ""))) == &"victory"


func victory_shown() -> bool:
	return _victory


## One size for all shown stat values: the largest (<= title size) at which
## every value fits its share of the row (columns, rules and gaps).
func _fit_stats() -> void:
	var n := 0
	for c in _stat_cells:
		if c.visible:
			n += 1
	var gaps := 2.0 * (n - 1) * STAT_GAP + (n - 1) * DIVIDER_W
	var cell_w := (UITheme.MENU_SIZE.x - 2.0 * 60.0 - gaps) / float(maxi(n, 1))
	var sz := UITheme.FS_TITLE
	for v in _stat_values:
		if v.get_parent().visible:
			sz = mini(sz, fit_size(v.get_theme_font("font"), v.text, UITheme.FS_TITLE, UITheme.FS_BODY, cell_w))
	for v in _stat_values:
		v.add_theme_font_size_override("font_size", sz)


func _fill_catches(by: Dictionary) -> void:
	for c in _catches.get_children():
		_catches.remove_child(c)
		c.queue_free()
	var ids := []
	for id in by:
		if int(by[id]) > 0:
			ids.append(id)
	# Biggest prey first: it is the achievement.
	ids.sort_custom(_bigger_first)
	var shown := ids.size() if ids.size() <= MAX_CHIPS else MAX_CHIPS - 1
	for i in shown:
		var id: StringName = StringName(str(ids[i]))
		var chip := hbox(12)
		var icon := BirdIcon.new()
		icon.custom_minimum_size = Vector2(80, 64)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon.setup(BirdIcon.Relation.PREY, 1.0, id)
		chip.add_child(icon)
		chip.add_child(make_label("%s ×%d" % [species_name(id), int(by[ids[i]])]))
		_catches.add_child(chip)
	if ids.size() > shown:
		var rest := make_label("+%d more species" % (ids.size() - shown), &"DimLabel")
		rest.name = "More"
		_catches.add_child(rest)
	_none.visible = ids.is_empty()
	_catches.visible = not ids.is_empty()


## "0.34 kg", "3.2 kg", "12 g": the body mass the player peaked at.
static func format_mass(kg: float) -> String:
	if kg < 0.1:
		return "%d g" % int(round(kg * 1000.0))
	if kg < 1.0:
		return "%.2f kg" % kg
	return "%.1f kg" % kg


static func _bigger_first(a: Variant, b: Variant) -> bool:
	return SizeRules.species_index(StringName(str(a))) > SizeRules.species_index(StringName(str(b)))
