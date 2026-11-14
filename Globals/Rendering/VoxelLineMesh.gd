extends RefCounted

## Pure helpers for line meshes that a cursor or a helper draws.
##
## The line list is a flat array of point pairs, so the mesh uses
## [constant Mesh.PRIMITIVE_LINES]. The build belongs to the main thread.

## Returns a line mesh for one line list. Call it on the main thread only.
##
## The mesh carries no surface material, so a caller owns the material choice and
## no shared resource is touched.
static func build(vertices: PackedVector3Array) -> ArrayMesh:
	var surface := ArrayMesh.new()
	if vertices.is_empty():
		return surface
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return surface
