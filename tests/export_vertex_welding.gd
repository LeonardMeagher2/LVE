extends "res://tests/test.gd"

var export_job: RefCounted
var source: Array
var welded: Array


func _ready() -> void:
	test("glTF welding joins epsilon-close seams and preserves color and sharp normal boundaries", _run)


func _run() -> void:
	step("Given two coplanar quads with an epsilon-close shared edge", func():
		export_job = plugin("ExportPlugin").GLTF_EXPORT.ExportJob.new()
		source = _quads(Color.RED, Vector3.UP)
	)
	step("When export welding joins their vertices", func():
		welded = export_job._weld_frame(source, 0)
	)
	step("Then the quads share one edge without changing triangle count", func():
		expect(welded[Mesh.ARRAY_VERTEX].size() == 6, "the shared edge uses two shared vertices")
		expect(welded[Mesh.ARRAY_INDEX].size() == 12, "welding preserves all four triangles")
		expect(welded[Mesh.ARRAY_INDEX][1] == welded[Mesh.ARRAY_INDEX][8], "both quads reference the same upper seam vertex")
		expect(welded[Mesh.ARRAY_INDEX][4] == welded[Mesh.ARRAY_INDEX][6], "both quads reference the same lower seam vertex")
	)
	step("When the welded quads are simplified", func():
		welded = export_job._simplify_frame(welded, 0)
	)
	step("Then simplification can merge the indexed surface", func():
		expect(welded[Mesh.ARRAY_INDEX].size() == 6, "the surface becomes one quad")
		expect(welded[Mesh.ARRAY_VERTEX].size() == 4, "the simplified quad has four vertices")
	)
	step("When adjacent quads have different colors", func():
		welded = export_job._weld_frame(_quads(Color.BLUE, Vector3.UP), 0)
	)
	step("Then welding preserves the color boundary", func():
		expect(welded[Mesh.ARRAY_VERTEX].size() == 8, "different vertex colors keep separate seam vertices")
		expect(welded[Mesh.ARRAY_COLOR][0] == Color.RED and welded[Mesh.ARRAY_COLOR][4] == Color.BLUE, "both surface colors are retained")
	)
	step("When adjacent quads have different normals", func():
		welded = export_job._weld_frame(_quads(Color.RED, Vector3.RIGHT), 0)
	)
	step("Then welding preserves the sharp edge", func():
		expect(welded[Mesh.ARRAY_VERTEX].size() == 8, "different normals keep separate seam vertices")
		expect(welded[Mesh.ARRAY_NORMAL][0] == Vector3.UP and welded[Mesh.ARRAY_NORMAL][4] == Vector3.RIGHT, "both sharp-edge normals are retained")
	)


func _quads(second_color: Color, second_normal: Vector3) -> Array:
	var epsilon: float = export_job.WELD_EPSILON
	var positions := PackedVector3Array([
		Vector3(-0.5, 0.5, -0.5), Vector3(-0.5, 0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(0.5, 0.5, -0.5),
		Vector3(0.5 + epsilon * 0.2, 0.5, -0.5), Vector3(0.5 + epsilon * 0.2, 0.5, 0.5), Vector3(1.5, 0.5, 0.5), Vector3(1.5, 0.5, -0.5)
	])
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for index in 8:
		normals.append(Vector3.UP if index < 4 else second_normal)
		colors.append(Color.RED if index < 4 else second_color)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2, 4, 6, 5, 4, 7, 6])
	return arrays
