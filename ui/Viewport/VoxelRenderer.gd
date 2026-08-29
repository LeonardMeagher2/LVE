extends MultiMeshInstance3D


func _ready() -> void:
	State.frame_changed.connect(sync)
	State.cells_changed.connect(sync)
	State.document_changed.connect(sync)
	sync()


func sync() -> void:
	if State.current_frame < State.document.frames.size():
		sync_to(State.current_frame)


func sync_to(frame: int) -> void:
	var d := State.document
	if frame < 0 or frame >= d.frames.size():
		return
	var voxel_frame: VoxelFrame = d.frames[frame]
	var keys: Array = voxel_frame.cells.keys()
	multimesh.instance_count = keys.size()
	for i in keys.size():
		var c: Vector3i = keys[i]
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(c)))
		multimesh.set_instance_color(i, voxel_frame.cells[c])
