class_name RunRecords
extends RefCounted
## Best-ever results, persisted across sessions in user:// (JSON).
##
## submit() folds a finished run's summary in, saves immediately (a Quest app
## can be killed from the system menu at any time) and reports which records
## the run broke so the summary screen can celebrate them.
##
## JSON rather than ConfigFile: a damaged file must fall back to defaults
## silently. ConfigFile.load() prints an engine ERROR for a corrupt file,
## which is noise in logs and trips grep-for-ERROR checks; JSON.parse()
## reports the failure only through its return value. Saves go through a
## temporary file and a rename, so a kill mid-write leaves the old records.

const DEFAULT_PATH := "user://gameloop_records.json"
const VERSION := 2

var path := DEFAULT_PATH
var best_score := 0
## Highest tier index ever reached (-1 = never played).
var best_tier := -1
var best_mass := 0.0
var most_catches := 0
var best_streak := 0
## Fastest run time (s) to reach the apex tier, -1 = never.
var fastest_apex_s := -1.0
## Fastest victory run time (s), -1 = never won.
var fastest_victory_s := -1.0
var runs := 0
var victories := 0


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path


## Loads from disk; a missing or corrupt file leaves the defaults.
func load_records() -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return
	var d: Dictionary = json.data
	best_score = int(_num(d, "best_score", 0))
	best_tier = int(_num(d, "best_tier", -1))
	best_mass = _num(d, "best_mass", 0.0)
	most_catches = int(_num(d, "most_catches", 0))
	best_streak = int(_num(d, "best_streak", 0))
	fastest_apex_s = _num(d, "fastest_apex_s", -1.0)
	fastest_victory_s = _num(d, "fastest_victory_s", -1.0)
	runs = int(_num(d, "runs", 0))
	victories = int(_num(d, "victories", 0))
	# Clamp anything a hand-edited or damaged file could put here.
	best_tier = clampi(best_tier, -1, SizeRules.SPECIES.size() - 1)
	best_score = maxi(best_score, 0)
	best_mass = maxf(best_mass, 0.0)
	most_catches = maxi(most_catches, 0)
	best_streak = maxi(best_streak, 0)
	runs = maxi(runs, 0)
	victories = clampi(victories, 0, runs)
	if fastest_apex_s < 0.0:
		fastest_apex_s = -1.0
	if fastest_victory_s < 0.0:
		fastest_victory_s = -1.0


## A number from the file, or `default` if the key is missing or not a number.
static func _num(d: Dictionary, key: String, default: float) -> float:
	var v: Variant = d.get(key, default)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		var x := float(v)
		return x if is_finite(x) else default
	return default


func save() -> Error:
	var data := to_dict()
	data.erase("best_species")
	data["version"] = VERSION
	var text := JSON.stringify(data, "\t")
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))
	if err != OK:
		# Some filesystems refuse to rename over an existing file: write in place.
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		var g := FileAccess.open(path, FileAccess.WRITE)
		if g == null:
			return FileAccess.get_open_error()
		g.store_string(text)
		g.close()
	return OK


## Folds a run summary (GameLoop._build_summary) into the records and saves.
## count_run / count_victory are false when the same run was already
## submitted (a won run that was continued and has now ended again), and for
## progress saved mid-run (GameLoop folds the run in at every new peak tier
## and when the app is paused or closed, so a best is never lost to the
## system menu): its bests still count, but it is not a (second) run or win.
## Returns {score, tier, mass, catches, streak, apex_time, victory_time}: true
## for each record the summary broke (see broken()).
func submit(summary: Dictionary, count_run: bool = true, count_victory: bool = true) -> Dictionary:
	var flags := broken(to_dict(), summary)
	if count_run:
		runs += 1
	best_score = maxi(best_score, int(summary.get("score", 0)))
	best_tier = maxi(best_tier, int(summary.get("peak_tier", -1)))
	best_mass = maxf(best_mass, float(summary.get("peak_mass", 0.0)))
	most_catches = maxi(most_catches, int(summary.get("catches", 0)))
	best_streak = maxi(best_streak, int(summary.get("best_streak", 0)))
	if flags["apex_time"]:
		fastest_apex_s = float((summary.get("apex", {}) as Dictionary).get("reached_at", -1.0))
	if bool(summary.get("victory", false)):
		if count_victory:
			victories = mini(victories + 1, maxi(runs, 1))
		if flags["victory_time"]:
			fastest_victory_s = float(summary.get("duration_s", -1.0))
	var err := save()
	if err != OK:
		push_warning("[gameloop] could not save records to %s: %s" % [path, error_string(err)])
	return flags


## Which records a run summary beats, measured against `before` (a
## to_dict()): the summary screen celebrates records broken against the
## bests as they were when the run started, even when the run's progress was
## already saved along the way.
static func broken(before: Dictionary, summary: Dictionary) -> Dictionary:
	var apex_at := float((summary.get("apex", {}) as Dictionary).get("reached_at", -1.0))
	var fa := float(before.get("fastest_apex_s", -1.0))
	var fv := float(before.get("fastest_victory_s", -1.0))
	var t := float(summary.get("duration_s", -1.0))
	var won := bool(summary.get("victory", false))
	return {
		"score": int(summary.get("score", 0)) > int(before.get("best_score", 0)),
		"tier": int(summary.get("peak_tier", -1)) > int(before.get("best_tier", -1)),
		"mass": float(summary.get("peak_mass", 0.0)) > float(before.get("best_mass", 0.0)) + 1e-9,
		"catches": int(summary.get("catches", 0)) > int(before.get("most_catches", 0)),
		"streak": int(summary.get("best_streak", 0)) > int(before.get("best_streak", 0)),
		"apex_time": apex_at >= 0.0 and (fa < 0.0 or apex_at < fa),
		"victory_time": won and t >= 0.0 and (fv < 0.0 or t < fv),
	}


func to_dict() -> Dictionary:
	return {
		"best_score": best_score, "best_tier": best_tier,
		"best_species": SizeRules.SPECIES[best_tier]["id"] if best_tier >= 0 else &"",
		"best_mass": best_mass, "most_catches": most_catches, "best_streak": best_streak,
		"fastest_apex_s": fastest_apex_s, "fastest_victory_s": fastest_victory_s,
		"runs": runs, "victories": victories,
	}
