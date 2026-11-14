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
	## Bend a connected limb around its joint.
	POSE
}

## The set of cells that the Pose brush moves.
enum Reach {
	## Every connected cell on the tip side of the joint.
	LIMB,
	## Only the cells inside the brush ring.
	SPHERE
}

## The active deform tool.
@export var tool: Tools = Tools.GRAB:
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

## The edge softness. Zero is a hard edge and one is a smooth edge. Grab scales
## the drag of each source by it. Pose sets the width of the joint neck by it.
@export var falloff := 0.5:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if value == falloff:
			return
		falloff = value
		emit_changed()

## The set of cells that the Pose brush moves.
@export var reach: Reach = Reach.LIMB:
	set(value):
		if value == reach:
			return
		reach = value
		emit_changed()

