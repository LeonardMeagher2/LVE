extends "res://tests/test.gd"

# Verify the sculpt normal source icon toggle.
#
# The Grow, Flatten, and Smooth tools share one two-state icon button. The
# button shows the current source as an icon, its pressed state marks the Face
# source, and its tooltip names the source. A real button press flips the shared
# resource enum. An external enum change updates the button with no feedback
# write. The Grab tool hides the button. The button carries an icon and no text.

const OptionsScript := preload("res://plugins/Sculpt/Options.gd")

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _options: Node


func _ready() -> void:
	test("a real press toggles the resource enum and the icon", _press_toggles, "press_toggles")
	test("an external change updates the button without feedback", _external_sync, "external_sync")
	test("every fitted tool shows the toggle and Grab hides it", _shared_and_hidden, "shared_hidden")
	test("the toggle has an icon, no text, and keyboard focus", _style, "style")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	_settings.tool = _settings.Tools.GROW
	_settings.normal_source = _settings.NormalSource.SURFACE
	activate_tool("sculpt")
	var sculpt := plugin("SculptPlugin")
	sculpt.activate_tool()
	_options = sculpt._options
	await get_tree().process_frame


func _cleanup_test() -> void:
	if plugin("SculptPlugin") != null:
		plugin("SculptPlugin").deactivate_tool()
		await get_tree().process_frame


func _press_toggles() -> void:
	var control: Button = _options.get_node("Normal")
	step("Given the Surface source and the Grow tool", func():
		# Force a sync through the Face source, so the control state is current.
		_settings.normal_source = _settings.NormalSource.FACE
		_settings.normal_source = _settings.NormalSource.SURFACE
		expect(control.visible, "the Grow tool shows the normal source toggle")
		expect(control.toggle_mode, "the normal source control is a toggle button")
		expect(not control.button_pressed, "the Surface source is not pressed")
		expect(control.icon == OptionsScript.NORMAL_ICONS[0], "the Surface icon is shown")
		expect(control.tooltip_text == OptionsScript.NORMAL_TOOLTIPS[0], "the Surface tooltip is shown")
	)
	step("When the user presses the toggle", func():
		control.button_pressed = true
	)
	step("Then the Face source is chosen and the icon follows", func():
		expect(_settings.normal_source == _settings.NormalSource.FACE, "the press selects the Face source")
		expect(control.icon == OptionsScript.NORMAL_ICONS[1], "the Face icon is shown")
		expect(control.tooltip_text == OptionsScript.NORMAL_TOOLTIPS[1], "the Face tooltip is shown")
	)
	step("When the user presses the toggle again", func():
		control.button_pressed = false
	)
	step("Then the Surface source returns", func():
		expect(_settings.normal_source == _settings.NormalSource.SURFACE, "the second press selects the Surface source")
		expect(control.icon == OptionsScript.NORMAL_ICONS[0], "the Surface icon returns")
		expect(not control.button_pressed, "the Surface source is not pressed")
	)


func _external_sync() -> void:
	var control: Button = _options.get_node("Normal")
	step("When another control changes the source", func():
		_settings.normal_source = _settings.NormalSource.FACE
	)
	step("Then the button follows without a feedback write", func():
		expect(control.button_pressed, "the button shows the pressed Face state")
		expect(control.icon == OptionsScript.NORMAL_ICONS[1], "the button shows the Face icon")
		expect(_settings.normal_source == _settings.NormalSource.FACE, "the external choice is unchanged")
		_settings.normal_source = _settings.NormalSource.SURFACE
		expect(not control.button_pressed, "the button returns to the unpressed Surface state")
		expect(_settings.normal_source == _settings.NormalSource.SURFACE, "the external Surface choice is unchanged")
	)


func _shared_and_hidden() -> void:
	var control: Button = _options.get_node("Normal")
	step("Then every fitted tool shows the toggle and Grab hides it", func():
		for tool in [_settings.Tools.GROW, _settings.Tools.FLATTEN, _settings.Tools.SMOOTH]:
			_settings.tool = tool
			expect(control.visible, "the fitted tool shows the normal source toggle")
		_settings.tool = _settings.Tools.GRAB
		expect(not control.visible, "the Grab tool hides the normal source toggle")
		_settings.tool = _settings.Tools.GROW
	)


func _style() -> void:
	step("Then the toggle has an icon, no text, and keyboard focus", func():
		var control: Button = _options.get_node("Normal")
		expect(control.icon != null, "the toggle shows an icon")
		expect(control.text == "", "the toggle has no text")
		expect(control.icon_alignment == HORIZONTAL_ALIGNMENT_CENTER, "the icon is centered")
		expect(control.focus_mode != Control.FOCUS_NONE, "the toggle keeps keyboard focus")
		expect(OptionsScript.NORMAL_ICONS[0] != null and OptionsScript.NORMAL_ICONS[1] != null, "both source icons load")
		expect(OptionsScript.NORMAL_ICONS[0] != OptionsScript.NORMAL_ICONS[1], "the two source icons differ")
	)
