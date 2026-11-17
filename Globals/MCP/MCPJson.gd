extends RefCounted

## The MCP JSON and argument helpers.
##
## These functions turn between the compact JSON forms and the editor's value
## types. They do not read or change the editor state.

static func parse_color(value: Variant) -> Variant:
	if value is String:
		var text: String = value
		if not Color.html_is_valid(text):
			return null
		return Color.html(text)
	if value is Array:
		var components: Array = value
		if components.size() < 3 or components.size() > 4:
			return null
		for component in components:
			if not (component is int or component is float):
				return null
		var alpha := 1.0
		if components.size() == 4:
			alpha = float(components[3])
		return Color(float(components[0]), float(components[1]), float(components[2]), alpha)
	return null


## Parses a three-number vector. Returns [code]null[/code] for a non-finite or
## malformed value.
static func parse_vector(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 3:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
		if not is_finite(float(component)):
			return null
	return Vector3(float(components[0]), float(components[1]), float(components[2]))


static func parse_cell(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 3:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var x := int(components[0])
	var y := int(components[1])
	var z := int(components[2])
	if not cell_in_range(x, y, z):
		return null
	return Vector3i(x, y, z)


## Returns [code]true[/code] when one cell coordinate is inside the storage limit.
static func cell_in_range(x: int, y: int, z: int) -> bool:
	var limit := VoxelFrame.MAX_CHUNK_COORDINATE * VoxelFrame.CHUNK_SIZE
	return (
		x >= -limit and x <= limit
		and y >= -limit and y <= limit
		and z >= -limit and z <= limit
	)


static func parse_cells(value: Variant, max_count: int) -> Variant:
	if not (value is Array):
		return null
	var source: Array = value
	if source.is_empty() or source.size() > max_count:
		return null
	var cells: Array[Vector3i] = []
	for item in source:
		var cell: Variant = parse_cell(item)
		if cell == null:
			return null
		var cell_position: Vector3i = cell
		cells.append(cell_position)
	return cells


static func parse_box(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 6:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var sx := int(components[0])
	var sy := int(components[1])
	var sz := int(components[2])
	var ex := int(components[3])
	var ey := int(components[4])
	var ez := int(components[5])
	if sx > ex or sy > ey or sz > ez:
		return null
	if not cell_in_range(sx, sy, sz) or not cell_in_range(ex, ey, ez):
		return null
	return [Vector3i(sx, sy, sz), Vector3i(ex, ey, ez)]


static func parse_run(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 4:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var first := int(components[0])
	var last := int(components[1])
	if first > last:
		return null
	var y := int(components[2])
	var z := int(components[3])
	if not cell_in_range(first, y, z) or not cell_in_range(last, y, z):
		return null
	return [first, last, y, z]


static func parse_write_cell(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() < 3 or components.size() > 4:
		return null
	var cell_value: Variant = parse_cell(components.slice(0, 3))
	if cell_value == null:
		return null
	var material_index := -1
	if components.size() == 4:
		if not (components[3] is int or components[3] is float):
			return null
		material_index = int(components[3])
		if material_index < -1:
			return null
	return [cell_value, material_index]


static func parse_write_box(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() < 6 or components.size() > 7:
		return null
	var box_value: Variant = parse_box(components.slice(0, 6))
	if box_value == null:
		return null
	var box: Array = box_value
	var material_index := -1
	if components.size() == 7:
		if not (components[6] is int or components[6] is float):
			return null
		material_index = int(components[6])
		if material_index < -1:
			return null
	return [box[0], box[1], material_index]


static func parse_write_run(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() < 4 or components.size() > 5:
		return null
	var run_value: Variant = parse_run(components.slice(0, 4))
	if run_value == null:
		return null
	var run: Array = run_value
	var material_index := -1
	if components.size() == 5:
		if not (components[4] is int or components[4] is float):
			return null
		material_index = int(components[4])
		if material_index < -1:
			return null
	return [run[0], run[1], run[2], run[3], material_index]


static func axis_name(axis: int) -> String:
	match axis:
		Vector3.AXIS_X:
			return "x"
		Vector3.AXIS_Z:
			return "z"
	return "y"


static func material_json(material: PackedFloat32Array) -> Dictionary:
	var color := VoxelFrame.material_color(material)
	var emission := Color(
		material[VoxelFrame.MATERIAL_EMISSION],
		material[VoxelFrame.MATERIAL_EMISSION + 1],
		material[VoxelFrame.MATERIAL_EMISSION + 2]
	)
	var data := {
		"color": hex_color(color),
		"metallic": snappedf(material[VoxelFrame.MATERIAL_METALLIC], 0.001),
		"roughness": snappedf(material[VoxelFrame.MATERIAL_ROUGHNESS], 0.001),
	}
	if emission != Color.BLACK:
		data["emission"] = hex_color(emission)
	return data


static func material_key(material: PackedFloat32Array) -> String:
	var emission := Color(
		material[VoxelFrame.MATERIAL_EMISSION],
		material[VoxelFrame.MATERIAL_EMISSION + 1],
		material[VoxelFrame.MATERIAL_EMISSION + 2]
	)
	return "%s|%.3f|%.3f|%s" % [
		hex_color(VoxelFrame.material_color(material)),
		material[VoxelFrame.MATERIAL_METALLIC],
		material[VoxelFrame.MATERIAL_ROUGHNESS],
		hex_color(emission),
	]


static func material_key_matches(key: String, filter: String) -> bool:
	return filter.is_empty() or key.begins_with(filter + "|")


static func hex_color(color: Color) -> String:
	if color.a < 0.999:
		return "#" + color.to_html(true)
	return "#" + color.to_html(false)


static func aabb_json(box: AABB) -> Dictionary:
	return {"position": vector_json(box.position), "size": vector_json(box.size)}


static func vector_json(value: Vector3) -> Array:
	return [number_json(value.x), number_json(value.y), number_json(value.z)]


static func number_json(value: float) -> Variant:
	if is_equal_approx(value, roundf(value)):
		return int(roundf(value))
	return snappedf(value, 0.001)


static func json_cell(cell: Vector3i) -> Array:
	return [cell.x, cell.y, cell.z]


static func cell_bounds_json(box: AABB) -> Variant:
	if not box.has_volume():
		return null
	var bounds := []
	var edge := box.position + Vector3.ONE * 0.5
	bounds.append(Vector3i(roundi(edge.x), roundi(edge.y), roundi(edge.z)))
	edge = box.end - Vector3.ONE * 0.5
	bounds.append(Vector3i(roundi(edge.x), roundi(edge.y), roundi(edge.z)))
	return {"min": json_cell(bounds[0]), "max": json_cell(bounds[1])}


static func cell_bounds_json_from_cells(min_cell: Vector3i, max_cell: Vector3i) -> Dictionary:
	return {"min": json_cell(min_cell), "max": json_cell(max_cell)}


static func bounds_of_cell_array(cells: Array) -> Variant:
	if cells.is_empty():
		return null
	var min_cell: Vector3i = cells[0]
	var max_cell: Vector3i = cells[0]
	for cell in cells:
		min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
		max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	return cell_bounds_json_from_cells(min_cell, max_cell)


static func bounds_of_dictionaries(dictionaries: Array) -> Variant:
	var min_cell := Vector3i.MAX
	var max_cell := Vector3i.MIN
	var found := false
	for dictionary in dictionaries:
		for cell in dictionary:
			found = true
			min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
			max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	if not found:
		return null
	return cell_bounds_json_from_cells(min_cell, max_cell)


static func json_cells(cells: Array, limit: int) -> Array:
	var result := []
	for index in range(mini(cells.size(), limit)):
		result.append(json_cell(cells[index]))
	return result
