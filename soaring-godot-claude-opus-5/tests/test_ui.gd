class_name UITests
extends RefCounted

## The menus, the settings and the first-flight coach.
##
## Two things are being pinned here that are otherwise only checkable by putting
## a headset on. The first is that there is always a way out: every screen has a
## row that leads back to flying, and every row leads somewhere. The second is
## that the menu can actually be [i]used[/i] — that a row is a big enough target
## for a hand that wobbles, that its text subtends enough of the view to read,
## and that a ray from the player's head lands on the row they are pointing at,
## measured in degrees rather than assumed.


static func run(t: TestCase) -> void:
	_test_every_screen_has_a_way_out(t)
	_test_every_row_does_something(t)
	_test_navigation_returns_where_it_came_from(t)
	_test_settings_are_clamped_and_quantised(t)
	_test_settings_survive_a_restart(t)
	_test_settings_drive_the_thing_they_name(t)
	_test_a_pointer_can_hit_every_row(t)
	_test_the_menu_is_legible_and_reachable(t)
	_test_a_panel_is_always_in_front_and_level(t)
	_test_hostile_pointing_is_survivable(t)
	_test_the_coach_teaches_the_four_gestures(t)
	_test_the_coach_cannot_be_fooled(t)
	_test_the_coach_gives_up(t)
	_test_the_summary_reports_the_run(t)
	_test_the_settings_screen_explains_itself(t)
	_test_the_ui_invents_no_colours(t)


const SCREENS: Array = [
	MenuModel.Screen.MAIN, MenuModel.Screen.PAUSE, MenuModel.Screen.SETTINGS,
	MenuModel.Screen.CONTROLS, MenuModel.Screen.SUMMARY,
]


static func _model(screen: MenuModel.Screen) -> MenuModel:
	var model := MenuModel.new()
	model.reset_to(screen)
	return model


static func _screen_name(screen: MenuModel.Screen) -> String:
	return ["main", "pause", "settings", "controls", "summary"][int(screen)]


# --- the flow ----------------------------------------------------------------

## No dead ends. This is the whole reason the flow lives in a plain object: a
## screen you can reach and cannot leave is a headset coming off, and it is not
## a thing anybody notices while building the screen that has the bug.
static func _test_every_screen_has_a_way_out(t: TestCase) -> void:
	t.begin("every screen has a way out")
	for screen: MenuModel.Screen in SCREENS:
		var model: MenuModel = _model(screen)
		var name: String = _screen_name(screen)
		t.ok(not model.title().is_empty(), "%s has a title" % name)
		t.greater(float(model.rows().size()), 0.0, "%s has rows" % name)
		t.ok(model.escape_of() >= 0, "%s offers a way back to flying" % name)
		# ...and the way out is near the top or the bottom, where a hand goes
		# looking for it, rather than buried in the middle of a list.
		var escape: int = model.escape_of()
		t.ok(
			escape == 0 or escape >= model.rows().size() - 2,
			"%s puts its way out at an end of the list (row %d of %d)" % [
				name, escape, model.rows().size()
			]
		)


static func _test_every_row_does_something(t: TestCase) -> void:
	t.begin("every row does something")
	var known: Array[StringName] = [
		MenuModel.ACT_START, MenuModel.ACT_RESUME, MenuModel.ACT_RESTART,
		MenuModel.ACT_SETTINGS, MenuModel.ACT_CONTROLS, MenuModel.ACT_BACK,
		MenuModel.ACT_QUIT, MenuModel.ACT_RECENTRE, MenuModel.ACT_DEFAULTS,
		MenuModel.ACT_TEACH,
	]
	for screen: MenuModel.Screen in SCREENS:
		var model: MenuModel = _model(screen)
		var name: String = _screen_name(screen)
		var seen: Array[StringName] = []
		for entry: Dictionary in model.rows():
			var id: StringName = entry["id"]
			var label: String = String(entry["label"])
			t.ok(not label.is_empty(), "%s: every row is labelled" % name)
			t.ok(not seen.has(id), "%s: %s appears once" % [name, id])
			seen.append(id)
			if int(entry["kind"]) == MenuModel.Kind.SETTING:
				t.ok(
					not PlayerSettings.spec(String(entry["key"])).is_empty(),
					"%s: %s is a declared setting" % [name, id]
				)
			else:
				t.ok(known.has(id), "%s: %s is an action the game handles" % [name, id])
			# The panel is 1.02 m wide and the row font is 5.6 cm tall; a label
			# much past thirty characters runs off the end of it.
			t.less(float(label.length()), 32.0, "%s: '%s' fits the panel" % [name, label])

	# Pressing a row that is not there must be a no-op rather than a crash: a
	# ray that leaves the panel between one frame and the press is normal.
	var model: MenuModel = _model(MenuModel.Screen.MAIN)
	t.ok(model.activate(-1) == MenuModel.ACT_NONE, "pressing nothing does nothing")
	t.ok(model.activate(99) == MenuModel.ACT_NONE, "pressing off the end does nothing")
	t.ok(not model.adjust(-1, 1), "nudging nothing does nothing")
	t.ok(model.screen == MenuModel.Screen.MAIN, "and neither moved the player")


static func _test_navigation_returns_where_it_came_from(t: TestCase) -> void:
	t.begin("navigation returns where it came from")
	for screen: MenuModel.Screen in [
		MenuModel.Screen.MAIN, MenuModel.Screen.PAUSE, MenuModel.Screen.SUMMARY
	]:
		for detour: StringName in [MenuModel.ACT_SETTINGS, MenuModel.ACT_CONTROLS]:
			var model: MenuModel = _model(screen)
			var row: int = _row_of(model, detour)
			if row < 0:
				continue
			t.ok(
				model.activate(row) == MenuModel.ACT_NONE,
				"%s: %s opens in place" % [_screen_name(screen), detour]
			)
			t.ok(model.screen != screen, "%s: %s went somewhere" % [_screen_name(screen), detour])
			var back: int = _row_of(model, MenuModel.ACT_BACK)
			t.ok(back >= 0, "%s: %s has a BACK" % [_screen_name(screen), detour])
			model.activate(back)
			t.ok(
				model.screen == screen,
				"%s: BACK out of %s returns here, not to the main menu" % [
					_screen_name(screen), detour
				]
			)
			t.ok(model.depth() == 0, "%s: and the trail is spent" % _screen_name(screen))

	# The settings screen is the one place you can be two deep. Backing out of it
	# twice must not fall off the end of the stack.
	var deep: MenuModel = _model(MenuModel.Screen.PAUSE)
	deep.open(MenuModel.Screen.SETTINGS)
	deep.back()
	deep.back()
	t.ok(deep.screen == MenuModel.Screen.MAIN, "an over-deep back lands on the main menu")

	# Only the summary lets the world keep moving underneath it.
	for screen: MenuModel.Screen in SCREENS:
		var model: MenuModel = _model(screen)
		var pausing: bool = screen != MenuModel.Screen.SUMMARY
		t.ok(
			model.is_pausing() == pausing,
			"%s %s the world" % [_screen_name(screen), "stops" if pausing else "does not stop"]
		)


static func _row_of(model: MenuModel, id: StringName) -> int:
	var rows: Array[Dictionary] = model.rows()
	for i in rows.size():
		if rows[i]["id"] == id:
			return i
	return -1


# --- settings ----------------------------------------------------------------

static func _test_settings_are_clamped_and_quantised(t: TestCase) -> void:
	t.begin("settings are clamped and quantised")
	for entry: Dictionary in PlayerSettings.SPECS:
		var settings := PlayerSettings.new()
		var key: String = String(entry["key"])
		t.ok(settings.has(key), "%s exists" % key)
		t.ok(not settings.value_text(key).is_empty(), "%s reads as something" % key)

		if int(entry["kind"]) != PlayerSettings.Kind.NUMBER:
			# A two-state setting drawn as a half-full bar would be a lie.
			t.ok(settings.value_fraction(key) < 0.0, "%s draws no bar" % key)
			var first: float = settings.get_value(key)
			var count: int = 2
			if entry.has("choices"):
				count = (entry["choices"] as Array).size()
			for i in count:
				settings.adjust(key, 1)
			t.near(settings.get_value(key), first, 0.001, "%s cycles back round" % key)
			continue

		var low: float = float(entry["min"])
		var high: float = float(entry["max"])
		settings.set_value(key, -1000.0)
		t.near(settings.get_value(key), low, 0.001, "%s clamps to its floor" % key)
		t.near(settings.value_fraction(key), 0.0, 0.001, "%s reads empty there" % key)
		settings.set_value(key, 1000.0)
		t.near(settings.get_value(key), high, 0.001, "%s clamps to its ceiling" % key)
		t.near(settings.value_fraction(key), 1.0, 0.001, "%s reads full there" % key)
		# In a headset the only input is "press the row", so a number that stopped
		# at its ceiling would be a comfort setting a player could turn up and
		# never turn back down.
		settings.adjust(key, 1)
		t.near(settings.get_value(key), low, 0.001, "%s wraps round from the top" % key)
		settings.adjust(key, -1)
		t.near(settings.get_value(key), high, 0.001, "%s wraps round from the bottom" % key)

		# A NaN out of a hand-edited config file must not become a NaN in Tuning.
		var before: float = settings.get_value(key)
		settings.set_value(key, NAN)
		t.near(settings.get_value(key), before, 0.001, "%s ignores a NaN" % key)
		t.finite(settings.get_value(key), "%s stays finite" % key)

		# Usable in a headset: few enough presses to cross the range that nobody
		# gives up, enough that the setting has some resolution.
		var steps: float = (high - low) / float(entry["step"])
		t.in_range(steps, 4.0, 24.0, "%s crosses its range in a sane number of presses" % key)

		# Every value is reachable by pressing one button over and over, and the
		# walk comes back to where it started rather than drifting.
		settings.set_value(key, low)
		var seen: Array[float] = []
		var walked: int = 0
		while walked < 100:
			settings.adjust(key, 1)
			walked += 1
			var now: float = settings.get_value(key)
			if is_equal_approx(now, low):
				break
			t.ok(not seen.has(now), "%s: %.2f comes up once per lap" % [key, now])
			seen.append(now)
		t.less(float(walked), 26.0, "%s laps in %d presses" % [key, walked])
		t.near(settings.get_value(key), low, 0.001, "%s ends the lap where it began" % key)
		t.ok(seen.has(high), "%s reaches its ceiling on the way round" % key)


static func _test_settings_survive_a_restart(t: TestCase) -> void:
	t.begin("settings survive a restart")
	var path: String = "user://test-settings.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var fresh := PlayerSettings.new()
	t.ok(not fresh.load_from(path), "a first launch finds no file and keeps the defaults")
	t.near(fresh.get_value("comfort_vignette"), 0.7, 0.001, "the default vignette is intact")

	fresh.set_value("comfort_vignette", 0.2)
	fresh.set_value("visual_roll", 0.0)
	fresh.set_value("pointer_hand", 0.0)
	fresh.set_value("learned", 1.0)
	t.ok(fresh.save(path), "settings save")

	var restored := PlayerSettings.new()
	t.ok(restored.load_from(path), "settings load")
	t.near(restored.get_value("comfort_vignette"), 0.2, 0.001, "the vignette came back")
	t.near(restored.get_value("visual_roll"), 0.0, 0.001, "a zero came back as a zero")
	t.ok(not restored.pointer_is_right_handed(), "handedness came back")
	t.ok(restored.flag("learned"), "and the game remembers it has taught this player")

	# A file edited by hand is the one input path with no other defence.
	var hostile := ConfigFile.new()
	hostile.set_value(PlayerSettings.SECTION, "comfort_vignette", 99.0)
	hostile.set_value(PlayerSettings.SECTION, "tilt_sensitivity", -5.0)
	hostile.set_value(PlayerSettings.SECTION, "nonsense", 3.0)
	hostile.save(path)
	var guarded := PlayerSettings.new()
	guarded.load_from(path)
	t.in_range(guarded.get_value("comfort_vignette"), 0.0, 1.0, "an absurd value is clamped")
	t.in_range(guarded.get_value("tilt_sensitivity"), 0.5, 1.6, "a negative value is clamped")
	t.ok(not guarded.has("nonsense"), "an invented key is ignored")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Every comfort setting claims to drive a [Tuning] field. This checks the claim
## against the source: a renamed knob would otherwise leave a settings row that
## moves a number nothing reads, which looks exactly like a setting that works.
static func _test_settings_drive_the_thing_they_name(t: TestCase) -> void:
	t.begin("settings drive the thing they name")
	var source: String = FileAccess.get_file_as_string("res://scripts/game/Tuning.gd")
	t.ok(not source.is_empty(), "Tuning is readable")
	var settings := PlayerSettings.new()
	var values: Dictionary = settings.tuning_values()
	t.greater(float(values.size()), 2.0, "the panel drives more than a token setting")
	for key: String in values:
		var declared: float = _declared_default(source, key)
		t.ok(is_finite(declared), "Tuning declares %s" % key)
		t.near(
			float(values[key]), declared, 0.001,
			"the panel's default for %s matches the game's" % key
		)
	# ...and the settings the UI keeps to itself stay out of Tuning.
	t.ok(not values.has("pointer_hand"), "handedness is the menu's business, not the model's")


static func _declared_default(source: String, name: String) -> float:
	for line: String in source.split("\n"):
		var code: String = line.strip_edges()
		if not code.begins_with("var %s" % name):
			continue
		var parts: PackedStringArray = code.split("=")
		if parts.size() < 2:
			return NAN
		return parts[1].strip_edges().to_float()
	return NAN


# --- pointing ----------------------------------------------------------------

## A ray from the player's head at every row of every screen, through the real
## placement maths. This is the test that would have caught a panel built facing
## away from the player, or one whose rows drifted out from under their labels.
static func _test_a_pointer_can_hit_every_row(t: TestCase) -> void:
	t.begin("a pointer can hit every row")
	var head := Transform3D(Basis.IDENTITY, Vector3(3.0, 60.0, -12.0))
	var panel: Transform3D = MenuLayout.place(head)
	for screen: MenuModel.Screen in SCREENS:
		var model: MenuModel = _model(screen)
		var rows: int = model.rows().size()
		var body: int = model.body().size()
		var name: String = _screen_name(screen)
		for row in rows:
			var point: Vector3 = panel * Vector3(
				0.0, MenuLayout.row_centre(row, rows, true, body), 0.0
			)
			var hit: Dictionary = MenuLayout.ray_panel(
				head.origin, point - head.origin, panel
			)
			t.ok(bool(hit["hit"]), "%s row %d is on the panel" % [name, row])
			t.ok(
				MenuLayout.row_at(hit["local"] as Vector2, rows, true, body) == row,
				"%s row %d is what the ray lands on" % [name, row]
			)
			# A hand-held ray wobbles. One degree either way must still be this
			# row and not the one above it.
			for wobble: float in [-1.0, 1.0]:
				var tilted: Vector3 = (point - head.origin).rotated(
					Vector3.RIGHT, deg_to_rad(wobble)
				)
				var shaky: Dictionary = MenuLayout.ray_panel(head.origin, tilted, panel)
				t.ok(
					bool(shaky["hit"]) and MenuLayout.row_at(
						shaky["local"] as Vector2, rows, true, body
					) == row,
					"%s row %d survives a %.0f degree wobble" % [name, row, wobble]
				)

		# The title is not a button.
		var title_point: Vector3 = panel * Vector3(
			0.0, MenuLayout.title_centre(rows, true, body), 0.0
		)
		var title_hit: Dictionary = MenuLayout.ray_panel(
			head.origin, title_point - head.origin, panel
		)
		t.ok(
			MenuLayout.row_at(title_hit["local"] as Vector2, rows, true, body) == -1,
			"%s: the title is not a row" % name
		)

	# Off the panel entirely.
	for direction: Vector3 in [Vector3.UP, Vector3.BACK, Vector3.RIGHT]:
		var miss: Dictionary = MenuLayout.ray_panel(head.origin, direction, panel)
		t.ok(
			not bool(miss["hit"]) or MenuLayout.row_at(miss["local"] as Vector2, 4, true) == -1,
			"pointing at %s hits nothing" % str(direction)
		)


static func _test_the_menu_is_legible_and_reachable(t: TestCase) -> void:
	t.begin("the menu is legible and reachable")
	var distance: float = MenuLayout.DISTANCE
	t.in_range(distance, 1.2, 2.5, "the panel sits at a comfortable focal distance")

	for pair: Array in [
		["title", UITheme.TEXT_TITLE], ["row", UITheme.TEXT_ROW],
		["body", UITheme.TEXT_BODY], ["small", UITheme.TEXT_SMALL],
	]:
		var degrees: float = UITheme.degrees_at(float(pair[1]), distance)
		t.greater(
			degrees, UITheme.MIN_TEXT_DEGREES,
			"%s text is readable in a headset (%.2f deg)" % [pair[0], degrees]
		)
	t.greater(
		UITheme.degrees_at(UITheme.TEXT_TITLE, distance),
		UITheme.degrees_at(UITheme.TEXT_ROW, distance),
		"a title outranks a row"
	)

	var target: float = UITheme.degrees_at(MenuLayout.ROW_HEIGHT, distance)
	t.greater(
		target, UITheme.MIN_TARGET_DEGREES,
		"a row is big enough to point a controller at (%.2f deg)" % target
	)

	# The panel must not fill the view. Anything past about 45 degrees of a
	# 100-degree headset stops being a panel and starts being a wall.
	var width: float = UITheme.degrees_at(MenuLayout.PANEL_WIDTH, distance)
	t.in_range(width, 20.0, 45.0, "the panel is a panel, not a wall (%.1f deg)" % width)
	var tallest: float = 0.0
	for screen: MenuModel.Screen in SCREENS:
		var model: MenuModel = _model(screen)
		var size: Vector2 = MenuLayout.panel_size(
			model.rows().size(), true, model.body().size()
		)
		tallest = maxf(tallest, size.y)
		t.greater(size.y, 0.2, "%s is big enough to hold its rows" % _screen_name(screen))
	t.less(
		UITheme.degrees_at(tallest, distance), 45.0,
		"even the busiest screen stays inside a comfortable field of view"
	)

	# The in-flight readout is head-locked, so it lives or dies on being legible
	# without being looked at. The coach line is the one a player who has never
	# flown has to read while falling, and it is the largest thing on the display
	# for exactly that reason.
	# Measured as cap height, not as the em box the font is laid out in. The two
	# differ by nearly a third, and the old floor of 1.4 degrees of em box was
	# passing a 0.9-degree capital — roughly a dozen pixels on a headset.
	var readout: float = UITheme.cap_degrees_at(
		float(HUD.READOUT_FONT) * HUD.LABEL_PIXEL_SIZE, HUD.PANEL_DISTANCE
	)
	var banner: float = UITheme.cap_degrees_at(
		float(HUD.BANNER_FONT) * HUD.LABEL_PIXEL_SIZE, HUD.PANEL_DISTANCE
	)
	var coach: float = UITheme.cap_degrees_at(
		float(HUD.COACH_FONT) * HUD.LABEL_PIXEL_SIZE, HUD.PANEL_DISTANCE
	)
	t.greater(
		readout, UITheme.MIN_CAP_DEGREES,
		"the flight readout is legible at speed (%.2f deg of capital)" % readout
	)
	t.greater(
		banner, UITheme.MIN_CAP_DEGREES,
		"a banner you get two seconds to read is legible (%.2f deg)" % banner
	)
	t.greater(coach, UITheme.MIN_CAP_DEGREES, "the coach's line is legible (%.2f deg)" % coach)
	t.greater(coach, readout, "and it is the biggest thing on the display")
	t.less(readout, 3.0, "without the readout becoming the game")

	# The menus are held to the same floor, in the same unit.
	for height: float in [UITheme.TEXT_TITLE, UITheme.TEXT_ROW, UITheme.TEXT_BODY,
			UITheme.TEXT_SMALL]:
		t.greater(
			UITheme.cap_degrees_at(height, MenuLayout.DISTANCE), UITheme.MIN_CAP_DEGREES,
			"menu text %.3f m is legible at %.2f m" % [height, MenuLayout.DISTANCE]
		)
	t.in_range(HUD.PANEL_DISTANCE, 1.2, 2.5, "the readout is at a comfortable distance")
	t.greater(
		HUD.PANEL_DROP, 0.3,
		"and low enough to leave the sky clear (%.2f m)" % HUD.PANEL_DROP
	)

	# Rows stack downward and never overlap.
	for rows in range(1, 9):
		var previous: float = INF
		for row in rows:
			var y: float = MenuLayout.row_centre(row, rows, true, 2)
			t.less(y, previous, "row %d of %d sits under the one before" % [row, rows])
			t.ok(
				previous - y >= MenuLayout.ROW_HEIGHT or is_inf(previous),
				"rows %d of %d do not overlap" % [row, rows]
			)
			previous = y
		var size: Vector2 = MenuLayout.panel_size(rows, true, 2)
		t.ok(
			MenuLayout.row_centre(rows - 1, rows, true, 2) - MenuLayout.ROW_HEIGHT * 0.5
				>= -size.y * 0.5 - 0.001,
			"the last of %d rows is still on the panel" % rows
		)


static func _test_a_panel_is_always_in_front_and_level(t: TestCase) -> void:
	t.begin("a panel is always in front and level")
	var poses: Array[Transform3D] = [
		Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Transform3D(Basis.from_euler(Vector3(0.0, 2.1, 0.0)), Vector3(40.0, 120.0, -8.0)),
		# Banked 70 degrees in a turn, which is where a player actually is.
		Transform3D(Basis.from_euler(Vector3(0.2, -1.0, 1.22)), Vector3(-9.0, 30.0, 4.0)),
		# Looking straight down at the ground, and straight up at the sky.
		Transform3D(Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)), Vector3(0.0, 200.0, 0.0)),
		Transform3D(Basis.from_euler(Vector3(PI * 0.5, 0.3, 0.0)), Vector3(0.0, 200.0, 0.0)),
	]
	for head: Transform3D in poses:
		var panel: Transform3D = MenuLayout.place(head)
		t.ok(panel.is_finite(), "the placement is finite")
		var offset: Vector3 = panel.origin - head.origin
		t.near(
			Vector2(offset.x, offset.z).length(), MenuLayout.DISTANCE, 0.01,
			"it is an arm and a half away"
		)
		t.near(
			offset.y, -MenuLayout.EYE_DROP, 0.01,
			"it sits just under eye level, not underfoot and not overhead"
		)
		t.in_range(
			MenuLayout.EYE_DROP, 0.0, 0.2,
			"and 'just under' is a few degrees, not a stoop"
		)
		# The readable face of a quad is +Z, so +Z has to point back at the head.
		t.greater(
			panel.basis.z.dot(-offset.normalized()), 0.99,
			"the panel faces the player"
		)
		t.near(panel.basis.y.dot(Vector3.UP), 1.0, 0.01, "and its text is the right way up")
		t.near(panel.basis.x.y, 0.0, 0.01, "with no roll in it")

	var broken: Transform3D = MenuLayout.place(
		Transform3D(Basis.IDENTITY, Vector3(NAN, INF, 0.0))
	)
	t.ok(broken.is_finite(), "a NaN head pose still produces a usable panel")


static func _test_hostile_pointing_is_survivable(t: TestCase) -> void:
	t.begin("hostile pointing is survivable")
	var panel: Transform3D = MenuLayout.place(Transform3D(Basis.IDENTITY, Vector3.ZERO))
	var origins: Array[Vector3] = [
		Vector3(NAN, 0.0, 0.0), Vector3(INF, INF, INF), Vector3(1e12, 1e12, 1e12),
		Vector3.ZERO,
	]
	var directions: Array[Vector3] = [
		Vector3(NAN, NAN, NAN), Vector3.ZERO, Vector3(0.0, 1.0, 0.0),
		Vector3(1e-9, 0.0, 0.0), Vector3.FORWARD, Vector3.BACK,
	]
	for origin: Vector3 in origins:
		for direction: Vector3 in directions:
			var hit: Dictionary = MenuLayout.ray_panel(origin, direction, panel)
			t.ok(hit.has("hit"), "a hostile ray still answers")
			var local: Vector2 = hit["local"]
			t.ok(local.is_finite(), "with a finite point")
			t.ok(is_finite(float(hit["distance"])), "and a finite distance")
			var row: int = MenuLayout.row_at(local, 4, true)
			t.ok(row >= -1 and row < 4, "and a row inside the list or none at all")
	t.ok(
		MenuLayout.row_at(Vector2(NAN, NAN), 4, true) == -1,
		"a NaN point selects nothing"
	)
	t.ok(MenuLayout.row_at(Vector2.ZERO, 0, true) == -1, "an empty screen selects nothing")
	t.near(
		MenuLayout.off_axis(Transform3D(Basis.IDENTITY, Vector3.ZERO), Vector3(NAN, 0.0, 0.0)),
		0.0, 0.001, "a broken panel position is nought degrees off, not NaN"
	)


# --- the coach ---------------------------------------------------------------

static func _command(span: float, bank: float, stroke: float) -> FlightCommand:
	var command := FlightCommand.new()
	command.span = span
	command.bank = bank
	command.stroke_speed = stroke
	command.alpha = 0.1
	return command


## Feeds the coach [param seconds] of one pose at 90 Hz. [param beat_hz] beats
## the wings on a duty cycle rather than holding the stroke on, which is what a
## real arm does and what [WingInput] actually reports.
static func _fly(
	coach: Coach, seconds: float, span: float, bank: float, beat_hz: float
) -> void:
	var dt: float = 1.0 / 90.0
	var phase: float = 0.0
	for i in int(seconds / dt):
		var stroke: float = 0.0
		if beat_hz > 0.0:
			phase = fmod(phase + dt * beat_hz, 1.0)
			stroke = 3.0 if phase < 0.25 else 0.0
		coach.observe(_command(span, bank, stroke), false, dt)


static func _test_the_coach_teaches_the_four_gestures(t: TestCase) -> void:
	t.begin("the coach teaches the four gestures")
	var coach := Coach.new()
	t.ok(coach.step == Coach.Step.SPREAD, "it starts by asking for a wingspan")
	t.ok(not coach.cue().is_empty(), "and says so")

	_fly(coach, 2.0, 1.0, 0.0, 0.0)
	t.ok(coach.step == Coach.Step.FLAP, "spreading the arms moves it on")
	t.ok(coach.cue().contains("BEAT"), "and it asks for a wingbeat: '%s'" % coach.cue())

	_fly(coach, 2.0, 1.0, 0.0, 1.5)
	t.ok(coach.step == Coach.Step.BANK, "two wingbeats move it on")

	_fly(coach, 2.0, 1.0, 0.9, 0.0)
	t.ok(coach.step == Coach.Step.TUCK, "dropping a hand moves it on")

	_fly(coach, 2.0, 0.1, 0.0, 0.0)
	t.ok(coach.complete, "and tucking finishes it")
	t.ok(coach.cue().is_empty(), "after which it says nothing at all, ever")

	_fly(coach, 30.0, 1.0, 0.0, 0.0)
	t.ok(coach.cue().is_empty(), "a finished coach stays finished")

	# A player who does everything the moment it is asked still gets to read it.
	var quick := Coach.new()
	var elapsed: float = 0.0
	var dt: float = 1.0 / 90.0
	while not quick.complete and elapsed < 60.0:
		var step: Coach.Step = quick.step
		var span: float = 0.1 if step == Coach.Step.TUCK else 1.0
		var bank: float = 0.9 if step == Coach.Step.BANK else 0.0
		var stroke: float = 3.0 if step == Coach.Step.FLAP and fmod(elapsed, 0.6) < 0.2 else 0.0
		quick.observe(_command(span, bank, stroke), false, dt)
		elapsed += dt
	t.ok(quick.complete, "a quick player finishes the lesson")
	t.greater(elapsed, Coach.MIN_DWELL * 3.0, "without any of it flashing past")
	t.less(elapsed, 30.0, "in %.1f seconds" % elapsed)

	var skipped := Coach.new()
	skipped.skip()
	_fly(skipped, 5.0, 1.0, 0.0, 0.0)
	t.ok(skipped.complete and skipped.cue().is_empty(), "a returning player is never taught")
	skipped.restart()
	t.ok(not skipped.complete, "and can ask to be taught again")


static func _test_the_coach_cannot_be_fooled(t: TestCase) -> void:
	t.begin("the coach cannot be fooled")
	var coach := Coach.new()
	_fly(coach, 2.0, 1.0, 0.0, 0.0)
	t.ok(coach.step == Coach.Step.FLAP, "at the wingbeat lesson")

	# Holding the arms down is one beat, not two hundred: the same
	# one-beat-per-arm-raise rule the input enforces.
	var dt: float = 1.0 / 90.0
	for i in 400:
		coach.observe(_command(1.0, 0.0, 3.0), false, dt)
	t.ok(coach.step == Coach.Step.FLAP, "holding the arms down is not a wingbeat cycle")

	# Nor is being perched: a lesson cannot be practised standing on a branch.
	var perched := Coach.new()
	for i in 400:
		perched.observe(_command(1.0, 0.0, 0.0), true, dt)
	t.ok(perched.step == Coach.Step.SPREAD, "a perched bird is not being taught")

	# A wobble on the way somewhere else does not tick a lesson off.
	var wobbler := Coach.new()
	_fly(wobbler, 2.0, 1.0, 0.0, 0.0)
	_fly(wobbler, 2.0, 1.0, 0.0, 1.5)
	t.ok(wobbler.step == Coach.Step.BANK, "at the banking lesson")
	for i in 900:
		var bank: float = 0.9 if fmod(float(i) * dt, 0.4) < 0.06 else 0.0
		wobbler.observe(_command(1.0, bank, 0.0), false, dt)
	t.ok(wobbler.step == Coach.Step.BANK, "a twitchy hand is not a turn")

	var hostile := Coach.new()
	for i in 200:
		hostile.observe(_command(NAN, INF, NAN), false, NAN)
		hostile.observe(_command(NAN, INF, NAN), false, -1.0)
		hostile.observe(null, false, dt)
	t.ok(hostile.step == Coach.Step.SPREAD, "garbage teaches nothing")
	t.ok(not hostile.complete, "and finishes nothing")


static func _test_the_coach_gives_up(t: TestCase) -> void:
	t.begin("the coach gives up")
	var stubborn := Coach.new()
	# A player who spreads their wings and then does nothing else at all.
	_fly(stubborn, Coach.STEP_PATIENCE + 2.0, 1.0, 0.0, 0.0)
	t.ok(stubborn.step != Coach.Step.FLAP, "one unlearned lesson does not block the rest")
	_fly(stubborn, Coach.LIFETIME, 1.0, 0.0, 0.0)
	t.ok(stubborn.complete, "and the whole thing expires rather than nagging forever")
	t.ok(stubborn.cue().is_empty(), "leaving the view clear")


# --- content -----------------------------------------------------------------

static func _test_the_summary_reports_the_run(t: TestCase) -> void:
	t.begin("the summary reports the run")
	var model: MenuModel = _model(MenuModel.Screen.SUMMARY)
	model.summary = {
		"title": "BROUGHT DOWN", "elapsed": 754.0, "catches": 19, "deaths": 5,
		"score": 4821, "best_streak": 6, "won": false,
	}
	model.restart_armed = false
	var lines: String = "\n".join(model.body())
	t.ok(model.title() == "BROUGHT DOWN", "it says how the run ended")
	t.ok(lines.contains("12:34"), "it says how long you were up: %s" % lines)
	t.ok(lines.contains("19"), "how many you caught")
	t.ok(lines.contains("4821"), "and what it scored")
	t.ok(not lines.contains("beat your wings"), "and does not offer a restart it will refuse")
	model.restart_armed = true
	t.ok(
		"\n".join(model.body()).contains("beat your wings"),
		"once the game will take it, it offers the wingbeat too"
	)
	t.ok(_row_of(model, MenuModel.ACT_RESTART) >= 0, "with a button for people who prefer one")

	# A summary that never arrived must not print NaNs at somebody.
	var empty: MenuModel = _model(MenuModel.Screen.SUMMARY)
	for line: String in empty.body():
		t.ok(not line.contains("nan") and not line.contains("inf"), "empty summary: '%s'" % line)


static func _test_the_settings_screen_explains_itself(t: TestCase) -> void:
	t.begin("the settings screen explains itself")
	var model: MenuModel = _model(MenuModel.Screen.SETTINGS)
	t.greater(float(model.body().size()), 0.0, "it says something before you touch it")
	for i in model.rows().size():
		model.hover(i)
		var entry: Dictionary = model.rows()[i]
		if int(entry["kind"]) != MenuModel.Kind.SETTING:
			continue
		var hint: String = "\n".join(model.body())
		t.ok(not hint.is_empty(), "hovering %s explains it" % entry["id"])
		t.less(float(hint.length()), 44.0, "briefly: '%s'" % hint)
	model.hover(999)
	t.ok(model.hovered == -1, "hovering nothing selects nothing")

	# Pressing a setting changes it and stays on the screen. A comfort slider
	# that closed the menu every time you nudged it would be unusable.
	var before: float = model.settings.get_value("comfort_vignette")
	var action: StringName = model.activate(0)
	t.ok(action == MenuModel.ACT_NONE, "a setting press is not an action")
	t.ok(model.screen == MenuModel.Screen.SETTINGS, "and does not leave the screen")
	t.ok(
		not is_equal_approx(model.settings.get_value("comfort_vignette"), before),
		"but it does move the setting"
	)

	var defaults: int = _row_of(model, MenuModel.ACT_DEFAULTS)
	t.ok(defaults >= 0, "there is a way back to the defaults")
	model.activate(defaults)
	t.near(
		model.settings.get_value("comfort_vignette"), 0.7, 0.001,
		"which puts everything back"
	)


## The same rule [PaletteTests] holds the world to, for the same reason: one
## file decides what this game looks like. [UITheme] is the UI's palette, and it
## is separate from the world's because a menu has to stay legible against a
## snowfield, a gorge and a night sky alike.
static func _test_the_ui_invents_no_colours(t: TestCase) -> void:
	t.begin("the UI invents no colours")
	var directory := DirAccess.open("res://scripts/ui")
	t.ok(directory != null, "the UI directory is readable")
	if directory == null:
		return
	var checked: int = 0
	for file: String in directory.get_files():
		if not file.ends_with(".gd") or file == "UITheme.gd":
			continue
		checked += 1
		var source: String = FileAccess.get_file_as_string("res://scripts/ui/%s" % file)
		var offences: PackedStringArray = []
		var number: int = 0
		for line: String in source.split("\n"):
			number += 1
			var code: String = line.strip_edges()
			if code.begins_with("#"):
				continue
			if code.contains("Color(") or code.contains("Color.from_hsv"):
				offences.append("%d: %s" % [number, code])
		t.ok(
			offences.is_empty(),
			"%s invents a colour; put it in UITheme instead [%s]" % [
				file, ", ".join(offences)
			]
		)
	t.greater(float(checked), 3.0, "and the scan actually found files to check")
