extends Node
## Round-3 verifier shot (birds): what a highlighted bird looks like at the
## catch moment and at mid range. Rows: plain / edible / danger; columns:
## species; each cell frames one bird at a fixed angular size (wingspan
## across the view): --deg=25 (a prey just before the catch, a hawk on you)
## or --deg=3 (inside GameLoop's highlight range). Pulse pinned at its
## dimmest (the shader's pulse_test), glance frozen.
##
##   tools/gd.sh birds_verify --rendering-method forward_plus --resolution 1400x900 \
##       res://tests/probes/birds/birds_r3_close.tscn -- --deg=25
##
## Writes artifacts/birds/verify/r3_close_<deg>deg.png.

const Stage := preload("res://tests/shots/birds_stage.gd")
const SPECIES: Array[StringName] = [&"sparrow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
const CELL := 280


func _ready() -> void:
	var deg := float(Paths.arg("deg", "25"))
	# The tint follows span / distance, not pixels: a view just wider than
	# the bird fills the cell at the angle under test.
	var vp := Stage.make(self, Vector2i(CELL, CELL), Color(0.62, 0.74, 0.5), 0.0, deg * 1.3)
	var cam := Stage.cam(vp)
	var mat := BirdModels.material()
	mat.set_shader_parameter("pulse_test", 0.0)
	mat.set_shader_parameter("head_look_amount", 0.0)
	var sheet := Image.create(CELL * SPECIES.size(), CELL * 3, false, Image.FORMAT_RGBA8)
	for col in SPECIES.size():
		var sp := SPECIES[col]
		var m := BirdModels.create(sp)
		vp.add_child(m)
		m.flap_amount = 0.0
		m.flap_phase = 0.25
		m.rotation_degrees = Vector3(0, -35, 0)
		# Wingspan 1 (the look scales with the angle, not the size): the
		# camera sits where the span covers `deg`.
		var dist := 0.5 / tan(deg_to_rad(deg) * 0.5)
		cam.position = Vector3(0.0, dist * 0.35, dist * 0.94)
		cam.look_at(Vector3.ZERO, Vector3.UP)
		for row in 3:
			m.highlight = row
			m.snap()
			var img := await Stage.grab(vp)
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(0, 0, CELL, CELL), Vector2i(col * CELL, row * CELL))
		m.queue_free()
		await get_tree().process_frame
	var labels := []
	for col in SPECIES.size():
		labels.append([String(SPECIES[col]), Vector2(col * CELL + 6, 4), 16, Color(0.1, 0.1, 0.1)])
	for row in 3:
		labels.append([["plain", "edible", "danger"][row] + " (%d deg)" % int(deg), Vector2(6, row * CELL + CELL - 24), 14, Color(0.1, 0.1, 0.1)])
	var out := await Stage.annotate(self, sheet, labels)
	var path := Paths.artifacts("birds/verify").path_join("r3_close_%ddeg.png" % int(deg))
	out.save_png(path)
	print("[birds] r3 wrote ", path)
	get_tree().quit()
