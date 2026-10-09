class_name Args
extends RefCounted

## Command-line user arguments (`godot -- --key=value --flag`).
static func value(key: String, default: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + key + "="):
			return a.substr(key.length() + 3)
	return default

static func flag(key: String) -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--" + key or a.begins_with("--" + key + "="):
			return true
	return false
