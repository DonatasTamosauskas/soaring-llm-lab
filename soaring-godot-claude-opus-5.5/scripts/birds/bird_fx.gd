class_name BirdFX
extends RefCounted
## Bird effects. Owned by the birds area.
##
##   BirdFX.feather_burst(parent, pos, color, span, species, velocity)
##       a puff of feathers (one draw call, frees itself after ~2.3 s)
##   BirdFX.catch_burst(prey)      the same, read from a caught Bird
##   BirdFX.attach_trails(model)   subtle wingtip trails at speed
##
## BirdFXDirector (a Node) does catch bursts automatically from
## Events.bird_caught, for scenes that want them without wiring.


## Feathers at `pos` (world space) under `parent`. Colours come from the
## species' palette when `species` is given, else from `color` (with
## variations), else a neutral brown. span = the prey's wingspan (m): sets
## feather size and burst speed. velocity = the prey's, partly inherited.
static func feather_burst(parent: Node, pos: Vector3, color: Color = Color(0, 0, 0, 0), span: float = 0.3,
		species: StringName = &"", velocity: Vector3 = Vector3.ZERO, seed_value: int = -1) -> FeatherBurst:
	var fb := FeatherBurst.new()
	fb.name = "FeatherBurst"
	fb.span = maxf(span, 0.04)
	fb.inherit_velocity = velocity
	fb.rng_seed = seed_value if seed_value >= 0 else int(hash(pos) & 0x7fffffff)
	var cols: Array[Color] = []
	if species != &"" and BirdSpecies.has(species):
		var p := BirdModels.palette(species)
		for k in ["back", "cov", "flight", "belly", "breast", "tail", "prim"]:
			cols.append(p[k])
	elif color.a > 0.0:
		cols = [color, color.lightened(0.15), color.darkened(0.15)]
	fb.colors = cols
	parent.add_child(fb)
	fb.global_position = pos
	return fb


## Feathers for a caught bird, parented to the prey's parent (or the current
## scene) so they outlive the prey.
static func catch_burst(prey: Bird) -> FeatherBurst:
	if prey == null or not is_instance_valid(prey) or not prey.is_inside_tree():
		return null
	var parent := prey.get_parent()
	if parent == null:
		parent = prey.get_tree().current_scene
	return feather_burst(parent, prey.get_body_position(), Color(0, 0, 0, 0), prey.get_wingspan(), prey.species, prey.velocity)


## Wingtip trails on a model (shown only while its bird flies fast).
static func attach_trails(model: BirdModel) -> WingTrails:
	for c in model.get_children():
		if c is WingTrails:
			return c
	var t := WingTrails.new()
	t.name = "WingTrails"
	model.add_child(t)
	return t
