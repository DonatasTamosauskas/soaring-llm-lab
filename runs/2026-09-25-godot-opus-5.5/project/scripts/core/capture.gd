class_name Capture
extends RefCounted
## Screenshots for verification.
##
## Desktop runs (--xr-mode off): save the main viewport.
## XR runs: the XR viewport reads back black on macOS, so XR code must render a
## mirror Camera3D into a SubViewport and pass that viewport here.
##
## On this Mac, take screenshots with --rendering-method forward_plus: the
## Mobile renderer under MoltenVK paints magenta tiles that never occur on
## Quest hardware.


## Waits for the frame to finish drawing, then writes vp as a PNG.
static func save_viewport(vp: Viewport, path: String) -> Error:
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		push_error("[capture] empty image for " + path)
		return FAILED
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	print("[capture] %s -> %s" % [error_string(err), path])
	return err


## Mean colour and fraction of pixels that are near-black, for cheap
## "did anything render" assertions.
static func image_stats(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var sum := Color(0, 0, 0, 0)
	var dark := 0
	var n := 0
	var step := maxi(1, int(sqrt(float(w * h) / 4096.0)))
	for y in range(0, h, step):
		for x in range(0, w, step):
			var c := img.get_pixel(x, y)
			sum += c
			if c.get_luminance() < 0.02:
				dark += 1
			n += 1
	return {"mean": sum / float(n), "dark_fraction": float(dark) / float(n), "samples": n}
