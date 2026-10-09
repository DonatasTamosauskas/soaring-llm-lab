extends SceneTree
## VERIFIER PROBE (round 2): crop + enlarge regions of the builder's A9
## screenshots so small perched birds can be inspected by eye.
##   godot --headless -s res://tests/probes/ai/ai_v2r_crop.gd -- --src=<png> --out=<png> --rect=x,y,w,h --scale=4


func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.substr(2).split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var img := Image.load_from_file(args["src"])
	var r := (args["rect"] as String).split(",")
	var crop := img.get_region(Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])))
	var s := int(args.get("scale", "4"))
	crop.resize(crop.get_width() * s, crop.get_height() * s, Image.INTERPOLATE_NEAREST)
	crop.save_png(args["out"])
	print("[ai] crop saved ", args["out"])
	quit(0)
