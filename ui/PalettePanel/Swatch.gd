extends Button

@export var color:Color :
	set(value):
		if color.is_equal_approx(value):
			return
		color = value
		tooltip_text = color.to_html(true)
		var sb_normal:StyleBoxFlat = get_theme_stylebox("normal")
		var sb_pressed:StyleBoxFlat = get_theme_stylebox("pressed")
		sb_normal.bg_color = color
		sb_pressed.bg_color = color
