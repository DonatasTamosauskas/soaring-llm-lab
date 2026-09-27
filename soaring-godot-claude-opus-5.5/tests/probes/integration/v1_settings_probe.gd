extends SceneTree
## VERIFIER PROBE (integration round 1): project settings the export and the
## vendors plugin depend on - their values, registered defaults, overrides.
##   tools/gd.sh v1probe --headless -s res://tests/probes/integration/v1_settings_probe.gd

func _initialize() -> void:
	for k in ["xr/openxr/extensions/hand_tracking", "xr/openxr/extensions/meta/color_space",
			"xr/openxr/extensions/meta/color_space/starting_color_space", "xr/openxr/foveation_eye_tracked",
			"xr/openxr/foveation_with_subsampled_images", "xr/openxr/extensions/user_presence",
			"application/config/use_custom_user_dir"]:
		var has := ProjectSettings.has_setting(k)
		print("[integration-verify] %s: has=%s value=%s with_override=%s default=%s" % [k, has,
			ProjectSettings.get_setting(k) if has else "-", ProjectSettings.get_setting_with_override(k) if has else "-",
			ProjectSettings.property_get_revert(k) if has else "-"])
	print("[integration-verify] features pc=%s android=%s" % [OS.has_feature("pc"), OS.has_feature("android")])
	quit()
