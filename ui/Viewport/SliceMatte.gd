extends MeshInstance3D

## A flat matte of the model around the slice.
##
## It projects every off-slice cell along the slice axis onto the slice plane.
## One texel covers one world column, or a few columns for a large model. The
## slice layer itself is skipped, because the solid plate owns that area. The
## matte is static. It has no lines and no animation.

## The largest texture side. A larger footprint downsamples each texel.
const MAX_SIDE := 1024
## The gap below the slice plane. The plate then hides the matte where it holds cells.
const SLICE_GAP := 0.02
## The matte color.
const TINT := Color(0.62, 0.78, 1.0)
## The matte alpha of a covered column.
const ALPHA := 0.32

## The number of builds that started. A test reads it to prove a skipped rebuild.
var build_count := 0
## The plane coordinate of the installed matte.
var plane_coordinate := 0.0
## The texture side of the installed matte.
var resolution := Vector2i.ZERO
## The world cells that one texel covers along each plane axis.
var texel_step := 1

var _pixels := PackedByteArray()
var _u_axis := 0
var _v_axis := 2
var _min_u := 0
var _min_v := 0
var _job: MatteJob
var _pending := false
var _generation := 0
var _material: StandardMaterial3D


## One footprint build. It reads a frame snapshot on the worker pool.
class MatteJob extends VoxelFrame.EditJob:
	## The frame snapshot to project.
	var frame: VoxelFrame
	## The world axis that the slice limits.
	var slice_axis := 1
	## The cell index of the slice layer.
	var slice_index := 0
	## The world axis of the matte texture u coordinate.
	var u_axis := 0
	## The world axis of the matte texture v coordinate.
	var v_axis := 2
	## The first world cell on the u axis.
	var min_u := 0
	## The first world cell on the v axis.
	var min_v := 0
	## The world cells that one texel covers on both plane axes.
	var step := 1
	## The texture side.
	var resolution := Vector2i.ONE
	## The generation that requested this build.
	var generation := 0
	## The packed RGBA bytes of the built matte.
	var pixels := PackedByteArray()
	## The number of covered texels that the build found.
	var covered := 0
	## The build microseconds.
	var build_us := 0

	## Projects the off-slice cells into the texture. This is the worker body.
	func run() -> void:
		var started := Time.get_ticks_usec()
		pixels = PackedByteArray()
		pixels.resize(resolution.x * resolution.y * 4)
		var chunk_size := VoxelFrame.CHUNK_SIZE
		var tint_r := int(round(TINT.r * 255.0))
		var tint_g := int(round(TINT.g * 255.0))
		var tint_b := int(round(TINT.b * 255.0))
		var alpha_byte := int(round(ALPHA * 255.0))
		var completed := 0
		for location: Vector3i in frame.chunks:
			var chunk: VoxelFrame.Chunk = frame.chunks[location]
			if chunk.occupied_count > 0:
				var rows := chunk.occupancy_rows()
				var origin := chunk.origin()
				var slice_local := -1
				if slice_index >= origin[slice_axis] and slice_index < origin[slice_axis] + chunk_size:
					slice_local = slice_index - origin[slice_axis]
				# A row holds the x bits of one local (y, z). Collapse the slice
				# axis into one plane bit per texel, so the chunk costs one pass
				# over its rows, not one pass over its cells.
				match slice_axis:
					0:
						for z in chunk_size:
							for y in chunk_size:
								var mask := rows.masks[y + chunk_size * z]
								if slice_local >= 0:
									mask &= ~(1 << slice_local)
								if mask != 0:
									_write_texel(origin.z + z, origin.y + y, tint_r, tint_g, tint_b, alpha_byte)
					1:
						for z in chunk_size:
							var union := 0
							for y in chunk_size:
								if y != slice_local:
									union |= rows.masks[y + chunk_size * z]
							if union == 0:
								continue
							for x in chunk_size:
								if (union & (1 << x)) != 0:
									_write_texel(origin.x + x, origin.z + z, tint_r, tint_g, tint_b, alpha_byte)
					_:
						for y in chunk_size:
							var union := 0
							for z in chunk_size:
								if z != slice_local:
									union |= rows.masks[y + chunk_size * z]
							if union == 0:
								continue
							for x in chunk_size:
								if (union & (1 << x)) != 0:
									_write_texel(origin.x + x, origin.y + y, tint_r, tint_g, tint_b, alpha_byte)
			completed += 1
			if completed % 32 == 0 and not checkpoint(completed):
				return
		build_us = Time.get_ticks_usec() - started


	# Writes one covered texel. A texel outside the texture is skipped.
	func _write_texel(world_u: int, world_v: int, tint_r: int, tint_g: int, tint_b: int, alpha_byte: int) -> void:
		var tu := (world_u - min_u) / step
		var tv := (world_v - min_v) / step
		if tu < 0 or tu >= resolution.x or tv < 0 or tv >= resolution.y:
			return
		var base := (tv * resolution.x + tu) * 4
		if pixels[base + 3] != 0:
			return
		pixels[base] = tint_r
		pixels[base + 1] = tint_g
		pixels[base + 2] = tint_b
		pixels[base + 3] = alpha_byte
		covered += 1


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_color = Color.WHITE
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material_override = _material
	visible = false
	State.slice_changed.connect(_on_slice_state_changed)
	State.floor_plane_changed.connect(_on_slice_state_changed)
	State.document_changed.connect(_on_model_changed)
	State.frame_changed.connect(_on_model_changed)
	State.cells_changed.connect(_on_cells_changed)
	_on_slice_state_changed()


func _process(_delta: float) -> void:
	if _job:
		if WorkerThreadPool.is_task_completed(_job.worker_task_id):
			WorkerThreadPool.wait_for_task_completion(_job.worker_task_id)
			var job := _job
			_job = null
			if job.generation == _generation and State.slice_enabled:
				_install(job)
		return
	if _pending:
		_start_build()


## Returns [code]true[/code] when no build is running and none waits.
func is_settled() -> bool:
	return _job == null and not _pending


## Returns the installed matte alpha at one world cell, from 0 to 1. A test reads
## it to check the coverage without a screen readback.
func coverage_at(cell_position: Vector3i) -> float:
	if _pixels.is_empty():
		return 0.0
	var tu := (cell_position[_u_axis] - _min_u) / texel_step
	var tv := (cell_position[_v_axis] - _min_v) / texel_step
	if tu < 0 or tu >= resolution.x or tv < 0 or tv >= resolution.y:
		return 0.0
	return _pixels[(tv * resolution.x + tu) * 4 + 3] / 255.0


func _on_slice_state_changed() -> void:
	_invalidate()


func _on_model_changed() -> void:
	_invalidate()


# A cell write on the slice layer cannot change the matte. A write anywhere else
# can, and an unknown cell list always rebuilds.
func _on_cells_changed(frame_index: int, affected: Array[Vector3i]) -> void:
	if not State.slice_enabled or frame_index != State.current_frame:
		return
	if affected.is_empty():
		_invalidate()
		return
	var axis := int(State.floor_axis)
	for cell_position in affected:
		if cell_position[axis] != State.floor_index:
			_invalidate()
			return


func _invalidate() -> void:
	_generation += 1
	if not State.slice_enabled:
		_pending = false
		visible = false
		return
	_pending = true


func _start_build() -> void:
	_pending = false
	var frame := State.get_current_voxel_frame()
	if frame == null:
		visible = false
		return
	var bounds := frame.get_bounds()
	if not bounds.has_volume():
		visible = false
		return
	var axis := int(State.floor_axis)
	var u_axis := 0
	var v_axis := 0
	match axis:
		0:
			u_axis = 2
			v_axis = 1
		1:
			u_axis = 0
			v_axis = 2
		_:
			u_axis = 0
			v_axis = 1
	var min_u := roundi(bounds.position[u_axis] + 0.5)
	var min_v := roundi(bounds.position[v_axis] + 0.5)
	var count_u := roundi(bounds.size[u_axis])
	var count_v := roundi(bounds.size[v_axis])
	var step := maxi(1, ceili(float(maxi(count_u, count_v)) / MAX_SIDE))
	var res := Vector2i(ceili(float(count_u) / step), ceili(float(count_v) / step))
	if res.x <= 0 or res.y <= 0:
		visible = false
		return
	var job := MatteJob.new()
	job.frame = frame.copy_frame()
	job.slice_axis = axis
	job.slice_index = State.floor_index
	job.u_axis = u_axis
	job.v_axis = v_axis
	job.min_u = min_u
	job.min_v = min_v
	job.step = step
	job.resolution = res
	job.generation = _generation
	build_count += 1
	_job = job
	job.worker_task_id = WorkerThreadPool.add_task(job.run, false, "Slice matte")


func _install(job: MatteJob) -> void:
	if job.covered <= 0:
		visible = false
		return
	var image := Image.create_from_data(job.resolution.x, job.resolution.y, false, Image.FORMAT_RGBA8, job.pixels)
	_material.albedo_texture = ImageTexture.create_from_image(image)
	_pixels = job.pixels
	resolution = job.resolution
	texel_step = job.step
	_u_axis = job.u_axis
	_v_axis = job.v_axis
	_min_u = job.min_u
	_min_v = job.min_v
	plane_coordinate = State.slice_level() - SLICE_GAP
	mesh = _quad_mesh(job)
	visible = true


# Builds the plane quad in world space. The quad edge follows the texture, so a
# texel center lands on its world cell.
func _quad_mesh(job: MatteJob) -> ArrayMesh:
	var u0 := float(job.min_u) - 0.5
	var v0 := float(job.min_v) - 0.5
	var u1 := u0 + float(job.resolution.x * job.step)
	var v1 := v0 + float(job.resolution.y * job.step)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		_corner(u0, v0, job),
		_corner(u1, v0, job),
		_corner(u0, v1, job),
		_corner(u1, v1, job),
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 2, 1, 3])
	var surface := ArrayMesh.new()
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return surface


func _corner(u: float, v: float, job: MatteJob) -> Vector3:
	var point := Vector3.ZERO
	point[job.u_axis] = u
	point[job.v_axis] = v
	point[job.slice_axis] = plane_coordinate
	return point
