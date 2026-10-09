class_name BirdRig
extends Node3D

## A whole bird, assembled: body, tail and two wings hung on the smallest number
## of nodes that can carry a flap cycle.
##
## Four [MeshInstance3D]s per bird — body, tail, two wings — every one of them
## sharing [method BirdMesh.material] and, with the rest of its species, sharing
## its mesh. Adding a bird to the world therefore adds four draw calls and
## nothing else: no material, no shader compile, no geometry. The wrist flex that
## would have needed a fifth and sixth node happens in the vertex shader instead.
##
## The node split is not arbitrary. Rotation and scale are kept on separate nodes
## everywhere they meet, because Godot rejects a slerp of a basis carrying a
## scale and this rig is hung under exactly such a slerp in [BirdNPC].

## The rig's own scale is left alone: callers scale the node they hang this on,
## because [BirdNPC] slerps a rotation one level above it.
var species: BirdMesh.Species = BirdMesh.Species.FALCON
var pose := BirdPose.new()

var _spine: Node3D
var _body: MeshInstance3D
var _tail_hinge: Node3D
var _tail: MeshInstance3D
var _left_shoulder: Node3D
var _right_shoulder: Node3D
var _left_wing: MeshInstance3D
var _right_wing: MeshInstance3D
var _plumage: Color = Palette.colour("plumage_slate")
## Threat tint and its energy, kept apart rather than packed into a colour's
## alpha: "how hard is this glowing" is not a colour channel, and every colour in
## this game comes out of [Palette].
var _threat_colour: Color = Palette.colour("threat_prey")
var _threat_energy: float = 0.0
var _headless: bool = false
var _winged: bool = true


## [param winged] and [param headless] exist for the player's own body: their
## wings are their arms and their head is the camera, so the rig they wear is the
## same bird with those two parts left off.
func build(
	new_species: BirdMesh.Species, plumage: Color,
	winged: bool = true, headless: bool = false
) -> void:
	species = new_species
	_plumage = plumage
	_winged = winged
	_headless = headless

	_spine = Node3D.new()
	_spine.name = "Spine"
	add_child(_spine)

	_body = _instance("Body", BirdMesh.body_mesh(species, headless))
	_spine.add_child(_body)

	_tail_hinge = Node3D.new()
	_tail_hinge.name = "TailHinge"
	_tail_hinge.position = BirdMesh.tail_root(species)
	_spine.add_child(_tail_hinge)
	_tail = _instance("Tail", BirdMesh.tail_mesh(species))
	_tail_hinge.add_child(_tail)

	if _winged:
		var anchor: Vector3 = BirdMesh.shoulder(species)
		_right_shoulder = _shoulder("RightShoulder", anchor)
		_right_wing = _instance("RightWing", BirdMesh.wing_mesh(species, 1.0))
		_right_shoulder.add_child(_right_wing)
		_left_shoulder = _shoulder("LeftShoulder", Vector3(-anchor.x, anchor.y, anchor.z))
		_left_wing = _instance("LeftWing", BirdMesh.wing_mesh(species, -1.0))
		_left_shoulder.add_child(_left_wing)

	pose.beat_rate = BirdMesh.profile(species)["beat"]
	_paint()
	_apply()


## Swaps the whole bird for another species without disturbing anything holding
## it. Cheap: the meshes are already built and shared, so this is four
## assignments and a repaint.
func set_species(new_species: BirdMesh.Species) -> void:
	if new_species == species or _spine == null:
		return
	species = new_species
	_body.mesh = BirdMesh.body_mesh(species, _headless)
	_tail.mesh = BirdMesh.tail_mesh(species)
	_tail_hinge.position = BirdMesh.tail_root(species)
	if _winged:
		var anchor: Vector3 = BirdMesh.shoulder(species)
		_right_shoulder.position = anchor
		_left_shoulder.position = Vector3(-anchor.x, anchor.y, anchor.z)
		_right_wing.mesh = BirdMesh.wing_mesh(species, 1.0)
		_left_wing.mesh = BirdMesh.wing_mesh(species, -1.0)
	pose.beat_rate = BirdMesh.profile(species)["beat"]
	_paint()


## The flight state, straight through. [param stroke], [param span] and
## [param alpha] are the [FlightCommand]'s own fields and [param bank] the
## model's, so the animation cannot drift out of step with the physics: there is
## nothing between them to drift.
func animate(
	stroke: float, span: float, bank: float, alpha: float, alpha_trim: float, delta: float
) -> void:
	if _spine == null:
		return
	pose.advance(stroke, span, bank, alpha, alpha_trim, delta)
	_apply()


## Emission painted over the bird's own colour: green for something you can eat,
## red for something that can eat you. [param energy] of 0 turns it off.
func set_threat(colour: Color, energy: float) -> void:
	_threat_colour = colour
	_threat_energy = maxf(energy, 0.0)
	_paint()


func set_plumage(colour: Color) -> void:
	_plumage = colour
	_paint()


## Tip to tip in metres at the rig's own scale. The gameplay number: how big this
## thing looks against the sky.
func wingspan() -> float:
	return BirdMesh.wingspan(species)


## Every mesh this rig owns. Used by the rig itself to paint them and by the
## tests to count what a flock actually costs.
func instances() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for candidate: MeshInstance3D in [_body, _tail, _left_wing, _right_wing]:
		if candidate != null:
			out.append(candidate)
	return out


# --- construction -------------------------------------------------------------

func _instance(label: String, mesh: ArrayMesh) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.material_override = BirdMesh.material()
	return node


func _shoulder(label: String, at: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = label
	node.position = at
	_spine.add_child(node)
	return node


## Shadows are worth their cost on a bird you are chasing and are pure waste on
## the one you are wearing: a wing a hand's width from the eye throws its shadow
## straight across the player's own view.
func hide_shadows() -> void:
	for node: MeshInstance3D in instances():
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# --- painting and posing ------------------------------------------------------

func _paint() -> void:
	# Handed over as a [Color], not a [Vector4]: the shader declares both of these
	# `source_color`, and Godot only converts the sRGB numbers the palette is
	# authored in when it is given a colour. A vector goes through raw, which is
	# the same mistake that once made the terrain four times too bright.
	var tint: Color = _threat_colour
	tint.a = _threat_energy
	for node: MeshInstance3D in instances():
		node.set_instance_shader_parameter("plumage", _plumage)
		node.set_instance_shader_parameter("threat", tint)


func _apply() -> void:
	_spine.rotation = Vector3(pose.body_pitch, 0.0, 0.0)
	_tail_hinge.rotation = Vector3(pose.tail_pitch, 0.0, pose.tail_roll)
	# Rotation on the hinge, scale on the mesh below it: a fanning tail is a
	# scale, and a scale on a rotating node is the bug that crashes a slerp.
	_tail.scale = Vector3(pose.tail_spread, 1.0, 1.0)
	if not _winged:
		return
	_right_shoulder.rotation = Vector3(pose.twist, pose.right_sweep, pose.right_flap)
	_left_shoulder.rotation = Vector3(pose.twist, pose.left_sweep, -pose.left_flap)
	_right_wing.scale = Vector3(pose.right_extension, 1.0, 1.0)
	_left_wing.scale = Vector3(pose.left_extension, 1.0, 1.0)
	_flex(_right_wing, pose.right_bend)
	_flex(_left_wing, pose.left_bend)


## A [Vector4] rather than a [Color] on purpose: the bend is signed, and a
## colour is the wrong shape for a number that can be negative.
func _flex(wing: MeshInstance3D, bend: float) -> void:
	wing.set_instance_shader_parameter(
		"flex", Vector4(bend, pose.tip_lift, 0.0, 0.0)
	)
