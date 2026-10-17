extends "res://tests/test.gd"

const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")
const REFERENCE := "res://CleanFlamingo.obj"
const CLEAN := "Clean_Mesh_0.002"
const BASE := "Base_Mesh_0.003"
const TAGS := [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW]
const CAPTURE_DIR := "res://tests/artifacts/planar_cleanup"
var obj := {}
var source: Array = []
var clean: Array = []
var result: RefCounted
var flat_result: RefCounted
var smooth_result: RefCounted


func _ready() -> void:
	timeout = 30.0
	test("planar cleanup dissolves smooth faces and checks an optional Blender reference", _run)


func _run() -> void:
	step("Given the optional original and cleaned Blender meshes", func():
		if not FileAccess.file_exists(REFERENCE):
			print("Blender reference removed. Skip the optional reference comparison.")
			return
		obj = _read_obj()
		expect(obj.groups.has(CLEAN) and obj.groups.has(BASE), "both named Blender meshes exist")
		if not obj.groups.has(CLEAN) or not obj.groups.has(BASE):
			return
		expect(obj.groups[CLEAN].vertices.size() == 94, "the cleaned reference has ninety-four position indices")
		expect(obj.groups[CLEAN].faces.size() == 192, "the cleaned reference has 192 triangles")
		expect(obj.groups[BASE].vertices.size() == 512, "the original reference has 512 quad corners")
		expect(obj.groups[BASE].faces.size() == 256, "the original reference has 256 triangles")
		_align_reference()
		clean = _clean_arrays()
		source = _base_quads()
		expect(source[Mesh.ARRAY_VERTEX].size() == 512, "the original triangles reconstruct 128 raw voxel quads")
		expect(_same_areas(_areas(source, false), _areas(clean, false)), "the aligned references have equal oriented material areas")
	)
	step("When the shared surface pipeline cleans the original smooth quads", func():
		if source.is_empty():
			return
		result = SURFACE.new()
		result.run(source, null)
		expect(result.error == OK, "the reference cleanup completes without a frame")
	)
	step("Then native cleanup preserves the reference surface and material boundaries", func():
		if result == null or result.error != OK or result.arrays.is_empty():
			return
		var arrays: Array = result.arrays
		var triangles: int = arrays[Mesh.ARRAY_INDEX].size() / 3
		expect(triangles <= 192 and triangles < 256, "native cleanup meets the Blender triangle budget")
		expect(_bounds(arrays[Mesh.ARRAY_VERTEX]) == _bounds(clean[Mesh.ARRAY_VERTEX]), "cleanup retains the exact reference bounds")
		expect(_same_areas(_areas(arrays, true), _areas(clean, false)), "each outward plane retains its exact material surface area")
		var unique := {}
		for position: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			unique[position] = true
		expect(unique.size() <= 94, "native cleanup meets the Blender geometric-position budget")
		expect(arrays[Mesh.ARRAY_VERTEX].size() < arrays[Mesh.ARRAY_INDEX].size(), "matching smooth corners share indexed vertices")
		_check_normals(arrays)
		_check_atlas(arrays)
		_check_face_samples(arrays)
		print("Planar reference: %d triangles, %d positions, %d indexed vertices" % [triangles, unique.size(), arrays[Mesh.ARRAY_VERTEX].size()])
	)
	step("Given uniform flat and smooth cubes with the same raw quad geometry", func():
		flat_result = SURFACE.new()
		smooth_result = SURFACE.new()
	)
	step("When both cubes pass through the shared surface pipeline", func():
		flat_result.run(_cube(false), null)
		smooth_result.run(_cube(true), null)
	)
	step("Then smooth shading changes normals and welding but not the triangle count", func():
		expect(flat_result.error == OK and smooth_result.error == OK, "both cube cleanups complete")
		if flat_result.arrays.is_empty() or smooth_result.arrays.is_empty():
			return
		expect(flat_result.arrays[Mesh.ARRAY_INDEX].size() == 36, "the flat cube has twelve triangles")
		expect(smooth_result.arrays[Mesh.ARRAY_INDEX].size() == 36, "the smooth cube has twelve triangles")
		expect(flat_result.arrays[Mesh.ARRAY_VERTEX].size() == 24, "the flat cube keeps twenty-four sharp corners")
		expect(smooth_result.arrays[Mesh.ARRAY_VERTEX].size() == 8, "the smooth cube welds to eight corners")
		_check_normals(smooth_result.arrays)
	)
	step("Then cancellation during contour extraction stops the whole cleanup", func():
		var calls := [0]
		var cancelled := SURFACE.new()
		cancelled.run(_cube(false), null, Vector3.ZERO, func(_progress):
			calls[0] += 1
			return calls[0] != 20
		)
		expect(cancelled.error == ERR_UNAVAILABLE and cancelled.arrays.is_empty(), "one rejected contour checkpoint cancels the complete operation")
	)
	if DisplayServer.get_name() != "headless":
		if result != null and result.error == OK and not result.arrays.is_empty():
			await _capture_comparison(clean, result, source)
		else:
			var frame := VoxelFrame.new()
			for z in 2:
				for y in 4:
					for x in 4:
						if x < 2 or y < 2:
							frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
			var builder := VoxelMeshBuilder.new()
			builder.source_frame = frame
			builder.smooth_normals = true
			builder.texture_materials = false
			builder.run()
			var surface := SURFACE.new()
			surface.run(builder.surface_arrays, frame)
			await _capture_comparison(builder.surface_arrays, surface, [], "source")


func _read_obj() -> Dictionary:
	# Read the reference only. OBJ indices span both groups.
	var parsed := {"positions": [], "normals": [], "uvs": [], "groups": {}}
	var group := ""
	for line in FileAccess.get_file_as_string(REFERENCE).split("\n"):
		var words := line.strip_edges().split(" ", false)
		if words.is_empty():
			continue
		match words[0]:
			"g":
				group = words[1]
				parsed.groups[group] = {"vertices": [], "faces": []}
			"v":
				parsed.positions.append(Vector3(float(words[1]), float(words[2]), float(words[3])))
				parsed.groups[group].vertices.append(parsed.positions.size() - 1)
			"vn":
				parsed.normals.append(Vector3(float(words[1]), float(words[2]), float(words[3])).normalized())
			"vt":
				parsed.uvs.append(Vector2(float(words[1]), float(words[2])))
			"f":
				var face: Array[Vector3i] = []
				for corner in range(1, words.size()):
					var ids := words[corner].split("/")
					face.append(Vector3i(int(ids[0]) - 1, int(ids[1]) - 1, int(ids[2]) - 1))
				parsed.groups[group].faces.append(face)
	return parsed


func _align_reference() -> void:
	var base_positions := PackedVector3Array()
	var clean_positions := PackedVector3Array()
	for id: int in obj.groups[BASE].vertices:
		base_positions.append(obj.positions[id])
	for id: int in obj.groups[CLEAN].vertices:
		clean_positions.append(obj.positions[id])
	var shift := _bounds(clean_positions).get_center().x - _bounds(base_positions).get_center().x
	expect(absf(absf(shift) - 5.71916) < 0.0001, "the original mesh has the known Blender X offset")
	var max_error := 0.0
	for group: String in [BASE, CLEAN]:
		for id: int in obj.groups[group].vertices:
			var position: Vector3 = obj.positions[id] + Vector3(shift if group == BASE else 0.0, 0.5, 0.0)
			var snapped := (position * 2.0).round() * 0.5
			max_error = maxf(max_error, position.distance_to(snapped))
			obj.positions[id] = snapped
	expect(max_error < 0.0001, "both aligned meshes lie on the voxel half grid")


func _empty_arrays() -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()
	return arrays


func _clean_arrays() -> Array:
	var arrays := _empty_arrays()
	for face: Array in obj.groups[CLEAN].faces:
		var tile := _tile(face)
		# OBJ uses outward counterclockwise winding. Godot uses clockwise winding.
		for corner: int in [0, 2, 1]:
			var ref: Vector3i = face[corner]
			arrays[Mesh.ARRAY_INDEX].append(arrays[Mesh.ARRAY_VERTEX].size())
			arrays[Mesh.ARRAY_VERTEX].append(obj.positions[ref.x])
			arrays[Mesh.ARRAY_NORMAL].append(obj.normals[ref.z])
			arrays[Mesh.ARRAY_COLOR].append(TAGS[tile])
	return arrays


func _base_quads() -> Array:
	var arrays := _empty_arrays()
	var faces: Array = obj.groups[BASE].faces
	var valid := faces.size() % 2 == 0
	for offset in range(0, faces.size(), 2):
		var refs := {}
		for face: Array in [faces[offset], faces[offset + 1]]:
			for ref: Vector3i in face:
				refs[ref.x] = ref
		valid = valid and refs.size() == 4
		if refs.size() != 4:
			continue
		var points := PackedVector3Array()
		var by_position := {}
		for ref: Vector3i in refs.values():
			var position: Vector3 = obj.positions[ref.x]
			points.append(position)
			by_position[position] = obj.normals[ref.z]
		var first: Array = faces[offset]
		var a: Vector3 = obj.positions[first[0].x]
		var b: Vector3 = obj.positions[first[1].x]
		var c: Vector3 = obj.positions[first[2].x]
		var outward := (b - a).cross(c - a).normalized()
		var axis := outward.abs().max_axis_index()
		var bounds := _bounds(points)
		var column := Vector3.ZERO
		var row := Vector3.ZERO
		column[(axis + 1) % 3] = bounds.size[(axis + 1) % 3]
		row[(axis + 2) % 3] = bounds.size[(axis + 2) % 3]
		var corners := PackedVector3Array([bounds.position, bounds.position + column, bounds.end, bounds.position + row])
		var normals := PackedVector3Array()
		for position: Vector3 in corners:
			normals.append(by_position[position])
		var combined: Array = refs.values()
		var tile := _tile(combined)
		valid = valid and _tile(faces[offset]) == tile and _tile(faces[offset + 1]) == tile
		_append_quad(arrays, corners, normals, outward, TAGS[tile])
	expect(valid, "each original triangle pair defines one four-corner material quad")
	return arrays


func _tile(refs: Array) -> int:
	# The MTL has no texture bindings. Use the four atlas blocks as material tags.
	var uv := Vector2.ZERO
	for ref: Vector3i in refs:
		uv += obj.uvs[ref.y]
	uv /= refs.size()
	return (0 if uv.y >= 0.5 else 2) + (0 if uv.x < 0.5 else 1)


func _append_quad(arrays: Array, corners: PackedVector3Array, normals: PackedVector3Array, outward: Vector3, color: Color) -> void:
	var first: int = arrays[Mesh.ARRAY_VERTEX].size()
	arrays[Mesh.ARRAY_VERTEX].append_array(corners)
	arrays[Mesh.ARRAY_NORMAL].append_array(normals)
	for corner in 4:
		arrays[Mesh.ARRAY_COLOR].append(color)
	var axis := outward.abs().max_axis_index()
	var winding := [0, 2, 1, 0, 3, 2] if outward[axis] > 0 else [0, 1, 2, 0, 2, 3]
	for corner: int in winding:
		arrays[Mesh.ARRAY_INDEX].append(first + corner)


func _cube(smooth: bool) -> Array:
	var arrays := _empty_arrays()
	for axis in 3:
		for sign_value: int in [-1, 1]:
			var origin := Vector3.ONE * -0.5
			origin[axis] = sign_value * 0.5
			var column := Vector3.ZERO
			var row := Vector3.ZERO
			column[(axis + 1) % 3] = 1.0
			row[(axis + 2) % 3] = 1.0
			var outward := Vector3.ZERO
			outward[axis] = sign_value
			var corners := PackedVector3Array([origin, origin + column, origin + column + row, origin + row])
			var normals := PackedVector3Array()
			for corner: Vector3 in corners:
				normals.append(corner.normalized() if smooth else outward)
			_append_quad(arrays, corners, normals, outward, Color.RED)
	return arrays


func _bounds(positions: PackedVector3Array) -> AABB:
	var bounds := AABB(positions[0], Vector3.ZERO)
	for position: Vector3 in positions:
		bounds = bounds.expand(position)
	return bounds


func _sample_tag(uv: Vector2) -> int:
	var pixel := Vector2i((uv * Vector2(result.atlas.size)).floor())
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= result.atlas.size.x or pixel.y >= result.atlas.size.y:
		return -1
	var color: Color = result.atlas.albedo.get_pixelv(pixel)
	for tag in TAGS.size():
		if color.is_equal_approx(TAGS[tag]):
			return tag
	return -1


func _areas(arrays: Array, textured: bool) -> Dictionary:
	var areas := {}
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for offset in range(0, indices.size(), 3):
		var a := positions[indices[offset]]
		var b := positions[indices[offset + 1]]
		var c := positions[indices[offset + 2]]
		var cross := -(b - a).cross(c - a)
		var axis := cross.abs().max_axis_index()
		var tag: int
		if textured:
			tag = _sample_tag(arrays[Mesh.ARRAY_TEX_UV][indices[offset]])
		else:
			tag = TAGS.find(arrays[Mesh.ARRAY_COLOR][indices[offset]])
		var key := Vector4(axis, signf(cross[axis]), a[axis] * 2.0, tag)
		areas[key] = float(areas.get(key, 0.0)) + cross.length() * 0.5
	return areas


func _same_areas(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.size() != expected.size():
		return false
	for key: Vector4 in expected:
		if not actual.has(key) or absf(float(actual[key]) - float(expected[key])) > 0.0001:
			return false
	return true


func _check_normals(arrays: Array) -> void:
	var unit := true
	var smooth := false
	for normal: Vector3 in arrays[Mesh.ARRAY_NORMAL]:
		unit = unit and absf(normal.length() - 1.0) < 0.0001
		smooth = smooth or normal.abs()[normal.abs().max_axis_index()] < 0.99
	expect(unit, "every retained smooth normal has unit length")
	expect(smooth, "the cleanup retains non-axis smooth normals")


func _check_atlas(arrays: Array) -> void:
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var constant := true
	var centered := true
	var tag_uvs := {}
	for offset in range(0, indices.size(), 3):
		var uv := uvs[indices[offset]]
		constant = constant and uv == uvs[indices[offset + 1]] and uv == uvs[indices[offset + 2]]
	for uv: Vector2 in uvs:
		var texel := uv * Vector2(result.atlas.size)
		centered = centered and texel.is_equal_approx(texel.floor() + Vector2.ONE * 0.5)
		var tag := _sample_tag(uv)
		constant = constant and tag >= 0
		if tag_uvs.has(tag):
			constant = constant and tag_uvs[tag] == uv
		else:
			tag_uvs[tag] = uv
	expect(centered, "all material UVs sample exact pixel centers")
	expect(constant and tag_uvs.size() == 4, "each of the four materials shares one constant color texel")


func _check_face_samples(arrays: Array) -> void:
	var positions: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = source[Mesh.ARRAY_INDEX]
	var preserved := true
	for offset in range(0, indices.size(), 3):
		var a := positions[indices[offset]]
		var b := positions[indices[offset + 1]]
		var c := positions[indices[offset + 2]]
		var outward := -(b - a).cross(c - a).normalized()
		var expected := TAGS.find(source[Mesh.ARRAY_COLOR][indices[offset]])
		preserved = preserved and _tag_at(arrays, (a + b + c) / 3.0, outward) == expected
	expect(preserved, "every original triangle retains its material at its surface location")


func _tag_at(arrays: Array, point: Vector3, outward: Vector3) -> int:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for offset in range(0, indices.size(), 3):
		var a := positions[indices[offset]]
		var ab := positions[indices[offset + 1]] - a
		var ac := positions[indices[offset + 2]] - a
		var cross := -ab.cross(ac)
		if cross.dot(outward) <= 0.0 or absf(outward.dot(point - a)) > 0.0001:
			continue
		var denominator := ab.length_squared() * ac.length_squared() - ab.dot(ac) * ab.dot(ac)
		if denominator <= 0.000001:
			continue
		var delta := point - a
		var v := (ac.length_squared() * delta.dot(ab) - ab.dot(ac) * delta.dot(ac)) / denominator
		var w := (ab.length_squared() * delta.dot(ac) - ab.dot(ac) * delta.dot(ab)) / denominator
		if v >= -0.00001 and w >= -0.00001 and v + w <= 1.00001:
			return _sample_tag(arrays[Mesh.ARRAY_TEX_UV][indices[offset]])
	return -1


func _capture_comparison(baseline: Array, native: RefCounted, original: Array, baseline_name := "blender") -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(384, 384)
	viewport.world_3d = World3D.new()
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.35
	environment.ambient_light_sky_contribution = 0.0
	viewport.world_3d.environment = environment
	var bounds := _bounds(baseline[Mesh.ARRAY_VERTEX])
	var center := bounds.get_center()
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = bounds.size.length() * 1.15
	viewport.add_child(camera)
	camera.position = center + Vector3(1.0, 0.65, 1.5).normalized() * bounds.size.length() * 2.0
	camera.look_at(center)
	camera.current = true
	var light := DirectionalLight3D.new()
	viewport.add_child(light)
	light.position = center + Vector3(1.0, 2.0, 3.0)
	light.look_at(center)
	light.light_energy = 1.0
	light.shadow_enabled = false
	var reference_material := StandardMaterial3D.new()
	reference_material.vertex_color_use_as_albedo = true
	reference_material.vertex_color_is_srgb = true
	reference_material.roughness = 1.0
	reference_material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	var instance := MeshInstance3D.new()
	viewport.add_child(instance)
	var images := {}
	var sources := {baseline_name: baseline, "native": native.arrays}
	if not original.is_empty():
		sources["base"] = original
	step("Given a separate comparison world with one fixed camera and lighting", func():
		expect(viewport.world_3d != get_viewport().find_world_3d(), "the comparison uses an isolated 3D world")
		expect(DirAccess.make_dir_recursive_absolute(CAPTURE_DIR) == OK, "the comparison capture directory exists")
	)
	for label: String in sources:
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sources[label])
		instance.mesh = mesh
		instance.material_override = native.atlas.create_material() if label == "native" else reference_material
		# Wait for mesh submission and rendering before reading the viewport texture.
		await get_tree().process_frame
		if not is_instance_valid(viewport):
			return
		await RenderingServer.frame_post_draw
		if not is_instance_valid(viewport):
			return
		images[label] = viewport.get_texture().get_image()
	viewport.free()
	step("Then all comparison captures retain the same visible silhouette", func():
		for label: String in sources:
			var image: Image = images[label]
			expect(image != null and not image.is_empty(), "%s has a readable render capture" % label)
			if image == null or image.is_empty():
				return
			expect(image.save_png(CAPTURE_DIR.path_join(label + ".png")) == OK, "%s saves its comparison PNG" % label)
			var metrics := _image_difference(images[baseline_name], image)
			expect(metrics.foreground > 100, "%s contains a visible shaded mesh" % label)
			expect(metrics.silhouette_difference == 0, "%s matches the reference silhouette" % label)
			# Dissolving polygons can change normal interpolation across triangle diagonals.
			print("Planar render %s: %d silhouette pixels differ, mean shaded RGB difference %.6f" % [label, metrics.silhouette_difference, metrics.rgb_difference])
	)


func _image_difference(baseline: Image, image: Image) -> Dictionary:
	var foreground := 0
	var shared := 0
	var silhouette_difference := 0
	var rgb_difference := 0.0
	for y in baseline.get_height():
		for x in baseline.get_width():
			var expected := baseline.get_pixel(x, y)
			var actual := image.get_pixel(x, y)
			var expected_visible := expected.a >= 0.5
			var actual_visible := actual.a >= 0.5
			if actual_visible:
				foreground += 1
			if expected_visible != actual_visible:
				silhouette_difference += 1
			if expected_visible and actual_visible:
				shared += 1
				rgb_difference += absf(actual.r - expected.r) + absf(actual.g - expected.g) + absf(actual.b - expected.b)
	return {"foreground": foreground, "silhouette_difference": silhouette_difference, "rgb_difference": rgb_difference / maxf(shared * 3.0, 1.0)}
