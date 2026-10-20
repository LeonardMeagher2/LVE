class_name RotSprite
extends RefCounted

## Rotates a small pixel grid with fewer jags and gaps.
##
## The class upscales the grid with a Scale2x-style pass, then rotates and
## downscales together by nearest-neighbor sampling at the finer resolution.
## An angle that is an exact multiple of 90 degrees uses an exact integer
## rotation instead.

# RotSprite (Xenowhirl): upscale with a Scale2x-style pass, then rotate and downscale together by
# nearest-neighbor sampling at the finer resolution. Reduces the jagged, gap-prone look of rotating
# a small pixel/voxel grid directly. Angles that are an exact multiple of 90 degrees never use this;
# they use an exact integer rotation instead (see RotateTool._compute_new_dest_exact).

## The empty cell color.
const EMPTY := Color.TRANSPARENT
## The number of 2x upscale passes.
const SCALE_STEPS := 3 # three 2x passes = 8x upscale, matching the reference algorithm

var _grid: PackedColorArray
var _w: int
var _h: int
var _scale: int
var _origin: Vector2i
var _src_min: Vector2i
var _src_max: Vector2i


func _init(cells: Dictionary) -> void:
	var keys := cells.keys()
	_src_min = keys[0]
	_src_max = _src_min
	for key in keys:
		var c: Vector2i = key
		_src_min = Vector2i(mini(_src_min.x, c.x), mini(_src_min.y, c.y))
		_src_max = Vector2i(maxi(_src_max.x, c.x), maxi(_src_max.y, c.y))
	_origin = _src_min - Vector2i.ONE
	var max_c := _src_max + Vector2i.ONE
	_w = max_c.x - _origin.x + 1
	_h = max_c.y - _origin.y + 1

	_grid = PackedColorArray()
	_grid.resize(_w * _h)
	_grid.fill(EMPTY)
	for key in keys:
		var c: Vector2i = key
		var lx: int = c.x - _origin.x
		var ly: int = c.y - _origin.y
		_grid[ly * _w + lx] = cells[key]

	_scale = 1
	for _i in SCALE_STEPS:
		var scaled := _scale2x(_grid, _w, _h)
		_grid = scaled[0]
		_w = scaled[1]
		_h = scaled[2]
		_scale *= 2


# Rotates the layer by `angle` radians around `pivot` (both in the same 1x local coordinate
# space the constructor's cells used). Returns a cell -> color dictionary; empty cells are
# omitted.
## Rotates the layer by [param angle] radians around [param pivot]. Both use the
## same local coordinate space as the constructor cells. Returns a cell-to-color
## dictionary. Empty cells are omitted.
func rotate(pivot: Vector2, angle: float) -> Dictionary:
	var corners := [
		Vector2(_src_min.x, _src_min.y),
		Vector2(_src_max.x + 1, _src_min.y),
		Vector2(_src_min.x, _src_max.y + 1),
		Vector2(_src_max.x + 1, _src_max.y + 1),
	]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for corner in corners:
		var rp: Vector2 = (corner - pivot).rotated(angle) + pivot
		lo = lo.min(rp)
		hi = hi.max(rp)
	var min_dest := Vector2i(floori(lo.x), floori(lo.y))
	var max_dest := Vector2i(ceili(hi.x) - 1, ceili(hi.y) - 1)

	var out: Dictionary = {}
	for y in range(min_dest.y, max_dest.y + 1):
		for x in range(min_dest.x, max_dest.x + 1):
			var cell := Vector2i(x, y)
			var color := _sample(cell, pivot, angle)
			if color != EMPTY:
				out[cell] = color
	return out


func _sample(cell: Vector2i, pivot: Vector2, angle: float) -> Color:
	var center := Vector2(cell) + Vector2(0.5, 0.5)
	var back: Vector2 = (center - pivot).rotated(-angle) + pivot
	var gx := int(floor((back.x - float(_origin.x)) * float(_scale)))
	var gy := int(floor((back.y - float(_origin.y)) * float(_scale)))
	if gx < 0 or gy < 0 or gx >= _w or gy >= _h:
		return EMPTY
	return _grid[gy * _w + gx]


# One Scale2x/EPX pass. Treats an out-of-bounds neighbor as the nearest edge pixel.
static func _scale2x(src: PackedColorArray, w: int, h: int) -> Array:
	var nw := w * 2
	var nh := h * 2
	var dst := PackedColorArray()
	dst.resize(nw * nh)
	for y in h:
		for x in w:
			var p := src[y * w + x]
			var a := src[maxi(y - 1, 0) * w + x]
			var b := src[y * w + mini(x + 1, w - 1)]
			var c := src[y * w + maxi(x - 1, 0)]
			var d := src[mini(y + 1, h - 1) * w + x]
			var p1 := a if (c == a and c != d and a != b) else p
			var p2 := b if (a == b and a != c and b != d) else p
			var p3 := c if (d == c and d != b and c != a) else p
			var p4 := d if (b == d and b != a and d != c) else p
			var dx := x * 2
			var dy := y * 2
			dst[dy * nw + dx] = p1
			dst[dy * nw + dx + 1] = p2
			dst[(dy + 1) * nw + dx] = p3
			dst[(dy + 1) * nw + dx + 1] = p4
	return [dst, nw, nh]
