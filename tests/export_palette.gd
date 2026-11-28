extends "res://tests/test.gd"


const EXPORT_PALETTE := preload("res://plugins/Export/ExportPalette.gd")


func _ready() -> void:
	test("the export palette maps colors to the nearest entry", _nearest_run, "palette_nearest")
	test("the export palette stops at its color limit", _limit_run, "palette_limit")
	test("the export palette falls back to a color cube", _cube_run, "palette_cube")


func _nearest_run() -> void:
	step("Given a palette with black and white", func():
		var palette = EXPORT_PALETTE.new(PackedColorArray([Color.BLACK, Color.WHITE]), EXPORT_PALETTE.MAX_COLORS, false)
		expect(palette.size() == 3, "the transparent slot comes first")
		expect(palette.nearest(EXPORT_PALETTE.pack(Color8(40, 40, 40))) == 1, "a dark color maps to black")
		expect(palette.nearest(EXPORT_PALETTE.pack(Color8(210, 210, 210))) == 2, "a light color maps to white")
	)


func _limit_run() -> void:
	step("Given more colors than the palette holds", func():
		var colors := PackedColorArray()
		for index in 300:
			colors.append(Color8(index % 256, index / 256, 0))
		var palette = EXPORT_PALETTE.new(colors, EXPORT_PALETTE.MAX_COLORS, false)
		expect(palette.size() == EXPORT_PALETTE.MAX_COLORS, "the palette stops at the limit")
		expect(not palette.is_empty(), "the palette holds the accepted colors")
	)


func _cube_run() -> void:
	step("Given no document colors", func():
		var palette = EXPORT_PALETTE.new()
		expect(palette.size() == 217, "the fallback cube holds 216 colors plus transparency")
	)

