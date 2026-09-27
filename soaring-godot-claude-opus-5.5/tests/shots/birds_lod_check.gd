extends Node
## B3 (LOD): a bird that changes level of detail is drawn in that very frame,
## with the mesh of the LOD it reports, and no other bird blinks.
##
## Rendered frame by frame (every frame is grabbed) while birds cross LOD
## thresholds in the three ways a move can land in another batch:
##   * a sparrow flying out and back across LOD0/LOD1, into a batch that has
##     room (a second sparrow keeps that batch alive),
##   * an eagle flying out and back across LOD1/LOD2, into a batch that does
##     not exist yet (it is created by the move),
##   * a hawk flying out into the LOD1 batch of 8 hawks already there, which
##     must grow (reallocating its GPU data) - the 8 must not blink either.
## Each bird sits on its own line of sight, so its pixels (differing from the
## background) are counted in its own box every frame. A blink is a frame in
## which a bird has under 40% of the pixels of both neighbouring frames. A
## size pop is a switch that changes a bird's pixel count by more than
## MAX_LOD_JUMP in that frame (far LODs are built to cover LOD0's area).
##   lod_check.json   per bird: pixels per frame, LOD per frame, blinks,
##                    the area jump at each switch
##   lod_check.png    the frames before, of and after each LOD change
## Then no ghosts: four of the parked hawks are freed (their batch keeps its
## grown capacity, so slots past the live count hold stale data) and the
## other hawks fly elsewhere: nothing may be drawn where any of them was.
## Exit 1 on any blink, size pop, frame drawing another LOD than reported,
## or ghost.
##
##   tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 \
##       res://tests/shots/birds_lod_check.tscn

const Stage := preload("res://tests/shots/birds_stage.gd")
const W := 640
const H := 360
const FOV := 40.0
const FRAMES := 240
const BG := Color(0.2, 0.62, 0.3)
## Largest one-frame change of a bird's pixel count at a LOD switch.
const MAX_LOD_JUMP := 0.06

var vp: SubViewport
var cam: Camera3D
## [model, label, direction, distance(frame) -> float, box half size px]
var tracks := []


func _ready() -> void:
	vp = Stage.make(self, Vector2i(W, H), BG, 0.0, FOV)
	cam = Stage.cam(vp)
	cam.position = Vector3.ZERO
	cam.rotation = Vector3.ZERO
	cam.far = 1000.0
	# (Span 1 m: LOD0/1 switches near 18-23 m, LOD1/2 near 56-71 m.)
	# Sparrow out and back 12 -> 40 m (LOD0 <-> LOD1), into a batch that has
	# room: a second sparrow keeps that batch alive.
	_track(&"sparrow", "sparrow LOD0<->1 (batch has room)", Vector2(110, 90), func(f: int) -> float: return _pingpong(f, 12.0, 40.0))
	_still(&"sparrow", Vector2(110, 270), 30.0)
	# Eagle 25 -> 90 m: LOD1 <-> LOD2, into a batch the move creates.
	_track(&"eagle", "eagle LOD1<->2 (new batch)", Vector2(290, 90), func(f: int) -> float: return _pingpong(f, 25.0, 90.0))
	# 8 hawks parked at LOD1, one flying in from LOD0: the batch grows 8 -> 16.
	for i in 8:
		_still(&"hawk", Vector2(380 + (i % 4) * 66, 220 + (i / 4) * 80), 40.0, "parked hawk %d (batch grows)" % i)
	_track(&"hawk", "hawk LOD0->1 (batch grows)", Vector2(500, 90), func(f: int) -> float: return 12.0 + minf(f, 120) * 0.25)
	var rows := {}
	for t in tracks:
		rows[t[1]] = {"pixels": [], "lod": [], "drawn_ok": true}
	var lod_frames := {}
	var drawn_bad := 0
	var prev_img: Image = null
	var keep_next := false
	for f in FRAMES:
		for t in tracks:
			var m: BirdModel = t[0]
			var dir: Vector3 = t[2]
			m.position = dir * (t[3] as Callable).call(f)
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		var d := img.get_data()
		for t in tracks:
			var m: BirdModel = t[0]
			var row: Dictionary = rows[t[1]]
			(row["pixels"] as Array).append(_count(d, cam.unproject_position(m.global_position), int(t[4])))
			(row["lod"] as Array).append(m.get_lod())
			if m._batch == null or m._batch.mesh != BirdModels.mesh(m.species, m.get_lod()):
				row["drawn_ok"] = false
				drawn_bad += 1
			var lods: Array = row["lod"]
			if lods.size() > 1 and lods[-1] != lods[-2]:
				if not lod_frames.has(t[1]):
					lod_frames[t[1]] = []
				lod_frames[t[1]].append(f)
		# The frames before, of and after every LOD change (the sheet).
		if _any_change(rows, f):
			_keep(prev_img, f - 1)
			_keep(img, f)
			keep_next = true
		elif keep_next:
			_keep(img, f)
			keep_next = false
		prev_img = img
	# Blinks: a frame with < 40% of both neighbours' pixels.
	var blinks := 0
	var size_pops := []
	var worst_jump := 0.0
	var report := {"frames": FRAMES, "rows": {}}
	for label in rows:
		var px: Array = rows[label]["pixels"]
		var bl := []
		for f in range(1, FRAMES - 1):
			if px[f] < 0.4 * mini(px[f - 1], px[f + 1]):
				bl.append(f)
		blinks += bl.size()
		var changes: Array = lod_frames.get(label, [])
		var around := []
		for c in changes:
			var jump := float(px[c]) / maxf(px[c - 1], 1.0) - 1.0
			around.append({"frame": c, "lod": rows[label]["lod"][c], "pixels_before_at_after": [px[c - 1], px[c], px[mini(c + 1, FRAMES - 1)]],
				"area_jump": snappedf(jump, 0.001)})
			# A LOD switch must not visibly resize the bird: from one frame
			# to the next the silhouette changes by at most MAX_LOD_JUMP
			# (the flight itself moves it 1-2% a frame here), checked where
			# the bird is big enough (>= 80 px) for a percentage to mean it.
			if px[c - 1] >= 80 and absf(jump) > MAX_LOD_JUMP:
				size_pops.append("%s frame %d: %+.1f%%" % [label, c, jump * 100.0])
			worst_jump = maxf(worst_jump, absf(jump) if px[c - 1] >= 80 else 0.0)
		report["rows"][label] = {"lod_changes": around, "blink_frames": bl, "min_pixels": px.min(), "drawn_lod_matches": rows[label]["drawn_ok"]}
		print("[birds] lod %-36s changes %s  blinks %s  min px %d" % [label, str(changes), str(bl), px.min()])
	report["blinks"] = blinks
	report["frames_drawing_another_lod"] = drawn_bad
	report["largest_area_jump_at_a_switch"] = snappedf(worst_jump, 0.001)
	report["area_pops"] = size_pops
	var moves := 0
	for label in lod_frames:
		moves += (lod_frames[label] as Array).size()
	report["lod_changes"] = moves
	var ghosts: Dictionary = await _ghost_check()
	report["ghosts"] = ghosts
	var fa := FileAccess.open(Paths.artifacts("birds").path_join("lod_check.json"), FileAccess.WRITE)
	fa.store_string(JSON.stringify(report, "  "))
	Stage.save(await _sheet(lod_frames), "lod_check.png")
	print("[birds] lod check: %d LOD changes rendered, %d blinks, %d frames drawing another LOD than reported, largest area jump %.1f%% (%d over %.0f%%); ghosts: %d px where removed or moved hawks were (%d slots stale, hawks drawn again %s)" % [moves, blinks, drawn_bad,
		worst_jump * 100.0, size_pops.size(), MAX_LOD_JUMP * 100.0, ghosts["ghost_px"], ghosts["stale_slots"], str(ghosts["moved_px"])])
	var ghost_bad: bool = int(ghosts["ghost_px"]) > 4 or int(ghosts["stale_slots"]) < 4 or (ghosts["moved_px"] as Array).min() < 10
	get_tree().quit(1 if blinks > 0 or drawn_bad > 0 or moves < 5 or not size_pops.is_empty() or ghost_bad else 0)


## Frees 4 of the parked hawks and flies the rest (and the hawk that joined
## them) to another part of the view. The batch keeps its capacity, so the
## GPU buffer still holds stale slots past the live count: if they were
## drawn, hawks would stay where they were. Returns {ghost_px: pixels left in
## the old boxes, stale_slots, moved_px: pixels of each hawk where it went}.
func _ghost_check() -> Dictionary:
	var hawks: Array[BirdModel] = []
	var old_px: Array[Vector2] = []
	for t in tracks:
		var m: BirdModel = t[0]
		if m.species == &"hawk":
			hawks.append(m)
			old_px.append(cam.unproject_position(m.global_position))
	var batch: BirdBatch = hawks[0]._batch
	for i in 4:
		hawks[i].queue_free()
	var moved: Array[BirdModel] = []
	var new_px: Array[Vector2] = []
	for i in range(4, hawks.size()):
		var p := Vector2(40.0 + (i - 4) * 70.0, 170.0)
		hawks[i].position = cam.project_ray_normal(p) * 40.0
		moved.append(hawks[i])
		new_px.append(p)
	for j in 3:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var d := img.get_data()
	var ghost := 0
	for c in old_px:
		ghost += _count(d, c, 30)
	var mp := []
	for c in new_px:
		mp.append(_count(d, c, 30))
	var stale := (batch.capacity - batch.models.size()) if is_instance_valid(moved[0]) and moved[0]._batch == batch else 0
	Stage.save(img, "lod_check_ghosts.png")
	return {"ghost_px": ghost, "stale_slots": stale, "moved_px": mp}


func _pingpong(f: int, a: float, b: float) -> float:
	var k := float(f) / (FRAMES * 0.5)
	return a + (b - a) * (k if k <= 1.0 else 2.0 - k)


## A bird on the line of sight through pixel `px` (so it stays put on screen
## while its distance changes), scale 1 (span 1 m), seen from above.
func _track(sp: StringName, label: String, px: Vector2, dist: Callable) -> void:
	var m := BirdModels.create(sp)
	m.flap_amount = 0.0
	vp.add_child(m)
	m.rotation = Vector3(deg_to_rad(-60.0), 0.0, 0.0)
	tracks.append([m, label, cam.project_ray_normal(px), dist, 30])


func _still(sp: StringName, px: Vector2, dist: float, label: String = "") -> void:
	_track(sp, label if label != "" else "%s parked (keeps the batch)" % sp, px, func(_f: int) -> float: return dist)


func _count(d: PackedByteArray, c: Vector2, r: int) -> int:
	var n := 0
	# The background as rendered (tonemapped), from a corner no bird is near.
	var bg := [d[(2 * W + 2) * 4], d[(2 * W + 2) * 4 + 1], d[(2 * W + 2) * 4 + 2]]
	for y in range(maxi(0, int(c.y) - r), mini(H, int(c.y) + r)):
		for x in range(maxi(0, int(c.x) - r), mini(W, int(c.x) + r)):
			var i := (y * W + x) * 4
			if absi(d[i] - bg[0]) + absi(d[i + 1] - bg[1]) + absi(d[i + 2] - bg[2]) > 30:
				n += 1
	return n


var _kept := {}


func _keep(img: Image, f: int) -> void:
	_kept[f] = img


func _any_change(rows: Dictionary, f: int) -> bool:
	for label in rows:
		var l: Array = rows[label]["lod"]
		if l.size() > 1 and l[-1] != l[-2]:
			return true
	return false


## The frame before, of and after each LOD change, per moving bird.
func _sheet(lod_frames: Dictionary) -> Image:
	var cell := 72
	var labels := []
	var lines := []
	for label in lod_frames:
		for f in lod_frames[label]:
			lines.append([label, f])
	var sheet := Image.create(cell * 3 * 2 + 300, maxi(1, lines.size()) * cell + 20, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	for li in lines.size():
		var label: String = lines[li][0]
		var f: int = lines[li][1]
		var t: Array = []
		for tt in tracks:
			if tt[1] == label:
				t = tt
		labels.append(["%s: frames %d-%d" % [label, f - 1, f + 1], Vector2(4, 20 + li * cell + 26), 11, Color(0.9, 0.9, 0.9)])
		var dir: Vector3 = t[2]
		var c := cam.unproject_position(dir * 20.0)
		for k in 3:
			var fr: int = f - 1 + k
			if not _kept.has(fr):
				continue
			var reg: Image = (_kept[fr] as Image).get_region(Rect2i(Vector2i(c) - Vector2i(18, 18), Vector2i(36, 36)))
			reg.resize(cell - 4, cell - 4, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(reg, Rect2i(0, 0, cell - 4, cell - 4), Vector2i(300 + k * cell * 2, 20 + li * cell))
	labels.append(["before / LOD change frame / after (x2)", Vector2(300, 2), 12, Color(1, 0.85, 0.4)])
	return await Stage.annotate(self, sheet, labels)
