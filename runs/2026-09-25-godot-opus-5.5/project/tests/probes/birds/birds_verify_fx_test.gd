extends TestCase
## Verifier probe (birds, round 1): B5 edge cases the builder's suite skips.
##  * the burst's parent is freed mid-burst (e.g. Ecosystem.reset);
##  * the prey is queue_freed in the same frame as catch_burst (GameLoop /
##    Ecosystem remove caught birds);
##  * extreme sizes: a moth (0.08 m) and an eagle (2.1 m) burst scale with
##    the prey (spread relative to span) and still free themselves;
##  * BirdFXDirector on a caught player and on an already freed prey;
##  * trails are freed with their model; attach_trails is idempotent.
## Leak check: node and object counts back to the start after everything.

const DT := 1.0 / 60.0


func _step_all(root: Node, seconds: float) -> void:
	var n := int(seconds / DT)
	for i in n:
		for fb in _bursts(root):
			if is_instance_valid(fb) and not fb.is_queued_for_deletion():
				fb.step(DT)
		await get_tree().process_frame


func _bursts(root: Node) -> Array:
	var out := []
	if root == null or not is_instance_valid(root):
		return out
	for c in root.find_children("*", "FeatherBurst", true, false):
		out.append(c)
	return out


func test_burst_survives_parent_free_and_prey_free_without_leaks() -> void:
	await get_tree().process_frame
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var orphans0 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	# 1. Parent freed mid-burst.
	var holder := Node3D.new()
	add_child(holder)
	var fb := BirdFX.feather_burst(holder, Vector3(0, 5, 0), Color(0, 0, 0, 0), 0.3, &"sparrow")
	fb.step(0.3)
	holder.free()
	check(not is_instance_valid(fb), "burst freed with its parent")
	# 2. Prey freed in the same frame as catch_burst.
	var eco := Node3D.new()
	add_child(eco)
	var prey := Bird.new()
	prey.species = &"starling"
	prey.mass = float(SizeRules.species_data(&"starling")["mass"])
	eco.add_child(prey)
	prey.position = Vector3(2, 10, -3)
	prey.velocity = Vector3(0, 0, -9)
	var cb := BirdFX.catch_burst(prey)
	prey.queue_free()
	check(cb != null and is_instance_valid(cb), "catch_burst made a burst")
	check(cb.get_parent() == eco, "burst parented to the prey's parent, outliving the prey")
	await get_tree().process_frame
	check(is_instance_valid(cb), "burst alive after the prey is gone")
	var life := cb.lifetime
	await _step_all(eco, life + 0.2)
	check(not is_instance_valid(cb), "burst freed itself after its lifetime (%.2f s)" % life)
	eco.free()
	await get_tree().process_frame
	var nodes1 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var orphans1 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	eq(int(nodes1 - nodes0), 0, "node count back to start")
	eq(int(orphans1 - orphans0), 0, "no orphan nodes")
	metric("nodes_delta", nodes1 - nodes0)
	metric("orphans_delta", orphans1 - orphans0)


func test_burst_scales_with_prey_size() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var rows := {}
	for sp in [&"moth", &"sparrow", &"eagle"]:
		var span: float = SizeRules.species_data(sp)["span"]
		var fb := BirdFX.feather_burst(holder, Vector3.ZERO, Color(0, 0, 0, 0), span, sp, Vector3.ZERO, 7)
		var t := 0.0
		while t < 0.5:
			fb.step(DT)
			t += DT
		var rel := fb.spread() / span
		rows[String(sp)] = {"spread_over_span_0.5s": snappedf(rel, 0.01), "lifetime": snappedf(fb.lifetime, 0.01)}
		between(rel, 0.2, 2.0, "%s: burst spread at 0.5 s is 0.2..2 spans (%.2f)" % [sp, rel])
		fb.free()
	holder.free()
	metric("burst_scale", rows)


func test_director_edge_cases() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var d := BirdFXDirector.new()
	holder.add_child(d)
	var prey := Bird.new()
	prey.species = &"wren"
	holder.add_child(prey)
	var gone := Bird.new()
	gone.species = &"moth"
	holder.add_child(gone)
	gone.free()
	Events.bird_caught.emit(null, prey)
	eq(d.bursts, 1, "burst for a caught bird with no predator")
	# A freed prey must be ignored, not crash (it may be freed by then).
	Events.bird_caught.emit(null, null)
	eq(d.bursts, 1, "null prey ignored")
	holder.free()


func test_trails_lifecycle() -> void:
	var m := BirdModels.create(&"hawk")
	add_child(m)
	var t1 := BirdFX.attach_trails(m)
	var t2 := BirdFX.attach_trails(m)
	check(t1 == t2, "attach_trails is idempotent")
	m.free()
	check(not is_instance_valid(t1), "trails freed with the model")
