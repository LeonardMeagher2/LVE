class_name TerrainToolSettings
extends Resource

## The shared terrain tool settings.
##
## The resource holds the active terrain tool, the footprint radius, the
## per-application strength, the edge falloff, and the build direction. The terrain
## toolbar, the option bar, and the terrain tool share it. The `changed` signal
## notifies its observers.

## Emitted when [member tool] changes.
signal tool_changed(tool: Tools)

## The terrain tool.
enum Tools {
	## Build the surface outward, or cut it inward.
	BUILD,
	## Fill and cut columns to one flat surface.
	FLATTEN,
	## Relax the surface toward the average of its neighbors.
	SMOOTH
}

## The build direction.
enum BuildMode {
	## Add voxels outward from the surface.
	ADD,
	## Remove voxels inward from the surface.
	REMOVE
}

## The active terrain tool.
@export var tool: Tools = Tools.BUILD:
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

## The circular footprint size in voxels. It clamps to 1 through 32. A size of
## one is one voxel. An even size centers between cells, like the shared brush
## size.
@export var radius := 4:
	set(value):
		value = clampi(value, 1, 32)
		if value == radius:
			return
		radius = value
		emit_changed()

## The voxel layers one dab adds at full weight. The falloff scales it per
## voxel, and a fraction below one half adds nothing. The default of one adds one
## layer to every voxel in the footprint.
@export var strength := 1:
	set(value):
		value = clampi(value, 1, 16)
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

## The build direction. Add grows outward. Remove cuts inward.
@export var build_mode: BuildMode = BuildMode.ADD:
	set(value):
		if value == build_mode:
			return
		build_mode = value
		emit_changed()

