class_name GeometryBatch
extends RefCounted

## Accumulates many primitives into a single multi-surface [ArrayMesh].
##
## A tree built the obvious way — one MeshInstance3D per branch and leaf clump —
## is forty draw calls. A forest of those is thousands, which is fine on a
## desktop and fatal on a standalone headset at 90 Hz per eye. Batching by
## material turns each structure into one or two draw calls instead.

var _surfaces: Dictionary = {}


func add(mesh: Mesh, transform: Transform3D, material: String) -> void:
	if not _surfaces.has(material):
		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surfaces[material] = tool
	(_surfaces[material] as SurfaceTool).append_from(mesh, 0, transform)


func is_empty() -> bool:
	return _surfaces.is_empty()


## [param materials] maps the names used in [method add] to real materials.
func commit(materials: Dictionary) -> ArrayMesh:
	var result: ArrayMesh = null
	for name: String in _surfaces:
		var tool: SurfaceTool = _surfaces[name]
		tool.index()
		result = tool.commit(result)
		var surface: int = result.get_surface_count() - 1
		result.surface_set_material(surface, materials.get(name))
	return result
