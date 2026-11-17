class_name PrimitiveToolSettings
extends Resource

## The shared primitive tool settings.
##
## The resource is shared by the primitive toolbar, the option bar, and the
## tools. The exported scalar values are saved with the active document.

## Emitted when the active primitive tool changes.
signal tool_changed(tool: Tools)
## Emitted when the option bar requests a commit.
signal commit_requested()
## Emitted when the option bar requests a cancel.
signal cancel_requested()

## The primitive tool.
enum Tools {
	## An axis-aligned box.
	BOX,
	## An axis-aligned ellipsoid.
	ELLIPSOID,
	## A cone with two radii.
	CONE
}

## The operation that the primitive applies.
enum Op {
	## Add the primitive cells.
	ADD,
	## Remove the primitive cells.
	SUBTRACT,
	## Keep only the existing cells inside the primitive.
	INTERSECT
}

## The active primitive tool.
@export var tool: Tools = Tools.BOX:
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

## The primitive operation.
@export var op: Op = Op.ADD:
	set(value):
		if value == op:
			return
		op = value
		emit_changed()

## The smooth blend from 0 to 1. One is the largest blend that the shape
## allows, which is half of its smallest extent.
@export_range(0.0, 1.0, 0.05) var smooth := 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(value, smooth):
			return
		smooth = value
		emit_changed()

## The shell thickness in cells. Zero means a solid shape.
@export_range(0, 16, 1) var shell := 0:
	set(value):
		value = clampi(value, 0, 16)
		if value == shell:
			return
		shell = value
		emit_changed()

## The narrow cone radius from 0 to 1. One equals the base radius, which makes
## a cylinder. Zero makes a point.
@export_range(0.0, 1.0, 0.01) var second_radius := 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(value, second_radius):
			return
		second_radius = value
		emit_changed()

## The rotation around the shape center in Euler degrees, applied in XYZ order.
## It turns every primitive that the tool builds.
@export var rotation_degrees := Vector3.ZERO:
	set(value):
		value = Vector3(wrapf(value.x, 0.0, 360.0), wrapf(value.y, 0.0, 360.0), wrapf(value.z, 0.0, 360.0))
		if value.is_equal_approx(rotation_degrees):
			return
		rotation_degrees = value
		emit_changed()

## The roundness from 0 to 1. It rounds cube edges and blends the cone between
## flat and round ends.
@export_range(0.0, 1.0, 0.05) var roundness := 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(value, roundness):
			return
		roundness = value
		emit_changed()

## Whether a primitive is pending. The option bar enables Commit and Cancel.
var editing := false:
	set(value):
		if value == editing:
			return
		editing = value
		emit_changed()

## Emits [signal commit_requested].
func commit() -> void:
	commit_requested.emit()

## Emits [signal cancel_requested].
func cancel() -> void:
	cancel_requested.emit()
