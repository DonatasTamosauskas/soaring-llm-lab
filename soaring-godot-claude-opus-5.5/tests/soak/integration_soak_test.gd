extends TestCase
## The whole game played over and over (headless, deterministic seeds), run
## on its own (it is not part of the unit suites):
##
##   GD_TIMEOUT=2700 tools/gd.sh integ_soak --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/soak --suite=integration_soak --fresh-settings [--soak_cycles=12] [--soak_tag=<name>]
##
## Leaks are judged by REPEATING THE SAME CONTENT, not by a quiet time
## window (integration round 1: the old 10-minute soak asked memory to be
## flat over its last 3 minutes, and failed or passed depending on whether a
## one-time step - the first run's summary, a new run - fell inside that
## window as the game loop's pacing moved it; its limits had been fitted to
## the pattern of one run).
##
## A cycle is one whole run, the same each time: the bot flies the valley
## through the real WingInput and chases what the game's target cue names
## (the real AI hunting it meanwhile), the pause menu with Settings and How
## to fly, a staged predator's strike (caught screen, a life lost, the
## respawn), growth through every tier on staged prey (every CHASE_S, with
## the catch assist a struggling player gets), the eagle, the apex goal
## won (the victory summary), then Fly again. The first cycle meets nearly
## every piece of content for the first time (each screen, each species'
## first tier-up, the victory summary, the AI's per-perch and ground caches).
##
## Integration hygiene (2026-09-27): the creep the round-2 soak showed (+3-7
## objects and ~0.05 MB a run, a +2 MB step now and then; its 0.75 MB
## window was fitted after the fact and failed one run in three) was traced
## source by source (soak_census.gd, tests/shots/integration_diag_steps_test.gd;
## docs/INTEGRATION.md §10). None of it is a leak - every one is a bounded
## cache - so the soak now measures the way a leak test must, by emptying
## the caches it can before each sample (_purge_caches) and judging what is
## left by how it behaves over the runs:
##   * a run start (the same moment of each run: 8 s of flight) is sampled
##     as the least nodes / objects / static memory over START_WINDOW_S,
##     objects less the sounds playing (a playing sound holds a playback
##     object: the sky's calls come and go);
##   * nodes: from the second run on EXACTLY the second run's (one NPC's
##     worth per NPC of difference) - the content is deterministic;
##   * objects: every start within OBJECT_SLACK of the median start (the
##     one-shot voices of the polyphonic players, which the count of playing
##     players cannot see), and the drift - the median of the last
##     DRIFT_WINDOW starts less that of the first - at most OBJECT_DRIFT: a
##     leak adds every run (one object a run moves it by 8 over 12 runs), a
##     bounded cache fills in the first runs and stops (the per-run
##     increments' median, judged until 09:40, failed 2 of 4 leak-free soaks);
##   * static memory: the median per-run increment within LEAK_MB_PER_HOUR
##     scaled to a run's length. A leak grows every run; a bounded cache
##     steps when new content first needs it (a glyph atlas page is 2 MB,
##     and a new headline or summary can need one in any run) - the median
##     sees the first and not the second, where the round-2 window did the
##     opposite. 1 MB an hour of play is ~2 MB over a long Quest session:
##     nothing on a 12 GB headset, and a leak of one 4 kB allocation per
##     second (a per-frame array's growth) is 14 MB an hour and fails;
##   * 0 orphans, every cycle won, 0 errors, 0 warnings.
## What the caches held when emptied, the fonts' glyph caches and samples
## every 30 s are kept for the record (artifacts/integration/soak.json).

const Kit := preload("res://tests/unit/integration/game_kit.gd")
## The bot flies with a person's eyes: it steers round what is in the way
## and backs out of a corner it got wedged in (integration round 2: the
## plain pilot sat 13 minutes as an eagle in the corner between the church's
## tower and nave, and a cycle was cut at 15 minutes).
const PersonPilot := preload("res://tests/unit/integration/integration_person_pilot.gd")
const Census := preload("res://tests/soak/soak_census.gd")
## Twelve whole runs (~1 h of play, ~13 min of wall time at --fixed-fps 72):
## enough repeats that the smallest object leak worth a soak - one object a
## run - moves the drift statistic (OBJECT_DRIFT) further than the bounded
## caches and transients ever did (integration hygiene, 2026-09-27: with six
## runs a leak of one a run (+5) could not be told from the bounded fill of
## +4-6 that five soaks of a leak-free tree showed, and the median per-run
## increment that tried to failed 2 of 4 of them).
const CYCLES := 12
## Game seconds a cycle may take before it is cut short (a failed cycle).
const CYCLE_MAX_S := 15.0 * 60.0
const SAMPLE_S := 30.0
## Staged prey appears ahead every CHASE_S game seconds.
const CHASE_S := 15.0
## Tolerances at the same moment of repeated runs (see the header).
const NODE_SLACK := 0
## Objects at a start (from the second run on) against the median of all of
## them: what a start can still catch that is no leak - a one-shot starting
## in the window (a voice of the polyphonic players is a playback object
## while it sounds, and their count is not visible to _sounds_playing), a
## caught bird's 0.5 s timer, a bounded engine-side cache still filling.
## Five 6-run soaks of a leak-free tree (2026-09-27, 09:10-09:37): within
## -4..+2 of their median.
const OBJECT_SLACK := 8
## The leak detector: the median of the last DRIFT_WINDOW starts less the
## median of the first DRIFT_WINDOW (from the second run on). Their centres
## are CYCLES - DRIFT_WINDOW runs apart (8 at the default 12), so a leak of
## k objects a run moves it by 8k; a bounded cache fills in the first few
## runs and stops. The five soaks above: -1, -1, 0, +3, +3 (their windows 3
## runs apart, the fill inside them). OBJECT_DRIFT is halfway from 3 to 8.
const DRIFT_WINDOW := 4
const OBJECT_DRIFT := 5.5
## One NPC's objects (its nodes, brain, flight, model resources).
const NPC_OBJECTS := 40
## The memory budget for growth that repeats every run.
const LEAK_MB_PER_HOUR := 1.0

var kit: Kit
## Node census at the current cycle's start (diagnostics in the samples).
var _census0 := {}
var _containers1 := {}
var _nodes0 := 0
## Diagnostics (--soak_reach, --soak_memtrace=<MB>): see soak_census.gd.
var _reach1 := {}
var _conn1 := {}
var _objs1 := 0
var _memtrace: Node = null


var _objs_before_boot := 0
## The 30 s samples go to a JSON-lines file as they are taken.
var _samples_path := ""
var _samples_file: FileAccess = null
var _worst_orphans := 0


func _write_sample(smp: Dictionary) -> void:
	if _samples_file == null:
		var tag := Paths.arg("soak_tag", "")
		_samples_path = Paths.artifacts("integration").path_join("soak%s_samples.jsonl" % ("" if tag.is_empty() else "_" + tag))
		_samples_file = FileAccess.open(_samples_path, FileAccess.WRITE)
	if _samples_file != null:
		_samples_file.store_line(JSON.stringify(smp))
		_samples_file.flush()


var _reach_before := {}


func before_all() -> void:
	_objs_before_boot = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	if Paths.arg("soak_reach", "") != "":
		_reach_before = Census.reach(get_tree(), Census.all_statics())
	kit = Kit.new()
	check(await kit.boot(self), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)
	kit = null
	await wait_frames(5)
	# What outlives the game (static caches, engine singletons): printed for
	# the record (game_lifecycle_test pins it for two short games).
	print("[integration] soak: objects before the game %d, after it was freed %d (%+d)" % [_objs_before_boot,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)), int(Performance.get_monitor(Performance.OBJECT_COUNT)) - _objs_before_boot])
	if not _reach_before.is_empty():
		var r := Census.reach(get_tree(), Census.all_statics())
		print("[integration] soak reach after the game: %d reachable (before it: %d)" % [r["total"], _reach_before["total"]])
		print("[integration] soak reach after the game, by class: %s" % [Census.diff(_reach_before["by_class"], r["by_class"]).slice(0, 40)])
		print("[integration] soak reach after the game, by path: %s" % [Census.diff(_reach_before["by_path"], r["by_path"]).slice(0, 60)])


static func _subtree_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _subtree_nodes(ch)
	return c


func _sample(t: float, extra := {}) -> Dictionary:
	var m := kit.main
	var pp := m.player.global_position
	var s := {"t": t, "mem_mb": OS.get_static_memory_usage() / 1048576.0,
		"objects": kit.objects(), "nodes": kit.nodes(), "orphans": kit.orphans(),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"npcs": m.ecosystem.count(), "state": Game.state_name(), "species": String(m.player.species),
		"mass": snappedf(m.player.mass, 0.001), "mode": m.player.mode_name(),
		"pos": [snappedf(pp.x, 0.1), snappedf(pp.y, 0.1), snappedf(pp.z, 0.1)]}
	s.merge(extra)
	return s


## Bounded caches, emptied before every run-start sample (integration
## hygiene, 2026-09-27): a leak is what survives when every cache is empty.
## The soak's creep (+3-7 objects and ~0.05 MB a run, a +2 MB step now and
## then) was, measured one by one (tests/soak/soak_census.gd,
## tests/shots/integration_diag_steps_test.gd):
##  * the fonts' shaped-text caches: every Font keeps the last 64 strings it
##    measured and 16 wrapped paragraphs (engine: Font::Font()
##    cache.set_capacity(64), cache_wrap 16) as TextLine / TextParagraph
##    objects outside the scene tree - each run's new scores and times add
##    a few until they are full (31 objects a run in them at a run start);
##  * the glyph atlases: a dynamic font rasterizes each glyph once per size
##    into 1024 x 1024 pages (2 MB at the HUD's 76-90 px), and the HUD's
##    tier-up headline tries sizes 90, 88, ... until the text fits
##    (UIScreen.fit_size): a new species name can open a new size - the +2 MB
##    steps (the first "Now a Swallow!" alone opens three);
##  * the polyphonic players' finished voices: each keeps its last playback
##    object until it is reused - as many as the most one-shots that ever
##    sounded at once, a new peak now and then (~1 object a run);
##  * memo tables keyed by continuous values: FlapDetector's reference stroke
##    per player size (x at 0.001), NpcFlight's level-speed table per NPC
##    mass bucket (capped at 4096) and the AI habitat's per-perch seat and
##    enclosure answers - bounded, filling a little more each run.
## Returns what emptying them freed (for the record).
func _purge_caches() -> Dictionary:
	var o0 := kit.objects()
	var m0 := OS.get_static_memory_usage()
	var entries := FlapDetector._ref_cache.size() + NpcFlight._table_cache.size()
	FlapDetector._ref_cache.clear()
	NpcFlight._table_cache.clear()
	for h: Habitat in Habitat._cache.values():
		entries += h._seat.size() + h._enclosed.size()
		h._seat.clear()
		h._enclosed.clear()
	# Font._invalidate_rids (behind set_fallbacks) empties a font's shaped-
	# text caches. (The glyph atlases cannot be emptied under a running UI:
	# FontFile.clear_cache frees the font data the labels' shaped text still
	# points at - "Parameter fd is null" at the next label. They are judged
	# by the per-run increments instead, see the memory assertion.)
	for f: Font in UITheme._fonts.values() + [ThemeDB.fallback_font]:
		f.set_fallbacks(f.get_fallbacks())
	# A polyphonic player keeps every voice's last playback object after it
	# has finished (engine: AudioStreamPlaybackPolyphonic::mix clears the
	# voice's active flag, not its playback) until the voice is reused: as
	# many as the most one-shots that ever sounded at once (up to the 16
	# one-shot and 6 UI voices). Restarting the player frees them.
	var a: Node = kit.main.audio
	if a != null and is_instance_valid(a):
		for pl in a.find_children("*", "AudioStreamPlayer", true, false):
			var ap := pl as AudioStreamPlayer
			if ap.stream is AudioStreamPolyphonic and ap.playing:
				ap.stop()
				ap.play()
	await kit.frames(3)
	return {"objects": o0 - kit.objects(), "mb": snappedf((m0 - OS.get_static_memory_usage()) / 1048576.0, 0.001),
		"memo_entries": entries}


## A run-start sample: the least nodes, objects and static memory over
## START_WINDOW_S (a bird caught a moment ago waits 0.5 s to be freed, a
## feather burst lives 2.3 s, a sound plays out: transients, not leaks).
const START_WINDOW_S := 3.0


func _start_sample(t: float, extra := {}) -> Dictionary:
	var nmin := 1 << 30
	var omin := 1 << 30
	var oamin := 1 << 30
	var mmin := 1 << 62
	for i in int(START_WINDOW_S * 18.0):
		await kit.advance(1.0 / 18.0)
		nmin = mini(nmin, kit.nodes() - _live_burst_nodes(kit.main))
		var o := kit.objects()
		omin = mini(omin, o)
		oamin = mini(oamin, o - _sounds_playing())
		mmin = mini(mmin, OS.get_static_memory_usage())
	var s := _sample(t, extra)
	s["nodes"] = nmin
	s["objects_raw"] = omin
	s["objects"] = oamin
	s["mem_mb"] = mmin / 1048576.0
	return s


## Sounds playing now (each holds its AudioStreamPlayback object while it
## plays: the calls of the birds around, wind, wingbeats - as many as the
## sky makes at that moment, not a leak).
func _sounds_playing() -> int:
	var a: Node = kit.main.audio
	if a == null or not is_instance_valid(a):
		return 0
	var n := 0
	for pl in a.find_children("*", "AudioStreamPlayer", true, false):
		if (pl as AudioStreamPlayer).playing:
			n += 1
	for pl in a.find_children("*", "AudioStreamPlayer3D", true, false):
		if (pl as AudioStreamPlayer3D).playing:
			n += 1
	return n


## Nodes of feather bursts still within their own lifetime (see
## game_flow_test._live_burst_nodes).
static func _live_burst_nodes(root: Node) -> int:
	var c := 0
	for ch in root.get_children():
		if ch is FeatherBurst and (ch as FeatherBurst).age < (ch as FeatherBurst).lifetime + 0.5:
			c += _subtree_nodes(ch)
	return c


## Node classes (script class <- parent class) and their counts, for the
## record when nodes grow between samples.
static func _census(n: Node, out: Dictionary) -> void:
	var key := n.get_class()
	var sc: Script = n.get_script()
	if sc != null and sc.get_global_name() != &"":
		key = String(sc.get_global_name())
	var p := n.get_parent()
	var pk := "-"
	if p != null:
		pk = p.get_class()
		var ps: Script = p.get_script()
		if ps != null and ps.get_global_name() != &"":
			pk = String(ps.get_global_name())
	var k := "%s <- %s" % [key, pk]
	out[k] = int(out.get(k, 0)) + 1
	for c in n.get_children():
		_census(c, out)


## Diagnostics (--soak_census): the size of every Array / Dictionary /
## packed array held by a script member of every node (and of the
## RefCounted objects those members hold, a few levels down), by path.
## Compared between two cycle starts, what grows run after run holds the
## creep.
static func _containers(root: Node, autoloads: Array) -> Dictionary:
	var out := {}
	var seen := {}
	var stack: Array = []
	for n in autoloads:
		stack.append([n, "/root/" + String(n.name), 0])
	stack.append([root, "tree", 0])
	while not stack.is_empty():
		var it: Array = stack.pop_back()
		var o: Object = it[0]
		var path: String = it[1]
		var depth: int = it[2]
		if o == null or not is_instance_valid(o) or seen.has(o.get_instance_id()):
			continue
		seen[o.get_instance_id()] = true
		if o.get_script() != null:
			for pr: Dictionary in o.get_property_list():
				if not (int(pr["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
					continue
				var v: Variant = o.get(pr["name"])
				var key := "%s.%s" % [path, pr["name"]]
				match typeof(v):
					TYPE_ARRAY, TYPE_DICTIONARY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_STRING_ARRAY:
						out[key] = v.size()
						if typeof(v) == TYPE_ARRAY and depth < 3:
							var k := 0
							for e in v:
								if typeof(e) == TYPE_OBJECT and is_instance_valid(e) and e is RefCounted:
									stack.append([e, "%s[%d]" % [key, k], depth + 1])
								k += 1
								if k > 64:
									break
						elif typeof(v) == TYPE_DICTIONARY and depth < 3:
							var k2 := 0
							for dk in v:
								var dv: Variant = v[dk]
								if typeof(dv) == TYPE_OBJECT and is_instance_valid(dv) and dv is RefCounted:
									stack.append([v[dk], "%s{%d}" % [key, k2], depth + 1])
								k2 += 1
								if k2 > 64:
									break
					TYPE_OBJECT:
						if is_instance_valid(v) and v is RefCounted and depth < 4:
							stack.append([v, key, depth + 1])
		if o is Node:
			var nd := o as Node
			var i := 0
			for c in nd.get_children():
				# NPCs come and go: one sample of their kind is enough.
				stack.append([c, "%s/%s" % [path, c.get_class() if String(c.name).begins_with("@") or String(c.name).contains("_") else String(c.name)], depth])
				i += 1
	return out


## The UI fonts' glyph caches (bytes, glyphs, pages): a dynamic font adds a
## texture page when a new glyph or size does not fit its pages (1024 x 1024
## LA8 = 2 MB for the title sizes).
static func _fonts() -> Dictionary:
	var fc := Census.font_caches(UITheme._fonts.values() + [ThemeDB.fallback_font])
	return {"mb": snappedf(fc["bytes"] / 1048576.0, 0.001), "glyphs": fc["glyphs"], "pages": fc["pages"],
		"rids": fc["rids"], "sizes": fc["sizes"].size()}


static func _median(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	var h := int(b.size() / 2.0)
	return float(b[h]) if b.size() % 2 == 1 else 0.5 * (float(b[h - 1]) + float(b[h]))


static func _statics() -> Dictionary:
	return {"BirdBatch._batches": BirdBatch._batches, "BirdBatch._marks": BirdBatch._marks,
		"BirdBatch._mark_changes": BirdBatch._mark_changes, "NpcFlight._table_cache": NpcFlight._table_cache,
		"FlapDetector._ref_cache": FlapDetector._ref_cache, "Habitat._cache": Habitat._cache,
		"VRProfile.usec": VRProfile.usec, "UITheme._fonts": UITheme._fonts, "BirdModels._meshes": BirdModels._meshes,
		"BirdModels._info": BirdModels._info, "BirdModels._cam_cache": BirdModels._cam_cache,
		"FlightGeometry._mats": FlightGeometry._mats, "NpcBrain.snap_birds": NpcBrain.snap_birds,
		"AudioBank._shared": AudioBank._shared}


## The reachability census (--soak_reach) at the start of cycles 1 and the
## last: what grew, by class, by path and by signal connection.
func _reach_census(c: int, cycles: int) -> void:
	if Paths.arg("soak_reach", "") == "" or not (c == 1 or c == cycles - 1):
		return
	var t0 := Time.get_ticks_msec()
	var st := _statics()
	st.merge(Census.all_statics())
	var r := Census.reach(get_tree(), st)
	r["static_sizes"] = Census.static_sizes(st)
	var cn := Census.connections(get_tree())
	var objs := kit.objects()
	print("[integration] soak reach at cycle %d: %d reachable of %d objects (%d ms)" % [c, r["total"], objs, Time.get_ticks_msec() - t0])
	if c == 1:
		_reach1 = r
		_conn1 = cn
		_objs1 = objs
		return
	print("[integration] soak reach: objects %+d, reachable %+d from cycle 1 to %d" % [objs - _objs1, int(r["total"]) - int(_reach1["total"]), c])
	print("[integration] soak reach by class: %s" % [Census.diff(_reach1["by_class"], r["by_class"]).slice(0, 30)])
	print("[integration] soak reach by path: %s" % [Census.diff(_reach1["by_path"], r["by_path"]).slice(0, 40)])
	print("[integration] soak connections: %s" % [Census.diff(_conn1, cn).slice(0, 30)])
	print("[integration] soak static containers: %s" % [Census.diff(_reach1["static_sizes"], r["static_sizes"]).slice(0, 30)])


static func _census_diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var d := {}
	for k in b:
		var dv := int(b[k]) - int(a.get(k, 0))
		if dv != 0:
			d[k] = dv
	for k in a:
		if not b.has(k):
			d[k] = -int(a[k])
	return d


func test_soak_repeated_runs() -> void:
	if kit.main == null or not kit.main.is_loaded:
		return
	var m := kit.main
	var cycles := int(Paths.arg("soak_cycles", str(CYCLES)))
	# Diagnostics (tracing a creep): --soak_drop=audio,fx,ui_sounds frees
	# those subsystems before the first cycle.
	for part in Paths.arg("soak_drop", "").split(",", false):
		var n: Node = m.get(StringName(part))
		if n != null and is_instance_valid(n):
			print("[integration] soak: dropped %s" % part)
			n.queue_free()
	if Paths.arg("soak_memtrace", "") != "":
		_memtrace = Census.install_memtrace(self, float(Paths.arg("soak_memtrace", "1.0")), func() -> Dictionary:
			if not is_instance_valid(m):
				return {}
			var au := {}
			if m.audio != null and is_instance_valid(m.audio):
				var playing := 0
				for pl in m.audio.find_children("*", "AudioStreamPlayer", true, false) + m.audio.find_children("*", "AudioStreamPlayer3D", true, false):
					if pl.playing:
						playing += 1
				au = {"playing": playing}
			return {"t": snappedf(Game.run_time, 0.1), "state": Game.state_name(), "species": String(m.player.species),
				"npcs": m.ecosystem.count(), "objects": kit.objects(), "nodes": kit.nodes(), "audio": au})
		_memtrace.set(&"detail", func() -> Dictionary:
			var fc := Census.font_caches(UITheme._fonts.values() + [ThemeDB.fallback_font])
			return {"font_mb": snappedf(fc["bytes"] / 1048576.0, 0.001), "glyphs": fc["glyphs"], "pages": fc["pages"], "sizes": fc["sizes"],
				"statics": Census.static_sizes(Census.all_statics())})
	await kit.frames(2)
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	var counts := {"catches": 0, "deaths": 0, "chases": 0, "staged": 0}
	var on_caught := func(pred: Bird, _prey: Bird) -> void:
		if pred == m.player:
			counts["catches"] += 1
	Events.bird_caught.connect(on_caught)
	var on_death := func(_by: Bird) -> void:
		counts["deaths"] += 1
	Events.player_caught.connect(on_death)
	var wall0 := Time.get_ticks_msec()
	var t := [0.0]
	var samples := []
	var starts := []
	var peaks := []
	var results := []
	var next_sample := [0.0]
	var per_npc := 0
	for c in cycles:
		# The same moment of every cycle: a new run, 8 s of flight.
		kit.fly_bot(11, PersonPilot)
		kit.set_mode(&"climb")
		await kit.advance(8.0)
		t[0] += 8.0
		if per_npc == 0 and m.ecosystem.count() > 0:
			per_npc = _subtree_nodes(m.ecosystem.get_npcs()[0])
		var fonts_now := _fonts()
		var purged := await _purge_caches()
		starts.append(await _start_sample(t[0], {"cycle": c, "fonts": fonts_now, "purged": purged}))
		t[0] += START_WINDOW_S
		_reach_census(c, cycles)
		if Paths.arg("soak_census", "") != "" and (c == 1 or c == cycles - 1):
			var auto := []
			for n in get_tree().root.get_children():
				if n != get_tree().current_scene and n.name in ["Events", "Game", "Birds", "Settings", "VR"]:
					auto.append(n)
			var cn := _containers(get_tree().root, auto)
			# Static caches (not reachable from the tree).
			cn["static BirdBatch._batches"] = BirdBatch._batches.size()
			cn["static NpcFlight._table_cache"] = NpcFlight._table_cache.size()
			cn["static FlapDetector._ref_cache"] = FlapDetector._ref_cache.size()
			cn["static Habitat._cache"] = Habitat._cache.size()
			cn["static VRProfile.usec"] = VRProfile.usec.size()
			cn["static UITheme._fonts"] = UITheme._fonts.size()
			for bk in BirdBatch._batches:
				var bb: BirdBatch = BirdBatch._batches[bk]
				cn["static BirdBatch %s models" % bk] = bb.models.size()
				cn["static BirdBatch %s lod_moves" % bk] = bb._lod_moves.size()
			print("[integration] soak census statics at cycle %d: %s" % [c, cn.keys().filter(func(k: String) -> bool: return k.begins_with("static ")).map(func(k: String) -> String: return "%s=%d" % [k, cn[k]])])
			if c == 1:
				_containers1 = cn
			else:
				var grew := []
				for k in cn:
					var d0: int = _containers1.get(k, 0)
					if int(cn[k]) > d0:
						grew.append([int(cn[k]) - d0, k, d0, cn[k]])
				grew.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
				print("[integration] soak census: containers that grew from cycle 1 to %d: %s" % [c, grew.slice(0, 40)])
		_census0 = {}
		_census(get_tree().root, _census0)
		_nodes0 = kit.nodes()
		var r := await _cycle(c, t, counts, samples, next_sample)
		results.append(r)
		peaks.append(r["peak_mem_mb"])
		print("[integration] soak cycle %d: %s" % [c, r])
		var oend := kit.objects()
		# Fly again from the summary (whatever ended the run).
		kit.free_staged()
		if Game.state != Game.State.ENDED:
			fail("cycle %d did not end its run (state %s)" % [c, Game.state_name()])
			break
		await kit.advance(1.0)
		t[0] += 1.0
		if not await kit.click(&"summary", &"again"):
			fail("cycle %d: Fly again was not clickable" % c)
			break
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
		print("[integration] soak segment objects, cycle %d: run start -> end %+d; end -> after Fly again %+d; %s" % [
			c, oend - int(starts[-1]["objects"]), kit.objects() - oend, r.get("segments", {})])
	# The start of the run after the last cycle.
	kit.fly_bot(11, PersonPilot)
	kit.set_mode(&"climb")
	await kit.advance(8.0)
	t[0] += 8.0
	var fonts_end := _fonts()
	var purged_end := await _purge_caches()
	starts.append(await _start_sample(t[0], {"cycle": cycles, "fonts": fonts_end, "purged": purged_end}))
	t[0] += START_WINDOW_S
	Events.bird_caught.disconnect(on_caught)
	Events.player_caught.disconnect(on_death)
	var wall_s := (Time.get_ticks_msec() - wall0) / 1000.0
	print("[integration] soak: %d cycles, %.0f s of play in %.0f s wall; %d cue chases, %d staged prey, %d catches, %d deaths" % [
		cycles, t[0], wall_s, counts["chases"], counts["staged"], counts["catches"], counts["deaths"]])
	for s in starts:
		print("[integration] soak cycle start ", s)
	var soak_tag := Paths.arg("soak_tag", "")
	var f := FileAccess.open(Paths.artifacts("integration").path_join("soak%s.json" % ("" if soak_tag.is_empty() else "_" + soak_tag)), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"cycles": results, "starts": starts, "samples_file": _samples_path.get_file(), "play_s": t[0],
			"wall_s": wall_s, "counts": counts, "per_npc_nodes": per_npc,
			"tolerances": {"leak_mb_per_hour": LEAK_MB_PER_HOUR, "nodes": NODE_SLACK, "objects": OBJECT_SLACK,
				"objects_drift": OBJECT_DRIFT, "drift_window": DRIFT_WINDOW}}, "  "))
	# --- every cycle is a whole run to the apex ---------------------------------
	for r: Dictionary in results:
		check(bool(r["victory"]), "cycle %d reached the eagle and won the apex goal (%s)" % [r["cycle"], r["end"]])
		gt(float(r["deaths"]), 0.5, "cycle %d: caught at least once (%d)" % [r["cycle"], r["deaths"]])
	if not check(starts.size() >= 4, "enough runs (%d starts)" % starts.size()):
		return
	# --- repeats of the same content add nothing ----------------------------------
	# (From the second run on: the first meets every piece of content first.)
	var ref: Dictionary = starts[1]
	var obj_inc := []
	var mem_inc := []
	# Objects from the second run on, one NPC's worth per NPC of difference
	# from the second run's sky taken out (the sky's size is held; a
	# difference would be the governor's).
	var objs := []
	for i in range(1, starts.size()):
		var s: Dictionary = starts[i]
		objs.append(float(s["objects"]) - NPC_OBJECTS * (int(s["npcs"]) - int(ref["npcs"])))
	var obj_mid := _median(objs.duplicate())
	for i in range(2, starts.size()):
		var s: Dictionary = starts[i]
		var dk: int = absi(int(s["npcs"]) - int(ref["npcs"]))
		lt(absf(float(s["nodes"]) - float(ref["nodes"])), NODE_SLACK + per_npc * dk + 0.5,
			"nodes at the start of run %d: %d, run 2: %d" % [i + 1, s["nodes"], ref["nodes"]])
		var prev: Dictionary = starts[i - 1]
		if int(s["npcs"]) == int(prev["npcs"]):
			obj_inc.append(int(s["objects"]) - int(prev["objects"]))
		mem_inc.append(float(s["mem_mb"]) - float(prev["mem_mb"]))
	for i in objs.size():
		lt(absf(float(objs[i]) - obj_mid), OBJECT_SLACK + 0.5,
			"objects at the start of run %d: %d, the median of runs 2-%d: %.1f" % [i + 2, int(objs[i]), objs.size() + 1, obj_mid])
	obj_inc.sort()
	mem_inc.sort()
	var obj_med := _median(obj_inc)
	var mem_med := _median(mem_inc)
	# The leak detector (see OBJECT_DRIFT).
	var w := mini(DRIFT_WINDOW, objs.size() / 2)
	var drift := _median(objs.slice(objs.size() - w)) - _median(objs.slice(0, w))
	lt(drift, OBJECT_DRIFT + 1e-6, "objects do not grow run after run: runs %d-%d %.1f, runs 2-%d %.1f: drift %+.1f over %d runs (one object a run leaked moves it by %d); starts %s" % [
		objs.size() - w + 2, objs.size() + 1, _median(objs.slice(objs.size() - w)), w + 1, _median(objs.slice(0, w)), drift,
		objs.size() - w, objs.size() - w, objs.map(func(x: float) -> int: return int(x))])
	metric("objects_drift", drift)
	# The budget for one run: its share of an hour of play.
	var run_s: Array = results.map(func(r: Dictionary) -> float: return float(r["play_s"]))
	var budget: float = LEAK_MB_PER_HOUR * _median(run_s) / 3600.0
	lt(mem_med, budget, "static memory does not grow run after run: median increment %.3f MB a run, budget %.3f MB (%.1f MB an hour); increments %s" % [
		mem_med, budget, LEAK_MB_PER_HOUR, mem_inc.map(func(x: float) -> float: return snappedf(x, 0.001))])
	metric("objects_median_increment", obj_med)
	metric("mem_median_increment_mb", snappedf(mem_med, 0.0001))
	metric("mem_budget_per_run_mb", snappedf(budget, 0.0001))
	metric("purged", starts.map(func(s5: Dictionary) -> Dictionary: return s5.get("purged", {})))
	var worst_orph := _worst_orphans
	for s2: Dictionary in starts:
		worst_orph = maxi(worst_orph, int(s2["orphans"]))
	eq(worst_orph, 0, "no orphan nodes")
	metric("starts_mem_mb", starts.map(func(s3: Dictionary) -> float: return snappedf(s3["mem_mb"], 0.01)))
	metric("starts_nodes", starts.map(func(s3: Dictionary) -> int: return s3["nodes"]))
	metric("starts_objects", starts.map(func(s3: Dictionary) -> int: return s3["objects"]))
	metric("cycle_peaks_mb", peaks.map(func(p: float) -> float: return snappedf(p, 0.01)))
	metric("starts_objects_raw", starts.map(func(s3: Dictionary) -> int: return s3.get("objects_raw", -1)))
	metric("cycles", results)
	metric("play_s", t[0])
	metric("wall_s", wall_s)
	eq(kit.log.errors, 0, "no errors in the whole soak: %s" % kit.log.summary())
	eq(kit.log.warnings, 0, "no warnings in the whole soak: %s" % kit.log.summary())


static func _seg(out: Dictionary, k: String, d: int) -> void:
	var sg: Dictionary = out.get("segments", {})
	sg[k] = int(sg.get(k, 0)) + d
	out["segments"] = sg


## One whole run: until Game.ENDED (the apex victory, or the lives ran out)
## or CYCLE_MAX_S. Returns what happened.
func _cycle(c: int, t: Array, counts: Dictionary, samples: Array, next_sample: Array) -> Dictionary:
	var m := kit.main
	var t0: float = t[0]
	var out := {"cycle": c, "victory": false, "end": "", "deaths": 0, "catches": 0, "peak": "sparrow", "peak_mem_mb": 0.0}
	var catches0: int = counts["catches"]
	var deaths0: int = counts["deaths"]
	var paused := false
	var struck := false
	var chase_since := -100.0
	var next_prey: float = t0 + 10.0
	var peak_tier := 0
	var victory := [false]
	var on_victory := func(_s: Dictionary) -> void:
		victory[0] = true
	m.game_loop.victory.connect(on_victory)
	while t[0] - t0 < CYCLE_MAX_S:
		var ct: float = t[0] - t0
		match Game.state:
			Game.State.PLAYING:
				if m.player.mode_name() != "flying":
					kit.set_mode(&"climb")
				else:
					kit.set_mode(&"cruise")
				# The pause menu, Settings and How to fly, once a cycle.
				if not paused and ct > 20.0:
					paused = true
					var om0 := kit.objects()
					await _menus()
					_seg(out, "menus", kit.objects() - om0)
					t[0] += 1.5
					continue
				# A staged strike, once a cycle (the caught screen, a respawn).
				if not struck and ct > 35.0 and m.player.mode_name() == "flying":
					struck = true
					if m.game_loop.protection_left(m.player) > 0.0:
						m.game_loop.set_protection(m.player, 0.0)
					out["_strike_o"] = kit.objects()
					kit.stage_strike(&"eagle", 30.0, 14.0)
				var tgt: Array = kit.last.get("target_changed", [])
				if kit.chase_target != null and t[0] - chase_since > 12.0:
					kit.cruise()
				if t[0] >= next_prey and m.player.mode_name() == "flying" and kit.strike.is_empty() \
						and (kit.chase_target == null or kit.chase_target.get_parent() != m):
					kit.cruise()
				if kit.chase_target != null and kit.chase_target.get_parent() == m and is_instance_valid(kit.chase_target):
					var rel := kit.chase_target.global_position - m.player.get_body_position()
					if rel.dot(m.player.velocity) < 0.0 and rel.length() > 1.5:
						kit.release(kit.chase_target)
						kit.cruise()
				if kit.chase_target == null and tgt.size() > 0 and tgt[0] is NpcBird and is_instance_valid(tgt[0]) \
						and t[0] - chase_since > 2.0:
					kit.chase_bird(tgt[0])
					chase_since = t[0]
					counts["chases"] += 1
				if kit.chase_target == null and t[0] >= next_prey and m.player.mode_name() == "flying" and kit.strike.is_empty():
					next_prey = t[0] + CHASE_S
					# The biggest ladder species the player can eat - by the
					# staged bird's own mass (an NPC is spawned within +-9 %
					# of its species' mass: a gull just over a small hawk's
					# limit can never be eaten, and a cycle once sat 700 s as
					# a hawk chasing such gulls), else the next smaller one.
					var edible: Array[StringName] = []
					for sd in SizeRules.SPECIES:
						if SizeRules.can_eat(m.player.mass, sd["mass"]):
							edible.push_front(sd["id"])
					edible.append(&"moth")
					var prey: NpcBird = null
					for sp: StringName in edible:
						prey = kit.stage_prey(sp, 30.0)
						if m.player.can_eat(prey):
							break
						kit.release(prey)
						kit.coop.erase(prey)
						prey = null
					if prey != null:
						m.game_loop.assist_override = 1.0
						kit.chase_bird(prey)
						chase_since = t[0]
						counts["staged"] += 1
					else:
						kit.cruise()
			Game.State.ENDED:
				break
			Game.State.PAUSED:
				Events.menu_requested.emit()
		await kit.advance(0.5)
		t[0] += 0.5
		peak_tier = maxi(peak_tier, SizeRules.tier_for_mass(m.player.mass))
		if kit.strike.is_empty() and not kit.staged.is_empty() and kit.chase_target == null:
			kit.free_staged()
		if out.has("_strike_o") and Game.state == Game.State.PLAYING and kit.strike.is_empty() and int(counts["deaths"]) > deaths0:
			_seg(out, "strike_to_respawn", kit.objects() - int(out["_strike_o"]))
			out.erase("_strike_o")
		if kit.chase_target == null and m.game_loop.assist_override >= 0.0:
			m.game_loop.assist_override = -1.0
		var mem := OS.get_static_memory_usage() / 1048576.0
		out["peak_mem_mb"] = maxf(float(out["peak_mem_mb"]), mem)
		if t[0] >= next_sample[0]:
			next_sample[0] = t[0] + SAMPLE_S
			var smp := _sample(t[0], {"cycle": c, "catches": counts["catches"], "deaths": counts["deaths"]})
			if absi(kit.nodes() - _nodes0) > 2:
				# What grew since this cycle started (for the record).
				var now := {}
				_census(get_tree().root, now)
				smp["grew"] = _census_diff(_census0, now)
			# Written out at once, not kept: the soak's own record must not
			# grow the memory it judges (10 samples a run with their node
			# census were ~20-40 kB a run).
			_write_sample(smp)
			_worst_orphans = maxi(_worst_orphans, int(smp["orphans"]))
	m.game_loop.victory.disconnect(on_victory)
	m.game_loop.assist_override = -1.0
	kit.cruise()
	out["victory"] = victory[0]
	out["end"] = "victory" if victory[0] else ("lives" if Game.state == Game.State.ENDED else "cut at %.0f s" % CYCLE_MAX_S)
	out["deaths"] = int(counts["deaths"]) - deaths0
	out["catches"] = int(counts["catches"]) - catches0
	out["peak"] = String(SizeRules.SPECIES[peak_tier]["id"])
	out["play_s"] = snappedf(t[0] - t0, 0.5)
	out["unsticks"] = int(kit.pilot.get(&"unsticks")) if kit.pilot != null and &"unsticks" in kit.pilot else -1
	return out


## The pause menu, Settings and back, How to fly and back, resume.
func _menus() -> void:
	Events.menu_requested.emit()
	await kit.frames(3)
	for pair: Array in [[&"pause", &"settings"], [&"settings", &"back"], [&"pause", &"howto"], [&"howto", &"back"]]:
		await kit.click(pair[0], pair[1])
		await kit.frames(3)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 300:
		await kit.frames(1)
	Events.menu_requested.emit()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 2.0)
	await kit.advance(1.5)
