class_name HUD
extends Control
## The in-flight readout, kept deliberately small and out of the way:
##  - notices (top rows): the current first-flight lesson (only during
##    onboarding) and the tier-up / apex celebrations
##  - status (bottom rows): the growth strip (your species, progress to the
##    next, next species; at the top of the ladder the apex goal)
## Text sits on dark plates so it clears 4.5:1 contrast over any sky.
## Everything redraws only when a value it shows actually changes.
##
## In VR the texture is shown as two bands (UIPanel.bands), with nothing in
## the band a hunting bird looks through (level to 30 deg down: the ground
## ahead, prey below, perches):
##  - notices ABOVE the horizon (+8 .. +20 deg) and off to the RIGHT of the
##    HUD's centre line: a fixed home from 9.7 to 41 deg right of it, text
##    on the inner side (11 .. at most 32 deg: every word within 35 deg of
##    a level gaze along the centre line, 10 deg inside the 45 deg a Quest
##    Pro shows sharply), the illustration outside it. The view never
##    pitches with the bird, so every climb, zoom and flap cycle sweeps the
##    flight path up and down (-46 .. +82 deg for the tutorial's
##    flap-and-glide): along the centre line it never crosses the notices.
##  - the growth strip LOW (-37 .. -43 deg), read with a deliberate glance.
## The HUD's centre line is where the player's body faces (UIRoot.body_yaw,
## the panel's yaw source): a head at rest looks along it. Not the head
## (whatever it did when the HUD appeared, wherever it turns to read or
## hunt), and not the flight path: wind makes a slow bird's path crab tens
## of degrees off where it faces, and a loop over the top reverses it.
## The flight path, the current target, a real threat and the cue chevrons
## pointing at them are never hidden (make_way):
##  - if one comes within FADE_MARGIN_DEG of a notice plate, the notices fade
##    to see-through at once (0.12 s), and come back gently once everything
##    is FADE_HYST_DEG further off (a path jittering on the margin is one
##    crossing, not a flicker);
##  - only if it *stays* there longer than MOVE_AFTER_S do the notices move,
##    to the mirror placement on the other side of the centre line, slowly
##    (MOVE_S, eased) and at most once every MOVE_GAP_S: a crossing, however
##    often, is a fade, never a move. A new notice appears wherever is
##    clear.
##  - the growth strip, which is always there, fades the same way;
## A celebration (tier-up, apex catch) is a moment, not a standing notice:
## it appears where the player is looking (as near the gaze as it can be
## while staying beside the centre line and clear of what matters, see
## _toast_place), stays there, and its clock holds (up to TOAST_HOLD_MAX in
## all) while it cannot be read or is out of view, so it is never used up
## unseen.
## The cue chevrons also draw on top of every plate (HudIndicators).
## On desktop the same Controls fill the window: card on top, strip below.

## The lesson card: text column (CARD_TEXT_W, px: 21 deg; every lesson's
## title at CARD_TITLE_SIZE and hint at the body size fits it, pinned by
## ui_legibility_test) and the illustration (CARD_ART_W) beside it. The
## title is the body size, set apart by its weight (900 against 700).
const CARD_TEXT_W := 548.0
const CARD_ART_W := 190.0
const CARD_TITLE_SIZE := 60
## Plate padding (left, top, right, bottom), the same on both sides so the
## text sits as near the centre line on the mirror side as at home.
const CARD_PAD := Vector4(22, 18, 22, 18)
const CARD_GAP := 26.0
const CARD_W := CARD_PAD.x + CARD_TEXT_W + CARD_GAP + CARD_ART_W + CARD_PAD.z
const CARD_H := 300.0
## The strip is narrower than the card: it is always on.
const STRIP_W := 780.0
const STRIP_H := 160.0
const TOAST_TIME := 3.2
## Pop-in time of a celebration (from nothing; a celebration replacing a
## visible one keeps its opacity).
const TOAST_IN := 0.25
## Growth bar steps: fine enough to see every catch, coarse enough that a
## continuously growing mass doesn't re-render the panel every frame.
const GROWTH_STEPS := 100
const TOAST_TITLE_SIZE := 90
## Widest text the toast plate may hold (px: 26 deg). At home the plate's
## inner edge is 9.7 deg from the centre line, so its text ends 37 deg
## out: every word within 41 deg of a level gaze along it; it is placed
## where the player looks, so that is only when they look ahead (round 4's
## 100 px title
## and 859 px lines reached 46 deg, past a Quest Pro's sharp view).
const TOAST_TEXT_W := 680.0
## Horizontal padding inside the toast plate, px (its stylebox).
const TOAST_PAD := 44.0

## VR bands (texture rows, centre elevations and home azimuths, degrees).
const BAND_NOTICE := 0
const BAND_STATUS := 1
const NOTICE_ROWS := Vector2(0.0, 344.0)
const STATUS_ROWS := Vector2(UITheme.HUD_SIZE.y - 172.0, UITheme.HUD_SIZE.y)
const NOTICE_PITCH := 13.0
const STATUS_PITCH := -40.0
## The notices' home: their band turned this far right of the HUD's centre
## line (UIPanel band "yaw", + = left), so the card's inner edge is 9.7 deg
## right of it (its text 11 deg): prey jinking +-8 deg round the centre
## line (the round-4 verifier's case) and a flight path crabbing up to 8
## deg towards the card pass it with the fade margin to spare, and the far
## end of the text stays near the gaze (the round-6 verifier: round 5's
## text ended 39 deg out, 41 deg from a level gaze, 4 deg inside the 45 deg
## bound; its narrower text column now ends at 32).
const NOTICE_YAW := -25.9
## The one other placement (a band offset): the mirror image, left of the
## centre line.
const NOTICE_MIRROR := Vector2(-2.0 * NOTICE_YAW, 0.0)
## The strip (or the notices) covering something that matters fades to
## this opacity...
const SEE_THROUGH_ALPHA := 0.15
## ...quickly out of the way, gently back.
const SEE_THROUGH_OUT_S := 0.12
const SEE_THROUGH_IN_S := 0.4
## The growth strip fades when something comes within this angle of it.
const SEE_THROUGH_MARGIN_DEG := 2.5
## The notices fade when something comes within this angle of a plate...
const FADE_MARGIN_DEG := 1.5
## ...and stay faded until everything is this much further off (hysteresis:
## a flapping bird's path jitters a few tenths of a degree frame to frame,
## and one crossing of the margin must be one fade, never a flicker; the
## round-7 verifier counted a 0.4 s pass as two or three crossings)...
const FADE_HYST_DEG := 1.0
## One crossing ends only once everything has been clear for this long
## (seconds): a gap shorter than the fade-out itself is no gap. The path,
## a bird and its cue chevron jitter in and out of the margin frame to
## frame; the round-7 verifier's live tutorial blinked the card 5 times in
## 0.6 s (gaps of 1-2 frames between them) where there was one crossing.
## The notices then come back over NOTICE_IN_S: all told as soon after the
## thing has gone as before the hold (SEE_THROUGH_IN_S).
const FADE_CLEAR_S := SEE_THROUGH_OUT_S
const NOTICE_IN_S := SEE_THROUGH_IN_S - FADE_CLEAR_S
## ...and move only if it stays there (inside that hysteresis) longer than
## this, counting the time something is actually on the plates. A crossing, however often it comes back, is a fade: round 4 also
## moved them after 3 crossings in 8 s, and in the live game (the round-7
## verifier's seeds) that moved the lesson card up to 4 times in a 35 s
## tutorial, half of them for one jittery crossing...
const MOVE_AFTER_S := 1.0
## (Crossings are still counted over this window, for diagnostics:
## crossings_lately().)
const ENTRY_WINDOW_S := 8.0
## ...to a placement that keeps at least this much sky round everything...
const CLEAR_MARGIN_DEG := 3.0
## ...at most once in this many seconds...
const MOVE_GAP_S := 4.0
## ...easing (smoothstep) over this long, never faster than the 110 deg/s
## of a panel following the head. They stay see-through while they move.
const MOVE_S := 0.9
const MOVE_MAX_SPEED := 110.0
## (Kept for the round-4 verifiers' probe, ui_r4eng_probe_test, so it loads
## unchanged: round 3's search ran this often; now a move waits this long.)
const DODGE_SEARCH_S := MOVE_AFTER_S
## The head pointing this close to a notice plate (degrees) is reading it:
## the cue ring, which turns with the head, then sweeps over the notices,
## and they must not fade for it (the cues draw on top of them anyway).
const READ_MARGIN_DEG := 6.0
## Opacity from which a notice counts as readable; below it a
## celebration's clock holds, for at most TOAST_HOLD_MAX seconds in all.
const READABLE_ALPHA := 0.6
const TOAST_HOLD_MAX := 3.0
## A celebration whose text reaches further than this from the gaze
## (degrees; its line's two ends and middle) is not in view: a Quest Pro
## shows about +-50 deg and blurs past ~45. It is placed where it is in view
## if it can be, and its clock holds while it is not.
const TOAST_VIEW_DEG := 45.0
## How far outwards (degrees beyond its home or mirror placement: never
## nearer the centre line) a celebration may be placed to meet the gaze, and
## the step of that search.
const TOAST_REACH_DEG := 150.0
const TOAST_SEARCH_STEP_DEG := 1.0
## Home's side wins unless the other side is this much nearer the gaze
## (degrees): looking along the centre line the two sides are equally near,
## and a head wandering a few degrees round it (or the HUD settling
## within 0.5 deg of where the body faces) must not decide it; the
## celebration then shows where the lesson card lives. A gaze more than
## about 3 deg to the left of the centre line sends it left.
const TOAST_HOME_BIAS_DEG := 5.0
## While something stays on a celebration, the clear place to move it to is
## looked for again at most this often (seconds).
const TOAST_SEARCH_S := 0.25
## Desktop: space between the plates and the window's top and bottom edges
## (texture px; the desktop HUD is drawn at UIPanel.desktop_scale).
const DESKTOP_MARGIN := 32.0


var _card: PanelContainer
var _card_row: HBoxContainer
var _card_text: VBoxContainer
var _art: GestureCard
var _step: Label
var _title: Label
var _hint: Label
var _lesson_bar: FacetBar
var _strip: PanelContainer
var _icon: BirdIcon
var _tier: Label
var _next: Label
var _growth_bar: FacetBar
var _toast: Control
var _toast_row: HBoxContainer
var _toast_plate: PanelContainer
var _burst: _Burst
var _toast_title: Label
var _toast_sub: Label
var _toast_note: Label
var _toast_t := -1.0
## Opacity a celebration pops in from (0, or the one it replaces).
var _toast_from := 0.0
## Seconds this celebration's clock has been held while unreadable.
var _toast_hold := 0.0
var _growth_q := -1
var _tier_i := -1
var _apex_key := ""
var _lesson_visible := false
## GameLoop's apex goal ({catches, needed, won}; {} = none known).
var _apex := {}
## The panel showing this HUD (UIRoot sets it): bands follow the content.
var panel: UIPanel
## Per band: faded because it covers something that matters (diagnostics).
var see_through := [false, false]
## Where the notices rest (a band offset: ZERO = home, or NOTICE_MIRROR).
var dodge_target := Vector2.ZERO
## True while something covers the notices and no placement clears it.
var dodge_stuck := false
## Indices into the directions of the last make_way that were on the notice
## plates then (diagnostics: what the notices made way for).
var last_on := PackedInt32Array()
## Moves started so far, and the fastest one, deg/s of frame time (tests).
var move_count := 0
var peak_move_speed := 0.0
## Which side of the centre line the notices are on (+1 right, -1 left):
## their text sits on the side nearer it.
var notice_side := 1
var _vr := false
## Seconds something has stayed on a notice plate, and since the last move.
var _cover_t := 0.0
## Something was on a notice plate at the last make_way (a crossing is
## counted when this turns on: a make_way with no time passing, as UIRoot
## calls on a new lesson, must not count the same crossing twice).
var _covered := false
## Seconds since something was last on the notice plates (FADE_CLEAR_S).
var _clear_t := 0.0
var _since_move := MOVE_GAP_S
## Clock (s) of make_way, and when things came onto the plates lately.
var _clock := 0.0
var _entries: PackedFloat64Array = []
## The move under way: from, to, and seconds into it (< 0: none).
var _move_from := Vector2.ZERO
var _move_t := -1.0
## True while notice plates are shown (a new set appears wherever is clear).
var _notices_up := false
## The notices changed to something new while shown (a celebration over the
## lesson card, the card back after one): placed afresh, like notices
## appearing from nothing, on the next make_way.
var _replace := false
## The celebration's move target while something stays on it (see
## TOAST_SEARCH_S): where, whether it is clear, seconds to the next search.
var _toast_other := Vector2.ZERO
var _toast_other_ok := false
var _search_t := 0.0


## The HUD's VR bands for UIPanel.bands (see the class comment).
static func bands() -> Array[Dictionary]:
	return [{"rows": NOTICE_ROWS, "pitch": NOTICE_PITCH, "yaw": NOTICE_YAW}, {"rows": STATUS_ROWS, "pitch": STATUS_PITCH}]


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_build_card()
	_build_strip()
	_build_toast()
	hide_lesson()
	_apply_side()


func _plate() -> StyleBoxFlat:
	return UITheme.box(Color(UITheme.HUD_PLATE, UITheme.HUD_PLATE_ALPHA), 0, Color.TRANSPARENT, 22, CARD_PAD)


func _build_card() -> void:
	_card = PanelContainer.new()
	_card.name = "Lesson"
	_card.add_theme_stylebox_override("panel", _plate())
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.offset_left = -CARD_W * 0.5
	_card.offset_right = CARD_W * 0.5
	_card.offset_top = 0.0
	_card.offset_bottom = CARD_H
	add_child(_card)
	_card_row = UIScreen.hbox(int(CARD_GAP))
	_card.add_child(_card_row)
	_card_text = UIScreen.vbox(0)
	_card_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_text.alignment = BoxContainer.ALIGNMENT_CENTER
	_card_row.add_child(_card_text)
	_step = UIScreen.make_label("", &"DimLabel")
	_card_text.add_child(_step)
	_title = UIScreen.make_label("", &"TitleLabel")
	_title.add_theme_font_size_override("font_size", CARD_TITLE_SIZE)
	_card_text.add_child(_title)
	_hint = UIScreen.make_label("")
	_card_text.add_child(_hint)
	_lesson_bar = FacetBar.new()
	_lesson_bar.custom_minimum_size = Vector2(0, 18)
	_lesson_bar.fill_color = UITheme.PREY
	_card_text.add_child(_lesson_bar)
	# The illustration on the outer side: text is read nearer the centre line.
	_art = GestureCard.new()
	_art.custom_minimum_size = Vector2(CARD_ART_W, 0)
	_art.fps = 15.0
	_card_row.add_child(_art)


func _build_strip() -> void:
	_strip = PanelContainer.new()
	_strip.name = "Growth"
	_strip.add_theme_stylebox_override("panel", _plate())
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.anchor_left = 0.5
	_strip.anchor_right = 0.5
	_strip.anchor_top = 1.0
	_strip.anchor_bottom = 1.0
	_strip.offset_left = -STRIP_W * 0.5
	_strip.offset_right = STRIP_W * 0.5
	_strip.offset_top = -STRIP_H
	_strip.offset_bottom = 0.0
	add_child(_strip)
	var col := UIScreen.vbox(6)
	_strip.add_child(col)
	var row := UIScreen.hbox(14)
	col.add_child(row)
	_icon = BirdIcon.new()
	_icon.custom_minimum_size = Vector2(96, 72)
	_icon.setup(BirdIcon.Relation.YOU)
	row.add_child(_icon)
	_tier = UIScreen.make_label("", &"AccentLabel")
	_tier.name = "Tier"
	_tier.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_tier)
	_next = UIScreen.make_label("", &"DimLabel")
	_next.name = "Next"
	_next.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_next)
	_growth_bar = FacetBar.new()
	_growth_bar.custom_minimum_size = Vector2(0, 26)
	_growth_bar.fill_color = UITheme.ACCENT
	col.add_child(_growth_bar)


func _build_toast() -> void:
	_toast = Control.new()
	_toast.name = "TierUp"
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_left = -CARD_W * 0.5
	_toast.offset_right = CARD_W * 0.5
	_toast.offset_top = 0.0
	_toast.offset_bottom = NOTICE_ROWS.y - 4.0
	# The burst stays inside the notice band: never over the growth strip.
	_toast.clip_contents = true
	add_child(_toast)
	# Burst behind, text on a plate in front: celebratory, and the text keeps
	# its contrast over any sky.
	_burst = _Burst.new()
	_burst.set_anchors_preset(Control.PRESET_FULL_RECT)
	_burst.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.add_child(_burst)
	# In VR the plate hugs the band's inner edge (nearer the centre line), on
	# desktop it is centred (_apply_side).
	_toast_row = UIScreen.hbox(0)
	_toast_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	_toast.add_child(_toast_row)
	_toast_plate = PanelContainer.new()
	_toast_plate.name = "Plate"
	_toast_plate.add_theme_stylebox_override("panel", UITheme.box(Color(UITheme.HUD_PLATE, UITheme.HUD_PLATE_ALPHA), 5, Color(UITheme.ACCENT, 0.9), 26, Vector4(TOAST_PAD, 8, TOAST_PAD, 12)))
	_toast_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_plate.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_toast_row.add_child(_toast_plate)
	var col := UIScreen.vbox(0)
	_toast_plate.add_child(col)
	_toast_title = UIScreen.make_label("", &"TitleLabel", TOAST_TITLE_SIZE)
	_toast_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_title.add_theme_color_override("font_color", UITheme.ACCENT)
	col.add_child(_toast_title)
	_toast_sub = UIScreen.make_label("")
	_toast_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_toast_sub)
	_toast_note = UIScreen.make_label("", &"DimLabel")
	_toast_note.name = "Note"
	_toast_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_toast_note)
	_toast.visible = false


## VR (notices beside the centre line, text on the inner side) or desktop
## (centred). UIRoot calls this with the panel's mode.
func set_vr(on: bool) -> void:
	_vr = on
	_apply_side()


## Lay the notices out for the side of the centre line they are on: text
## nearer the centre line, the illustration outside it; a celebration's
## plate against the inner edge. Desktop: text first, plate centred.
func _apply_side() -> void:
	if _card_row == null:
		return
	var inner_first := notice_side > 0 or not _vr
	_card_row.move_child(_card_text, 0 if inner_first else 1)
	# The words hug the inner edge on either side (left-aligned on the left
	# side they started at the column's outer end: 37 deg from a level gaze
	# instead of 34.7).
	for l: Label in lesson_labels():
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if inner_first else HORIZONTAL_ALIGNMENT_RIGHT
	if not _vr:
		_toast_row.alignment = BoxContainer.ALIGNMENT_CENTER
	else:
		_toast_row.alignment = BoxContainer.ALIGNMENT_BEGIN if notice_side > 0 else BoxContainer.ALIGNMENT_END
	# Desktop: the plates keep off the window's edges (in VR the texture's
	# rows are the bands, and the bands have sky all round).
	var top := 0.0 if _vr else DESKTOP_MARGIN
	_card.offset_top = top
	_card.offset_bottom = top + CARD_H
	_toast.offset_top = top
	_toast.offset_bottom = top + NOTICE_ROWS.y - 4.0
	_strip.offset_top = -STRIP_H - (0.0 if _vr else DESKTOP_MARGIN)
	_strip.offset_bottom = -(0.0 if _vr else DESKTOP_MARGIN)
	_relayout()


## Lay the notices out now, not at the end of the frame (a container sorts
## deferred, and not at all while hidden): whatever measures where the words
## are in this frame (a test, a probe, the next placement) must see them
## where they will be drawn, not on the side they just left. Called when
## the side changes and when a hidden plate is shown again.
func _relayout() -> void:
	_card_row.notification(Container.NOTIFICATION_SORT_CHILDREN)
	_toast_row.notification(Container.NOTIFICATION_SORT_CHILDREN)


# --- growth ---------------------------------------------------------------------

## Update the growth strip. Cheap to call every frame: it only touches the
## Controls (and so only re-renders the panel) when the shown value changes.
## At the top of the ladder the strip shows the apex goal instead (set_apex).
func set_growth(mass: float) -> void:
	var tier := SizeRules.tier_for_mass(mass)
	var top := tier >= SizeRules.SPECIES.size() - 1
	var q := int(round(HudMath.growth_progress(mass) * GROWTH_STEPS))
	var key := str(_apex) if top else ""
	if tier == _tier_i and q == _growth_q and key == _apex_key:
		return
	_tier_i = tier
	_growth_q = q
	_apex_key = key
	_tier.text = SizeRules.SPECIES[tier]["name"]
	_icon.setup(BirdIcon.Relation.YOU, 1.0, SizeRules.SPECIES[tier]["id"])
	if not top:
		_next.text = SizeRules.SPECIES[tier + 1]["name"]
		_growth_bar.value = q / float(GROWTH_STEPS)
	elif _apex.is_empty():
		_next.text = "Apex"
		_growth_bar.value = 1.0
	elif _apex["won"]:
		_next.text = "You won!"
		_growth_bar.value = 1.0
	else:
		# The goal at the top: worthwhile catches as the eagle.
		_next.text = "%d of %d to win" % [_apex["catches"], _apex["needed"]]
		_growth_bar.value = float(_apex["catches"]) / float(_apex["needed"])


## GameLoop's apex goal ({catches, needed, won}, see PauseScreen.apex_goal);
## {} when there is none.
func set_apex(goal: Dictionary) -> void:
	_apex = goal.duplicate()


func apex_goal() -> Dictionary:
	return _apex


func growth_value() -> float:
	return _growth_bar.value


func tier_text() -> String:
	return _tier.text


func next_text() -> String:
	return _next.text


# --- lessons ------------------------------------------------------------------

func show_lesson(index: int, total: int, lesson: Dictionary) -> void:
	_lesson_visible = true
	_step.text = "Lesson %d of %d" % [index + 1, total]
	_title.text = lesson.get("title", "")
	# In VR the gesture; on the desktop the keys that make it.
	_hint.text = lesson.get("hint", "") if _vr else lesson.get("keys", lesson.get("hint", ""))
	_hint.remove_theme_color_override("font_color")
	_art.set_art(lesson.get("art", &"glide"))
	_lesson_bar.value = 0.0
	_lesson_bar.fill_color = UITheme.PREY
	_card.visible = _toast_t < 0.0
	_relayout()
	sync_bands()


## New words for the lesson on show (the catch lesson's help), keeping its
## progress; nothing re-renders unless a word changed.
func update_lesson(lesson: Dictionary) -> void:
	var title: String = lesson.get("title", "")
	var hint: String = lesson.get("hint", "") if _vr else lesson.get("keys", lesson.get("hint", ""))
	if title == _title.text and hint == _hint.text:
		return
	_title.text = title
	_hint.text = hint
	_art.set_art(lesson.get("art", &"glide"))
	_relayout()


func set_lesson_progress(p: float) -> void:
	# 25 steps: smooth enough to feel live, few enough re-renders.
	_lesson_bar.value = snappedf(p, 0.04)


func lesson_done(timed_out: bool) -> void:
	_lesson_bar.value = 1.0
	_hint.text = "Let's move on" if timed_out else "Nice!"
	_hint.add_theme_color_override("font_color", UITheme.TEXT_DIM if timed_out else UITheme.PREY)


func hide_lesson() -> void:
	_lesson_visible = false
	if _card:
		_card.visible = false
	sync_bands()


func lesson_visible() -> bool:
	return _card.visible


func lesson_title() -> String:
	return _title.text


## The lesson card's and the celebration's text Labels (tests measure where
## the glyphs are in the player's view).
func lesson_labels() -> Array[Label]:
	return [_step, _title, _hint]


func toast_labels() -> Array[Label]:
	return [_toast_title, _toast_sub, _toast_note]


# --- tier up and apex -------------------------------------------------------------

## What the celebration says when the player goes from old_tier to new_tier
## at `mass` (their actual mass; species mass if unknown), given GameLoop's
## apex goal ({} if none). Pure, so tests pin every tier:
##   up:    "Now a Crow!" / "Hunt: Swallow–Pigeon" / "Ignore: Wren"
##          (the prey range is what is *worth chasing*, SizeRules
##          .is_worthwhile; the note names what dropped off the menu since
##          the old tier)
##   apex:  "Eagle!" / "Catch 5 big birds to win" / "Hunt: Crow–Hawk"
##   down:  "Back to a Crow" / "Eat to grow again"
static func tier_up_text(old_tier: int, new_tier: int, mass: float = -1.0, goal: Dictionary = {}) -> Dictionary:
	var n := SizeRules.SPECIES.size()
	new_tier = clampi(new_tier, 0, n - 1)
	var name_s: String = SizeRules.SPECIES[new_tier]["name"]
	if mass <= 0.0 or SizeRules.tier_for_mass(mass) != new_tier:
		mass = SizeRules.SPECIES[new_tier]["mass"]
	if new_tier <= old_tier:
		return {"title": "Back to %s" % UIScreen.a_an(name_s), "sub": "Eat to grow again", "note": ""}
	var chain := PauseScreen.food_chain(mass)
	if new_tier == n - 1:
		var sub := "Nothing hunts you now"
		if not goal.is_empty():
			sub = "Catch %d big birds to win" % int(goal["needed"])
		return {"title": "%s!" % name_s, "sub": sub, "note": chain["eat_line"]}
	# Species that were worth chasing at the old size and no longer are.
	var dropped: Array[int] = []
	if old_tier >= 0:
		var before := PauseScreen.food_chain(float(SizeRules.SPECIES[clampi(old_tier, 0, n - 1)]["mass"]))
		for i: int in before["prey"]:
			if i in chain["dust"]:
				dropped.append(i)
	var note := ""
	if not dropped.is_empty():
		# The pause screen's word for it, and short enough for the plate.
		note = "Ignore: %s" % PauseScreen.species_range(dropped)
	return {"title": "Now %s!" % UIScreen.a_an(name_s), "sub": chain["eat_line"], "note": note}


func show_tier_up(old_tier: int, new_tier: int, mass: float = -1.0) -> void:
	var t := tier_up_text(old_tier, new_tier, mass, _apex)
	_burst.color = UITheme.ACCENT if new_tier > old_tier else UITheme.TEXT_DIM
	_show_toast(t)


## A worthwhile catch as the eagle (GameLoop.apex_progress).
func show_apex_progress(catches: int, needed: int) -> void:
	var left := needed - catches
	if left <= 0:
		# The winning catch: the run summary takes over.
		return
	_burst.color = UITheme.PREY
	_show_toast({"title": "%d of %d!" % [catches, needed],
		"sub": "One more to win!" if left == 1 else "%d more to win" % left, "note": ""})


func _show_toast(t: Dictionary) -> void:
	# A celebration replacing one the player is reading swaps its text in
	# place: it does not blink out and pop in again (two apex catches in a
	# row), and it stays where it is being read. One that is out of view or
	# faded (its clock held) is no place to put news: like any other
	# celebration, the new one is placed afresh where the player is looking
	# (_toast_place).
	var swapping := _toast_t >= 0.0 and _toast.visible and notice_alpha() >= READABLE_ALPHA and toast_view_angle() <= TOAST_VIEW_DEG
	_toast_from = _toast_alpha() if swapping else 0.0
	if not swapping:
		_replace = true
	_toast_title.text = t["title"]
	_toast_sub.text = t["sub"]
	_toast_note.text = t["note"]
	_toast_note.visible = t["note"] != ""
	_toast_title.add_theme_font_size_override("font_size",
		UIScreen.fit_size(_toast_title.get_theme_font("font"), _toast_title.text, TOAST_TITLE_SIZE, UITheme.FS_BODY + 10, TOAST_TEXT_W))
	_toast_t = 0.0
	_toast_hold = 0.0
	_toast.visible = true
	_card.visible = false
	_relayout()
	set_process(true)
	_update_toast()
	sync_bands()


## End a celebration at once (the HUD is going away: its moment is over,
## and it must not replay into the next flight).
func cancel_toast() -> void:
	if _toast_t < 0.0:
		return
	_end_toast()


## The celebration is over: the lesson card (if any) comes back, placed
## afresh (home if clear), not wherever the celebration was.
func _end_toast() -> void:
	_toast_t = -1.0
	_toast.visible = false
	_card.visible = _lesson_visible
	_relayout()
	if _lesson_visible:
		_replace = true
		# Not shown until make_way has placed it (next frame): it would
		# otherwise show for a frame wherever the celebration was, which may
		# be further out than the card ever rests (the celebration has faded
		# out by now, so the blank frame is not seen).
		if panel != null and panel.vr_mode:
			panel.set_band_alpha(BAND_NOTICE, 0.0)
	sync_bands()


## A celebration is running: up, with the HUD shown (in play).
func toast_active() -> bool:
	return _toast_t >= 0.0 and (panel == null or panel.shown)


## A celebration is waiting for the HUD to come back (a pause): it goes on
## after Resume.
func toast_waiting() -> bool:
	return _toast_t >= 0.0 and panel != null and not panel.shown


func toast_text() -> String:
	return _toast_title.text


func toast_lines() -> PackedStringArray:
	var out := PackedStringArray([_toast_title.text, _toast_sub.text])
	if _toast_note.visible:
		out.append(_toast_note.text)
	return out


func _process(delta: float) -> void:
	advance(delta)


## Run the celebration's clock by `delta` seconds (the frame loop calls it;
## tests drive it with synthetic time).
func advance(delta: float) -> void:
	if _toast_t < 0.0:
		return
	# The HUD hidden (a pause: UIRoot cancels a celebration for anything
	# else): the moment waits for the player to come back to it.
	if panel != null and not panel.shown:
		return
	# Never used up unseen: while the notices cannot be read (faded because
	# something that matters is behind them) or the celebration is out of
	# view (the player looked away after it appeared), the clock holds.
	if _toast_t >= TOAST_IN and _toast_hold < TOAST_HOLD_MAX and (notice_alpha() < READABLE_ALPHA or toast_view_angle() > TOAST_VIEW_DEG):
		_toast_hold += delta
		return
	_toast_t += delta
	if _toast_t >= TOAST_TIME:
		_end_toast()
		return
	_update_toast()


## The celebration's own opacity now: pops in over TOAST_IN (from what it
## replaced, if anything), holds, fades out over the last 0.6 s.
func _toast_alpha() -> float:
	var k := clampf(_toast_t / TOAST_IN, 0.0, 1.0)
	return lerpf(_toast_from, 1.0, k) * clampf((TOAST_TIME - _toast_t) / 0.6, 0.0, 1.0)


func _update_toast() -> void:
	_toast.modulate.a = _toast_alpha()
	var k := clampf(_toast_t / TOAST_IN, 0.0, 1.0)
	# A small scale pulse also marks a replacement that kept its opacity.
	_toast.scale = Vector2.ONE * (0.85 + 0.15 * k if _toast_from < 0.5 else 0.96 + 0.04 * k)
	_toast.pivot_offset = _toast_plate.position + _toast_plate.size * 0.5
	_burst.phase = _toast_t / TOAST_TIME
	_burst.focus = _toast_plate.position + _toast_plate.size * 0.5
	_burst.reach = _toast_plate.size.x * 0.5
	_burst.queue_redraw()


# --- VR bands ---------------------------------------------------------------------

## Plates drawn in a band right now (what could hide something).
func band_plates(bi: int) -> Array[Control]:
	var out: Array[Control] = []
	if bi == BAND_NOTICE:
		if _card and _card.visible:
			out.append(_card)
		if _toast and _toast.visible:
			out.append(_toast_plate)
	elif _strip and _strip.visible:
		out.append(_strip)
	return out


## The notice plates' rects in the texture, as laid out for the side of the
## centre line the notices are on now. The celebration's comes from its size
## (_toast_plate_rect), so it is right in the very frame the celebration is
## placed or changes sides, before its container has laid it out again.
func notice_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if _card and _card.visible:
		out.append(_card.get_global_rect())
	if _toast and _toast.visible:
		out.append(_toast_plate_rect(notice_side) if _vr else _toast_plate.get_global_rect())
	return out


## Hide a band's mesh while it has nothing to show (no fill cost).
func sync_bands() -> void:
	if panel == null or not is_node_ready():
		return
	for bi in 2:
		panel.set_band_visible(bi, not band_plates(bi).is_empty())


## How opaque the notices are to the player right now (1 on desktop).
func notice_alpha() -> float:
	if panel == null or not panel.vr_mode:
		return 1.0
	return panel.band_alpha(BAND_NOTICE)


## Seconds the current celebration's clock has been held (diagnostics).
func toast_held() -> float:
	return _toast_hold


## Make way for `dirs` (world directions from the eye: the flight path, the
## current target, a real threat, the cue chevrons), once per frame in VR:
##  - notices: fade while one of them is within FADE_MARGIN_DEG of a plate;
##    if one stays that long (MOVE_AFTER_S), move once to the other side of
##    the centre line, if that is clear (at most every MOVE_GAP_S). A new
##    lesson card appears at home, or on the other side if only that is
##    clear; a new celebration where the player looks (_toast_place);
##  - the growth strip: fades while it covers one of them.
## Moves and fades are mesh transforms and a shader value: no re-render.
func make_way(dirs: Array[Vector3], delta: float) -> void:
	if panel == null:
		return
	var covered := _strip_covers(dirs)
	see_through[BAND_STATUS] = covered
	_fade_band(BAND_STATUS, covered, delta)
	_make_way_notices(dirs, delta)


func _strip_covers(dirs: Array[Vector3]) -> bool:
	var margin := deg_to_rad(SEE_THROUGH_MARGIN_DEG) * UITheme.HUD_DISTANCE * UITheme.PX_PER_M
	for d in dirs:
		var px := panel.direction_pixel(BAND_STATUS, d)
		if not px.is_finite():
			continue
		for plate in band_plates(BAND_STATUS):
			if plate.get_global_rect().grow(margin).has_point(px):
				return true
	return false


func _fade_band(bi: int, covered: bool, delta: float, in_s := SEE_THROUGH_IN_S) -> void:
	var want := SEE_THROUGH_ALPHA if covered else 1.0
	var rate := (1.0 - SEE_THROUGH_ALPHA) / (SEE_THROUGH_OUT_S if covered else in_s)
	panel.set_band_alpha(bi, move_toward(panel.band_alpha(bi), want, rate * delta))


func _make_way_notices(dirs: Array[Vector3], delta: float) -> void:
	var plates := band_plates(BAND_NOTICE)
	_since_move += delta
	_clock += delta
	if plates.is_empty():
		# Nothing shown: the next notice is placed afresh when it appears.
		_notices_up = false
		_cover_t = 0.0
		_covered = false
		_entries.clear()
		_move_t = -1.0
		dodge_stuck = false
		see_through[BAND_NOTICE] = false
		panel.set_band_alpha(BAND_NOTICE, 1.0)
		return
	var rects := notice_rects()
	var level: Array[Vector3] = []
	for d in dirs:
		level.append(panel.level_direction(d))
	var appearing := not _notices_up or _replace
	_notices_up = true
	_replace = false
	if appearing:
		# Not seen yet, so placing it costs no motion. A celebration: where
		# the player is looking (_toast_place). The lesson card: home if that
		# is clear, else the other side if that is, else home (faded).
		var place := Vector2.ZERO
		if _toast.visible:
			place = _toast_place(level, gaze_level())
		else:
			var area: Array[Rect2] = [_card.get_global_rect()]
			if not _clear(level, Vector2.ZERO, area, CLEAR_MARGIN_DEG) and _clear(level, NOTICE_MIRROR, area, CLEAR_MARGIN_DEG):
				place = NOTICE_MIRROR
		_rest_at(place)
		# (A celebration placed on the other side is laid out for it.)
		rects = notice_rects()
		_move_t = -1.0
		_cover_t = 0.0
		_covered = false
		_entries.clear()
		panel.set_band_offset(BAND_NOTICE, place)
	elif _move_t >= 0.0:
		_move_t += delta
		var k := clampf(_move_t / MOVE_S, 0.0, 1.0)
		var prev := panel.band_offset(BAND_NOTICE)
		var cur := _move_from.lerp(dodge_target, k * k * (3.0 - 2.0 * k))
		# The eased curve peaks at 1.5x the mean speed; the cap is a guard.
		var step := cur - prev
		var cap := MOVE_MAX_SPEED * delta
		if step.length() > cap:
			cur = prev + step.normalized() * cap
		if delta > 0.0:
			peak_move_speed = maxf(peak_move_speed, cur.distance_to(prev) / delta)
		if k >= 1.0 and cur.distance_to(dodge_target) < 0.01:
			cur = dodge_target
			_move_t = -1.0
		panel.set_band_offset(BAND_NOTICE, cur)
		# The text changes sides (to stay nearest the centre line) as the
		# band crosses it, mid-move, where it is see-through: flipped at the
		# start, the words jumped to the outer end while the card was still
		# opaque (44.7 deg from the gaze for a few frames).
		set_notice_side(_side_of(cur))
		rects = notice_rects()
	var here := panel.band_offset(BAND_NOTICE)
	# Something on a plate now: in within FADE_MARGIN_DEG, out only once
	# clear by the hysteresis. One crossing lasts until it has been clear for
	# FADE_CLEAR_S (a path swinging in and out with the strokes is one).
	var margin := FADE_MARGIN_DEG + (FADE_HYST_DEG if _covered else 0.0)
	var on := not _clear(level, here, rects, margin)
	_clear_t = 0.0 if on else _clear_t + delta
	# (Diagnostics: which of `dirs` are on the plates. Only while something
	# is: a few more checks then, none otherwise.)
	last_on.clear()
	if on:
		for i in level.size():
			if not _clear([level[i]], here, rects, margin):
				last_on.append(i)
	var covered := on or (_covered and _clear_t < FADE_CLEAR_S)
	if covered and not _covered and not appearing:
		_entries.append(_clock)
	_covered = covered
	while not _entries.is_empty() and _entries[0] < _clock - ENTRY_WINDOW_S:
		_entries.remove_at(0)
	# How long something has actually been on the plates in this crossing
	# (the clear gaps within it do not count towards "staying").
	if not covered:
		_cover_t = 0.0
		_search_t = 0.0
	elif on:
		_cover_t += delta
	dodge_stuck = false
	if on and _move_t < 0.0 and _cover_t > MOVE_AFTER_S:
		# It stays: go to the other side of the centre line (a celebration:
		# the clear place nearest the gaze), if that is clear and the last
		# move was long enough ago (calm, never a dance).
		var other := Vector2.ZERO
		var ok := false
		if _toast.visible:
			# The clear place nearest the gaze; searched again at most every
			# TOAST_SEARCH_S while it stays (it cannot move before
			# MOVE_GAP_S anyway, and the sky changes slowly).
			_search_t -= delta
			if _search_t <= 0.0:
				_search_t = TOAST_SEARCH_S
				_toast_other = _toast_place(level, gaze_level())
				var r: Array[Rect2] = [_toast_plate_rect(_side_of(_toast_other))]
				_toast_other_ok = _toast_other.distance_to(here) > 0.5 and _clear(level, _toast_other, r, CLEAR_MARGIN_DEG)
			other = _toast_other
			ok = _toast_other_ok
		else:
			other = NOTICE_MIRROR if _side_of(dodge_target) > 0 else Vector2.ZERO
			ok = _clear(level, other, rects, CLEAR_MARGIN_DEG)
		if not ok:
			dodge_stuck = true
		elif _since_move >= MOVE_GAP_S:
			_move_from = here
			_move_t = 0.0
			_since_move = 0.0
			move_count += 1
			# Where it will rest; it keeps its layout until it crosses the
			# centre line (above).
			dodge_target = other
	var fade := covered or _move_t >= 0.0
	see_through[BAND_NOTICE] = fade
	if appearing:
		panel.set_band_alpha(BAND_NOTICE, SEE_THROUGH_ALPHA if fade else 1.0)
	else:
		_fade_band(BAND_NOTICE, fade, delta, NOTICE_IN_S)


## The places the lesson card rests, as [offset] rows (home, then the other
## side of the centre line; a celebration may rest further out). Round 3
## searched a longer list; kept for the round-4 verifiers' probe.
func placement_candidates() -> Array:
	return [[Vector2.ZERO], [NOTICE_MIRROR]]


## Separate crossings of the notice plates (something coming within
## FADE_MARGIN_DEG after being clear by the hysteresis) in the last
## ENTRY_WINDOW_S of make_way (diagnostics, tests).
func crossings_lately() -> int:
	return _entries.size()


## True if the head's forward direction `dir` (world) points at the notices
## or within READ_MARGIN_DEG of them (VR, notices shown): the player is
## reading them.
func looks_at_notices(dir: Vector3) -> bool:
	if panel == null or not panel.vr_mode or not panel.is_band_visible(BAND_NOTICE):
		return false
	var rects := notice_rects()
	if rects.is_empty():
		return false
	var level: Array[Vector3] = [panel.level_direction(dir)]
	return not _clear(level, panel.band_offset(BAND_NOTICE), rects, READ_MARGIN_DEG)


## The notices now rest at `off` (ZERO = home, right of the centre line;
## NOTICE_MIRROR = left of it; a celebration may be further out on either
## side): lay them out for that side.
func _rest_at(off: Vector2) -> void:
	dodge_target = off
	set_notice_side(_side_of(off))


## Which side of the centre line (+1 right, -1 left) the notice band is on
## at offset `off`.
static func _side_of(off: Vector2) -> int:
	return 1 if NOTICE_YAW + off.x < 0.0 else -1


## The gaze (the camera's forward) in the HUD panel's level frame, or ZERO
## without a camera (desktop, tests without one).
func gaze_level() -> Vector3:
	if panel == null or not panel.vr_mode or panel.camera == null or not panel.camera.is_inside_tree():
		return Vector3.ZERO
	return panel.level_direction(-panel.camera.global_basis.z)


## Where the celebration's plate would sit in the texture with the notices
## on `side` of the centre line: against the band's inner edge, vertically
## centred (_apply_side's layout), from its minimum size, so it is right
## before the new text has been laid out.
func _toast_plate_rect(side: int) -> Rect2:
	var area := Rect2(_toast.position, _toast.size)
	var ms := _toast_plate.get_combined_minimum_size()
	var w := minf(ms.x, area.size.x)
	var h := minf(ms.y, area.size.y)
	var x := area.position.x if side > 0 else area.end.x - w
	return Rect2(x, area.position.y + (area.size.y - h) * 0.5, w, h)


## Where a new celebration goes (a band offset): as near the gaze as it can
## be, beside the centre line (on either side, at its home distance from it
## or further out, never nearer), clear of everything in `level` by
## CLEAR_MARGIN_DEG. In order of preference: clear and in view (its text
## within TOAST_VIEW_DEG of the gaze), in view but not clear (it waits,
## faded), clear but out of view, anything; then nearest the gaze (its
## middle); ties go to home's side and nearer the path. Without a gaze:
## home, else the mirror, else further out.
## A band offset turns the band about the vertical, so a point's azimuth is
## its home azimuth plus the offset, exactly, and its elevation does not
## change: every candidate's distance from the gaze is a few multiplications.
## They are sorted by it (one packed key, sorted natively) and clearance,
## the costly part, is checked in that order until one is clear.
func _toast_place(level: Array[Vector3], gaze: Vector3) -> Vector2:
	var n := int(TOAST_REACH_DEG / TOAST_SEARCH_STEP_DEG)
	var has_gaze := gaze != Vector3.ZERO
	var az_g := atan2(gaze.x, -gaze.z) if has_gaze else 0.0
	var el_g := asin(clampf(gaze.y, -1.0, 1.0)) if has_gaze else 0.0
	var sides: Array = []
	var keys := PackedFloat64Array()
	for si in 2:
		var side := 1 if si == 0 else -1
		var base := Vector2.ZERO if side > 0 else NOTICE_MIRROR
		var one: Array[Rect2] = [_toast_plate_rect(side)]
		# The text line's inner end, middle and outer end: [az, el] at base.
		var pts := _toast_text_points(side, base)
		sides.append([base, one, pts, side])
		var mid: Vector2 = pts[1]
		for i in n + 1:
			var cost := float(i)
			if has_gaze:
				cost = _sph_angle(az_g, el_g, mid.x + side * deg_to_rad(i * TOAST_SEARCH_STEP_DEG), mid.y) + si * TOAST_HOME_BIAS_DEG
			# Cost in thousandths of a degree, then the tie order: home's side
			# first, nearer the centre line first (2 i + side bit < 1024).
			keys.append(floorf(cost * 1000.0) * 1024.0 + float(2 * i + si))
	keys.sort()
	var nearest := Vector2.INF
	var first_in_view := Vector2.INF
	for pass_i in 2:
		for key: float in keys:
			var order := int(key - floorf(key / 1024.0) * 1024.0)
			# The true distance of its middle from the gaze (the key's cost
			# carries the home bias).
			var cost := floorf(key / 1024.0) / 1000.0 - (order & 1) * (TOAST_HOME_BIAS_DEG if has_gaze else 0.0)
			var sd: Array = sides[order & 1]
			var i := order >> 1
			var off := (sd[0] as Vector2) + Vector2(-int(sd[3]) * i * TOAST_SEARCH_STEP_DEG, 0.0)
			if nearest == Vector2.INF:
				nearest = off
			if pass_i == 0:
				if has_gaze:
					if cost > TOAST_VIEW_DEG + TOAST_HOME_BIAS_DEG:
						# The middle already out of view: so is all that follows.
						break
					if cost > TOAST_VIEW_DEG:
						continue
					var worst := 0.0
					for p: Vector2 in sd[2]:
						worst = maxf(worst, _sph_angle(az_g, el_g, p.x + int(sd[3]) * deg_to_rad(i * TOAST_SEARCH_STEP_DEG), p.y))
					if worst > TOAST_VIEW_DEG:
						continue
				if first_in_view == Vector2.INF:
					first_in_view = off
			if _clear(level, off, sd[1], CLEAR_MARGIN_DEG):
				return off
		if pass_i == 0 and first_in_view != Vector2.INF:
			# In view, but nowhere there is clear: the nearest of those (it
			# waits, faded, its clock held).
			return first_in_view
	# Nothing can be in view and nothing is clear: the nearest.
	return nearest


## The celebration's text line on `side` at band offset `base`: its inner
## end, middle and outer end as [azimuth, elevation] (radians, + = right,
## up) in the HUD panel's level frame.
func _toast_text_points(side: int, base: Vector2) -> Array[Vector2]:
	var rect := _toast_plate_rect(side)
	var y := rect.get_center().y
	var out: Array[Vector2] = []
	for x: float in [rect.position.x + TOAST_PAD, rect.get_center().x, rect.end.x - TOAST_PAD]:
		var d := panel.band_placement(BAND_NOTICE, base) * panel.band_frame_direction(BAND_NOTICE, Vector2(x, y))
		out.append(Vector2(atan2(d.x, -d.z), asin(clampf(d.y, -1.0, 1.0))))
	return out


## Angle (degrees) between two directions given as azimuth and elevation
## (radians).
static func _sph_angle(az1: float, el1: float, az2: float, el2: float) -> float:
	return rad_to_deg(acos(clampf(sin(el1) * sin(el2) + cos(el1) * cos(el2) * cos(az1 - az2), -1.0, 1.0)))


## Degrees from the gaze to the furthest of the celebration's text line
## (its two ends and middle) as it is placed now: 0 on desktop, without a
## camera, or with no celebration.
func toast_view_angle() -> float:
	if _toast_t < 0.0:
		return 0.0
	var g := gaze_level()
	if g == Vector3.ZERO:
		return 0.0
	var az_g := atan2(g.x, -g.z)
	var el_g := asin(clampf(g.y, -1.0, 1.0))
	var worst := 0.0
	for p: Vector2 in _toast_text_points(notice_side, panel.band_offset(BAND_NOTICE)):
		worst = maxf(worst, _sph_angle(az_g, el_g, p.x, p.y))
	return worst


## Lay the notices out for the right (+1) or left (-1) side of the centre
## line (see _apply_side).
func set_notice_side(side: int) -> void:
	if side != notice_side:
		notice_side = side
		_apply_side()


## True if no direction (given in the panel's level frame) comes within
## margin_deg of a plate with the notice band at offset `off`.
func _clear(level: Array[Vector3], off: Vector2, rects: Array[Rect2], margin_deg: float) -> bool:
	var inv := panel.band_placement(BAND_NOTICE, off).inverse()
	var m := deg_to_rad(margin_deg) * UITheme.HUD_DISTANCE * UITheme.PX_PER_M
	for d in level:
		var px := panel.band_frame_pixel(BAND_NOTICE, inv * d)
		if not px.is_finite():
			continue
		for r in rects:
			if r.grow(m).has_point(px):
				return false
	return true


class _Burst:
	extends Control
	## Low-poly celebration: triangles flying out from the plate and fading.
	var phase := 0.0
	var color := UITheme.ACCENT
	## Centre of the plate the triangles fly out from, and its half width.
	var focus := Vector2.ZERO
	var reach := 400.0

	func _draw() -> void:
		if phase <= 0.0 or phase >= 1.0:
			return
		var c := focus if focus != Vector2.ZERO else size * 0.5
		var rng := RandomNumberGenerator.new()
		rng.seed = 42
		var n := 22
		var e := 1.0 - pow(1.0 - clampf(phase * 1.6, 0.0, 1.0), 3.0)
		var fade := clampf((1.0 - phase) * 1.8, 0.0, 1.0)
		for i in n:
			var a := TAU * i / n + rng.randf_range(-0.12, 0.12)
			var r := lerpf(40.0, reach + rng.randf_range(20.0, 110.0), e)
			# The plate may hug one edge of the band (VR): each side's
			# triangles spread only as far as there is room, so the burst
			# is never cut off on one side.
			var room := (c.x - 16.0) if cos(a) < 0.0 else (size.x - c.x - 16.0)
			var p := c + Vector2(cos(a) * minf(r, maxf(room, 40.0)), sin(a) * 0.55 * r)
			var s := rng.randf_range(10.0, 22.0) * (1.0 - phase * 0.5)
			var rot := a + phase * rng.randf_range(-6.0, 6.0)
			var tri := PackedVector2Array([
				p + Vector2(cos(rot), sin(rot)) * s,
				p + Vector2(cos(rot + 2.3), sin(rot + 2.3)) * s,
				p + Vector2(cos(rot - 2.3), sin(rot - 2.3)) * s])
			var col := color if i % 3 else UITheme.FEATHER
			GestureArt.poly(self, tri, Color(col, fade))
