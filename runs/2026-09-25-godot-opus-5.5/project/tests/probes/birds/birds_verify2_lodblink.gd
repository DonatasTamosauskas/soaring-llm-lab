extends Node
## Verifier probe (birds, round 1): is a bird drawn in the frame in which it
## changes LOD? BirdBatch.sync_all uploads every batch, then re-attaches the
## models whose LOD changed; the new batch's GPU buffer is only written on
## the next frame. This renders every frame of a slow fly-away / fly-back
## across the LOD0/LOD1 threshold and counts the bird's pixels.
##
##   tools/gd.sh birds_verify2 --rendering-method forward_plus --resolution 640x360 res://tests/probes/birds/birds_verify2_lodblink.tscn
##
## Writes artifacts/birds/verify/v2_lod_blink.json and v2_lod_blink.png; exits 1
## when a frame loses the bird.

const W := 320
const H := 180
const BG := Color(0.2, 0.9, 0.2)

var vp: SubViewport
var cam: Camera3D


func _ready() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	we.environment = env
	vp.add_child(we)
	cam = Camera3D.new()
	cam.fov = 8.0
	vp.add_child(cam)
	cam.current = true
	# A second bird that keeps the LOD1 batch alive (the "slot already
	# allocated" case), far to the side so it never enters the counted area.
	var keeper := BirdModels.create(&"sparrow")
	vp.add_child(keeper)
	keeper.position = Vector3(40, 0, -40)
	var m := BirdModels.create(&"sparrow")
	m.flap_amount = 0.0
	vp.add_child(m)
	m.look_at(Vector3(-1, 0, -20), Vector3.UP)
	var rows := []
	var lost := []
	var frames := []
	var prev_lod := -1
	for f in 180:
		# Out from 16 m to 34 m and back (LOD0 <-> LOD1 around 22-25 m).
		var k := f / 90.0
		var d := 16.0 + 18.0 * (k if k <= 1.0 else 2.0 - k)
		m.position = Vector3(0, 0, -d)
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var n := 0
		for y in range(H / 2 - 12, H / 2 + 12):
			for x in range(W / 2 - 40, W / 2 + 40):
				var c := img.get_pixel(x, y)
				if absf(c.r - BG.r) + absf(c.g - BG.g) + absf(c.b - BG.b) > 0.15:
					n += 1
		var lod := m.get_lod()
		rows.append({"frame": f, "d": snappedf(d, 0.01), "lod": lod, "pixels": n})
		if lod != prev_lod and prev_lod >= 0:
			print("[birds-verify] frame %d: LOD %d -> %d at %.2f m, pixels %d (prev %d)" % [f, prev_lod, lod, d, n, rows[f - 1]["pixels"]])
			frames.append(img.get_region(Rect2i(W / 2 - 40, H / 2 - 12, 80, 24)))
		if n == 0:
			lost.append(f)
		prev_lod = lod
	print("[birds-verify] frames with the bird missing: %s" % str(lost))
	var out := {"lost_frames": lost, "rows": rows}
	var dir := Paths.artifacts("birds").path_join("verify")
	DirAccess.make_dir_recursive_absolute(dir)
	var fa := FileAccess.open(dir.path_join("v2_lod_blink.json"), FileAccess.WRITE)
	fa.store_string(JSON.stringify(out, "  "))
	if not frames.is_empty():
		var sheet := Image.create(80 * frames.size(), 24, false, Image.FORMAT_RGBA8)
		for i in frames.size():
			var fr: Image = frames[i]
			fr.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(fr, Rect2i(0, 0, 80, 24), Vector2i(i * 80, 0))
		sheet.resize(sheet.get_width() * 4, sheet.get_height() * 4, Image.INTERPOLATE_NEAREST)
		sheet.save_png(dir.path_join("v2_lod_blink.png"))
	get_tree().quit(1 if not lost.is_empty() else 0)
