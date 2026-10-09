extends TestCase
## The palette's rules: every colour the world code names exists, nothing
## but a few genuinely white things is authored near-white (sunlit facets
## would clip and lose their shape), and surfaces that meet differ in value.

## Genuinely white surfaces, plus light and unshaded-effect colours (the sun,
## pollen/dust motes) which are not lit facets.
const BRIGHT_OK := [&"snow", &"cloud", &"foam", &"trim", &"flower_white", &"mast_white", &"insulator", &"bark_birch", &"wall_white",
	&"sun", &"pollen", &"dust"]


static func _lum(c: Color) -> float:
	# Relative luminance of the sRGB colour (perceptual enough for rules).
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func test_every_named_colour_exists() -> void:
	var re := RegEx.new()
	re.compile("Palette\\.c\\(&\"([a-z_]+)\"\\)|\\[&\"([a-z_]+)\"")
	var missing: PackedStringArray = []
	var used := {}
	var dir := DirAccess.open("res://scripts/world")
	for f in dir.get_files():
		if not f.ends_with(".gd"):
			continue
		var src := FileAccess.get_file_as_string("res://scripts/world/" + f)
		for m in re.search_all(src):
			var key := m.get_string(1) if not m.get_string(1).is_empty() else m.get_string(2)
			used[key] = true
	for key in used:
		# Array literals of StringNames are also used for species ids etc.
		if Palette.C.has(StringName(key)):
			continue
		if src_is_colour_context(key):
			missing.append(key)
	eq(missing.size(), 0, "unknown palette names: %s" % ", ".join(missing))
	gt(float(used.size()), 40.0, "the world draws from the palette")
	metric("names_used", used.size())


## Palette.c() is the only colour accessor; bare &"x" in arrays can be other
## ids (strata, crops) that must also be palette keys when used as colours.
func src_is_colour_context(key: String) -> bool:
	return not key in ["day", "dusk", "forest", "village", "farm", "fields", "lake", "river", "copse", "rocks", "orchard", "powerline", "mast", "canyon", "cliff", "ruin", "foothills", "roofs", "meadow", "glade", "hay", "rock", "wheat", "ploughed"]


func test_nothing_clips_to_white() -> void:
	var too_bright: PackedStringArray = []
	for k in Palette.C:
		var c: Color = Palette.C[k]
		if _lum(c) > 0.9 and not k in BRIGHT_OK:
			too_bright.append(String(k))
	eq(too_bright.size(), 0, "near-white colours outside the allow-list: %s" % ", ".join(too_bright))
	for k in Palette.C:
		check(Palette.C[k].a > 0.99, "%s is opaque" % k)


func test_meeting_surfaces_differ_in_value() -> void:
	var pairs := [[&"bark", &"leaf"], [&"bark", &"leaf_light"], [&"roof_red", &"wall_white"], [&"roof_slate", &"wall_cream"],
		[&"wire", &"sky_horizon"], [&"conifer", &"grass"], [&"hedge", &"wheat"], [&"water", &"sand"], [&"rock_dark", &"snow"],
		[&"window_dark", &"wall_ochre"], [&"pole", &"sky_horizon"], [&"barn_red", &"roof_moss"], [&"door", &"wall_white"],
		[&"burrow", &"sandstone"], [&"burrow", &"wood_light"]]
	for p in pairs:
		var d := absf(_lum(Palette.C[p[0]]) - _lum(Palette.C[p[1]]))
		gt(d, 0.07, "%s vs %s differ in value" % [p[0], p[1]])


func test_lighting_presets_complete() -> void:
	var keys: Array = Palette.LIGHT[&"day"].keys()
	for preset in Palette.LIGHT:
		for k in keys:
			check(Palette.LIGHT[preset].has(k), "%s has %s" % [preset, k])
	# Dusk is lower, warmer and dimmer in the sky than day.
	lt(Palette.LIGHT[&"dusk"]["sun_elev"], Palette.LIGHT[&"day"]["sun_elev"], "dusk sun is lower")
	gt(Palette.LIGHT[&"dusk"]["sun"].r - Palette.LIGHT[&"dusk"]["sun"].b, Palette.LIGHT[&"day"]["sun"].r - Palette.LIGHT[&"day"]["sun"].b, "dusk sun is warmer")


func test_materials_are_shared() -> void:
	check(Palette.solid_material() == Palette.solid_material(), "one solid material")
	check(Palette.foliage_material() == Palette.foliage_material(), "one foliage material")
	check(Palette.solid_material().vertex_color_use_as_albedo, "vertex colours drive albedo")
	check(Palette.solid_material().vertex_color_is_srgb, "vertex colours are sRGB")
