extends "res://tests/test.gd"

var panel: PalettePanel
var field: Button
var original := VoxelFrame.material(Color.RED, Color(0.5, 0, 0), 0.25, 0.25)
var first_drag := PackedFloat32Array()
var start := Vector2.ZERO


func _ready() -> void:
	timeout = 30.0
	test("Material value buttons drag, accept typed values, and cancel with one undo scope", _run)


func _run() -> void:
	step("Given three icon and value buttons", func():
		panel = main.find_child("PalettePanel", true, false)
		main.set_ui_scale(1.0, false)
		State.document = VoxelDocument.new()
		State.set_palette([original])
		State.select_palette_entry(0)
		State.undo_redo.clear_history()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the buttons share one row and use standard UI icons", func():
		var first: Button = panel.get_node("%EmissionStrength")
		for name in ["%EmissionStrength", "%Metallic", "%Roughness"]:
			var control: Button = panel.get_node(name)
			expect(is_equal_approx(control.global_position.y, first.global_position.y), "all material buttons share one row")
			expect(control.icon != null and control.icon.get_size() == Vector2(24, 24), "each button uses a standard-size glyph")
			expect(control.focus_mode != Control.FOCUS_NONE, "each button retains keyboard focus")
			expect(absf(control.size.x - first.size.x) <= 1.0, "the buttons share available width with pixel rounding")
	)
	for name in ["%EmissionStrength", "%Metallic", "%Roughness"]:
		step("When the user drags %s horizontally" % name.trim_prefix("%"), func():
			_restore_original()
			field = panel.get_node(name)
			var before: float = field.value
			start = field.get_global_rect().get_center()
			_button(start, true)
			expect(field.value == before, "pressing keeps the current value")
			_motion(start + Vector2(8, 0), Vector2(8, 0))
			_motion(start + Vector2(40, 0), Vector2(32, 0))
			expect(field.value > before and field.get_node("Fill").visible, "dragging changes the value and shows its slider fill")
			expect(is_equal_approx(field.value, before + 0.2), "forty pixels changes the value by 0.2")
		)
		if name == "%Metallic":
			await _capture("dragging.png")
		step("When the user releases the value button", func():
			_button(start + Vector2(40, 0), false)
		)
		step("Then the drag is one undo action", func():
			expect(not field.get_line_edit().visible and not field.get_node("Fill").visible, "release returns to the value button")
			State.undo_redo.undo()
			expect(State.current_material == original and not State.undo_redo.has_undo(), "one undo restores all original material values")
		)
	step("When two controls are dragged in quick succession", func():
		_restore_original()
		_drag(panel.get_node("%Metallic"))
		first_drag = State.current_material
		_drag(panel.get_node("%Roughness"))
		State.undo_redo.undo()
		expect(State.current_material == first_drag and State.undo_redo.has_undo(), "the second drag keeps a separate undo action")
		State.undo_redo.undo()
		expect(State.current_material == original and not State.undo_redo.has_undo(), "the first drag restores the original material")
	)
	step("When the user clicks and types an exact value", func():
		_restore_original()
		field = panel.get_node("%Metallic")
		_click(field)
		expect(field.get_line_edit().visible and field.get_line_edit().has_focus(), "a click opens focused inline number entry")
		expect(not State.undo_redo.has_undo(), "opening number entry creates no undo action")
		field.get_line_edit().text = "0.625"
	)
	await _capture("typing.png")
	step("When the user confirms the typed value", func():
		_key(KEY_ENTER)
		expect(is_equal_approx(State.current_material[VoxelFrame.MATERIAL_METALLIC], 0.63), "Enter rounds typed values to hundredths")
		expect(field.text == "0.63", "the button displays two decimal places")
		expect(not field.get_line_edit().visible, "Enter returns to the value button")
		State.undo_redo.undo()
		expect(State.current_material == original and not State.undo_redo.has_undo(), "one undo restores the typed edit")
	)
	step("When the user edits a button with the keyboard", func():
		_restore_original()
		field.grab_focus()
		_key(KEY_ENTER)
		expect(field.get_line_edit().visible, "Enter opens number entry on a focused button")
		field.get_line_edit().text = "0.5"
		_key(KEY_ENTER)
		expect(State.current_material[VoxelFrame.MATERIAL_METALLIC] == 0.5, "keyboard entry applies its value")
		State.undo_redo.undo()
		expect(State.current_material == original and not State.undo_redo.has_undo(), "keyboard entry creates one undo action")
	)
	step("When the user cancels typed input", func():
		_restore_original()
		_click(field)
		field.get_line_edit().text = "0.9"
		_key(KEY_ESCAPE)
		expect(State.current_material == original and not State.undo_redo.has_undo(), "Escape preserves the material and undo history")
		expect(not field.get_line_edit().visible, "Escape closes number entry")
	)
	step("When the user cancels a live emission drag", func():
		var legacy := VoxelFrame.material(Color.RED, Color.GREEN, 0.25, 0.25)
		State.set_palette([legacy])
		State.select_palette_entry(0)
		State.undo_redo.clear_history()
		field = panel.get_node("%EmissionStrength")
		start = field.get_global_rect().get_center()
		_button(start, true)
		_motion(start - Vector2(40, 0), Vector2(-40, 0))
		_key(KEY_ESCAPE)
		_button(start - Vector2(40, 0), false)
		expect(State.current_material == legacy and State.get_palette() == [legacy], "cancel restores every original emission component")
		expect(not State.undo_redo.has_undo(), "the cancelled drag adds no undo action")
	)
	step("When the user types a value outside the allowed range", func():
		_restore_original()
		field = panel.get_node("%Roughness")
		_click(field)
		field.get_line_edit().text = "2"
		_key(KEY_ENTER)
		expect(State.current_material[VoxelFrame.MATERIAL_ROUGHNESS] == 1.0, "typed values stay within the material range")
		State.undo_redo.undo()
		expect(State.current_material == original, "undo restores the clamped edit")
	)
	step("When invalid text is submitted", func():
		_restore_original()
		_click(field)
		field.get_line_edit().text = "not a number"
		_key(KEY_ENTER)
		expect(State.current_material == original and not State.undo_redo.has_undo(), "invalid input preserves material values and history")
	)
	step("When an older precise value is opened without editing", func():
		var precise := VoxelFrame.material(Color.RED, Color.BLACK, 0.25, 0.625)
		State.set_palette([precise])
		State.select_palette_entry(0)
		State.undo_redo.clear_history()
		_click(field)
		expect(field.get_line_edit().text == "0.63", "number entry uses two decimal places")
		panel.get_node("%RemoveBtn").grab_focus()
		expect(State.current_material == precise and not State.undo_redo.has_undo(), "display rounding preserves untouched saved values")
	)
	step("When valid number entry loses focus", func():
		_restore_original()
		_click(field)
		field.get_line_edit().text = "0.75"
		panel.get_node("%RemoveBtn").grab_focus()
		expect(State.current_material[VoxelFrame.MATERIAL_ROUGHNESS] == 0.75, "focus loss applies the entered value")
		State.undo_redo.undo()
		expect(State.current_material == original and not State.undo_redo.has_undo(), "focus loss keeps the edit in one undo action")
	)
	step("When another swatch is selected during number entry", func():
		var other := VoxelFrame.material(Color.BLUE, Color.BLACK, 0.75, 0.8)
		State.set_palette([original, other])
		State.select_palette_entry(0)
		State.undo_redo.clear_history()
		_click(field)
		field.get_line_edit().text = "0.9"
		State.select_palette_entry(1)
		field.get_line_edit().text_submitted.emit("0.9")
		expect(State.current_material == other and State.get_palette() == [original, other], "old input cannot change the newly selected swatch")
		expect(not field.get_line_edit().visible and not State.undo_redo.has_undo(), "swatch changes close the old entry without adding history")
	)
	step("When the document changes during number entry", func():
		_click(field)
		field.get_line_edit().text = "0.9"
		State.document = VoxelDocument.new()
		field.get_line_edit().text_submitted.emit("0.9")
		expect(State.get_palette().is_empty() and not State.undo_redo.has_undo(), "old entry cannot change the new document")
		expect(not field.get_line_edit().visible, "document changes close the old number entry")
	)
	step("When a foreground edit disables material controls", func():
		var operation := State.begin_operation("Testing value buttons", 1, true, self)
		_click(field)
		expect(field.disabled and not field.get_line_edit().visible, "disabled material buttons ignore input")
		State.finish_operation(operation)
	)


func _restore_original() -> void:
	State.set_palette([original])
	State.select_palette_entry(0)
	State.undo_redo.clear_history()


func _drag(control: Button) -> void:
	var center := control.get_global_rect().get_center()
	_button(center, true)
	_motion(center + Vector2(8, 0), Vector2(8, 0))
	_motion(center + Vector2(40, 0), Vector2(32, 0))
	_button(center + Vector2(40, 0), false)


func _click(control: Button) -> void:
	var center := control.get_global_rect().get_center()
	_button(center, true)
	_button(center, false)


func _button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = position
	event.global_position = position
	get_tree().root.push_input(event)


func _motion(position: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.position = position
	event.global_position = position
	event.relative = relative
	get_tree().root.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)
	event.pressed = false
	get_tree().root.push_input(event)


func _capture(filename: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_tree().root.get_texture().get_image().save_png(_dir() + "/" + filename)
