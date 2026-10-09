extends SceneTree
## Tool: pixel difference of image pairs (absolute paths after --):
##   tools/gd.sh ih_main --headless -s res://tests/shots/integration_imgdiff.gd -- a.png b.png [c.png d.png ...]
## Prints the share of pixels that differ by more than 2/255 in any channel,
## the mean difference, and the bounding box of the differing pixels.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i + 1 < args.size():
		var a := Image.load_from_file(args[i])
		var b := Image.load_from_file(args[i + 1])
		if a == null or b == null or a.get_size() != b.get_size():
			print("[integration] imgdiff %s vs %s: cannot compare" % [args[i].get_file(), args[i + 1].get_file()])
			i += 2
			continue
		var n := 0
		var tot := 0.0
		var lo := Vector2i(1 << 20, 1 << 20)
		var hi := Vector2i(-1, -1)
		for y in a.get_height():
			for x in a.get_width():
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				var d := maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b)))
				tot += d
				if d > 2.0 / 255.0:
					n += 1
					lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
					hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
		var px := a.get_width() * a.get_height()
		# The difference as an image beside the second one (white = differs).
		var di := Image.create(a.get_width(), a.get_height(), false, Image.FORMAT_RGB8)
		for y2 in a.get_height():
			for x2 in a.get_width():
				var ca2 := a.get_pixel(x2, y2)
				var cb2 := b.get_pixel(x2, y2)
				var d2 := maxf(absf(ca2.r - cb2.r), maxf(absf(ca2.g - cb2.g), absf(ca2.b - cb2.b)))
				di.set_pixel(x2, y2, Color(1, 1, 1) if d2 > 2.0 / 255.0 else cb2 * 0.35)
		di.save_png(args[i + 1].get_basename() + "_diff.png")
		print("[integration] imgdiff %s vs %s: %.3f %% of pixels differ (> 2/255), mean %.5f, box %s-%s" % [
			args[i].get_file(), args[i + 1].get_file(), 100.0 * n / px, tot / px, lo, hi])
		i += 2
	quit()
