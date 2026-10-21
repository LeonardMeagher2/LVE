class_name SculptToolSettings
extends Resource

## The shared sculpt tool settings.
##
## The resource holds the active sculpt tool, the footprint radius, the
## per-application strength, the edge falloff, and the grow direction. The sculpt
## toolbar, the option bar, and the sculpt tool share it. The `changed` signal
## notifies its observers.

## Emitted when [member tool] changes.
signal tool_changed(tool: Tools)

## The sculpt tool.
enum Tools {
	## Grow the surface outward, or cut it inward.
	GROW,
	## Fill and cut columns to one flat surface.
	FLATTEN,
	## Stretch the voxels under the pointer.
	GRAB,
	## Relax the surface toward the average of its neighbors.
	SMOOTH
}

## The grow direction.
enum GrowMode {
	## Add voxels outward from the surface.
	ADD,
	## Remove voxels inward from the surface.
	REMOVE
}

## The source of the plane normal.
enum NormalSource {
	## Derive the plane from the nearby voxels.
	SURFACE,
	## Use the exact face of the hovered voxel.
	FACE
}

## The active sculpt tool.
@export var tool: Tools = Tools.GROW:
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

## The circular footprint radius in voxels. It clamps to 1 through 32.
@export var radius := 4:
	set(value):
		value = clampi(value, 1, 32)
		if value == radius:
			return
		radius = value
		emit_changed()

## The voxel steps one application applies at full weight. The default of one
## shows one layer at the brush center on a press or a one-cell move.
@export var strength := 1.0:
	set(value):
		value = clampf(value, 0.1, 16.0)
		if value == strength:
			return
		strength = value
		emit_changed()

## The edge softness. Zero is a hard edge and one is a smooth edge.
@export var falloff := 0.5:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if value == falloff:
			return
		falloff = value
		emit_changed()

## The grow direction. Add grows outward. Remove cuts inward.
@export var grow_mode: GrowMode = GrowMode.ADD:
	set(value):
		if value == grow_mode:
			return
		grow_mode = value
		emit_changed()

## The source of the plane normal. Surface derives the plane from the nearby
## voxels. Face uses the exact face of the hovered voxel, so Grow and Flatten
## follow that one face and Smooth keeps its outward direction while it edits.
@export var normal_source: NormalSource = NormalSource.SURFACE:
	set(value):
		if value == normal_source:
			return
		normal_source = value
		emit_changed()
