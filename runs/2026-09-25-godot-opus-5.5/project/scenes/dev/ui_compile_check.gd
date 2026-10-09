extends Node
## Dev helper for the ui area: compiles every ui script and reports errors
## without running anything (fast feedback while other areas import).


func _ready() -> void:
	var bad := 0
	for dir in ["res://scripts/ui", "res://tests/unit/ui", "res://tests/shots", "res://scenes/dev"]:
		for f in _find(dir):
			if dir.ends_with("shots") or dir.ends_with("dev"):
				if not f.get_file().begins_with("ui_"):
					continue
			var s := load(f) as Script
			if s == null or not s.can_instantiate():
				print("[ui] COMPILE FAIL ", f)
				bad += 1
	print("[ui] checked scripts, failures=%d" % bad)
	get_tree().quit(1 if bad > 0 else 0)


func _find(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for sub in d.get_directories():
		out.append_array(_find(dir.path_join(sub)))
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	return out
