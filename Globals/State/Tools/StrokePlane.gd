class_name StrokePlane
extends RefCounted

## A flat plane that a drag maps onto.
##
## A tool keeps one plane for an open stroke. Most tools face the plane to one
## world axis. A transform view-axis drag can use the camera normal.

## The world axis that the plane faces. Axis 0 is X, axis 1 is Y, and axis 2 is
## Z.
var axis := 0
## The cell index along [member axis] that the plane holds.
var idx := 0
## A point on the plane in world space.
var point := Vector3.ZERO
## The unit plane normal. Most tools point it along [member axis]. A transform
## view-axis drag points it at the camera.
var normal := Vector3.ZERO
