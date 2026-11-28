extends "res://tests/test.gd"


const EXPORT_PALETTE := preload("res://plugins/Export/ExportPalette.gd")


func _ready() -> void:
	test("the export palette maps colors to the nearest entry", _nearest_run, "palette_nearest")
	test("the export palette stops at its color limit", _limit_run, "palette_limit")
	test("the export palette adapts to an image", _adaptive_run, "palette_adaptive")


func _nearest_run() -> void:
	step("Given a palette with black and white", func():
		var palette = EXPORT_PALETTE.new(PackedColorArray([Color.BLACK, Color.WHITE]))
		expect(palette.size() == 3, "the transparent slot comes first")
		expect(palette.nearest(EXPORT_PALETTE.pack(Color8(40, 40, 40))) == 1, "a dark color maps to black")
		expect(palette.nearest(EXPORT_PALETTE.pack(Color8(210, 210, 210))) == 2, "a light color maps to white")
	)


func _limit_run() -> void:
	step("Given more colors than the palette holds", func():
		var colors := PackedColorArray()
		for index in 300:
			colors.append(Color8(index % 256, index / 256, 0))
		var palette = EXPORT_PALETTE.new(colors, EXPORT_PALETTE.MAX_COLORS)
		expect(palette.size() == EXPORT_PALETTE.MAX_COLORS, "the palette stops at the limit")
		expect(not palette.is_empty(), "the palette holds the accepted colors")
	)


func _adaptive_run() -> void:
	step("Given an image with red, blue, and transparent areas", func():
		var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		image.fill(Color8(255, 0, 0))
		for y in 8:
			for x in 8:
				image.set_pixel(x, y, Color8(0, 0, 255))
		for y in 4:
			for x in 12:
				image.set_pixel(x, y, Color8(0, 255, 0, 0))
		var tiles: Array[Image] = [image]
		var colors := EXPORT_PALETTE.adaptive_colors(tiles)
		expect(colors.size() == 2, "the adaptive palette keeps the opaque colors")
		var palette = EXPORT_PALETTE.new(colors, EXPORT_PALETTE.MAX_COLORS)
		var red_index := palette.nearest(EXPORT_PALETTE.pack(Color8(255, 0, 0)))
		expect(palette.packed_at(red_index) == EXPORT_PALETTE.pack(Color8(255, 0, 0)), "the red area keeps its color")
		var blue_index := palette.nearest(EXPORT_PALETTE.pack(Color8(0, 0, 255)))
		expect(palette.packed_at(blue_index) == EXPORT_PALETTE.pack(Color8(0, 0, 255)), "the blue area keeps its color")
	)
	step("Given four opaque colors", func():
		var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		image.fill(Color8(255, 0, 0))
		for y in 8:
			for x in range(8, 16):
				image.set_pixel(x, y, Color8(0, 255, 0))
		for y in range(8, 16):
			for x in 8:
				image.set_pixel(x, y, Color8(0, 0, 255))
			for x in range(8, 16):
				image.set_pixel(x, y, Color8(255, 255, 255))
		var tiles: Array[Image] = [image]
		var colors := EXPORT_PALETTE.adaptive_colors(tiles)
		expect(colors.size() == 4, "the adaptive palette keeps four colors")
		var palette = EXPORT_PALETTE.new(colors, EXPORT_PALETTE.MAX_COLORS)
		for color in [Color8(255, 0, 0), Color8(0, 255, 0), Color8(0, 0, 255), Color8(255, 255, 255)]:
			var index := palette.nearest(EXPORT_PALETTE.pack(color))
			expect(palette.packed_at(index) == EXPORT_PALETTE.pack(color), "each source color keeps its entry")
	)

