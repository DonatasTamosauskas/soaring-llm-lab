extends Node
## B5 visual evidence:
##   feather_burst.png   catches of a sparrow, a pigeon and a hawk: the bird,
##                       then its feathers at 0.05 .. 2.2 s (they puff out in
##                       the prey's colours, stop, flutter down, shrink away)
##   wing_trails.png     a stooping hawk with wingtip trails, and the same
##                       hawk at cruise (no trails)
##   fx_report.json      node counts before, during and after (no leaks)
##
##   tools/gd.sh birds --rendering-method forward_plus --resolution 640x360 \
##       res://tests/shots/birds_fx.tscn

const Stage := preload("res://tests/shots/birds_stage.gd")
const CELL := 220
const TIMES := [0.0, 0.05, 0.15, 0.3, 0.6, 1.0, 1.5, 2.2]
const DT := 1.0 / 72.0


func _ready() -> void:
	var report := {}
	var rows := [&"sparrow", &"pigeon", &"hawk"]
	var vp := Stage.make(self, Vector2i(CELL, CELL), Stage.BG, 0.0, 40.0)
	var sheet := Image.create(120 + CELL * TIMES.size(), 40 + CELL * rows.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.97, 0.97, 0.96))
	var labels := []
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for r in rows.size():
		var sp: StringName = rows[r]
		var span: float = SizeRules.species_data(sp)["span"]
		var cam := Stage.cam(vp)
		cam.position = Vector3(0, span * 0.6, span * 3.2)
		cam.look_at(Vector3(0, -span * 0.25, 0), Vector3.UP)
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * span
		m.flap_amount = 1.0
		m.flap_phase = 0.2
		m.rotation.y = deg_to_rad(60.0)
		vp.add_child(m)
		m.snap()
		labels.append([String(sp), Vector2(8, 40 + r * CELL + CELL / 2 - 12), 22, Color(0.1, 0.1, 0.1)])
		var fb: FeatherBurst = null
		var t := 0.0
		for c in TIMES.size():
			var want: float = TIMES[c]
			if c == 1:
				# The catch: the prey vanishes, feathers appear where it was.
				m.queue_free()
				fb = BirdFX.feather_burst(vp, Vector3.ZERO, Color(0, 0, 0, 0), span, sp, Vector3(1.5, 0, 0) * span * 10.0, 11 + r)
				fb.set_process(false)
				report["%s_nodes_during" % sp] = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
			while fb != null and t + DT <= want:
				fb.step(DT)
				t += DT
			var img: Image = await Stage.grab(vp)
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(120 + c * CELL, 40 + r * CELL))
		# Run it out: the burst frees itself.
		while is_instance_valid(fb) and not fb.is_queued_for_deletion():
			fb.step(DT)
			t += DT
		report["%s_lifetime_s" % sp] = snappedf(t, 0.01)
		await get_tree().process_frame
	for c in TIMES.size():
		labels.append(["%.2f s" % TIMES[c] if c > 0 else "caught", Vector2(120 + c * CELL + 70, 8), 20, Color(0.1, 0.1, 0.1)])
	await get_tree().process_frame
	report["nodes_before"] = nodes0
	report["nodes_after"] = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	report["leaked_nodes"] = report["nodes_after"] - nodes0
	var out: Image = await Stage.annotate(self, sheet, labels)
	Stage.save(out, "feather_burst.png")
	vp.queue_free()
	await _trails(report)
	# (Exit 1 when any node is left behind or a burst ends at once.)
	var f := FileAccess.open(Paths.artifacts("birds").path_join("fx_report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	var ok: bool = report["leaked_nodes"] == 0
	for sp in rows:
		ok = ok and float(report["%s_lifetime_s" % sp]) > 0.5
	print("[birds] fx: leaked nodes %d, bursts freed after %s s; %s" % [report["leaked_nodes"],
		str(rows.map(func(sp: StringName) -> float: return report["%s_lifetime_s" % sp])), "ok" if ok else "FAIL"])
	get_tree().quit(0 if ok else 1)


func _trails(report: Dictionary) -> void:
	var vp := Stage.make(self, Vector2i(900, 500), Color(0.72, 0.8, 0.88), 0.0, 50.0)
	var sheet := Image.create(1800, 500, false, Image.FORMAT_RGBA8)
	var labels := []
	for k in 2:
		var bird := Bird.new()
		bird.mass = 1.3
		bird.species = &"hawk"
		vp.add_child(bird)
		var m := BirdModels.create(&"hawk")
		m.scale = Vector3.ONE * 1.6
		bird.add_child(m)
		var tr := BirdFX.attach_trails(m)
		tr.set_process(false)
		var cruise: float = SizeRules.performance(1.3)["cruise"]
		var fast := k == 0
		var v := Vector3(0, -cruise * 2.2, -cruise * 1.2) if fast else Vector3(0, 0, -cruise)
		bird.velocity = v
		bird.position = Vector3(0, 30, 0)
		bird.look_at(bird.position + v, Vector3.UP)
		m.wing_fold = 0.55 if fast else 0.0
		m.flap_amount = 0.0 if fast else 0.6
		m.snap()
		var cam := Stage.cam(vp)
		for i in 36:
			bird.position += v * DT
			m.flap_phase = fposmod(i * DT * 3.0, 1.0)
			# Every frame: the model syncs, then the trail samples its tips.
			BirdBatch.sync_all(DT)
			tr.step(DT)
			cam.position = bird.position + Vector3(7.0, 2.5, 4.0)
			cam.look_at(bird.position - v.normalized() * 1.5, Vector3.UP)
		report["trail_strength_%s" % ("stoop" if fast else "cruise")] = snappedf(tr.strength(), 0.01)
		var img: Image = await Stage.grab(vp)
		img.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(img, Rect2i(0, 0, 900, 500), Vector2i(k * 900, 0))
		labels.append(["stoop at %.0f m/s: wingtip trails" % v.length() if fast else "cruise at %.0f m/s: no trails" % v.length(),
			Vector2(k * 900 + 16, 12), 24, Color(0.1, 0.1, 0.1)])
		bird.queue_free()
		await get_tree().process_frame
	var out: Image = await Stage.annotate(self, sheet, labels)
	Stage.save(out, "wing_trails.png")
	vp.queue_free()
