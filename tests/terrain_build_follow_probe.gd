extends "res://plugins/Terrain/TerrainTool.gd"

## A test-only probe that records the production Build placement of every dab.
##
## The probe never changes the production behavior. It delegates to
## [method TerrainTool._run_dab] and records the observable stroke state after the
## call. The camera capture at the press and the placement policy live in the
## production tool, so the test exercises the real app path.

## The effect center of every Build dab, in application order.
var build_centers: Array = []
## The locked normal of every Build dab.
var build_normals: Array = []
## The operation plane origin of every Build dab.
var build_origins: Array = []


## Clears the recorded Build dabs.
func reset_dabs() -> void:
	build_centers = []
	build_normals = []
	build_origins = []


func _run_dab(cell: Vector3i) -> void:
	if _stroke_tool == TerrainSettings.Tools.BUILD:
		# Record the frame the dab uses, before the dab recenters it.
		build_centers.append(_plane_point(cell))
		build_normals.append(_stroke_frame.normal if _stroke_frame != null else Vector3.ZERO)
		build_origins.append(_stroke_frame.origin if _stroke_frame != null else Vector3.ZERO)
		super._run_dab(cell)
