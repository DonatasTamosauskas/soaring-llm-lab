class_name UIStandInBird
extends Bird
## A stand-in NPC for the UI dev scene and screenshots: a flat-shaded
## low-poly delta (two wing facets and a body ridge) in the palette's prey
## teal or threat coral. It honours the one part of NpcBird's contract the UI
## touches, a `model` with a `highlight` (1 target, 2 threat: brighter), so
## the dev scene and shots never depend on another area's bird models.

var model: StandInModel


func _init(p_species: StringName = &"moth", p_mass: float = 0.004) -> void:
	species = p_species
	mass = p_mass
	model = StandInModel.new()
	model.color = UITheme.PREY if p_mass < 0.05 else UITheme.THREAT
	model.span = maxf(SizeRules.wingspan_for_mass(p_mass), 0.5)
	add_child(model)


class StandInModel:
	extends MeshInstance3D
	var color := UITheme.PREY
	var span := 0.5
	## A lit-up bird (the lesson prey's `glow`, read duck-typed by
	## GameBridge.lesson_prey_info).
	var glow := false
	## BirdModel's highlight contract: 0 none, 1 target, 2 threat.
	var highlight := 0:
		set(v):
			highlight = v
			if _mat:
				_mat.albedo_color = Color.WHITE.lerp(Color(1.25, 1.25, 1.25), 1.0 if v > 0 else 0.0)
	var _mat: StandardMaterial3D

	func _ready() -> void:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var nose := Vector3(0, 0.02, -0.45) * span
		var tail := Vector3(0, 0.0, 0.25) * span
		var top := Vector3(0, 0.08, -0.05) * span
		for sd: float in [-1.0, 1.0]:
			var tip := Vector3(0.5 * sd, 0.0, 0.1) * span
			st.set_color(color)
			for v: Vector3 in ([nose, tip, tail] if sd > 0.0 else [nose, tail, tip]):
				st.add_vertex(v)
			st.set_color(color.darkened(0.25))
			for v: Vector3 in ([nose, top, tail] if sd > 0.0 else [nose, tail, top]):
				st.add_vertex(v + Vector3(0.02 * sd * span, 0, 0))
		st.generate_normals()
		mesh = st.commit()
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		material_override = _mat
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
