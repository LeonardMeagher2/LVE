class_name PickRequest
extends RefCounted

## Describes one voxel pick request.
##
## A tool fills the fields for a ray, then passes the request to a picking
## function. The request holds the input only. It holds no result.

## The ray origin in world space.
var origin := Vector3.ZERO
## The normalized ray direction.
var dir := Vector3.ZERO
## The frame that the ray tests. A null frame skips the voxel test.
var frame: VoxelFrame
## The drag plane. A null plane starts a press pick instead of a drag pick.
var plane: StrokePlane = null
## The camera forward direction. It selects the view axis.
var forward := Vector3.ZERO
## Whether the pick targets the floor layer instead of the front-most voxel.
var slice := false
