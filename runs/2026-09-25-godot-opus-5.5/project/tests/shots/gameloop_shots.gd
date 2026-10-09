extends Control
## Game-loop evidence charts, rendered by Godot into PNGs:
##   artifacts/gameloop/pacing_chart.png    time to each species by skill (G4)
##   artifacts/gameloop/danger_chart.png    being caught, by skill (G4)
##   artifacts/gameloop/cadence_chart.png   every catch of every valley run (G4)
##   artifacts/gameloop/duel_mirror.png     the sims' NPCs vs the AI's own duels
##   artifacts/gameloop/loop_shift.png      what each species is worth to you (G5)
##   artifacts/gameloop/threat_timeline.png threat level vs time-to-contact (G6)
##   artifacts/gameloop/threat_naming.png   who the danger cue names in an attack (G6)
##
##   tools/gd.sh gameloop --rendering-method forward_plus --resolution 1600x900 res://tests/shots/gameloop_shots.tscn
##
## Reads artifacts/gameloop/integrated_live.json (runs in the AI's sky in the
## shipped valley; competent = the tuning seeds and the held-out seeds),
## integrated.json (the same runs in the AI mirror) and duels.json
## (tests/shots/gameloop_pacing.tscn writes them; a tier never reached is
## stored as null); computes the rest live.
## Palette and marks follow the data-viz method: light surface, text in ink
## tokens, categorical slots 1-3 for the three skills, status red only for
## "can eat you", sequential blue for magnitudes, one axis per chart.

const SURFACE := Color("#fcfcfb")
const INK := Color("#0b0b0b")
const INK2 := Color("#52514e")
const MUTED := Color("#898781")
const GRID := Color("#e1e0d9")
const BASE := Color("#c3c2b7")
const NEUTRAL := Color("#f0efec")
const CRITICAL := Color("#d03b3b")
const SERIES := [Color("#2a78d6"), Color("#eb6834"), Color("#1baf7a")]
const SEQ := [Color("#cde2fb"), Color("#b7d3f6"), Color("#9ec5f4"), Color("#86b6ef"), Color("#6da7ec"),
	Color("#5598e7"), Color("#3987e5"), Color("#2a78d6"), Color("#256abf"), Color("#1c5cab"),
	Color("#184f95"), Color("#104281"), Color("#0d366b")]
const SKILLS := ["novice", "competent", "expert"]
## The Quest quality tier's competent runs (a fourth categorical slot).
const QUEST_COL := Color("#7c5cd6")

var font: Font
var _chart := ""
var _integrated := {}
var _quest := {}
var _mirror := {}
var _duels := {}
var _threat := {}
var _naming := {}


func _ready() -> void:
	font = ThemeDB.fallback_font
	# Draw in real window pixels (the project stretches a 1280x720 canvas).
	get_tree().root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	set_anchors_preset(Control.PRESET_FULL_RECT)
	await get_tree().process_frame
	var dir := Paths.artifacts("gameloop")
	_integrated = _load(dir.path_join("integrated_live.json"))
	_quest = _load(dir.path_join("integrated_live_quest.json"))
	_mirror = _load(dir.path_join("integrated.json"))
	_duels = _load(dir.path_join("duels.json"))
	_threat = await _threat_scenario()
	_naming = await _naming_scenario()
	var only: String = Paths.user_args().get("only", "")
	for c in ["pacing_chart", "danger_chart", "cadence_chart", "duel_mirror", "loop_shift", "threat_timeline", "threat_naming"]:
		if not only.is_empty() and c != only:
			continue
		_chart = c
		queue_redraw()
		await get_tree().process_frame
		await get_tree().process_frame
		await Capture.save_viewport(get_viewport(), dir.path_join(c + ".png"))
	get_tree().quit()


static func _load(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


## A stored number (null = never reached = INF).
static func _f(v: Variant) -> float:
	return INF if v == null else float(v)


## Every valley run of a skill (competent: tuning and held-out seeds);
## "quest": the Quest tier's competent runs.
func _raw(skill: String) -> Array:
	var src := _quest if skill == "quest" else _integrated
	var sk := "competent" if skill == "quest" else skill
	var out: Array = (src.get(sk, {}).get("raw", []) as Array).duplicate()
	out.append_array(src.get("holdout_" + sk, {}).get("raw", []))
	return out


## The lanes of the pacing and danger charts: the three skills, and the
## competent player on the Quest tier.
func _lanes() -> Array:
	var out := [["novice", SERIES[0], "novice"], ["competent", SERIES[1], "competent"], ["expert", SERIES[2], "expert"]]
	if not _raw("quest").is_empty():
		out.append(["quest", QUEST_COL, "competent, Quest tier (28 NPCs)"])
	return out


## Median and quartiles of the time to tier t over runs (INF = not reached).
static func _tier_stats(runs: Array, t: int) -> Dictionary:
	var xs: Array[float] = []
	for r: Dictionary in runs:
		xs.append(_f(r["tier_at"].get(str(t))))
	xs.sort()
	var n := xs.size()
	if n == 0:
		return {}
	var reached := 0
	for x in xs:
		if is_finite(x):
			reached += 1
	return {"median": xs[n / 2] if n % 2 == 1 else (xs[n / 2 - 1] + xs[n / 2]) * 0.5, "q25": xs[n / 4],
		"q75": xs[(3 * n) / 4], "reached": float(reached) / n}


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), SURFACE)
	match _chart:
		"pacing_chart":
			_draw_pacing()
		"loop_shift":
			_draw_loop_shift()
		"threat_timeline":
			_draw_threat()
		"threat_naming":
			_draw_naming()
		"danger_chart":
			_draw_danger()
		"cadence_chart":
			_draw_cadence()
		"duel_mirror":
			_draw_duel_mirror()


# ------------------------------------------------------------------ helpers

func _text(pos: Vector2, s: String, sz: int, col: Color = INK, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, pos, s, align, width, sz, col)


func _title(t: String, sub: String) -> void:
	_text(Vector2(48, 58), t, 30, INK)
	_text(Vector2(48, 92), sub, 17, INK2)


func _dot(c: Vector2, r: float, col: Color) -> void:
	draw_circle(c, r + 2.0, SURFACE)  # 2px surface ring on overlapping marks
	draw_circle(c, r, col)


func _legend(x: float, y: float, items: Array) -> void:
	for it in items:
		var col: Color = it[0]
		var kind: String = it[2] if it.size() > 2 else "dot"
		match kind:
			"dot":
				_dot(Vector2(x + 7, y - 6), 6.0, col)
			"bar":
				draw_rect(Rect2(x, y - 12, 16, 12), col)
			"box":
				draw_rect(Rect2(x, y - 12, 16, 12), BASE, false, 1.0)
			"diamond":
				_diamond(Vector2(x + 7, y - 6), 7.0, col)
			"ring":
				draw_arc(Vector2(x + 7, y - 6), 6.0, 0.0, TAU, 24, col, 2.0, true)
		_text(Vector2(x + 22, y), it[1], 16, INK2)
		x += 34.0 + font.get_string_size(it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x


func _diamond(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0), c + Vector2(0, -r)])
	draw_polyline(pts, col, 2.0, true)


static func _mmss(s: float) -> String:
	if not is_finite(s):
		return "never"
	return "%d:%02d" % [int(s) / 60, int(s) % 60]


func _seq(t: float) -> Color:
	var i := clampi(int(round(clampf(t, 0.0, 1.0) * (SEQ.size() - 1))), 0, SEQ.size() - 1)
	return SEQ[i]


# ------------------------------------------------------------------ pacing

func _draw_pacing() -> void:
	var n_runs := (_integrated.get("novice", {}).get("raw", []) as Array).size()
	var n_comp := _raw("competent").size()
	var lanes := _lanes()
	_title("Time to reach each species, by player skill",
			"Whole runs (%d per skill, %d competent incl. held-out seeds%s): the real GameLoop, the AI's sky in the shipped valley, modelled players. Dot = median, bar = middle 50%%, marks = each run." % [
				n_runs, n_comp, (", %d on the Quest tier" % _raw("quest").size()) if lanes.size() > 3 else ""])
	var leg := []
	for ln: Array in lanes:
		leg.append([ln[1], ln[2]])
	leg.append_array([[INK2, "one run", "diamond"], [SERIES[1], "competent, AI mirror", "ring"], [NEUTRAL, "the brief", "bar"]])
	_legend(48, 132, leg)
	var left := 170.0
	var right := size.x - 70.0
	var top := 170.0
	var bottom := size.y - 90.0
	var max_min := 50.0
	var x_of := func(sec: float) -> float: return left + (right - left) * clampf(sec / 60.0 / max_min, 0.0, 1.0)
	var tiers := range(3, SizeRules.SPECIES.size())
	var row_h := (bottom - top) / tiers.size()
	var lane_h := minf(19.0, (row_h - 8.0) / lanes.size())
	for m in range(0, int(max_min) + 1, 5):
		var x: float = x_of.call(m * 60.0)
		draw_line(Vector2(x, top), Vector2(x, bottom), GRID if m > 0 else BASE, 1.0)
		_text(Vector2(x - 20, bottom + 26), "%d" % m, 15, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 40)
	draw_line(Vector2(left, bottom), Vector2(right, bottom), BASE, 1.0)
	_text(Vector2(left, bottom + 58), "Run time (minutes); runs stop at 50 min", 16, INK2)
	var targets := {SizeRules.species_index(&"pigeon"): [5.0, 8.0], SizeRules.species_index(&"eagle"): [20.0, 30.0]}
	var margin_used := false
	for k in tiers.size():
		var t: int = tiers[k]
		var yc := top + row_h * (k + 0.5)
		if k > 0:
			draw_line(Vector2(left, top + row_h * k), Vector2(right, top + row_h * k), GRID, 1.0)
		_text(Vector2(40, yc + 6), SizeRules.SPECIES[t]["name"], 18, INK, HORIZONTAL_ALIGNMENT_RIGHT, left - 60)
		if targets.has(t):
			var a: float = x_of.call(targets[t][0] * 60.0)
			var b: float = x_of.call(targets[t][1] * 60.0)
			draw_rect(Rect2(a, top + row_h * k + 3, b - a, row_h - 6), NEUTRAL)
			_text(Vector2(a, top + row_h * k + 14), "%d-%d" % [targets[t][0], targets[t][1]], 12, MUTED, HORIZONTAL_ALIGNMENT_CENTER, b - a)
		for si in lanes.size():
			var raw := _raw(lanes[si][0])
			var q := _tier_stats(raw, t)
			if q.is_empty():
				continue
			var y := yc + (si - (lanes.size() - 1) * 0.5) * lane_h
			var col: Color = lanes[si][1]
			var q25 := float(q["q25"])
			var q75 := float(q["q75"])
			if is_finite(q25):
				var xa: float = x_of.call(q25)
				var xb: float = x_of.call(q75) if is_finite(q75) else right
				var bar := col
				bar.a = 0.35
				draw_line(Vector2(xa, y), Vector2(maxf(xb, xa + 1.0), y), bar, 6.0, true)
			for r: Dictionary in raw:
				var at := _f(r["tier_at"].get(str(t)))
				if at <= max_min * 60.0:
					_diamond(Vector2(x_of.call(at), y + lane_h * 0.42), 3.0, col)
			var med := float(q["median"])
			if is_finite(med) and med <= max_min * 60.0:
				_dot(Vector2(x_of.call(med), y), 5.5, col)
				if lanes[si][0] in ["competent", "quest"]:
					# On a surface pill beside the dot, inside its lane.
					var lbl := _mmss(med)
					var lw := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
					var lx: float = x_of.call(med) + 10.0
					draw_rect(Rect2(lx - 3.0, y - 7.0, lw + 6.0, 12.0), SURFACE)
					_text(Vector2(lx, y + 4.0), lbl, 13, col.darkened(0.25))
			else:
				_text(Vector2(right + 6, y + 5), "%d%%" % roundi(float(q["reached"]) * 100.0), 12, MUTED)
				margin_used = true
			if lanes[si][0] == "competent":
				# The same skill in the mirror sky (a snapshot of the AI).
				var mq: Dictionary = _mirror.get("competent", {}).get("tiers", {}).get(str(t), {})
				var mm := _f(mq.get("median"))
				if is_finite(mm) and mm <= max_min * 60.0:
					draw_arc(Vector2(x_of.call(mm), y), 6.0, 0.0, TAU, 24, col, 2.0, true)
	var comp := _raw("competent")
	var pig := float(_tier_stats(comp, SizeRules.species_index(&"pigeon")).get("median", INF))
	var eag := float(_tier_stats(comp, SizeRules.species_index(&"eagle")).get("median", INF))
	var head := "Competent median: pigeon %s, eagle %s" % [_mmss(pig), _mmss(eag)]
	if lanes.size() > 3:
		var qr := _raw("quest")
		head += "  |  Quest tier: %s, %s" % [_mmss(float(_tier_stats(qr, SizeRules.species_index(&"pigeon")).get("median", INF))),
			_mmss(float(_tier_stats(qr, SizeRules.species_index(&"eagle")).get("median", INF)))]
	_text(Vector2(size.x - 760, 58), head, 20, INK, HORIZONTAL_ALIGNMENT_RIGHT, 710)
	if margin_used:
		_text(Vector2(size.x - 760, 100), "right margin: share of runs that get there, where the median does not", 14, MUTED, HORIZONTAL_ALIGNMENT_RIGHT, 710)


# ------------------------------------------------------------------ danger

func _draw_danger() -> void:
	_title("Being eaten happens, and is avoidable",
			"The same runs in the AI's sky in the shipped valley: deaths per run (each dot one run, bar = median), and how runs ended.")
	var lanes := _lanes()
	var leg := []
	for ln: Array in lanes:
		leg.append([ln[1], ln[2]])
	_legend(48, 132, leg)
	# Panel 1: deaths per run, a dot strip per skill.
	var left := 220.0
	var right := size.x * 0.55
	var top := 190.0
	var bottom := size.y - 110.0
	# The axis covers every run (lives come back with new tiers, so a run
	# can die more than 3 times).
	var dmax := 6
	for ln: Array in lanes:
		for r: Dictionary in _raw(ln[0]):
			dmax = maxi(dmax, int(r["deaths"]))
	var x_of := func(d: float) -> float: return left + (right - left) * d / dmax
	_text(Vector2(left, top - 14), "Deaths per run", 17, INK2)
	for d in range(0, dmax + 1):
		var x: float = x_of.call(float(d))
		draw_line(Vector2(x, top), Vector2(x, bottom), GRID if d > 0 else BASE, 1.0)
		_text(Vector2(x - 20, bottom + 26), "%d" % d, 15, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 40)
	_text(Vector2(left + (right - left) * 0.5 - 150, bottom + 58), "3 deaths end a run (lives); a new tier, or 5 worthwhile catches, give one back", 14, MUTED)
	var row_h := (bottom - top) / lanes.size()
	for si in lanes.size():
		var yc := top + row_h * (si + 0.5)
		var lbl: String = "Competent,\nQuest tier" if lanes[si][0] == "quest" else String(lanes[si][0]).capitalize()
		var lines := lbl.split("\n")
		for li in lines.size():
			_text(Vector2(40, yc + 6 + (li - (lines.size() - 1) * 0.5) * 22.0), lines[li], 18, INK, HORIZONTAL_ALIGNMENT_RIGHT, left - 60)
		var raw := _raw(lanes[si][0])
		var totals := {}
		for r: Dictionary in raw:
			totals[int(r["deaths"])] = int(totals.get(int(r["deaths"]), 0)) + 1
		var counts := {}
		var ds: Array[float] = []
		# Dots stack in columns of PER_COL, the columns side by side round the
		# value, so 70 runs stay inside their row.
		const PER_COL := 9
		for r: Dictionary in raw:
			var d := int(r["deaths"])
			ds.append(float(d))
			var k := int(counts.get(d, 0))
			counts[d] = k + 1
			var n := int(totals[d])
			var cols := (n + PER_COL - 1) / PER_COL
			var rows := mini(n, PER_COL)
			var cx: float = x_of.call(float(d)) + (float(k / PER_COL) - (cols - 1) * 0.5) * 9.0
			var cy := yc - (rows - 1) * 4.5 + (k % PER_COL) * 9.0
			_dot(Vector2(cx, cy), 4.0, lanes[si][1])
		ds.sort()
		var med := -1.0
		if not ds.is_empty():
			med = ds[ds.size() / 2] if ds.size() % 2 == 1 else (ds[ds.size() / 2 - 1] + ds[ds.size() / 2]) * 0.5
		if med >= 0.0:
			var xm: float = x_of.call(med)
			var hh := minf(44.0, row_h * 0.45)
			draw_line(Vector2(xm, yc - hh), Vector2(xm, yc + hh), INK, 2.0)
			_text(Vector2(xm + 6, yc + hh), "median %s" % str(med), 13, INK2)
	# Panel 2: how runs ended (share of runs), one bar group per skill.
	var l2 := size.x * 0.62
	var r2 := size.x - 70.0
	_text(Vector2(l2, top - 14), "How runs ended (share of runs)", 17, INK2)
	var kinds := [["victory", "won the apex goal"], ["caught", "lost every life"], ["time", "still going at 50 min"]]
	var gh := (bottom - top) / lanes.size()
	var bh := minf(30.0, gh / 3.4)
	for si in lanes.size():
		var raw := _raw(lanes[si][0])
		var n := maxf(raw.size(), 1.0)
		var y0 := top + gh * (si + 0.5) - bh * 1.35  # centred on the deaths row
		for ki in kinds.size():
			var c := 0
			for r: Dictionary in raw:
				if r["end_reason"] == kinds[ki][0]:
					c += 1
			var w := (r2 - l2 - 150) * c / n
			var yb := y0 + ki * bh
			var col: Color = lanes[si][1]
			if kinds[ki][0] == "caught":
				col = CRITICAL
			elif kinds[ki][0] == "time":
				col = BASE
			if w > 0.0:
				draw_rect(Rect2(l2, yb, maxf(w, 3.0), bh * 0.68), col)
			_text(Vector2(l2 + maxf(w, 3.0) + 8, yb + bh * 0.55), "%d/%d %s" % [c, int(n), kinds[ki][1]], 14, INK2)
	_legend(l2, size.y - 50, [[CRITICAL, "lost every life", "bar"], [BASE, "still going", "bar"]])


# ------------------------------------------------------------------ cadence

## The gaps between a run's catches (s): from the start, between catches,
## and to the end unless the run ended on its winning catch.
static func _gaps(r: Dictionary) -> Array[float]:
	var out: Array[float] = []
	var prev := 0.0
	for c: Array in r.get("catch_log", []):
		out.append(float(c[0]) - prev)
		prev = float(c[0])
	if String(r["end_reason"]) != "victory":
		out.append(_f(r["ended_at"]) - prev)
	return out


func _draw_cadence() -> void:
	var n_all := 0
	for sk in SKILLS:
		n_all += _raw(sk).size()
	_title("Catches come steadily",
			"Every valley run (%d; competent = tuning and held-out seeds): one row per run, a tick per catch. The shaded stretch is the run's longest dry spell, its length on the right." % n_all)
	_legend(48, 132, [[SERIES[0], "novice"], [SERIES[1], "competent"], [SERIES[2], "expert"],
			[BASE, "longest dry spell", "bar"], [INK, "won the apex goal", "diamond"]])
	var left := 250.0
	var right := size.x - 110.0
	var top := 160.0
	var bottom := size.y - 80.0
	var max_min := 50.0
	var x_of := func(sec: float) -> float: return left + (right - left) * clampf(sec / 60.0 / max_min, 0.0, 1.0)
	var gap_rows := 1.5
	var rows := float(n_all) + gap_rows * (SKILLS.size() - 1) / 1.0
	var row_h := (bottom - top) / maxf(rows, 1.0)
	for m in range(0, int(max_min) + 1, 5):
		var x: float = x_of.call(m * 60.0)
		draw_line(Vector2(x, top - 6), Vector2(x, bottom), GRID if m > 0 else BASE, 1.0)
		_text(Vector2(x - 20, bottom + 24), "%d" % m, 15, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 40)
	_text(Vector2(left, bottom + 52), "Run time (minutes); runs stop at 50 min or when the apex goal is won", 15, INK2)
	# The right strip: each run's longest dry spell, 0-20 minutes.
	var strip_w := size.x - right - 30.0
	_text(Vector2(right + 6, top - 26), "longest dry", 12, MUTED)
	_text(Vector2(right + 6, top - 12), "spell, min", 12, MUTED)
	for m in [0, 10, 20]:
		var sx: float = right + 14.0 + strip_w * float(m) / 20.0
		draw_line(Vector2(sx, top - 4), Vector2(sx, bottom), GRID if m > 0 else BASE, 1.0)
		_text(Vector2(sx - 12, bottom + 24), "%d" % m, 12, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 24)
	var y := top
	for si in SKILLS.size():
		var raw := _raw(SKILLS[si])
		raw.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["seed"]) < int(b["seed"]))
		var longest: Array[float] = []
		var catches := 0
		var played := 0.0
		for r: Dictionary in raw:
			var g := _gaps(r)
			longest.append(g.max() if not g.is_empty() else 0.0)
			catches += int(r["catches"])
			played += _f(r["ended_at"])
		var ls := longest.duplicate()
		ls.sort()
		var med := 0.0
		if not ls.is_empty():
			med = ls[ls.size() / 2] if ls.size() % 2 == 1 else (ls[ls.size() / 2 - 1] + ls[ls.size() / 2]) * 0.5
		var y0 := y
		for k in raw.size():
			var r: Dictionary = raw[k]
			var yc := y + row_h * 0.5
			var end: float = x_of.call(_f(r["ended_at"]))
			draw_line(Vector2(left, yc), Vector2(end, yc), GRID, 1.0)
			# The longest dry spell, as a band behind the ticks.
			var prev := 0.0
			var best := -1.0
			var best_at := 0.0
			for c: Array in r.get("catch_log", []):
				if float(c[0]) - prev > best:
					best = float(c[0]) - prev
					best_at = prev
				prev = float(c[0])
			if String(r["end_reason"]) != "victory" and _f(r["ended_at"]) - prev > best:
				best = _f(r["ended_at"]) - prev
				best_at = prev
			if best > 0.0:
				var xa: float = x_of.call(best_at)
				var xb: float = x_of.call(best_at + best)
				draw_rect(Rect2(xa, yc - row_h * 0.42, maxf(xb - xa, 1.0), row_h * 0.84), NEUTRAL)
				draw_rect(Rect2(xa, yc - row_h * 0.42, maxf(xb - xa, 1.0), row_h * 0.84), BASE, false, 1.0)
			for c: Array in r.get("catch_log", []):
				var xc: float = x_of.call(float(c[0]))
				draw_line(Vector2(xc, yc - row_h * 0.38), Vector2(xc, yc + row_h * 0.38), SERIES[si], 2.0)
			if String(r["end_reason"]) == "victory":
				_diamond(Vector2(end + 8.0, yc), minf(row_h * 0.4, 6.0), INK)
			# The longest dry spell on the right, as a mark on its own 0-20
			# minute axis (fix round 5 review: 110 numbers in 6-px rows ran
			# into an unreadable column).
			var dx := right + 14.0 + (strip_w) * clampf(best / 60.0 / 20.0, 0.0, 1.0)
			draw_line(Vector2(dx - 1.5, yc), Vector2(dx + 1.5, yc), SERIES[si], maxf(row_h * 0.8, 2.0))
			y += row_h
		# Group label, on the left, centred on its rows.
		var gy := (y0 + y) * 0.5
		_text(Vector2(24, gy - 4), SKILLS[si].capitalize(), 18, INK, HORIZONTAL_ALIGNMENT_RIGHT, left - 40)
		_text(Vector2(8, gy + 16), "median longest dry spell %.1f min" % (med / 60.0), 13, INK2, HORIZONTAL_ALIGNMENT_RIGHT, left - 24)
		_text(Vector2(24, gy + 32), "%.2f catches / min" % (catches / maxf(played / 60.0, 1e-6)), 13, INK2, HORIZONTAL_ALIGNMENT_RIGHT, left - 40)
		y += row_h * gap_rows / 1.0 if si < SKILLS.size() - 1 else 0.0


# ------------------------------------------------------------------ duel mirror

func _draw_duel_mirror() -> void:
	_title("The simulations' birds hunt and flee like the AI's",
			"The AI area's own duel test (a hunter 55-90%% of its range away, raptors from above in half; strict catch rule), run with the game loop's AI mirror. %d trials per pair." % int(_duels.get("trials", 0)))
	_legend(48, 132, [[INK2, "AI area's measurement (hunt_duel_test)"], [SERIES[0], "game-loop mirror (SimBrains on SimFlight)"]])
	if _duels.is_empty():
		return
	var pairs: Array = _duels["pairs"]
	var ai: Array = _duels["ai_flee"]
	var mir: Dictionary = _duels["flee_strict"]["pairs"]
	var left := 260.0
	var right := size.x * 0.55
	var top := 200.0
	var bottom := size.y - 110.0
	var x_of := func(v: float) -> float: return left + (right - left) * v
	_text(Vector2(left, top - 16), "Share of chases that end in a catch, prey fleeing", 17, INK2)
	for v in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var x: float = x_of.call(v)
		draw_line(Vector2(x, top), Vector2(x, bottom), GRID if v > 0.0 else BASE, 1.0)
		_text(Vector2(x - 24, bottom + 26), "%d%%" % roundi(v * 100.0), 15, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 48)
	var rows := pairs.size() + 1
	var rh := (bottom - top) / rows
	for i in rows:
		var yc := top + rh * (i + 0.5)
		var label := "overall" if i == pairs.size() else String(pairs[i]).replace(">", " hunts ")
		var a := 0.0
		var m := 0.0
		if i == pairs.size():
			for v in ai:
				a += float(v) / ai.size()
			m = float(_duels["flee_strict"]["overall"])
		else:
			a = float(ai[i])
			m = float(mir[pairs[i]]["rate"])
		_text(Vector2(30, yc + 6), label, 17, INK, HORIZONTAL_ALIGNMENT_RIGHT, left - 50)
		draw_line(Vector2(x_of.call(a), yc), Vector2(x_of.call(m), yc), BASE, 2.0)
		_dot(Vector2(x_of.call(a), yc), 6.0, INK2)
		_dot(Vector2(x_of.call(m), yc), 6.0, SERIES[0])
		_text(Vector2(right + 12, yc + 6), "AI %d%%  mirror %d%%" % [roundi(a * 100.0), roundi(m * 100.0)], 14, INK2)
	var calm := float(_duels["calm_strict"]["overall"])
	_text(Vector2(left, bottom + 58), "Prey that does not flee: mirror catches %d%% (AI 98%%)." % roundi(calm * 100.0), 14, MUTED)
	# Flight paths (top view) of a few mirror duels.
	var paths: Dictionary = _duels.get("paths", {})
	var keys := paths.keys()
	var pw := (size.x - right - 260) / 2.0
	var ph := (bottom - top) / 2.0 - 20
	for k in mini(keys.size(), 4):
		var px := right + 230 + (k % 2) * pw
		var py := top + (k / 2) * (ph + 30)
		var d: Dictionary = paths[keys[k]]
		draw_rect(Rect2(px, py, pw - 20, ph), NEUTRAL)
		_text(Vector2(px + 8, py + 20), "%s: %s, %.1f s" % [String(keys[k]).replace(">", " vs "), d["reason"], float(d["t"])], 12, INK2)
		_path(d["hunter"], d["prey"], Rect2(px + 8, py + 28, pw - 36, ph - 36))
	_legend(right + 230, bottom + 30, [[CRITICAL, "hunter", "bar"], [SERIES[0], "prey", "bar"]])


func _path(h: Array, q: Array, box: Rect2) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Array in h + q:
		lo = lo.min(Vector2(p[0], p[2]))
		hi = hi.max(Vector2(p[0], p[2]))
	var span := maxf(maxf(hi.x - lo.x, hi.y - lo.y), 10.0)
	var c := (lo + hi) * 0.5
	var sc := minf(box.size.x, box.size.y) / span
	var to := func(p: Array) -> Vector2: return box.get_center() + (Vector2(p[0], p[2]) - c) * sc
	for pair in [[q, SERIES[0]], [h, CRITICAL]]:
		var pts := PackedVector2Array()
		for p: Array in pair[0]:
			pts.append(to.call(p))
		if pts.size() > 1:
			draw_polyline(pts, pair[1], 2.0, true)
			_dot(pts[0], 4.0, pair[1])
	_text(Vector2(box.position.x, box.end.y + 2), "%.0f m across" % span, 12, MUTED)


# ------------------------------------------------------------------ loop shift

func _draw_loop_shift() -> void:
	_title("The menu moves up the ladder as you grow",
			"Blue = worth chasing (meal value >= %d%%, darker = more). Number = how much one catch actually grows you: meals shrink with smaller prey and with your size." % int(SizeRules.WORTH_MIN * 100.0))
	var n := SizeRules.SPECIES.size()
	var first_row := SizeRules.species_index(&"sparrow")
	var left := 230.0
	var top := 190.0
	var cw := (size.x - left - 60.0) / n
	var ch := (size.y - top - 110.0) / (n - first_row)
	_text(Vector2(left, top - 44), "... catching a", 16, INK2)
	_text(Vector2(48, top - 12), "You are a ...", 16, INK2)
	for j in n:
		_text(Vector2(left + cw * j, top - 14), SizeRules.SPECIES[j]["name"], 16, INK, HORIZONTAL_ALIGNMENT_CENTER, cw)
	var max_w := SizeRules.meal_value(1.0, 1.0 / SizeRules.EAT_RATIO)
	for i in range(first_row, n):
		var y := top + ch * (i - first_row)
		var pm: float = SizeRules.SPECIES[i]["mass"]
		_text(Vector2(40, y + ch * 0.5 + 6), SizeRules.SPECIES[i]["name"], 17, INK, HORIZONTAL_ALIGNMENT_RIGHT, left - 60)
		for j in n:
			var qm: float = SizeRules.SPECIES[j]["mass"]
			var r := Rect2(left + cw * j + 1, y + 1, cw - 2, ch - 2)  # 2px surface gap between cells
			if SizeRules.is_worthwhile(pm, qm):
				var v := SizeRules.meal_value(pm, qm)
				var w := SizeRules.meal_worth(pm, qm)
				var t := 0.25 + 0.75 * log(v / SizeRules.WORTH_MIN) / log(max_w / SizeRules.WORTH_MIN)
				var col := _seq(t)
				draw_rect(r, col)
				_text(Vector2(r.position.x, r.get_center().y + 7), ("+%d%%" % roundi(w * 100.0)) if w >= 0.01 else ("+%.1f%%" % (w * 100.0)), 19,
						Color.WHITE if t > 0.55 else INK, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
			elif SizeRules.can_eat(pm, qm):
				# Edible but not worth chasing: no number (fix round 5 review:
				# a grey "+2.0%" - its growth - read against the legend's
				# "meal value >= 2%" as if it were worth chasing).
				draw_rect(r, NEUTRAL)
				_text(Vector2(r.position.x, r.get_center().y + 6), "dust", 15, MUTED, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
			elif SizeRules.can_eat(qm, pm):
				draw_rect(r, CRITICAL)
				_text(Vector2(r.position.x, r.get_center().y + 6), "! eats you", 15, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
			else:
				draw_rect(r, SURFACE)
				draw_rect(r, GRID, false, 1.0)
				_text(Vector2(r.position.x, r.get_center().y + 6), "peer", 14, MUTED, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	var ly := size.y - 50.0
	_legend(left, ly, [[_seq(0.3), "worthwhile (darker = worth more)", "bar"], [NEUTRAL, "dust: edible, meal value under %d%%" % int(SizeRules.WORTH_MIN * 100.0), "bar"],
			[CRITICAL, "can eat you", "bar"], [GRID, "neither can eat the other (peer)", "box"]])


# ------------------------------------------------------------------ threat

## A hawk approaches a sparrow-sized player from 40 m at 10 m/s with 35 cm /
## 1.4 m/s tracking noise and turns away ~1 s from contact: what the loop
## reports each frame.
func _threat_scenario() -> Dictionary:
	var loop := GameLoop.new()
	loop.auto_step = false
	loop.verbose = false
	loop.records_path = "user://gameloop_shots_records.json"
	add_child(loop)
	var p := SimBird.new()
	p.player_mode = true
	add_child(p)
	loop.start_run()
	loop.set_protection(p, 600.0)
	var hawk := SimBird.new()
	hawk.mass = 1.6
	add_child(hawk)
	hawk.target = p  # hunting the player (the cue reads intent)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var dt := 1.0 / 72.0
	var pos := p.get_body_position() + Vector3(0, 0, -40)
	var vel := Vector3(0, 0, 10)
	var out := {"t": [], "raw": [], "level": [], "ttc": [], "emit_t": [], "emit_v": []}
	var now := [0.0]  # lambdas capture locals by value; share time through an array
	var cb := func(lv: float, _b: Bird) -> void:
		out["emit_t"].append(now[0])
		out["emit_v"].append(lv)
	Events.threat_changed.connect(cb)
	for i in int(8.0 / dt):
		var t := i * dt
		now[0] = t
		if t > 3.0:
			vel = vel.lerp(Vector3(10, 0, -4), 0.05)
		pos += vel * dt
		var jit := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.35
		hawk.global_position = pos + jit
		hawk.velocity = vel + jit * 4.0
		hawk.set_heading(vel)
		loop.step(dt)
		out["t"].append(t)
		out["raw"].append(loop.watch.raw_level)
		out["level"].append(loop.watch.level)
		out["ttc"].append(loop.watch.predator_ttc if loop.watch.predator != null else INF)
	Events.threat_changed.disconnect(cb)
	loop.queue_free()
	p.queue_free()
	hawk.queue_free()
	await get_tree().process_frame
	return out


func _draw_threat() -> void:
	_title("Danger cue: stable, and ordered by time-to-contact",
			"A hawk hunting a sparrow-sized player closes at 10 m/s with tracking noise (35 cm, 1.4 m/s), then turns away. ThreatWatch output each frame.")
	_legend(48, 132, [[BASE, "raw level (worst predator, this frame)", "bar"], [SERIES[0], "reported level (fast attack, slow release)"],
			[SERIES[1], "Events.threat_changed emitted", "diamond"]])
	var left := 120.0
	var right := size.x - 60.0
	var ts: Array = _threat.get("t", [])
	if ts.is_empty():
		return
	var tmax := 8.0
	var x_of := func(t: float) -> float: return left + (right - left) * t / tmax
	# Panel 1: level 0..1.
	var t1 := 170.0
	var b1 := 520.0
	for v in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var y: float = b1 - (b1 - t1) * v
		draw_line(Vector2(left, y), Vector2(right, y), GRID if v > 0.0 else BASE, 1.0)
		_text(Vector2(left - 60, y + 5), "%.2f" % v, 14, MUTED, HORIZONTAL_ALIGNMENT_RIGHT, 50)
	_text(Vector2(left, t1 - 12), "Threat level", 16, INK2)
	var raw := PackedVector2Array()
	var lvl := PackedVector2Array()
	for i in ts.size():
		raw.append(Vector2(x_of.call(ts[i]), b1 - (b1 - t1) * float(_threat["raw"][i])))
		lvl.append(Vector2(x_of.call(ts[i]), b1 - (b1 - t1) * float(_threat["level"][i])))
	draw_polyline(raw, BASE, 1.2, true)
	draw_polyline(lvl, SERIES[0], 2.0, true)
	var et: Array = _threat["emit_t"]
	var ev: Array = _threat["emit_v"]
	for i in et.size():
		_diamond(Vector2(x_of.call(et[i]), b1 - (b1 - t1) * float(ev[i])), 3.5, SERIES[1])
	_text(Vector2(x_of.call(3.0) + 6, t1 + 18), "hawk turns away", 14, MUTED)
	draw_line(Vector2(x_of.call(3.0), t1), Vector2(x_of.call(3.0), size.y - 90), MUTED, 1.0)
	_text(Vector2(right - 470, t1 + 18), "%d emissions over 8 s (quantised to 0.02; not every frame)" % et.size(), 14, INK2)
	# Panel 2: time to contact.
	var t2 := 590.0
	var b2 := size.y - 90.0
	var ttc_max := 5.0
	for v in [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]:
		var y: float = b2 - (b2 - t2) * v / ttc_max
		draw_line(Vector2(left, y), Vector2(right, y), GRID if v > 0.0 else BASE, 1.0)
		_text(Vector2(left - 60, y + 5), "%d s" % v, 14, MUTED, HORIZONTAL_ALIGNMENT_RIGHT, 50)
	var yh := b2 - (b2 - t2) * GameLoop.CUE_HORIZON_S / ttc_max
	draw_line(Vector2(left, yh), Vector2(right, yh), MUTED, 1.0)
	_text(Vector2(right - 420, yh - 6), "%.1f s horizon for a sparrow (longer for bigger birds)" % GameLoop.CUE_HORIZON_S, 14, MUTED)
	_text(Vector2(left, t2 - 12), "Time to contact (s): shorter = more dangerous", 16, INK2)
	var seg := PackedVector2Array()
	for i in ts.size():
		var v := float(_threat["ttc"][i])
		if is_finite(v) and v <= ttc_max:
			seg.append(Vector2(x_of.call(ts[i]), b2 - (b2 - t2) * v / ttc_max))
		elif seg.size() > 1:
			draw_polyline(seg, SERIES[0], 2.0, true)
			seg = PackedVector2Array()
		else:
			seg = PackedVector2Array()
	if seg.size() > 1:
		draw_polyline(seg, SERIES[0], 2.0, true)
	for s in range(0, 9):
		_text(Vector2(x_of.call(float(s)) - 20, b2 + 24), "%d s" % s, 14, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 40)


## The fix round 4 case: a hawk hunting a sparrow-sized player attacks,
## jinks twice (0.8 s across and away, its own threat 0) and leaves; two
## crows merely passing sit nearby at a small threat of their own; then a
## second hawk stoops in. Each frame: every bird's own smoothed level, the
## level the cue reports and whom it names - and whom round 3's rule would
## have named, re-enacted from the same per-bird raw threats (its level was
## the low-passed worst raw threat; its name held only while the named
## bird's raw threat stayed above 0, else the worst bird took it).
## The danger cue through an attack (fix round 5): hawk A attacks a
## sparrow-sized player, jinks twice (0.8 s each, its own threat 0) and
## leaves; crow 1 flies at something beside the player (not hunting it, its
## own threat shown, ~0.13); crow 2 passes faintly; hawk B stoops in from
## 5 s and presses its attack slowly; hawk C stoops in from behind at 16 m/s
## while B is named. Whom the cue names each frame under this round's rule,
## and - re-enacted on the same per-bird threats - under round 4's (a sticky
## name: a rival needs +0.15 for 0.5 s) and round 3's (the worst raw
## threat, smoothed, the name held while its raw threat stays above 0).
func _naming_scenario() -> Dictionary:
	var loop := GameLoop.new()
	loop.auto_step = false
	loop.verbose = false
	loop.records_path = "user://gameloop_shots_records.json"
	add_child(loop)
	var p := SimBird.new()
	p.player_mode = true
	add_child(p)
	loop.start_run()
	loop.set_protection(p, 600.0)
	p.global_position = Vector3(0, 30, 0)
	p.velocity = Vector3.ZERO
	var mk := func(m: float, pos: Vector3, hunting: bool) -> SimBird:
		var b := SimBird.new()
		b.mass = m
		add_child(b)
		b.global_position = pos
		b.target = p if hunting else null
		return b
	var a: SimBird = mk.call(1.3, Vector3(0, 30, -40), true)
	var b: SimBird = mk.call(1.3, Vector3(-45, 34, -45), true)
	var c: SimBird = mk.call(1.3, Vector3(0, 30, 60), true)
	var c1: SimBird = mk.call(0.5, Vector3(0, 30, 0), false)
	var c2: SimBird = mk.call(0.5, Vector3(-4.5, 31, 3.0), false)
	var birds: Array[SimBird] = [a, b, c, c1, c2]
	var dt := 1.0 / 72.0
	var span := a.get_wingspan()
	var contact := loop.rule.contact_distance(a.get_body_radius(), span, false, p.get_body_radius(), true)
	var hold_gap := (loop.watch.proximity_spans + 1.0) * span + contact
	var cc := loop.rule.contact_distance(c1.get_body_radius(), c1.get_wingspan(), false, p.get_body_radius(), true)
	var out := {"t": [], "own": [[], [], [], [], []], "level": [], "named": [], "r4_level": [], "r4_named": [],
		"old_level": [], "old_named": []}
	var old_level := 0.0
	var old_pred := -1
	var r4 := -1
	var r4_ch := 0.0
	var r4_q := 0.0
	var w := loop.watch
	for i in int(10.0 / dt):
		var t := i * dt
		# Hawk A: attack, jink, attack, jink, leave.
		var av := Vector3.ZERO
		if (t > 2.0 and t < 2.8) or (t > 3.6 and t < 4.4):
			av = Vector3(12, 0, 0)  # the jinks: across and pointed away
		elif t >= 4.4:
			av = Vector3(8, 4, -10)  # leaving
		elif a.global_position.distance_to(p.global_position) > hold_gap:
			av = (p.global_position - a.global_position).normalized() * 12.0
		a.velocity = av
		a.global_position += av * dt
		a.set_heading(av if av != Vector3.ZERO else Vector3.BACK)
		if (t > 2.0 and t < 2.8) or (t > 3.6 and t < 4.4):
			a.set_heading(Vector3(1, 0, -1).normalized())
		# Hawk B: circles far off, stoops from 5 s, then presses its attack
		# from 20 m: held there, closing at a speed that keeps its
		# time-to-contact at 1.6 s (a steady threat, as in threat_test).
		var to_b := p.global_position - b.global_position
		var bv := Vector3(6, 0, 0)
		if t >= 5.0:
			if to_b.length() > 20.0:
				bv = to_b.normalized() * 15.0
				b.global_position += bv * dt
			else:
				bv = to_b.normalized() * (to_b.length() - contact) / 1.6
		else:
			b.global_position += bv * dt
		b.velocity = bv
		b.set_heading(to_b if t >= 5.0 else bv)
		# Hawk C: waits 60 m behind, stoops from 6.5 s at 16 m/s.
		var to_c := p.global_position - c.global_position
		var cv := Vector3.ZERO
		if t >= 6.5 and to_c.length() > contact + 0.6:
			cv = to_c.normalized() * 16.0
		c.velocity = cv
		c.global_position += cv * dt
		c.set_heading(to_c)
		# Crow 1 flies at a moth beside the player (held in place).
		c1.global_position = Vector3(cc + 6.0, 30, 0)
		c1.velocity = Vector3(-3.0, 0, 0)
		c1.set_heading(Vector3.LEFT)
		loop.step(dt)
		out["t"].append(t)
		var own: Array[float] = []
		var raws: Array[float] = []
		for k in birds.size():
			own.append(w.level_of(birds[k]))
			raws.append(w.raw_of(birds[k]))
			(out["own"][k] as Array).append(own[k])
		out["level"].append(w.level)
		out["named"].append(birds.find(w.predator))
		# Round 4's rule, re-enacted on the same per-bird levels.
		var cur_l := own[r4] if r4 >= 0 else 0.0
		var riv := -1
		for k in birds.size():
			if k != r4 and (riv < 0 or own[k] > own[riv]):
				riv = k
		var riv_l := own[riv] if riv >= 0 else 0.0
		r4_q = r4_q + dt if cur_l < ThreatWatch.QUIET_LEVEL else 0.0
		r4_ch = r4_ch + dt if r4 >= 0 and riv_l > cur_l + w.switch_margin else 0.0
		var take := false
		if riv >= 0 and riv_l > 0.0:
			if r4 < 0:
				take = true
			elif raws[riv] < ThreatWatch.QUIET_LEVEL:
				take = false
			elif cur_l < ThreatWatch.QUIET_LEVEL and riv_l >= w.announce_level:
				take = true
			elif r4_ch >= w.switch_hold_s - 1e-9:
				take = true
			elif r4_q >= w.switch_hold_s - 1e-9 and riv_l > cur_l:
				take = true
		if take:
			r4 = riv
			r4_ch = 0.0
			r4_q = 0.0
		elif r4 >= 0 and own[r4] <= 0.0:
			r4 = -1
		out["r4_named"].append(r4)
		out["r4_level"].append(own[r4] if r4 >= 0 else 0.0)
		# Round 3's rule, re-enacted on the same raw threats.
		var best := -1
		var best_raw := 0.0
		for k in birds.size():
			if raws[k] > best_raw:
				best_raw = raws[k]
				best = k
		var chosen := best
		if old_pred >= 0 and raws[old_pred] > 0.0 and best_raw < raws[old_pred] + w.switch_margin:
			chosen = old_pred
		var up := best_raw > old_level
		var al := 1.0 - exp(-dt / (w.rise_tau if up else w.fall_tau))
		old_level = clampf(old_level + (best_raw - old_level) * al, old_level - w.fall_rate * dt, old_level + w.rise_rate * dt)
		if best_raw <= 0.0 and old_level < 0.01:
			old_level = 0.0
		if chosen >= 0 and best_raw > 0.0:
			old_pred = chosen
		if old_level <= 0.0:
			old_pred = -1
		out["old_level"].append(old_level)
		out["old_named"].append(old_pred)
	for n in birds:
		n.queue_free()
	loop.queue_free()
	p.queue_free()
	await get_tree().process_frame
	return out


func _draw_naming() -> void:
	_title("Danger cue: a real attack is named at once, a bystander never",
			"Hawk A attacks, jinks twice (0.8 s, its own threat 0) and leaves; crow 1 flies at something beside the player (shown, not hunting it); hawk B stoops in; hawk C stoops from behind.")
	var ts: Array = _naming.get("t", [])
	if ts.is_empty():
		return
	var names := ["hawk A", "hawk B", "hawk C (from behind)", "crow 1 (not hunting you)", "crow 2 (passing)"]
	var cols := [SERIES[0], SERIES[1], SERIES[2], MUTED, BASE]
	var left := 230.0
	var right := size.x - 60.0
	var tmax := 10.0
	var x_of := func(t: float) -> float: return left + (right - left) * t / tmax
	_legend(48, 132, [[cols[0], names[0]], [cols[1], names[1]], [cols[2], names[2]], [cols[3], names[3]], [cols[4], names[4]]])
	# Panel 1: levels.
	var t1 := 185.0
	var b1 := 470.0
	for v in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var y: float = b1 - (b1 - t1) * v
		draw_line(Vector2(left, y), Vector2(right, y), GRID if v > 0.0 else BASE, 1.0)
		_text(Vector2(left - 60, y + 5), "%.2f" % v, 14, MUTED, HORIZONTAL_ALIGNMENT_RIGHT, 50)
	draw_line(Vector2(left, b1 - (b1 - t1) * 0.3), Vector2(right, b1 - (b1 - t1) * 0.3), Color(CRITICAL, 0.5), 1.0)
	_text(Vector2(right - 150, b1 - (b1 - t1) * 0.3 - 6), "attack strength 0.3", 13, CRITICAL)
	_text(Vector2(left, t1 - 12), "Each bird's own threat (thin) and the level the cue reports this round (thick, in the named bird's colour)", 16, INK2)
	for span_: Array in [[2.0, 2.8], [3.6, 4.4]]:
		draw_rect(Rect2(x_of.call(span_[0]), t1, x_of.call(span_[1]) - x_of.call(span_[0]), b1 - t1), Color(NEUTRAL, 0.9))
		_text(Vector2(x_of.call(span_[0]) + 4, t1 + 18), "jink", 14, MUTED)
	for k in 5:
		var pl := PackedVector2Array()
		for i in ts.size():
			pl.append(Vector2(x_of.call(ts[i]), b1 - (b1 - t1) * float(_naming["own"][k][i])))
		draw_polyline(pl, cols[k], 1.5, true)
	for i in range(1, ts.size()):
		var k := int(_naming["named"][i])
		var col: Color = cols[k] if k >= 0 else BASE
		draw_line(Vector2(x_of.call(ts[i - 1]), b1 - (b1 - t1) * float(_naming["level"][i - 1])),
				Vector2(x_of.call(ts[i]), b1 - (b1 - t1) * float(_naming["level"][i])), col, 4.0, true)
	# Panel 2: whom the cue names, under each rule.
	var rows := [["this round", "named", "level"], ["round 4's rule", "r4_named", "r4_level"], ["round 3's rule", "old_named", "old_level"]]
	var y0 := 530.0
	_text(Vector2(left, y0 - 16), "Whom the cue names (the HUD arrow, the haptics and the predator's call follow it)", 16, INK2)
	for r in rows.size():
		var y := y0 + r * 92.0
		_text(Vector2(48, y + 26), rows[r][0], 16, INK)
		var hops := 0
		var on_crow := 0.0
		var masked := 0.0
		# When hawk C (from behind) is first named, as its time-to-contact
		# then (from its own level: aimed straight in, level = 1 - ttc / 3.5).
		var c_named := "never"
		for i in range(1, ts.size()):
			if int(_naming[rows[r][1]][i]) == 2 and c_named == "never":
				c_named = "%.2f s before contact" % ((1.0 - float(_naming["own"][2][i])) * 3.5)
			var k := int(_naming[rows[r][1]][i])
			var col: Color = cols[k] if k >= 0 else SURFACE
			draw_rect(Rect2(x_of.call(ts[i - 1]), y, x_of.call(ts[i]) - x_of.call(ts[i - 1]) + 0.6, 38), col)
			if k != int(_naming[rows[r][1]][i - 1]) and k >= 0 and int(_naming[rows[r][1]][i - 1]) >= 0:
				hops += 1
			var hawk_attacking := false
			for h in 3:
				hawk_attacking = hawk_attacking or float(_naming["own"][h][i]) >= 0.3
			if k >= 3 and hawk_attacking:
				on_crow += ts[i] - ts[i - 1]
			# A hawk hunting the player at attack strength, unnamed, while the
			# cue reports at least 0.15 less (the review's "masked").
			var shown := float(_naming[rows[r][2]][i])
			for h in 3:
				var lv := float(_naming["own"][h][i])
				if h != k and lv >= 0.3 and lv - shown >= 0.15:
					masked += ts[i] - ts[i - 1]
					draw_rect(Rect2(x_of.call(ts[i - 1]), y + 40, x_of.call(ts[i]) - x_of.call(ts[i - 1]) + 0.6, 6), CRITICAL)
					break
		draw_rect(Rect2(left, y, right - left, 38), BASE, false, 1.0)
		var line := "%d change%s of name; %.1f s naming a crow while a hawk is at attack strength; %.1f s with an attacking hawk masked (red); hawk C named %s" % [
			hops, "" if hops == 1 else "s", on_crow, masked, c_named]
		_text(Vector2(left + 8, y + 66), line, 15, INK2)
	for s in range(0, 11):
		_text(Vector2(x_of.call(float(s)) - 20, y0 + 3.0 * 92.0 + 4.0), "%d s" % s, 14, MUTED, HORIZONTAL_ALIGNMENT_CENTER, 40)


## A dashed polyline (draw_dashed_line per segment run).
func draw_dashed_line_poly(pts: PackedVector2Array, col: Color, width: float) -> void:
	var acc := 0.0
	for i in range(1, pts.size()):
		var seg := pts[i] - pts[i - 1]
		var l := seg.length()
		if fmod(acc, 16.0) < 9.0:
			draw_line(pts[i - 1], pts[i], col, width, true)
		acc += l
