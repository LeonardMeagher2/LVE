extends Node3D

class Chunk extends RefCounted:
	var position:Vector3i
	var node:MultiMeshInstance3D
	var multimesh:MultiMesh
	var cells:Dictionary[Vector3i, Color] = {}
	var indexes:Dictionary[int, Vector3i] = {}
	var chunk_size:int = 0
	var capacity:int
	
	@warning_ignore("shadowed_variable")
	func _init(position:Vector3i, chunk_size:int, mesh:Mesh) -> void:
		self.position = position
		self.chunk_size = chunk_size
		self.capacity = chunk_size*2
		self.node = MultiMeshInstance3D.new()
		self.multimesh = MultiMesh.new()
		self.multimesh.mesh = mesh
		self.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		self.multimesh.use_colors = true
		self.multimesh.instance_count = self.capacity
		self.multimesh.visible_instance_count = 0
		self.node.multimesh = self.multimesh
		self.node.name = str(position.x) + "_" + str(position.y) + "_" + str(position.z)
	
	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE and is_instance_valid(node):
			if node.get_parent():
				node.get_parent().remove_child(node)
			node.queue_free()
	
	
	func grow(needed_capacity:int) -> void:
		var target := capacity
		while target < needed_capacity and target < chunk_size*chunk_size*chunk_size:
			target *= 2
		capacity = target
		update()
		
	func shrink(fill_to:int) -> void:
		@warning_ignore("integer_division")
		var target := capacity / 2
		while capacity > chunk_size*2 and fill_to * 4 < capacity:
			target /= 2
		capacity = target
		update()
		
	func update() -> void:
		multimesh.instance_count = capacity
		multimesh.visible_instance_count = indexes.size()
		for i in indexes:
			var cell:Vector3i = indexes[i]
			var color:Color = cells[cell]
			multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(cell)))
			multimesh.set_instance_color(i, color)
		
			
	func set_color(cell:Vector3i, color:Color) -> void:
		var size:int = indexes.size()
		var index_key:Variant = indexes.find_key(cell)
		var index = index_key if index_key is int else -1
		
		if index == -1:
			if color == Color.TRANSPARENT:
				return
			index = size
			cells[cell] = color
			indexes[index] = cell
			if size + 1 > capacity:
				grow(capacity + 1)
			size += 1
		elif color == Color.TRANSPARENT:
			cells.erase(cell)
			if index != size - 1:
				cell = indexes[size - 1]
				color = cells[cell]
				indexes[index] = cell
			indexes.erase(size - 1)
			size -= 1
				
			if size * 4 < capacity and capacity > chunk_size * 2:
				shrink(size)
		else:
			cells[cell] = color
		
		multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3(cell)))
		multimesh.set_instance_color(index, color)
		multimesh.visible_instance_count = size


@export_range(-1, 100, 1, "or_greater") var frame:int = -1
@export_range(1, 256, 1, "or_greater") var chunk_size:int = 32
@export var mesh:Mesh

var _chunks: Dictionary = {}


func _ready() -> void:
	State.frame_changed.connect(_rebuild)
	State.cells_changed.connect(_update)
	State.document_changed.connect(_rebuild)
	_rebuild()

func _get_max_capacity() -> int:
	return chunk_size * chunk_size * chunk_size

func _get_min_capacity() -> int:
	return chunk_size * 2

func _rebuild() -> void:
	_chunks.clear()
	var cells: Dictionary = {}
	if frame >= 0:
		cells = State.get_voxel_frame(frame).cells
	else:
		cells = State.get_current_voxel_frame().cells
	for cell in cells:
		set_cell(cell, cells[cell])


func _update(updated_frame: int, affected: Array[Vector3i] = []) -> void:
	if frame >= 0 and updated_frame != frame:
		return
	if affected.is_empty():
		_rebuild()
		return
	var cells: Dictionary = State.get_current_voxel_frame().cells
	for cell in affected:
		set_cell(cell, cells.get(cell, Color.TRANSPARENT))


func set_cell(cell: Vector3i, color: Color) -> void:
	var chunk:Chunk = null
	var chunk_position := cell_to_chunk(cell)
	if color == Color.TRANSPARENT:
		chunk = _chunks.get(chunk_position)
		if not chunk or not chunk.cells.has(cell):
			return
	else:
		chunk = _chunks.get_or_add(chunk_position, Chunk.new(chunk_position, chunk_size, mesh))
		if not chunk.node.get_parent() == self:
			add_child(chunk.node)
	chunk.set_color(cell, color)
	if chunk.cells.size() == 0:
		remove_child(chunk.node)
		_chunks.erase(cell)


func cell_to_chunk(c: Vector3i) -> Vector3i:
	return Vector3i(
		floori(c.x / float(chunk_size)),
		floori(c.y / float(chunk_size)),
		floori(c.z / float(chunk_size))
	)
