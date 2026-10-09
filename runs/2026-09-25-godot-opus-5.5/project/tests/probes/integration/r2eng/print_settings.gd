extends SceneTree
## PROBE (round-2 engineering verifier): what the OpenXR settings the game
## relies on resolve to, and their defaults (property_get_revert), with the
## vendors plugin loaded. Run: tools/gd.sh v2e_probe --headless -s res://tests/probes/integration/r2eng/print_settings.gd

func _init() -> void:
	for k in ["xr/openxr/extensions/meta/color_space", "xr/openxr/extensions/meta/color_space/starting_color_space",
			"xr/openxr/extensions/hand_tracking", "xr/openxr/extensions/user_presence", "xr/openxr/foveation_level",
			"xr/openxr/foveation_dynamic", "rendering/vrs/mode", "rendering/anti_aliasing/quality/msaa_3d"]:
		var has := ProjectSettings.has_setting(k)
		print("[r2eng] %s = %s (default %s, has %s, override.android %s)" % [k, ProjectSettings.get_setting(k) if has else "<none>",
			ProjectSettings.property_get_revert(k) if has else "<none>", has, ProjectSettings.get_setting(k + ".android", "<none>")])
	quit()
