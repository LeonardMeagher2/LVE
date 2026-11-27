extends "res://tests/test.gd"


const FIXTURE := preload("res://tests/helpers/marching_fixture.gd")
const VIEW := preload("res://tests/helpers/marching_view.gd")
const MODEL_NAMES: Array[String] = ["Testing2", "Test3", "Testing", "me"]
const MODEL_HASHES := {
	"Testing2": -5498388611216165116,
	"Test3": -7364442111179200461,
	"Testing": 7524680455144278717,
	"me": 6804043150157951673,
}
const SPHERE_HASH := 1883275330112574591
const SPHERE_VERTICES := 3188
const SPHERE_TRIANGLES := 2594
const WARMUPS := 1
const PASSES := 3

var _rows := {}
var _order: Array[String] = []


func _ready() -> void:
	timeout = 900.0
	test("the low-poly mesher keeps its snapshot and reports its cost", _run, "marching_surface")


func _run() -> void:
	step("Given the material sphere and the available prototype models", func():
		_order.append("sphere")
		_rows["sphere"] = _row(FIXTURE.sphere_frame(5, 4), SPHERE_HASH)
		for name: String in MODEL_NAMES:
			var path := "res://LVE-prototypes/%s.lve" % name
			if not FileAccess.file_exists(path):
				print("MEASURE marching_surface %s: skipped, file is absent" % name)
				continue
			var document := VoxelDocument.load_file(path)
			if document == null:
				print("MEASURE marching_surface %s: skipped, file does not load" % name)
				continue
			_order.append(name)
			_rows[name] = _row(document.frames[0], MODEL_HASHES[name])
		expect(_rows.has("sphere"), "the deterministic sphere loads")
	)
	step("When each scene builds warmed and repeated", func():
		for name in _order:
			_measure(name, _rows[name])
	)
	var viewport := await _time_viewport()
	step("Then the editor viewport builds the same sphere surface", func():
		print("MEASURE marching_surface viewport: us=%d vertices=%d triangles=%d" % [
			viewport["us"], viewport["vertices"], viewport["triangles"],
		])
		expect(int(viewport["vertices"]) == SPHERE_VERTICES, "the viewport keeps the sphere vertex count")
		expect(int(viewport["triangles"]) == SPHERE_TRIANGLES, "the viewport keeps the sphere triangle count")
	)
	step("Then every scene keeps its snapshot", func():
		for name in _order:
			var row: Dictionary = _rows[name]
			var medians: Dictionary = row["medians"]
			for pass_data: Dictionary in row["passes"].slice(WARMUPS):
				expect(int(pass_data["hash"]) == int(medians["hash"]), "%s keeps one hash across passes" % name)
			expect(int(medians["hash"]) == int(row["expected_hash"]), "%s keeps its geometry snapshot" % name)
			expect(int(medians["nonempty"]) > 0, "%s builds a surface" % name)
		var sphere: Dictionary = _rows["sphere"]["medians"]
		expect(int(sphere["vertices"]) == SPHERE_VERTICES, "the sphere keeps its vertex count")
		expect(int(sphere["triangles"]) == SPHERE_TRIANGLES, "the sphere keeps its triangle count")
	)


func _row(frame: VoxelFrame, expected_hash: int) -> Dictionary:
	return {"frame": frame, "expected_hash": expected_hash, "passes": [], "medians": {}}


func _measure(name: String, row: Dictionary) -> void:
	var frame: VoxelFrame = row["frame"]
	var locations := FIXTURE.requested_locations(frame)
	var passes: Array = []
	for pass_index in WARMUPS + PASSES:
		var totals := {
			"us": 0, "sample": 0, "field": 0, "cells": 0, "drop": 0, "normals": 0, "merge": 0, "dissolve": 0, "atlas": 0,
			"chunks": locations.size(), "nonempty": 0, "vertices": 0, "triangles": 0, "hash": 5381,
		}
		var started := Time.get_ticks_usec()
		for location: Vector3i in locations:
			var builder := VoxelMarchingMeshBuilder.new()
			builder.profile = true
			builder.source_frame = frame
			builder.chunk_location = location
			builder.run()
			var arrays: Array = builder.surface_arrays
			if not arrays[Mesh.ARRAY_VERTEX].is_empty():
				totals["nonempty"] += 1
				totals["vertices"] += arrays[Mesh.ARRAY_VERTEX].size()
				totals["triangles"] += arrays[Mesh.ARRAY_INDEX].size() / 3
			totals["hash"] = FIXTURE.geometry_hash(arrays, location, totals["hash"])
			totals["sample"] += builder.sample_us
			totals["field"] += builder.field_us
			totals["cells"] += builder.cells_us
			totals["drop"] += builder.drop_us
			totals["normals"] += builder.normals_us
			totals["merge"] += builder.merge_us
			totals["dissolve"] += builder.dissolve_us
			totals["atlas"] += builder.atlas_us
		totals["us"] = Time.get_ticks_usec() - started
		passes.append(totals)
	var medians := {}
	for key in passes[0]:
		medians[key] = _median(passes.slice(WARMUPS), key)
	row["passes"] = passes
	row["medians"] = medians
	print("MEASURE marching_surface %s: chunks=%d nonempty=%d vertices=%d triangles=%d us=%d sample_us=%d field_us=%d cells_us=%d drop_us=%d normals_us=%d merge_us=%d dissolve_us=%d atlas_us=%d hash=%d" % [
		name, medians["chunks"], medians["nonempty"], medians["vertices"], medians["triangles"],
		medians["us"], medians["sample"], medians["field"], medians["cells"], medians["drop"],
		medians["normals"], medians["merge"], medians["dissolve"], medians["atlas"], medians["hash"],
	])


func _median(passes: Array, key: String) -> int:
	var values: Array[int] = []
	for pass_data: Dictionary in passes:
		values.append(int(pass_data[key]))
	values.sort()
	return values[values.size() / 2]


func _time_viewport() -> Dictionary:
	var view = VIEW.new(self)
	var started := Time.get_ticks_usec()
	view.apply(FIXTURE.sphere_materials(5, 4), 1)
	await view.settle()
	var elapsed := Time.get_ticks_usec() - started
	view.collect()
	return {"us": elapsed, "vertices": view.positions.size(), "triangles": view.indices.size() / 3}
