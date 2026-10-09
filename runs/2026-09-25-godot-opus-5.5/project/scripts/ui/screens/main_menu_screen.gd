class_name MainMenuScreen
extends UIScreen
## Title screen: emblem and name on the left, four big buttons on the right.

var _best: Label


func build() -> void:
	var m := margin_box(64, 48)
	var row := hbox(48)
	m.add_child(row)
	var left := vbox(6)
	left.custom_minimum_size = Vector2(640, 0)
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(left)
	var em := Emblem.new()
	em.custom_minimum_size = Vector2(640, 330)
	left.add_child(em)
	var title := make_label("SOARING", &"TitleLabel", UITheme.FS_DISPLAY)
	title.add_theme_font_override("font", UITheme.font(1000))
	title.add_theme_color_override("font_color", UITheme.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(title)
	var tag := make_label("Fly with your arms.\nEat or be eaten.", &"DimLabel")
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(tag)
	_best = make_label("", &"AccentLabel")
	_best.name = "Best"
	_best.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(_best)

	var right := vbox(22)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	var play := make_button(&"play", "Play", 124, true)
	play.add_theme_font_size_override("font_size", 76)
	right.add_child(play)
	right.add_child(make_button(&"howto", "How to fly"))
	right.add_child(make_button(&"settings", "Settings"))
	# Quit is a hold (integration round 2, all three verifiers: in the
	# headset the resting right controller's laser lies on Quit, and one
	# pull closed the game - a reload on a Quest takes several seconds).
	right.add_child(make_button(&"quit", "Quit", 90.0, false, "Hold to quit"))


func refresh(ctx: Dictionary) -> void:
	var best := int(ctx.get("best_score", 0))
	_best.text = "Best  %s" % format_int(best) if best > 0 else ""
	_best.visible = best > 0
