class_name PickResult
extends RefCounted

## Holds the result of one voxel pick.
##
## A picking function fills the fields for a ray. A cell value of
## [constant VoxelPicking.NONE] means that the pick found no cell.

## The cell that the tool acts on. A voxel pick uses the hit cell. A drag uses
## the cell under the pointer on the drag plane.
var target := VoxelPicking.NONE
## The occupied cell that the ray hit. It is [constant VoxelPicking.NONE] when
## the ray misses the model.
var hit := VoxelPicking.NONE
## The face step from the hit cell toward the ray origin. It selects the add
## cell.
var entry := Vector3i.ZERO
## The empty cell next to the hit face. A paint tool adds here to build on the
## surface.
var add_target := VoxelPicking.NONE
## The drag plane for this pick. A drag maps the pointer onto this plane.
var plane: StrokePlane = null
