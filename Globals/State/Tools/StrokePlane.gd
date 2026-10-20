class_name StrokePlane
extends RefCounted

## A flat plane that a drag maps onto.
##
## A tool keeps one plane for an open stroke. The plane faces one world axis.

## The world axis that the plane faces. Axis 0 is X, axis 1 is Y, and axis 2 is
## Z.
var axis := 0
## The cell index along [member axis] that the plane holds.
var idx := 0
## A point on the plane in world space.
var point := Vector3.ZERO
## The unit plane normal. It points along [member axis].
var normal := Vector3.ZERO
