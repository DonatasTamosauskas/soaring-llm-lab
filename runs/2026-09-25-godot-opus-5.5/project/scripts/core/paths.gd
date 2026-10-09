class_name Paths
extends RefCounted
## Where tools and tests write their output.
##
## tools/gd.sh runs Godot inside a sandbox copy of the project, so res:// is
## not the real tree. It exports SOARING_ARTIFACTS pointing at the real
## <project>/artifacts; outside the wrapper this falls back to res://artifacts.


static func artifacts(sub: String = "") -> String:
	var base := OS.get_environment("SOARING_ARTIFACTS")
	if base.is_empty():
		base = ProjectSettings.globalize_path("res://artifacts")
	var dir := base.path_join(sub) if not sub.is_empty() else base
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## Parses "--key=value" user args (everything after "--" on the command line).
static func user_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out


static func arg(key: String, default: String = "") -> String:
	return user_args().get(key, default)
