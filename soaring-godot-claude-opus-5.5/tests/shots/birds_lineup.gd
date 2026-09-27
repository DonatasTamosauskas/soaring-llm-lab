extends Node
## B1 visual evidence: every species side by side.
##   lineup_equal_span.png   top / bottom / side / front / perched / 3-4 view,
##                           every bird at wingspan 1.0 (orthographic)
##   lineup_true_scale.png   the ladder at true relative size (3/4 view, 1 m bar)
##
##   tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 \
##       res://tests/shots/birds_lineup.tscn
## Exit 1 if any cell shows no bird.

const Stage := preload("res://tests/shots/birds_stage.gd")
const CELL := 190
const LEFT := 110
const TOP := 40

## Cells that showed no bird (exit 1 if any).
var empty := []


func _ready() -> void:
	var ids := BirdSpecies.IDS
	var rows := [["top", "from above", false], ["bottom", "from below", false], ["side", "side", false],
		["front", "front", false], ["side", "perched", true], ["three_q", "3/4 view", false]]
	var vp := Stage.make(self, Vector2i(CELL, CELL), Stage.BG, 1.14)
	var sheet := Image.create(LEFT + CELL * ids.size(), TOP + CELL * rows.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.97, 0.97, 0.96))
	var labels := []
	for c in ids.size():
		var sp: StringName = ids[c]
		var m := BirdModels.create(sp)
		vp.add_child(m)
		labels.append([String(SizeRules.species_data(sp).get("name", sp)), Vector2(LEFT + c * CELL + 8, 8), 22, Color(0.1, 0.1, 0.1)])
		for r in rows.size():
			var row: Array = rows[r]
			m.perched = row[2]
			m.wing_fold = 1.0 if row[2] else 0.0
			m.flap_amount = 0.0
			m.snap()
			var cam := Stage.cam(vp)
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.size = 1.14 if not row[2] else 0.7
			Stage.aim(vp, row[0], Vector3(0, -0.04, 0) if row[2] else Vector3.ZERO, 4.0)
			var img: Image = await Stage.grab(vp)
			img.convert(Image.FORMAT_RGBA8)
			if Stage.bird_px(img) < 40:
				empty.append("%s %s" % [sp, row[1]])
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(LEFT + c * CELL, TOP + r * CELL))
		m.queue_free()
		await get_tree().process_frame
	for r in rows.size():
		labels.append([rows[r][1], Vector2(8, TOP + r * CELL + CELL / 2 - 14), 20, Color(0.1, 0.1, 0.1)])
	var out: Image = await Stage.annotate(self, sheet, labels)
	Stage.save(out, "lineup_equal_span.png")
	await _true_scale()
	# Every cell must show its bird (exit 1 otherwise: a broken shader or a
	# model that never drew).
	print("[birds] lineup: %d cells, %d empty %s" % [ids.size() * rows.size(), empty.size(), str(empty)])
	get_tree().quit(0 if empty.is_empty() else 1)


## The ladder at true relative scale: every cell is the same 2.3 m wide
## window, each bird at its SizeRules wingspan, glide pose, from above,
## the side and the front, plus perched from the side.
func _true_scale() -> void:
	var ids := BirdSpecies.IDS
	var rows := [["top", "from above", false], ["side", "side", false], ["front", "front", false], ["side", "perched", true]]
	var vp := Stage.make(self, Vector2i(CELL, CELL), Stage.BG, 2.3)
	var sheet := Image.create(LEFT + CELL * ids.size(), TOP + CELL * rows.size() + 30, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.97, 0.97, 0.96))
	var labels := []
	for c in ids.size():
		var sp: StringName = ids[c]
		var span: float = SizeRules.species_data(sp)["span"]
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * span
		m.lod_override = 0
		vp.add_child(m)
		labels.append(["%s %.2f m" % [SizeRules.species_data(sp).get("name", sp), span], Vector2(LEFT + c * CELL + 8, 8), 18, Color(0.1, 0.1, 0.1)])
		for r in rows.size():
			var row: Array = rows[r]
			m.perched = row[2]
			m.wing_fold = 1.0 if row[2] else 0.0
			m.snap()
			Stage.aim(vp, row[0], Vector3.ZERO, 6.0)
			var img: Image = await Stage.grab(vp)
			img.convert(Image.FORMAT_RGBA8)
			# (A moth is ~7 px across in a 2.3 m window.)
			if Stage.bird_px(img) < 4:
				empty.append("true scale %s %s" % [sp, row[1]])
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(LEFT + c * CELL, TOP + r * CELL))
		m.queue_free()
		await get_tree().process_frame
	for r in rows.size():
		labels.append([rows[r][1], Vector2(8, TOP + r * CELL + CELL / 2 - 12), 20, Color(0.1, 0.1, 0.1)])
	labels.append(["True relative scale: every cell is the same 2.3 m window (wingspans from SizeRules).", Vector2(LEFT, TOP + rows.size() * CELL + 4), 18, Color(0.1, 0.1, 0.1)])
	var out: Image = await Stage.annotate(self, sheet, labels)
	Stage.save(out, "lineup_true_scale.png")
