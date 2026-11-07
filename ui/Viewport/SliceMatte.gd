extends MeshInstance3D

## A flat matte of the model around the slice.
##
## It projects every off-slice cell along the slice axis onto the slice plane.
## One texel covers one world column, or a few columns for a large model. The
## slice layer itself is skipped, because the solid plate owns that area. A
## column above the plane reads light and cool. A column below reads dark and
## warm. The nearer the nearest cell, the stronger the matte. The matte is
## static. It has no lines and no animation.

## The largest texture side. A larger footprint downsamples each texel.
const MAX_SIDE := 1024
## The gap below the slice plane. The plate then hides the matte where it holds cells.
const SLICE_GAP := 0.02
## The color of the cells above the plane.
const ABOVE_TINT := Color(0.62, 0.82, 1.0)
## The color of the cells below the plane.
const BELOW_TINT := Color(0.95, 0.55, 0.28)
## The alpha at one layer from the plane, and at [constant FADE_LAYERS] or more.
const NEAR_ALPHA := 0.45
const FAR_ALPHA := 0.12
## The layer distance that reaches [constant FAR_ALPHA].
const FADE_LAYERS := 8
## The largest stored layer distance. The color blend needs no exact far value.
const MAX_DISTANCE := 32

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
	## The first layer of the slice.
	var slice_first := 0
	## The number of slice layers.
	var slice_count := 1
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

	var _above := PackedByteArray()
	var _below := PackedByteArray()
	var _touched := PackedInt32Array()

	## Projects the off-slice cells into the texture. This is the worker body.
	func run() -> void:
		var started := Time.get_ticks_usec()
		var texels := resolution.x * resolution.y
		_above = PackedByteArray()
		_above.resize(texels)
		_below = PackedByteArray()
		_below.resize(texels)
		_touched = PackedInt32Array()
		var chunk_size := VoxelFrame.CHUNK_SIZE
		var completed := 0
		for location: Vector3i in frame.chunks:
			var chunk: VoxelFrame.Chunk = frame.chunks[location]
			if chunk.occupied_count > 0:
				_scan_chunk(chunk, chunk_size)
			completed += 1
			if completed % 32 == 0 and not checkpoint(completed):
				return
		_compose()
		build_us = Time.get_ticks_usec() - started

	# Walks the rows of one chunk and records the nearest off-slab cell on each
	# side, per plane column.
	func _scan_chunk(chunk: VoxelFrame.Chunk, chunk_size: int) -> void:
		var rows := chunk.occupancy_rows()
		var origin := chunk.origin()
		var first_local := slice_first - origin[slice_axis]
		var last_local := first_local + slice_count - 1
		var slice_last := slice_first + slice_count - 1
		if slice_axis == 0:
			for z in chunk_size:
				var world_u := origin.z + z
				for y in chunk_size:
					var mask := rows.masks[y + chunk_size * z]
					if mask == 0:
						continue
					var world_v := origin.y + y
					if first_local >= chunk_size:
						_note(world_u, world_v, origin.x + _lowest_bit(mask) - slice_last, true)
					elif last_local < 0:
						_note(world_u, world_v, slice_first - (origin.x + _highest_bit(mask)), false)
					else:
						if first_local > 0:
							var below_mask := mask & ((1 << mini(first_local, chunk_size)) - 1)
							if below_mask != 0:
								_note(world_u, world_v, first_local - _highest_bit(below_mask), false)
						if last_local < chunk_size - 1:
							var above_mask := mask >> (last_local + 1)
							if above_mask != 0:
								_note(world_u, world_v, _lowest_bit(above_mask) + 1, true)
			return
		# The rows hold x bits. Walk the layer axis outward from the slab, and
		# drop the x bits that a closer layer already claimed.
		for line in chunk_size:
			for zone in 2:
				var above := zone == 0
				var remaining := 0xFFFF
				var layer := 0
				var direction := 1
				if above:
					layer = maxi(0, last_local + 1)
				else:
					layer = mini(chunk_size - 1, first_local - 1)
					direction = -1
				for step_index in chunk_size:
					if layer < 0 or layer >= chunk_size:
						break
					var row := 0
					var plane := 0
					if slice_axis == 1:
						row = layer + chunk_size * line
						plane = origin.z + line
					else:
						row = line + chunk_size * layer
						plane = origin.y + line
					var mask := rows.masks[row] & remaining
					if mask != 0:
						var world := origin[slice_axis] + layer
						var distance := world - slice_last if above else slice_first - world
						for x in chunk_size:
							if (mask & (1 << x)) != 0:
								_note(origin.x + x, plane, distance, above)
						remaining &= ~mask
						if remaining == 0:
							break
					layer += direction

	# Records one plane column. The nearest cell on each side wins.
	func _note(world_u: int, world_v: int, distance: int, above: bool) -> void:
		var tu := (world_u - min_u) / step
		var tv := (world_v - min_v) / step
		if tu < 0 or tu >= resolution.x or tv < 0 or tv >= resolution.y:
			return
		var index := tv * resolution.x + tu
		var capped := mini(distance, MAX_DISTANCE)
		var old_above := _above[index]
		var old_below := _below[index]
		if above:
			if old_above == 0 or capped < old_above:
				_above[index] = capped
		else:
			if old_below == 0 or capped < old_below:
				_below[index] = capped
		if old_above == 0 and old_below == 0:
			_touched.append(index)

	# Blends the two sides and fades by the nearest distance.
	func _compose() -> void:
		pixels = PackedByteArray()
		pixels.resize(resolution.x * resolution.y * 4)
		for index in _touched:
			var above_distance := _above[index]
			var below_distance := _below[index]
			var above_weight := (1.0 / float(above_distance)) if above_distance > 0 else 0.0
			var below_weight := (1.0 / float(below_distance)) if below_distance > 0 else 0.0
			var total := above_weight + below_weight
			var red := (ABOVE_TINT.r * above_weight + BELOW_TINT.r * below_weight) / total
			var green := (ABOVE_TINT.g * above_weight + BELOW_TINT.g * below_weight) / total
			var blue := (ABOVE_TINT.b * above_weight + BELOW_TINT.b * below_weight) / total
			var nearest := above_distance
			if below_distance > 0 and (above_distance == 0 or below_distance < above_distance):
				nearest = below_distance
			var amount := clampf(float(nearest - 1) / float(FADE_LAYERS - 1), 0.0, 1.0)
			var alpha := lerpf(NEAR_ALPHA, FAR_ALPHA, amount)
			var base := index * 4
			pixels[base] = int(round(red * 255.0))
			pixels[base + 1] = int(round(green * 255.0))
			pixels[base + 2] = int(round(blue * 255.0))
			pixels[base + 3] = int(round(alpha * 255.0))
			covered += 1

	# Returns the lowest set bit index of a non-zero mask.
	static func _lowest_bit(mask: int) -> int:
		var index := 0
		while (mask & (1 << index)) == 0:
			index += 1
		return index

	# Returns the highest set bit index of a non-zero mask.
	static func _highest_bit(mask: int) -> int:
		var index := VoxelFrame.CHUNK_SIZE - 1
		while (mask & (1 << index)) == 0:
			index -= 1
		return index


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
	var index := _texel_at(cell_position)
	return 0.0 if index < 0 else _pixels[index * 4 + 3] / 255.0


## Returns the installed matte color at one world cell. A test reads it to check
## the side that the column belongs to.
func color_at(cell_position: Vector3i) -> Color:
	var index := _texel_at(cell_position)
	if index < 0:
		return Color(0, 0, 0, 0)
	var base := index * 4
	return Color(_pixels[base] / 255.0, _pixels[base + 1] / 255.0, _pixels[base + 2] / 255.0, _pixels[base + 3] / 255.0)


# Returns the installed texture index of one world cell, or -1.
func _texel_at(cell_position: Vector3i) -> int:
	if _pixels.is_empty():
		return -1
	var tu := (cell_position[_u_axis] - _min_u) / texel_step
	var tv := (cell_position[_v_axis] - _min_v) / texel_step
	if tu < 0 or tu >= resolution.x or tv < 0 or tv >= resolution.y:
		return -1
	return tv * resolution.x + tu


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
	var first := State.slice_first()
	var last := State.slice_last()
	for cell_position in affected:
		var layer := cell_position[axis]
		if layer < first or layer > last:
			_invalidate()
			return


func _invalidate() -> void:
	_generation += 1
	if _job:
		_job.cancel()
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
	job.slice_first = State.slice_first()
	job.slice_count = State.slice_count()
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
