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
	var lo := Vector3i.MAX
	var hi := Vector3i.MIN
	for c in frame.cells.keys():
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	var sx_min := float(lo.x - hi.z)
	var sx_max := float(hi.x - lo.z)
	var sy_min := (float(lo.x) + float(lo.z)) / 2.0 - float(hi.y)
	var sy_max := (float(hi.x) + float(hi.z)) / 2.0 - float(lo.y)
	var s := (float(SIZE) - 2.0 * PAD) / maxf(sx_max - sx_min, sy_max - sy_min)
	var mid_x := (sx_min + sx_max) / 2.0
	var mid_y := (sy_min + sy_max) / 2.0
	var cells: Array = []
	for c in frame.cells.keys():
		var depth: float = c.x - c.y
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
	_fill_diamond(img, cx, cy, hw, hv, col)
	_fill_diamond(img, cx, cy + hv, hw, hv, col.darkened(0.45))
	_fill_diamond(img, cx + hw, cy + hv / 2.0, hw, hv, col.darkened(0.3))


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


func _fill_diamond(img: Image, cx: float, cy: float, w: float, v: float, col: Color) -> void:
	var i := int(floor(cy - v / 2.0))
	while i <= int(ceil(cy + v / 2.0)) and i < SIZE:
		if i < 0:
			i += 1
			continue
		var yy: float = float(i)
		var half := w * (1.0 - absf(yy - cy) / v)
		if half <= 0.0:
			i += 1
			continue
		var x0 := int(ceil(cx - half))
		var x1 := int(floor(cx + half))
		if x1 < 0 or x0 >= SIZE:
			i += 1
			continue
		for x in range(maxi(x0, 0), mini(x1, SIZE - 1) + 1):
			img.set_pixel(x, i, col)
		i += 1
