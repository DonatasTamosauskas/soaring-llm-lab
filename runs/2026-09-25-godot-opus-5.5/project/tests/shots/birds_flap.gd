extends Node
## B2 visual evidence (GPU-animated, forward_plus):
##   flap_strip.png  one wingbeat in 10 frames (phase 0 = top of the
##                   upstroke; downstroke = first 42%), front and 3/4 views
##   poses.png       glide, half tuck, full tuck (dive: top, side, behind),
##                   perched (side, top, behind, 35 deg above-behind, 3/4),
##                   bank, for all 10 species: the folded wings lie on the
##                   back and flanks (no gap between wing and body)
##   perched_close.png  every species perched, close up (side, top, behind,
##                   35 deg above-behind, 3/4) and dive-tucked from above and
##                   behind: folded wings on the back, no see-through gaps
##   flap_plot.png   wingtip height over one beat (from BirdPose, the maths the
##                   shader runs): the downstroke is quicker than the upstroke
##
##   tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 \
##       res://tests/shots/birds_flap.tscn

const Stage := preload("res://tests/shots/birds_stage.gd")
const CELL := 170
const LEFT := 150
const TOP := 44


## Cells of the strip that showed no bird (exit 1 if any).
var _empty := []


func _ready() -> void:
	await _strip()
	await _poses()
	await _perched_close()
	await _plot()
	print("[birds] flap: %d empty strip cells %s" % [_empty.size(), str(_empty)])
	get_tree().quit(0 if _empty.is_empty() else 1)


func _strip() -> void:
	var rows := [[&"sparrow", "front"], [&"sparrow", "three_q"], [&"swallow", "front"], [&"gull", "front"],
		[&"eagle", "front"], [&"eagle", "three_q_below"], [&"moth", "three_q"]]
	var n := 10
	var vp := Stage.make(self, Vector2i(CELL, CELL), Stage.BG, 1.25)
	var sheet := Image.create(LEFT + CELL * n, TOP + CELL * rows.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.97, 0.97, 0.96))
	var labels := []
	var m: BirdModel = null
	for r in rows.size():
		var sp: StringName = rows[r][0]
		if m == null or m.species != sp:
			if m:
				m.queue_free()
			m = BirdModels.create(sp)
			vp.add_child(m)
		labels.append(["%s\n%s" % [sp, rows[r][1]], Vector2(8, TOP + r * CELL + CELL / 2 - 26), 20, Color(0.1, 0.1, 0.1)])
		for c in n:
			var ph := float(c) / n
			m.flap_phase = ph
			m.flap_amount = 1.0
			m.snap()
			Stage.aim(vp, rows[r][1], Vector3.ZERO, 4.0)
			var img: Image = await Stage.grab(vp)
			img.convert(Image.FORMAT_RGBA8)
			if Stage.bird_px(img) < 20:
				_empty.append("%s %s %.1f" % [sp, rows[r][1], ph])
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(LEFT + c * CELL, TOP + r * CELL))
	for c in n:
		var ph := float(c) / n
		var tag := "down" if ph < BirdPose.DOWN_FRAC else "up"
		labels.append(["%.1f %s" % [ph, tag], Vector2(LEFT + c * CELL + 40, 8), 20, Color(0.55, 0.1, 0.05) if tag == "down" else Color(0.05, 0.2, 0.55)])
	var out: Image = await Stage.annotate(self, sheet, labels)
	Stage.save(out, "flap_strip.png")
	m.queue_free()
	vp.queue_free()


func _poses() -> void:
	# [label, amount, fold, perched, bank, view]
	var cols := [["glide", 0.0, 0.0, false, 0.0, "three_q"], ["tuck 0.5 (top)", 0.0, 0.5, false, 0.0, "top"],
		["dive tuck (top)", 0.0, 1.0, false, 0.0, "top"], ["dive tuck (side)", 0.0, 1.0, false, 0.0, "side"],
		["dive tuck (behind)", 0.0, 1.0, false, 0.0, "behind"],
		["perched (side)", 0.0, 1.0, true, 0.0, "side"], ["perched (top)", 0.0, 1.0, true, 0.0, "top"],
		["perched (behind)", 0.0, 1.0, true, 0.0, "behind"], ["perched (35° behind)", 0.0, 1.0, true, 0.0, "above_behind"],
		["perched (3/4)", 0.0, 1.0, true, 0.0, "three_q"], ["bank +35 (front)", 0.0, 0.0, false, deg_to_rad(35.0), "front"]]
	var species := BirdSpecies.IDS.duplicate()
	var vp := Stage.make(self, Vector2i(CELL, CELL), Stage.BG, 1.1)
	var sheet := Image.create(LEFT + CELL * cols.size(), TOP + CELL * species.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.97, 0.97, 0.96))
	var labels := []
	for c in cols.size():
		labels.append([cols[c][0], Vector2(LEFT + c * CELL + 8, 10), 18, Color(0.1, 0.1, 0.1)])
	for r in species.size():
		var m := BirdModels.create(species[r])
		vp.add_child(m)
		labels.append([String(species[r]), Vector2(8, TOP + r * CELL + CELL / 2 - 12), 20, Color(0.1, 0.1, 0.1)])
		for c in cols.size():
			var p: Array = cols[c]
			m.flap_amount = p[1]
			m.wing_fold = p[2]
			m.perched = p[3]
			m.bank = p[4]
			m.snap()
			var cam := Stage.cam(vp)
			cam.size = 0.75 if (p[2] as float) > 0.4 else 1.1
			Stage.aim(vp, p[5], Vector3.ZERO, 4.0)
			var img: Image = await Stage.grab(vp)
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(LEFT + c * CELL, TOP + r * CELL))
		m.queue_free()
	var out: Image = await Stage.annotate(self, sheet, labels)
	Stage.save(out, "poses.png")
	vp.queue_free()


## Folded wings close up: the look the perched-wing test measures (the
## folded wing lies on the upper flank and back, the tips converge onto the
## rump), from the views a flying player sees perched birds from.
func _perched_close() -> void:
	var cols := [["perched (side)", true, "side"], ["perched (top)", true, "top"], ["perched (behind)", true, "behind"],
		["perched (35° behind)", true, "above_behind"], ["perched (3/4)", true, "three_q"],
		["dive tuck (top)", false, "top"], ["dive tuck (behind)", false, "behind"]]
	var cell := 250
	var species := BirdSpecies.IDS.duplicate()
	species.erase(&"moth")
	var vp := Stage.make(self, Vector2i(cell, cell), Stage.BG, 0.62)
	# Heads straight ahead (perched birds otherwise glance around).
	BirdModels.material().set_shader_parameter("head_look_amount", 0.0)
	var sheet := Image.create(LEFT + cell * cols.size(), TOP + cell * species.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.97, 0.97, 0.96))
	var labels := []
	for c in cols.size():
		labels.append([cols[c][0], Vector2(LEFT + c * cell + 8, 10), 18, Color(0.1, 0.1, 0.1)])
	for r in species.size():
		var m := BirdModels.create(species[r])
		vp.add_child(m)
		labels.append([String(species[r]), Vector2(8, TOP + r * cell + cell / 2 - 12), 20, Color(0.1, 0.1, 0.1)])
		for c in cols.size():
			m.flap_amount = 0.0
			m.wing_fold = 1.0
			m.perched = cols[c][1]
			m.snap()
			Stage.aim(vp, cols[c][2], Vector3.ZERO, 4.0)
			var img: Image = await Stage.grab(vp)
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(LEFT + c * cell, TOP + r * cell))
		m.queue_free()
	var out: Image = await Stage.annotate(self, sheet, labels)
	Stage.save(out, "perched_close.png")
	BirdModels.material().set_shader_parameter("head_look_amount", 1.0)
	vp.queue_free()


## Wingtip height (right tip, model units) over one beat at full amount,
## from BirdPose, for three species; the downstroke (tip going down) spans
## 0 .. DOWN_FRAC of the cycle.
func _plot() -> void:
	var w := 1000
	var h := 520
	var vp := SubViewport.new()
	vp.size = Vector2i(w, h)
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bg := ColorRect.new()
	bg.color = Color(0.98, 0.98, 0.97)
	bg.size = Vector2(w, h)
	vp.add_child(bg)
	var x0 := 80.0
	var x1 := w - 30.0
	var y0 := 60.0
	var y1 := h - 70.0
	var down := ColorRect.new()
	down.color = Color(1.0, 0.85, 0.8, 0.6)
	down.position = Vector2(x0, y0)
	down.size = Vector2((x1 - x0) * BirdPose.DOWN_FRAC, y1 - y0)
	vp.add_child(down)
	var axis := Line2D.new()
	axis.points = PackedVector2Array([Vector2(x0, y0), Vector2(x0, y1), Vector2(x1, y1)])
	axis.width = 2.0
	axis.default_color = Color(0.2, 0.2, 0.2)
	vp.add_child(axis)
	var colors := [Color(0.75, 0.35, 0.1), Color(0.2, 0.35, 0.8), Color(0.2, 0.2, 0.2)]
	var sps := [&"sparrow", &"gull", &"eagle"]
	var labels := []
	for si in sps.size():
		var rec := BirdModels.tip_record(sps[si])
		var line := Line2D.new()
		line.width = 3.0
		line.default_color = colors[si]
		for i in 201:
			var ph := float(i) / 200.0
			var r := BirdPose.pose(rec[0], rec[1], rec[2], rec[3], rec[4], rec[5], Vector4(ph, 1.0, 0.0, 0.0), 0.0, 0.0, false, rec[6], rec[7])
			var y: float = (r[0] as Vector3).y
			line.add_point(Vector2(lerpf(x0, x1, ph), lerpf(y1, y0, (y + 0.45) / 0.9)))
		vp.add_child(line)
		labels.append([String(sps[si]), Vector2(x1 - 140, y0 + 10 + si * 26), 20, colors[si]])
	labels.append(["Wingtip height (model units, span 1) over one wingbeat", Vector2(x0, 14), 22, Color(0.1, 0.1, 0.1)])
	labels.append(["downstroke %d%% of the beat" % roundi(BirdPose.DOWN_FRAC * 100.0), Vector2(x0 + 20, y1 - 40), 20, Color(0.6, 0.15, 0.05)])
	labels.append(["upstroke %d%%" % roundi((1.0 - BirdPose.DOWN_FRAC) * 100.0), Vector2(lerpf(x0, x1, 0.62), y1 - 40), 20, Color(0.05, 0.2, 0.55)])
	labels.append(["phase 0", Vector2(x0 - 30, y1 + 10), 18, Color(0.1, 0.1, 0.1)])
	labels.append(["1", Vector2(x1 - 6, y1 + 10), 18, Color(0.1, 0.1, 0.1)])
	labels.append(["+0.45", Vector2(8, y0 - 10), 18, Color(0.1, 0.1, 0.1)])
	labels.append(["-0.45", Vector2(8, y1 - 10), 18, Color(0.1, 0.1, 0.1)])
	for l in labels:
		var lb := Label.new()
		lb.text = l[0]
		lb.position = l[1]
		lb.add_theme_font_size_override("font_size", l[2])
		lb.add_theme_color_override("font_color", l[3])
		vp.add_child(lb)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	Stage.save(vp.get_texture().get_image(), "flap_plot.png")
	vp.queue_free()
