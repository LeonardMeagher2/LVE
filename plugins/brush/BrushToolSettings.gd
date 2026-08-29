extends Resource

enum BrushMode {
	PENCIL,
	PAINT
}

@export var mode:BrushMode = BrushMode.PENCIL :
	set(value):
		if value == mode:
			return
		mode = value
		emit_changed()

@export var pixel_perfect:bool = false :
	set(value):
		if value == pixel_perfect:
			return
		pixel_perfect = value
		emit_changed()
