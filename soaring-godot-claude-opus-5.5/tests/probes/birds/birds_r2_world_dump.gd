extends Node
## Verifier helper: prints landmark kinds/positions of the real world (to pick
## viewpoints for birds_r2_render). Quits itself.

func _ready() -> void:
	var w: Node = load("res://scenes/world/world.tscn").instantiate()
	add_child(w)
	if not w.get("is_generated"):
		await w.generated
	var seen := {}
	for l: Dictionary in w.get_landmarks():
		var k := String(l.get("kind", ""))
		if k in ["lake", "meadow", "field", "forest", "orchard", "farm", "village", "town", "glade", "canyon", "tower", "hedge", "powerline"] or String(l.get("name", "")).begins_with("village"):
			if int(seen.get(k, 0)) < 3:
				seen[k] = int(seen.get(k, 0)) + 1
				print("[birds-r2] landmark %s %s %s" % [k, l.get("name", ""), str(l.get("position", Vector3.ZERO))])
	var sp: Transform3D = w.get_player_spawn()
	print("[birds-r2] spawn ", sp.origin, " ground(0,0)=", w.ground_height(0, 0))
	get_tree().quit()
