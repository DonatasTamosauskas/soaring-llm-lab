class_name PauseScreen
extends UIScreen
## Pause: actions on the left; on the right, where you stand in the food
## chain (what is worth hunting, who hunts you, what is now too small to
## bother with) and the run so far. At the top of the ladder the progress
## line shows the apex goal (worthwhile catches as the eagle) instead.
##
## Restart run and Quit to menu discard the run, so they are HoldButtons:
## one short, mis-aimed pull does nothing.
##
## VR area addition (calibration redesign, 2026-09-26; see docs/areas/VR.md
## §2.3): while the VR autoload says the headset may be on someone new
## (context "recalibrate_suggested": it came off and on, a long absence, a
## relaunch) the top row offers "New player? Recalibrate wings" (action
## &"recalibrate", as Settings > Recalibrate wings) in place of the
## run-so-far line, which then takes the tip's line. Nothing else changes.

var _you: Label
var _ladder: HBoxContainer
var _eat: Label
var _flee: Label
var _ignore: Label
var _run: Label
var _next: Label
var _growth: FacetBar
var _tip: Label
var _tip_i := 0
## VR's suggestion (see the class comment); hidden unless suggested.
var _recal: Button
var _top_gap: Control
var _recal_fitted := false

## One short tip per pause (a new one each time the game is paused, the same
## one while you browse Settings and come back); each fits one line of the
## right column (tested; the label still wraps rather than clip).
const TIPS := [
	"Sunny fields lift you up.",
	"Tuck to dive on prey.",
	"Hedges shelter prey.",
	"Glide in slowly to perch.",
	"Big birds turn wide.",
	"Circle in rising air.",
]


func build() -> void:
	var m := margin_box()
	var col := vbox(20)
	m.add_child(col)
	var top := hbox()
	col.add_child(top)
	top.add_child(make_label("Paused", &"TitleLabel"))
	_top_gap = spacer(false)
	top.add_child(_top_gap)
	_recal = make_button(&"recalibrate", "New player? Recalibrate wings")
	_recal.visible = false
	_recal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_recal)
	_run = make_label("", &"DimLabel")
	_run.name = "RunSoFar"
	top.add_child(_run)
	var row := hbox(56)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(row)

	var left := vbox(12)
	left.custom_minimum_size = Vector2(500, 0)
	row.add_child(left)
	left.add_child(make_button(&"resume", "Resume", 90, true))
	left.add_child(make_button(&"restart", "Restart run", 90, false, "Hold to restart"))
	left.add_child(make_button(&"settings", "Settings"))
	left.add_child(make_button(&"howto", "How to fly"))
	left.add_child(make_button(&"skip_tutorial", "Skip tutorial"))
	left.add_child(make_button(&"quit_menu", "Quit to menu", 90, false, "Hold to quit"))

	var right := vbox(14)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	_you = make_label("", &"AccentLabel")
	right.add_child(_you)
	_ladder = hbox(2)
	_ladder.custom_minimum_size = Vector2(0, 96)
	right.add_child(_ladder)
	for i in SizeRules.SPECIES.size():
		var icon := BirdIcon.new()
		icon.custom_minimum_size = Vector2(62, 96)
		icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		icon.species = SizeRules.SPECIES[i]["id"]
		_ladder.add_child(icon)
	_eat = make_label("")
	_eat.add_theme_color_override("font_color", UITheme.PREY)
	right.add_child(_eat)
	_flee = make_label("")
	_flee.add_theme_color_override("font_color", UITheme.THREAT_TEXT)
	right.add_child(_flee)
	_ignore = make_label("", &"DimLabel")
	_ignore.name = "Ignore"
	right.add_child(_ignore)
	right.add_child(spacer())
	_tip = make_label("", &"DimLabel")
	_tip.name = "Tip"
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_tip)
	right.add_child(spacer())
	_next = make_label("", &"DimLabel")
	right.add_child(_next)
	_growth = FacetBar.new()
	_growth.custom_minimum_size = Vector2(0, 26)
	right.add_child(_growth)


func refresh(ctx: Dictionary) -> void:
	var mass: float = ctx.get("player_mass", SizeRules.SPECIES[2]["mass"])
	var tier := SizeRules.tier_for_mass(mass)
	_you.text = "You are %s" % a_an(SizeRules.SPECIES[tier]["name"])
	var chain := food_chain(mass)
	for i in _ladder.get_child_count():
		var icon := _ladder.get_child(i) as BirdIcon
		# Icons grow with the species so the row reads as a ladder.
		icon.setup(chain["relations"][i], lerpf(0.5, 1.0, i / float(SizeRules.SPECIES.size() - 1)))
	var stats: Dictionary = ctx.get("stats", {})
	var top := tier >= SizeRules.SPECIES.size() - 1
	var goal := apex_goal(stats) if top else {}
	if not top:
		_next.text = "Growing into %s" % a_an(SizeRules.SPECIES[tier + 1]["name"])
		_growth.value = HudMath.growth_progress(mass)
	elif goal.is_empty():
		_next.text = "Top of the sky"
		_growth.value = 1.0
	elif goal["won"]:
		_next.text = "You won! Victory lap"
		_growth.value = 1.0
	else:
		_next.text = "Apex hunt: %d of %d" % [goal["catches"], goal["needed"]]
		_growth.value = float(goal["catches"]) / float(goal["needed"])
	_tip.text = TIPS[_tip_i]
	_tip.max_lines_visible = 2
	_eat.text = chain["eat_line"]
	_flee.text = chain["flee_line"]
	_ignore.text = chain["ignore_line"]
	_ignore.visible = _ignore.text != ""
	var get_skip := get_button(&"skip_tutorial")
	get_skip.visible = bool(ctx.get("tutorial_active", false))
	var t: float = stats.get("time", ctx.get("run_time", 0.0))
	var catches := int(stats.get("catches", 0))
	_run.text = "%s  ·  %d caught" % [format_time(t), catches]
	# VR's "New player? Recalibrate wings": the run-so-far line moves to the
	# tip's place (the top row has no room for both).
	var suggest := bool(ctx.get("recalibrate_suggested", false))
	if suggest and not _recal_fitted:
		_fit_recal()
	_recal.visible = suggest
	_top_gap.visible = not suggest
	_run.visible = not suggest
	if suggest:
		_tip.text = _run.text


## The suggestion button fills the top row beside the title; its sides are
## padded 24 px (the theme's 28 would make the row 5 px wider than the
## panel's content at 60 px type).
func _fit_recal() -> void:
	_recal_fitted = true
	for st: StringName in [&"normal", &"hover", &"pressed", &"focus", &"disabled"]:
		var sb := _recal.get_theme_stylebox(st)
		if sb != null:
			var c := sb.duplicate() as StyleBox
			c.content_margin_left = 24.0
			c.content_margin_right = 24.0
			_recal.add_theme_stylebox_override(st, c)


## A new pause: show the next tip (UIRoot calls this on entering PAUSED).
func next_tip() -> void:
	_tip_i = (_tip_i + 1) % TIPS.size()
	_tip.text = TIPS[_tip_i]


func tip_text() -> String:
	return _tip.text


## GameLoop's apex goal from its run stats ({catches, needed, won}), or {}
## when there is none (no GameLoop, or it has no apex block).
static func apex_goal(stats: Dictionary) -> Dictionary:
	var a: Variant = stats.get("apex")
	if not (a is Dictionary) or int((a as Dictionary).get("needed", 0)) <= 0:
		return {}
	var d := a as Dictionary
	var needed := int(d["needed"])
	return {"catches": clampi(int(d.get("catches", 0)), 0, needed), "needed": needed,
		"won": bool(d.get("victory", false)) or bool(stats.get("endless", false))}


## Relation of every species on the ladder to a bird of `mass`, and the
## lines the pause screen and the tier-up toast say about it. "Prey" is only
## what is *worth chasing* (SizeRules.is_worthwhile: the rule GameLoop's
## highlights, target cue and apex count use). Birds you could eat but that
## are too small to bother with are DUST, listed as "Ignore": as you grow,
## the smallest birds drop off your menu, which is what makes a bigger bird
## hunt differently. Pure, so tests pin the loop's message at every size.
static func food_chain(mass: float) -> Dictionary:
	var rel: Array[int] = []
	var prey: Array[int] = []
	var dust: Array[int] = []
	var min_threat := -1
	var me := SizeRules.tier_for_mass(mass)
	var top := SizeRules.SPECIES.size() - 1
	for i in SizeRules.SPECIES.size():
		var m: float = SizeRules.SPECIES[i]["mass"]
		if i == me:
			rel.append(BirdIcon.Relation.YOU)
		elif SizeRules.can_eat(mass, m):
			if SizeRules.is_worthwhile(mass, m):
				rel.append(BirdIcon.Relation.PREY)
				prey.append(i)
			else:
				rel.append(BirdIcon.Relation.DUST)
				dust.append(i)
		elif SizeRules.can_eat(m, mass):
			rel.append(BirdIcon.Relation.THREAT)
			if min_threat < 0:
				min_threat = i
		else:
			rel.append(BirdIcon.Relation.NEUTRAL)
	var hunt := species_range(prey)
	var flee: String = "" if min_threat < 0 else (SizeRules.SPECIES[min_threat]["name"] if min_threat == top else "%s & up" % SizeRules.SPECIES[min_threat]["name"])
	return {"relations": rel, "prey": prey, "dust": dust, "max_prey": prey[-1] if not prey.is_empty() else -1,
		"min_threat": min_threat, "eat_text": hunt, "flee_text": flee, "ignore_text": species_range(dust),
		"eat_line": "Nothing to hunt yet" if prey.is_empty() else "Hunt: %s" % hunt,
		"flee_line": "Nothing hunts you" if min_threat < 0 else "Flee: %s" % flee,
		"ignore_line": "" if dust.is_empty() else "Ignore: %s" % species_range(dust)}


## "Moth", "Moth–Wren", "Swallow–Pigeon": a run of ladder indices as an
## inclusive range, short enough for one line of the pause screen's right
## column (the ladder of icons above it shows every bird in between).
static func species_range(idx: Array[int]) -> String:
	if idx.is_empty():
		return ""
	var a: String = SizeRules.SPECIES[idx[0]]["name"]
	if idx.size() == 1:
		return a
	return "%s–%s" % [a, SizeRules.SPECIES[idx[-1]]["name"]]
