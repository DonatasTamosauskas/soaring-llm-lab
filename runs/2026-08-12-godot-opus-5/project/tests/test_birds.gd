class_name BirdTests
extends RefCounted

## Holds the birds to the two things that are not a matter of taste.
##
## [b]Legibility is a rule, not an opinion.[/b] The player has to decide "eat it
## or run" against a shape at an unknown distance, so the size ladder has to be
## ordered all the way up: every step up a size class is a longer body, a wider
## wing and one more splayed primary, and no bird may ever appear to shrink by
## growing. That is a set of inequalities, and inequalities can be asserted.
##
## [b]Cost is a number.[/b] One material for the whole flock, one set of meshes
## per species, four draw calls per bird, a triangle budget for twenty-six of
## them. Every one of those is checked here, because every one of them is the
## kind of thing that decays quietly — one per-bird material at a time.
##
## The rest is the flap cycle, which is judged by eye (see
## [code]tests/aviary.gd[/code]) but whose skeleton is arithmetic: the downstroke
## is quicker than the recovery, the wrist folds on the way up and not on the way
## down, a beat that starts finishes, and nothing anywhere goes non-finite.


static func run(t: TestCase) -> void:
	_test_the_size_ladder_is_ordered(t)
	_test_a_growing_bird_never_looks_smaller(t)
	_test_species_do_not_flicker_on_a_boundary(t)
	_test_silhouettes_are_told_apart(t)
	_test_no_bird_is_inside_out(t)
	_test_the_vertex_channels_are_sane(t)
	_test_a_wing_cannot_tear(t)
	_test_the_whole_flock_is_one_material(t)
	_test_a_bird_costs_four_draw_calls(t)
	_test_the_downstroke_is_quicker_than_the_recovery(t)
	_test_the_wrist_folds_on_the_way_up(t)
	_test_a_beat_that_starts_finishes(t)
	_test_a_glide_is_still(t)
	_test_effort_and_species_set_the_beat(t)
	_test_the_flight_state_drives_the_pose(t)
	_test_the_pose_survives_hostile_input(t)
	_test_a_bird_wears_its_own_size(t)
	_test_the_player_wing_matches_the_arm(t)
	_test_the_birds_invent_no_colours(t)


# --- the size ladder ----------------------------------------------------------

## Bigger class, bigger bird, more fingers — with no exceptions, because the
## exception is the bird that gets eaten by someone who read it wrong.
static func _test_the_size_ladder_is_ordered(t: TestCase) -> void:
	t.begin("the size ladder is ordered")
	var previous: Dictionary = {}
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var p: Dictionary = BirdMesh.profile(species)
		t.greater(float(p["beat"]), 0.5, "species %d beats its wings" % species)
		if previous.is_empty():
			previous = p
			continue
		t.greater(float(p["body"]), float(previous["body"]), "species %d is longer" % species)
		t.greater(
			BirdMesh.wingspan(species), BirdMesh.wingspan((species - 1) as BirdMesh.Species),
			"species %d spans wider" % species
		)
		# Area, unlike span, is allowed to dip: a seabird is deliberately a
		# slender high-aspect glider and carries less wing than the stockier
		# corvid below it. What may not happen is a class becoming a visibly
		# slighter bird, so the dip is bounded.
		t.greater(
			float(p["span"]) * float(p["chord"]),
			float(previous["span"]) * float(previous["chord"]) * 0.7,
			"species %d carries nearly as much wing as the class below" % species
		)
		t.greater(
			float(p["fingers"]), float(previous["fingers"]) - 0.5,
			"species %d has at least as many fingers" % species
		)
		t.less(
			float(p["beat"]), float(previous["beat"]),
			"species %d beats more slowly" % species
		)
		previous = p
	var biggest: Dictionary = BirdMesh.profile(BirdMesh.Species.RAPTOR)
	var smallest: Dictionary = BirdMesh.profile(BirdMesh.Species.SWIFT)
	t.greater(
		float(biggest["span"]) * float(biggest["chord"]),
		float(smallest["span"]) * float(smallest["chord"]) * 3.0,
		"an eagle carries several times the wing a swift does"
	)
	t.greater(
		float(BirdMesh.profile(BirdMesh.Species.RAPTOR)["fingers"]),
		float(BirdMesh.profile(BirdMesh.Species.SWIFT)["fingers"]) + 3.5,
		"a hand you can count the fingers of only ever means a big bird"
	)

	# The whole size range lands somewhere, in order.
	var last: int = -1
	for step in 200:
		var size: float = 0.2 + float(step) * 0.05
		var species: int = BirdMesh.species_for_size(size)
		t.ok(
			species >= 0 and species < BirdMesh.Species.size(),
			"size %.2f is some bird" % size
		)
		t.ok(species >= last, "size %.2f is not a step backwards" % size)
		last = species
	t.ok(
		BirdMesh.species_for_size(GameRules.MIN_SIZE) == BirdMesh.Species.SWIFT,
		"the smallest bird in the rules is the smallest bird there is"
	)
	t.ok(
		BirdMesh.species_for_size(GameRules.MAX_SIZE) == BirdMesh.Species.RAPTOR,
		"and the biggest is the biggest"
	)


## The trap in choosing a silhouette by size class: if the next class up is a
## smaller shape, then a bird that grows past the boundary gets [i]visually
## smaller[/i] at the moment it becomes more dangerous. Apparent size is
## silhouette times scale, and that product has to rise everywhere.
static func _test_a_growing_bird_never_looks_smaller(t: TestCase) -> void:
	t.begin("a growing bird never looks smaller")
	var previous: float = 0.0
	for step in 400:
		var size: float = 0.3 + float(step) * 0.02
		var apparent: float = BirdMesh.wingspan(BirdMesh.species_for_size(size)) * size
		t.greater(apparent, previous, "size %.2f spans wider than the size below it" % size)
		previous = apparent

	for bound: float in BirdMesh.CLASS_BOUNDS:
		var below: float = BirdMesh.wingspan(
			BirdMesh.species_for_size(bound - 0.001)
		) * bound
		var above: float = BirdMesh.wingspan(BirdMesh.species_for_size(bound)) * bound
		t.greater(above, below, "crossing %.2f makes a bird bigger, not different" % bound)
		# But not by so much that a hair of growth doubles the bird.
		t.less(above / below, 1.45, "and not absurdly bigger (%.2f)" % bound)


static func _test_species_do_not_flicker_on_a_boundary(t: TestCase) -> void:
	t.begin("species do not flicker on a boundary")
	for i in BirdMesh.CLASS_BOUNDS.size():
		var bound: float = BirdMesh.CLASS_BOUNDS[i]
		var below: BirdMesh.Species = i as BirdMesh.Species
		var above: BirdMesh.Species = (i + 1) as BirdMesh.Species
		t.ok(
			BirdMesh.species_for_size(bound + 0.001, below) == below,
			"a bird just over %.2f keeps the shape it had" % bound
		)
		t.ok(
			BirdMesh.species_for_size(bound - 0.001, above) == above,
			"and a bird just under it does too"
		)
		var clear: float = bound * (1.0 + BirdMesh.CLASS_HYSTERESIS * 1.5)
		t.ok(
			BirdMesh.species_for_size(clear, below) == above,
			"but a bird well past %.2f has changed" % bound
		)
		# And the same answer with no history at all.
		t.ok(
			BirdMesh.species_for_size(clear) == above,
			"with or without a shape to keep"
		)


## Two birds a player has to tell apart cannot differ only in a number. Every
## pair of species differs in the proportions you can see from a long way off:
## how long the wing is against its own chord, or how many fingers it has.
static func _test_silhouettes_are_told_apart(t: TestCase) -> void:
	t.begin("silhouettes are told apart")
	var all: Array = BirdMesh.Species.values()
	for i in all.size():
		for j in range(i + 1, all.size()):
			var a: Dictionary = BirdMesh.profile(all[i])
			var b: Dictionary = BirdMesh.profile(all[j])
			var aspect_a: float = float(a["span"]) / float(a["chord"])
			var aspect_b: float = float(b["span"]) / float(b["chord"])
			var fingers: bool = int(a["fingers"]) != int(b["fingers"])
			var tails: bool = absf(float(a["shape"]) - float(b["shape"])) > 0.15
			t.ok(
				fingers or tails or absf(aspect_a - aspect_b) > 0.5,
				"%d and %d are different shapes (aspect %.2f vs %.2f)" % [
					all[i], all[j], aspect_a, aspect_b
				]
			)


# --- the meshes ---------------------------------------------------------------

## Every surface has to face outward. Reversed, a bird still renders — the shader
## draws both sides — but it renders as its own interior: lit from the wrong
## side and washed with the pale underside tint. That is exactly how the player's
## own body first looked, and the picture was the only thing that noticed.
static func _test_no_bird_is_inside_out(t: TestCase) -> void:
	t.begin("no bird is inside out")
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var outward: float = _outward_fraction(BirdMesh.body_mesh(species))
		t.greater(outward, 0.75, "species %d faces outward (%.2f)" % [species, outward])
		var headless: float = _outward_fraction(BirdMesh.body_mesh(species, true))
		t.greater(headless, 0.75, "species %d without a head too (%.2f)" % [species, headless])
		for side: float in [-1.0, 1.0]:
			var up: float = _upward_fraction(BirdMesh.wing_mesh(species, side))
			t.greater(up, 0.90, "species %d wing %d faces the sky (%.2f)" % [species, side, up])
		var tail: float = _upward_fraction(BirdMesh.tail_mesh(species))
		t.greater(tail, 0.90, "species %d tail faces the sky (%.2f)" % [species, tail])


## The vertex channels are masks, not colours — see [BirdMesh]. Out of range they
## do not fail loudly; they quietly paint a bird white or bend a body in half.
static func _test_the_vertex_channels_are_sane(t: TestCase) -> void:
	t.begin("the vertex channels are sane")
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var body: PackedColorArray = _colours(BirdMesh.body_mesh(species))
		var flexed: int = 0
		for c: Color in body:
			if c.b > 0.02:
				flexed += 1
		t.ok(flexed == 0, "species %d has no bend weight on its body" % species)
		t.ok(_in_gamut(body), "species %d body masks are in range" % species)

		var wing: ArrayMesh = BirdMesh.wing_mesh(species, 1.0)
		var arrays: Array = wing.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		t.ok(_in_gamut(colours), "species %d wing masks are in range" % species)
		var span: float = BirdMesh.profile(species)["span"]
		var root: float = 0.0
		var tip: float = 0.0
		for i in vertices.size():
			var u: float = vertices[i].x / span
			if u < 0.05:
				root = maxf(root, colours[i].b)
			if u > 0.97:
				tip = maxf(tip, colours[i].b)
		t.less(root, 0.02, "species %d does not bend at the shoulder" % species)
		t.greater(tip, 0.90, "species %d bends at the tip" % species)

		# Dark tips are the read that survives being a silhouette, so every
		# species that has fingers has to have them painted.
		if int(BirdMesh.profile(species)["fingers"]) > 0:
			var darkest: float = 0.0
			for c: Color in colours:
				darkest = maxf(darkest, c.g)
			t.greater(darkest, 0.5, "species %d has dark primaries" % species)


## The wrist flex rotates every vertex by its own weight, so two vertices sitting
## in the same place with different weights are a wing that tears itself open
## mid-beat. Panels meet at shared spanwise stations; this proves they agree
## there.
static func _test_a_wing_cannot_tear(t: TestCase) -> void:
	t.begin("a wing cannot tear")
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var arrays: Array = BirdMesh.wing_mesh(species, 1.0).surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var seen: Dictionary = {}
		var welded: bool = true
		var worst: float = 0.0
		for i in vertices.size():
			var key: String = "%.4f|%.4f|%.4f" % [
				vertices[i].x, vertices[i].y, vertices[i].z
			]
			if seen.has(key):
				var difference: float = absf(float(seen[key]) - colours[i].b)
				worst = maxf(worst, difference)
				# Vertex colours are quantised on their way into the mesh.
				welded = welded and difference < 0.01
			else:
				seen[key] = colours[i].b
		t.ok(welded, "species %d wing is welded (worst %.4f)" % [species, worst])


# --- what a flock costs -------------------------------------------------------

## The number that matters on a headset. The old flock made one
## [StandardMaterial3D] per bird; this one makes none at all, because plumage and
## threat glow are instance uniforms on a single shared shader.
static func _test_the_whole_flock_is_one_material(t: TestCase) -> void:
	t.begin("the whole flock is one material")
	var rigs: Array[BirdRig] = []
	var materials: Dictionary = {}
	for i in 26:
		var rig := BirdRig.new()
		var species: BirdMesh.Species = (i % BirdMesh.Species.size()) as BirdMesh.Species
		rig.build(species, Palette.plumage(float(i) * 0.037))
		rig.set_threat(Palette.colour("threat_prey"), 0.55 if i % 2 == 0 else 0.0)
		rigs.append(rig)
		for node: MeshInstance3D in rig.instances():
			materials[node.material_override.get_instance_id()] = true
	# The player's own wings are made of the same stuff.
	var wing := WingVisual.new()
	wing.build(1.0, Palette.colour("plumage_player"))
	for node: Node in wing.get_children():
		if node is MeshInstance3D:
			materials[(node as MeshInstance3D).material_override.get_instance_id()] = true

	t.ok(
		materials.size() == 1,
		"twenty-six birds and a player share one material (got %d)" % materials.size()
	)

	# And the meshes are shared per species, not per bird.
	var meshes: Dictionary = {}
	var triangles: int = 0
	for rig: BirdRig in rigs:
		for node: MeshInstance3D in rig.instances():
			meshes[node.mesh.get_instance_id()] = true
			triangles += _triangles(node.mesh)
	t.less(
		float(meshes.size()), 21.0,
		"and no more meshes than species times parts (got %d)" % meshes.size()
	)
	t.less(float(triangles), 7000.0, "the whole flock is %d triangles" % triangles)
	for rig: BirdRig in rigs:
		rig.free()
	wing.free()


static func _test_a_bird_costs_four_draw_calls(t: TestCase) -> void:
	t.begin("a bird costs four draw calls")
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var rig := BirdRig.new()
		rig.build(species, Palette.colour("plumage_slate"))
		var instances: Array[MeshInstance3D] = rig.instances()
		t.ok(instances.size() == 4, "species %d is four meshes" % species)
		var triangles: int = 0
		for node: MeshInstance3D in instances:
			t.ok(node.mesh.get_surface_count() == 1, "each one is a single surface")
			triangles += _triangles(node.mesh)
		t.less(float(triangles), 260.0, "species %d is %d triangles" % [species, triangles])
		t.greater(float(triangles), 60.0, "and is not a stick")
		rig.free()

	# A player's body has no head and no wings, and is cheaper for it.
	var body := BirdRig.new()
	body.build(BirdMesh.Species.FALCON, Palette.colour("plumage_player"), false, true)
	t.ok(body.instances().size() == 2, "the player's own body is two meshes")
	for node: MeshInstance3D in body.instances():
		t.ok(
			node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
			"and casts a shadow until it is told not to"
		)
	body.hide_shadows()
	for node: MeshInstance3D in body.instances():
		t.ok(
			node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"which it then does not"
		)
	body.free()


# --- the flap cycle -----------------------------------------------------------

## The one thing that separates a bird from a moth. The wing spends
## [constant BirdPose.DOWNSTROKE] of the cycle going down and the rest coming
## back, so it must travel through the same arc distinctly faster on the way
## down. A symmetric sine fails this, which is the point.
static func _test_the_downstroke_is_quicker_than_the_recovery(t: TestCase) -> void:
	t.begin("the downstroke is quicker than the recovery")
	var pose := BirdPose.new()
	pose.beat_rate = 2.0
	var dt: float = 1.0 / 240.0
	for i in 600:
		pose.advance(3.2, 1.0, 0.0, 0.105, 0.105, dt)

	var down_travel: float = 0.0
	var down_time: float = 0.0
	var up_travel: float = 0.0
	var up_time: float = 0.0
	var last: float = pose.right_flap
	var lowest: float = INF
	var highest: float = -INF
	var jump: float = 0.0
	for i in 480:
		var phase: float = pose.phase
		pose.advance(3.2, 1.0, 0.0, 0.105, 0.105, dt)
		var travel: float = absf(pose.right_flap - last)
		jump = maxf(jump, travel)
		if phase < BirdPose.DOWNSTROKE:
			down_travel += travel
			down_time += dt
		else:
			up_travel += travel
			up_time += dt
		lowest = minf(lowest, pose.right_flap)
		highest = maxf(highest, pose.right_flap)
		last = pose.right_flap

	var down_rate: float = down_travel / maxf(down_time, 1e-6)
	var up_rate: float = up_travel / maxf(up_time, 1e-6)
	t.greater(
		down_rate, up_rate * 1.4,
		"the power stroke is the fast half (%.2f vs %.2f rad/s)" % [down_rate, up_rate]
	)
	t.greater(highest - lowest, 1.2, "and the wing really travels (%.2f rad)" % (highest - lowest))
	t.greater(highest, 0.5, "up past the shoulder")
	t.less(lowest, -0.3, "and down past level")
	# 240 Hz here, but the game runs at 90: a wrap that jumps is visible.
	t.less(jump, 0.10, "with no jump in the cycle (%.4f rad)" % jump)

	# A gentler command is a shallower beat, not a slower one.
	var soft := BirdPose.new()
	soft.beat_rate = 2.0
	var soft_low: float = INF
	var soft_high: float = -INF
	for i in 900:
		soft.advance(1.0, 1.0, 0.0, 0.105, 0.105, dt)
		if i > 400:
			soft_low = minf(soft_low, soft.right_flap)
			soft_high = maxf(soft_high, soft.right_flap)
	t.less(
		soft_high - soft_low, (highest - lowest) * 0.85,
		"a light beat is a shallower one (%.2f)" % (soft_high - soft_low)
	)


## Wings fold on the way up. A wing held flat through the recovery pushes the
## bird back down again, and a bird animated that way looks like it is rowing.
static func _test_the_wrist_folds_on_the_way_up(t: TestCase) -> void:
	t.begin("the wrist folds on the way up")
	var pose := BirdPose.new()
	pose.beat_rate = 2.0
	var dt: float = 1.0 / 240.0
	for i in 600:
		pose.advance(3.2, 1.0, 0.0, 0.105, 0.105, dt)

	var down_bend: float = 0.0
	var down_n: int = 0
	var up_bend: float = 0.0
	var up_n: int = 0
	for i in 480:
		var phase: float = pose.phase
		pose.advance(3.2, 1.0, 0.0, 0.105, 0.105, dt)
		if phase < BirdPose.DOWNSTROKE:
			down_bend += absf(pose.right_bend)
			down_n += 1
		else:
			up_bend += absf(pose.right_bend)
			up_n += 1
	var down_mean: float = down_bend / maxf(float(down_n), 1.0)
	var up_mean: float = up_bend / maxf(float(up_n), 1.0)
	t.greater(
		up_mean, down_mean * 3.0 + 0.05,
		"the wing is folded on the recovery and open on the power stroke (%.3f vs %.3f)" % [
			up_mean, down_mean
		]
	)
	t.ok(
		signf(pose.left_bend) != signf(pose.right_bend) or absf(pose.right_bend) < 1e-6,
		"and the two wings fold toward their own tips"
	)


## A wingbeat is a unit. The flight model thinks in whole beats and so does the
## player's arm; cutting one off halfway is a twitch.
static func _test_a_beat_that_starts_finishes(t: TestCase) -> void:
	t.begin("a beat that starts finishes")
	var pose := BirdPose.new()
	pose.beat_rate = 2.0
	var dt: float = 1.0 / 90.0
	for i in 10:
		pose.advance(3.2, 1.0, 0.0, 0.105, 0.105, dt)
	t.ok(pose.beating, "the beat is running")
	var caught: float = pose.phase
	t.less(caught, BirdPose.DOWNSTROKE, "and is still on its way down")

	var kept_going: bool = false
	var finished_at: int = -1
	for i in 200:
		pose.advance(0.0, 1.0, 0.0, 0.105, 0.105, dt)
		if pose.phase > BirdPose.DOWNSTROKE + 0.2:
			kept_going = true
		if not pose.beating and finished_at < 0:
			finished_at = i
	t.ok(kept_going, "the stroke carries on after the command stops")
	t.greater(float(finished_at), 20.0, "and runs to the top before it settles")
	t.near(pose.phase, 0.0, 1e-6, "settling at the top of the stroke, not mid-air")
	t.near(pose.right_flap, BirdPose.GLIDE_DIHEDRAL, 0.02, "back to a glide")


static func _test_a_glide_is_still(t: TestCase) -> void:
	t.begin("a glide is still")
	var pose := BirdPose.new()
	for i in 400:
		pose.advance(0.0, 1.0, 0.0, 0.105, 0.105, 1.0 / 90.0)
	t.near(pose.right_flap, BirdPose.GLIDE_DIHEDRAL, 0.001, "wings level and a little raised")
	t.near(pose.left_flap, pose.right_flap, 1e-6, "and symmetric")
	t.near(pose.right_bend, 0.0, 0.001, "not folded")
	t.near(pose.left_sweep, 0.0, 0.001, "not swept")
	t.near(pose.right_extension, 1.0, 0.001, "fully out")
	t.ok(not pose.beating, "and not beating")
	t.greater(pose.tip_lift, 0.0, "with the tips carrying their own load")


static func _test_effort_and_species_set_the_beat(t: TestCase) -> void:
	t.begin("effort and species set the beat")
	var counts: Array = []
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var pose := BirdPose.new()
		pose.beat_rate = BirdMesh.profile(species)["beat"]
		var beats: int = 0
		var last: float = 0.0
		for i in 270:
			pose.advance(3.2, 1.0, 0.0, 0.105, 0.105, 1.0 / 90.0)
			if pose.phase < last:
				beats += 1
			last = pose.phase
		counts.append(beats)
	for i in range(1, counts.size()):
		t.ok(
			counts[i] <= counts[i - 1],
			"species %d beats no faster than the smaller bird (%d vs %d)" % [
				i, counts[i], counts[i - 1]
			]
		)
	t.greater(
		float(counts[0]), float(counts[-1]),
		"a swift beats its wings visibly faster than an eagle (%d vs %d)" % [
			counts[0], counts[-1]
		]
	)


## Every angle on the bird is the flight command, so what you see is what the
## bird is doing. If these come apart, the animation is decoration.
static func _test_the_flight_state_drives_the_pose(t: TestCase) -> void:
	t.begin("the flight state drives the pose")

	# Span folds the wings.
	var open := BirdPose.new()
	var shut := BirdPose.new()
	for i in 200:
		open.advance(0.0, 1.0, 0.0, 0.105, 0.105, 1.0 / 90.0)
		shut.advance(0.0, 0.0, 0.0, 0.105, 0.105, 1.0 / 90.0)
	t.less(shut.right_extension, open.right_extension * 0.45, "a tuck shortens the wing")
	t.greater(absf(shut.right_bend), 0.7, "sweeps the hand back")
	t.greater(absf(shut.right_sweep), 0.2, "and the whole wing with it")
	t.less(shut.tail_spread, open.tail_spread * 0.8, "and shuts the tail")

	# Bank draws the inner wing in and twists the tail the other way.
	var right := BirdPose.new()
	var left := BirdPose.new()
	for i in 200:
		right.advance(0.0, 1.0, 0.9, 0.105, 0.105, 1.0 / 90.0)
		left.advance(0.0, 1.0, -0.9, 0.105, 0.105, 1.0 / 90.0)
	t.less(right.right_extension, right.left_extension, "the inside wing draws in")
	t.less(left.left_extension, left.right_extension, "on whichever side is inside")
	t.near(
		right.right_extension, left.left_extension, 1e-6, "and the turn is symmetric"
	)
	t.ok(signf(right.tail_roll) != signf(left.tail_roll), "the tail twists into the turn")
	t.greater(absf(right.tail_roll), 0.15, "far enough to see")
	t.ok(
		absf(right.right_flap - right.left_flap) > 0.05,
		"and the wings are no longer level"
	)

	# Angle of attack pitches the body and drops the tail.
	var nose_up := BirdPose.new()
	var nose_down := BirdPose.new()
	for i in 200:
		nose_up.advance(0.0, 1.0, 0.0, 0.40, 0.105, 1.0 / 90.0)
		nose_down.advance(0.0, 1.0, 0.0, -0.20, 0.105, 1.0 / 90.0)
	t.greater(nose_up.body_pitch, nose_down.body_pitch + 0.3, "the body flies at its angle")
	t.greater(nose_up.body_pitch, 0.0, "nose up when the wings are pulling")
	t.less(nose_down.body_pitch, 0.0, "and down when they are not")
	t.greater(nose_up.tail_pitch, nose_down.tail_pitch + 0.2, "the tail works as a brake")
	t.greater(nose_up.tail_spread, nose_down.tail_spread + 0.1, "and fans out to do it")
	t.greater(nose_up.twist, nose_down.twist, "the wings take the same angle the bird does")


## The house rule: sanitise at the boundary. A NaN reaching a rotation is a bird
## that disappears, and [FlightModel] is allowed to hand out one bad frame while
## it repairs itself.
static func _test_the_pose_survives_hostile_input(t: TestCase) -> void:
	t.begin("the pose survives hostile input")
	var pose := BirdPose.new()
	var nan_value: float = sqrt(-1.0)
	var hostile: Array = [
		[nan_value, 1.0, 0.0, 0.105, 0.105, 1.0 / 90.0],
		[3.2, nan_value, 0.0, 0.105, 0.105, 1.0 / 90.0],
		[3.2, 1.0, nan_value, 0.105, 0.105, 1.0 / 90.0],
		[3.2, 1.0, 0.0, nan_value, 0.105, 1.0 / 90.0],
		[3.2, 1.0, 0.0, 0.105, nan_value, 1.0 / 90.0],
		[3.2, 1.0, 0.0, 0.105, 0.105, nan_value],
		[INF, INF, INF, INF, INF, INF],
		[-INF, -1e9, 1e9, -1e9, 1e9, 1e9],
		[3.2, 1.0, 0.0, 0.105, 0.105, 0.0],
		[3.2, 1.0, 0.0, 0.105, 0.105, -1.0],
		[1e12, 1e12, 1e12, 1e12, 1e12, 0.011],
	]
	for row: Array in hostile:
		pose.advance(row[0], row[1], row[2], row[3], row[4], row[5])
		for name: String in [
			"left_flap", "right_flap", "left_sweep", "right_sweep", "twist",
			"left_bend", "right_bend", "left_extension", "right_extension",
			"tip_lift", "tail_pitch", "tail_roll", "tail_spread", "body_pitch",
			"phase", "effort",
		]:
			t.finite(pose.get(name), "%s survives %s" % [name, str(row[0])])
		t.in_range(pose.phase, 0.0, 1.0, "the beat clock stays a clock")
		t.in_range(pose.right_extension, 0.0, 1.0, "a wing is never inside out")

	# And it still works afterwards.
	for i in 200:
		pose.advance(3.2, 1.0, 0.0, 0.105, 0.105, 1.0 / 90.0)
	t.finite(pose.right_flap, "and the bird still flies afterwards")
	t.greater(pose.effort, 0.5, "with its effort recovered")


# --- the birds in the game ----------------------------------------------------

## Two things at once: an NPC wears the silhouette its size class calls for, and
## it wears its size at all. [method BirdNPC.configure] runs [i]after[/i]
## [method Node._ready], so a bird built at the default size and never re-scaled
## flew around at size 1.0 whatever the rules thought it weighed.
static func _test_a_bird_wears_its_own_size(t: TestCase) -> void:
	t.begin("a bird wears its own size")
	for size: float in [0.4, 0.9, 1.6, 3.0, 6.0]:
		var bird := BirdNPC.new()
		# A `--script` suite has no running tree to fire _ready for us, and this
		# is the one thing here that has to be tested through the node the game
		# actually builds rather than through the rig underneath it.
		bird._ready()
		bird.configure(size, Vector3(0.0, 100.0, 0.0), null, 7)
		var scaler: Node3D = bird.get_child(0).get_child(0)
		t.near(scaler.scale.x, size, 0.001, "a size %.1f bird is %.1f across" % [size, size])
		var rig: BirdRig = scaler.get_child(0)
		t.ok(
			rig.species == BirdMesh.species_for_size(size),
			"and wears the shape of its class"
		)
		t.ok(rig.instances().size() == 4, "in four draw calls")

		# Growing across a class rebuilds it into the next bird up.
		bird.set_size(7.5)
		t.ok(rig.species == BirdMesh.Species.RAPTOR, "eating enough makes an eagle of it")
		t.near(scaler.scale.x, 7.5, 0.001, "at the size to match")

		# The threat tint is emission over its own colour, not a repaint.
		bird.show_threat(0.2)
		bird.show_threat(20.0)
		t.ok(rig.instances()[0].material_override == BirdMesh.material(), "still one material")
		bird.free()


static func _test_the_player_wing_matches_the_arm(t: TestCase) -> void:
	t.begin("the player's wing matches the arm")
	for species: BirdMesh.Species in BirdMesh.Species.values():
		var wing := WingVisual.new()
		wing.build(1.0, Palette.colour("plumage_player"), species)
		wing.set_span(1.0, 1.0, 0.0)
		var surface: MeshInstance3D = wing.get_child(0)
		var reach: float = surface.mesh.get_aabb().end.x * surface.scale.x
		t.near(
			reach, WingVisual.LENGTH, 0.02,
			"a %d wing still reaches the player's own hand (%.2f m)" % [species, reach]
		)
		# Tucking shortens it and sweeps it back, without changing the mesh.
		wing.set_span(0.0, 1.0, 0.0)
		var tucked: float = surface.mesh.get_aabb().end.x * surface.scale.x
		t.less(tucked, reach * 0.45, "and folds to a tuck")
		t.greater(absf(wing.rotation.y), 1.0, "swept back as it goes")
		wing.free()


## The same rule [PaletteTests] holds the world to, extended to the birds: no
## file that draws a feather may invent a colour. [PaletteTests] scans the files
## that existed when it was written; this scans the ones that draw birds, so the
## discipline covers the whole game rather than the half of it that is older.
##
## Vertex masks are the one exception, and they are not an exception really: a
## [code]MASK_[/code] constant is four channel weights that happen to be carried
## in a [Color], and none of its numbers is ever seen as a colour. See the vertex
## channel table in [BirdMesh].
static func _test_the_birds_invent_no_colours(t: TestCase) -> void:
	t.begin("the birds invent no colours")
	var painted: PackedStringArray = [
		"res://scripts/art/BirdMesh.gd",
		"res://scripts/art/BirdRig.gd",
		"res://scripts/art/BirdPose.gd",
		"res://scripts/player/WingVisual.gd",
	]
	for path: String in painted:
		var source: String = FileAccess.get_file_as_string(path)
		t.ok(not source.is_empty(), "%s is readable" % path)
		var offences: PackedStringArray = []
		var line_number: int = 0
		for line: String in source.split("\n"):
			line_number += 1
			var code: String = line.strip_edges()
			if code.begins_with("#") or code.begins_with("//") or code.begins_with("const MASK_"):
				continue
			if code.contains("Color(") or code.contains("Color.from_hsv"):
				offences.append("%d: %s" % [line_number, code])
		t.ok(
			offences.is_empty(),
			"%s invents a colour; put it in Palette instead [%s]" % [
				path, ", ".join(offences)
			]
		)

	# And the shader is painted from the palette rather than from numbers in a
	# string, where no scan would ever have found them.
	var material: ShaderMaterial = BirdMesh.material()
	var pale: Color = material.get_shader_parameter("pale")
	var dark: Color = material.get_shader_parameter("dark")
	t.less(
		_difference(pale, Palette.colour("plumage_cream")), 0.10,
		"a pale belly is the palette's own cream"
	)
	t.less(
		_difference(dark, Palette.colour("plumage_char")), 0.10,
		"and a dark primary its own charcoal"
	)
	t.greater(
		_luminance(pale) - _luminance(dark), 0.35,
		"with enough between them to read as countershading"
	)
	var code: String = material.shader.code
	t.ok(code.contains("instance uniform vec4 plumage"), "plumage is per instance")
	t.ok(code.contains("instance uniform vec4 threat"), "so is the threat glow")
	t.ok(code.contains("instance uniform vec4 flex"), "and so is the wing flex")
	t.ok(code.contains("specular_disabled"), "feathers have no highlight")
	t.ok(code.contains("cull_disabled"), "and a wing is visible from underneath")


# --- helpers ------------------------------------------------------------------


static func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


static func _difference(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0



## Fraction of a closed loft's triangles whose normal points away from its own
## long axis. Faces that point along the axis (the nose and tail caps) and the
## deliberately double-sided feet are left out of the count.
static func _outward_fraction(mesh: ArrayMesh) -> float:
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var counted: int = 0
	var outward: int = 0
	for i in range(0, vertices.size(), 3):
		var centre: Vector3 = (vertices[i] + vertices[i + 1] + vertices[i + 2]) / 3.0
		var radial := Vector3(centre.x, centre.y, 0.0)
		if radial.length() < 0.02 or absf(normals[i].z) > 0.8:
			continue
		counted += 1
		if normals[i].dot(radial.normalized()) > 0.0:
			outward += 1
	return float(outward) / maxf(float(counted), 1.0)


static func _upward_fraction(mesh: ArrayMesh) -> float:
	var normals: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var up: int = 0
	for i in range(0, normals.size(), 3):
		if normals[i].y > 0.0:
			up += 1
	return float(up) / maxf(float(normals.size() / 3), 1.0)


static func _colours(mesh: ArrayMesh) -> PackedColorArray:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]


static func _in_gamut(colours: PackedColorArray) -> bool:
	for c: Color in colours:
		if not (is_finite(c.r) and is_finite(c.g) and is_finite(c.b) and is_finite(c.a)):
			return false
		if c.r < 0.0 or c.r > 1.0 or c.g < 0.0 or c.g > 1.0:
			return false
		if c.b < 0.0 or c.b > 1.0 or c.a < 0.0 or c.a > 1.0:
			return false
	return true


static func _triangles(mesh: Mesh) -> int:
	var total: int = 0
	for surface in mesh.get_surface_count():
		total += mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX].size() / 3
	return total
