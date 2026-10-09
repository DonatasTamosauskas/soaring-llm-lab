extends Node
# Freeze the original procedural UI drawings into native Unity sprite assets.
class Drawing extends Control:
	var art_id: StringName
	var time := 0.0
	var bird := false
	func _draw() -> void:
		if bird:
			BirdIcon.draw_species(self, size * 0.5, size.x * 0.88, art_id, Color.WHITE)
		else:
			GestureArt.draw(self, art_id, Rect2(Vector2.ZERO, size).grow(-12), time)

func _ready() -> void:
	run.call_deferred()

func run() -> void:
	var output := OS.get_environment("SOARING_UI_EXPORT")
	DirAccess.make_dir_recursive_absolute(output)
	var vp := SubViewport.new()
	vp.size = Vector2i(256, 256)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var art := Drawing.new()
	art.size = Vector2(256,256)
	vp.add_child(art)
	for id: StringName in GestureArt.IDS:
		var sheet := Image.create(1024,768,false,Image.FORMAT_RGBA8)
		for frame in 12:
			art.art_id = id
			art.time = frame / 12.0 * (1.3 if id == &"flap" else TAU / 1.4)
			art.queue_redraw()
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var image := vp.get_texture().get_image()
			sheet.blit_rect(image,Rect2i(0,0,256,256),Vector2i((frame % 4)*256,(frame / 4)*256))
		sheet.save_png(output.path_join("gesture_" + str(id) + ".png"))
	art.bird = true
	for id in ["moth","wren","sparrow","swallow","starling","pigeon","crow","gull","hawk","eagle"]:
		art.art_id = StringName(id)
		art.queue_redraw()
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		vp.get_texture().get_image().save_png(output.path_join("bird_" + id + ".png"))
	art.queue_free()
	await get_tree().process_frame
	vp.size = Vector2i(640,330)
	var emblem := Emblem.new()
	emblem.size = Vector2(640,330)
	vp.add_child(emblem)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(output.path_join("emblem.png"))
	print("SOARING_UI_ART_OK 9 gesture atlases, 10 bird icons, original emblem")
	get_tree().quit()
