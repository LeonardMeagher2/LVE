class_name FramePreview
extends TextureRect

const SIZE := 48
const PAD := 2.0

var _tex: ImageTexture


func set_frame(frame: VoxelFrame, document: VoxiDocument) -> void:
	_tex = _render(frame, document)
	texture = _tex


func _render(frame: VoxelFrame, document: VoxiDocument) -> ImageTexture:
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_fill_checkerboard(img)
	if frame == null or frame.cells.is_empty():
		return ImageTexture.create_from_image(img)
	var bounds := document.bounds()
	if not bounds.has_volume():
		return ImageTexture.create_from_image(img)
	var lo := Vector3i(bounds.position)
	var hi := Vector3i(bounds.position + bounds.size) - Vector3i.ONE
	var sx_min := float(lo.x - hi.z)
	var sx_max := float(hi.x - lo.z)
	var sy_min := (float(lo.x) + float(lo.z)) / 2.0 - float(hi.y)
	var sy_max := (float(hi.x) + float(hi.z)) / 2.0 - float(lo.y)
	var s := (float(SIZE) - 2.0 * PAD) / maxf(sx_max - sx_min + 2.0, sy_max - sy_min + 2.0)
	var mid_x := (sx_min + sx_max) / 2.0
	var mid_y := (sy_min + sy_max) / 2.0
	var cells: Array = []
	for c in frame.cells.keys():
		var depth: float = c.x + c.y + c.z
		cells.append([depth, c, document.color_of(int(frame.cells[c]))])
	cells.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var hw := s
	var hv := s / 2.0
	for item in cells:
		var c: Vector3i = item[1]
		var col: Color = item[2]
		var cx := (float(c.x) - float(c.z) - mid_x) * s + SIZE / 2.0
		var cy := ((float(c.x) + float(c.z)) / 2.0 - float(c.y) - mid_y) * s + SIZE / 2.0
		_draw_cube(img, cx, cy, hw, hv, col)
	return ImageTexture.create_from_image(img)


func _draw_cube(img: Image, cx: float, cy: float, hw: float, hv: float, col: Color) -> void:
	_fill_poly(img, PackedVector2Array([
		Vector2(cx, cy - hw),
		Vector2(cx + hw, cy - hv),
		Vector2(cx, cy),
		Vector2(cx - hw, cy - hv),
	]), col)
	_fill_poly(img, PackedVector2Array([
		Vector2(cx + hw, cy - hv),
		Vector2(cx + hw, cy + hv),
		Vector2(cx, cy + hw),
		Vector2(cx, cy),
	]), col.darkened(0.3))
	_fill_poly(img, PackedVector2Array([
		Vector2(cx - hw, cy - hv),
		Vector2(cx - hw, cy + hv),
		Vector2(cx, cy + hw),
		Vector2(cx, cy),
	]), col.darkened(0.45))


func _fill_checkerboard(img: Image) -> void:
	var step := 6
	var y := 0
	while y < SIZE:
		var x := 0
		while x < SIZE:
			var even := ((x / step) + (y / step)) % 2 == 0
			var c := Color8(42, 42, 46) if even else Color8(54, 54, 60)
			for j in mini(step, SIZE - y):
				for i in mini(step, SIZE - x):
					img.set_pixel(x + i, y + j, c)
			x += step
		y += step


func _fill_poly(img: Image, pts: PackedVector2Array, col: Color) -> void:
	var y_min := pts[0].y
	var y_max := pts[0].y
	for p in pts:
		y_min = minf(y_min, p.y)
		y_max = maxf(y_max, p.y)
	for y in range(maxi(int(ceil(y_min)), 0), mini(int(floor(y_max)), SIZE - 1) + 1):
		var x_l := INF
		var x_r := -INF
		for e in pts.size():
			var a := pts[e]
			var b := pts[(e + 1) % pts.size()]
			if a.y == b.y:
				continue
			var t := (float(y) - a.y) / (b.y - a.y)
			if t < 0.0 or t > 1.0:
				continue
			var x := a.x + t * (b.x - a.x)
			x_l = minf(x_l, x)
			x_r = maxf(x_r, x)
		if x_r < x_l:
			continue
		for x in range(maxi(int(ceil(x_l)), 0), mini(int(floor(x_r)), SIZE - 1) + 1):
			img.set_pixel(x, y, col)
