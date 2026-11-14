class_name DeformToolSettings
extends Resource

## The shared deform tool settings.
##
## The resource holds the active deform tool, the shared brush inputs, and the
## Pose options. The deform toolbar, the option bar, and the deform tools share
## it. The `changed` signal notifies its observers.

## Emitted when [member tool] changes.
signal tool_changed(tool: Tools)

## The deform tool.
enum Tools {
	## Stretch the voxels under the pointer.
	GRAB,
	## Bend the voxels inside the brush around its joint.
	POSE
}

## The active deform tool. Pose is the default.
@export var tool: Tools = Tools.POSE:
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

## The circular footprint size in voxels. It clamps to 1 through 32. A size of
## one is one voxel. An even size centers between cells, like the shared brush
## size.
@export var size := 4:
	set(value):
		value = clampi(value, 1, 32)
		if value == size:
			return
		size = value
		emit_changed()

## Whether the pose angle snaps to a 90 degree step. The fit can still lower it,
## so a blocked snap falls back to the largest angle that fits. It starts off, so
## a drag is free.
@export var snap := false:
	set(value):
		if value == snap:
			return
		snap = value
		emit_changed()

## The edge softness. Zero is a hard edge and one is a smooth edge. Grab scales
## the drag of each source by it. Pose sets the width of the joint neck by it.
@export var falloff := 0.5:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if value == falloff:
			return
		falloff = value
		emit_changed()

## Whether the pose uses only the six face neighbors. On follows faces for the
## joint search and the captured set. Off adds every edge and corner neighbor, so
## a diagonal contact joins both. It starts off.
@export var connected := false:
	set(value):
		if value == connected:
			return
		connected = value
		emit_changed()

