class_name VoxelRenderer
extends MultiMeshInstance3D


func sync_to(frame: int) -> void:
	var d := State.document
	var voxel_frame: VoxelFrame = d.frames[frame]
	var keys: Array = voxel_frame.cells.keys()
	multimesh.instance_count = keys.size()
	for i in keys.size():
		var c: Vector3i = keys[i]
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(c)))
		multimesh.set_instance_color(i, d.color_of(int(voxel_frame.cells[c])))
