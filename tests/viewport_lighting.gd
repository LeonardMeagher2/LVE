extends "res://tests/test.gd"

var scene: Node
var light: DirectionalLight3D
var environment: Environment
var _relative := Basis.IDENTITY
var _unlocked := Basis.IDENTITY


func _ready() -> void:
	test("the viewport light and ambient controls update the scene and the document", _color_run)
	test("the light lock follows the camera and resets with the document", _lock_run)
	test("the environment row owns the light widget and shading controls", _environment_run)


func _prepare() -> void:
	scene = viewport_scene()
	light = scene.get_node("Light")
	environment = scene.get_node("WorldEnvironment").environment


func _color_run() -> void:
	step("Given the editor viewport", func():
		_prepare()
	)
	step("When the user changes the light color", func():
		scene.get_node("%LightColor").color_changed.emit(Color(0.2, 0.4, 0.8))
	)
	step("Then the light and the document use the color", func():
		expect(light.light_color.is_equal_approx(Color(0.2, 0.4, 0.8)), "the light uses the new color")
		var saved: Color = State.document.lighting_settings.color
		expect(saved.is_equal_approx(Color(0.2, 0.4, 0.8, 1.0)), "the document stores the new color")
	)
	step("When the user changes the ambient color", func():
		scene.get_node("%AmbientColor").color_changed.emit(Color(0.1, 0.3, 0.2))
	)
	step("Then the environment and the document use the ambient color", func():
		expect(environment.ambient_light_color.is_equal_approx(Color(0.1, 0.3, 0.2)), "the environment uses the new ambient color")
		var saved: Color = State.document.lighting_settings.ambient_color
		expect(saved.is_equal_approx(Color(0.1, 0.3, 0.2, 1.0)), "the document stores the new ambient color")
	)
	step("When a lighting dictionary is applied", func():
		var settings: Dictionary = scene.get_lighting_settings()
		settings.color = Color(0.9, 0.5, 0.1)
		settings.ambient_color = Color(0.2, 0.6, 0.9)
		scene.set_lighting_settings(settings)
	)
	step("Then both color controls follow the applied settings", func():
		expect(scene.get_node("%LightColor").color.is_equal_approx(Color(0.9, 0.5, 0.1)), "the light swatch follows the light color")
		expect(scene.get_node("%AmbientColor").color.is_equal_approx(Color(0.2, 0.6, 0.9)), "the ambient swatch follows the ambient color")
	)
	step("When the user changes the export viewport light color", func():
		var exporter: Node = plugin("ExportPlugin")
		exporter._model_scene.get_node("%LightColor").color_changed.emit(Color(0.1, 0.8, 0.3))
	)
	step("Then the sprite sheet reads the viewport color and lock", func():
		var exporter: Node = plugin("ExportPlugin")
		expect(exporter._sheet_lighting().color.is_equal_approx(Color(0.1, 0.8, 0.3)), "the sprite sheet uses the viewport light color")
		exporter._model_scene.get_node("%LockView").button_pressed = true
		expect(exporter._sheet_lighting().view_locked, "the sprite sheet uses the viewport lock")
		exporter._model_scene.get_node("%LockView").button_pressed = false
	)


func _lock_run() -> void:
	step("Given the editor viewport with a known light direction", func():
		_prepare()
		light.basis = Basis(Vector3.UP, 0.4)
		_relative = camera_rig().basis.inverse() * light.basis
	)
	step("When the user locks the light and orbits the view", func():
		scene.get_node("%LockView").button_pressed = true
		camera_rig().orbit(Vector2(40, 15))
	)
	step("Then the light keeps its angle to the camera", func():
		expect(light.basis.is_equal_approx(camera_rig().basis * _relative), "the locked light follows the camera")
		expect(scene.get_lighting_settings().view_locked, "the viewport reports the lock")
		expect(not State.document.lighting_settings.has("view_locked"), "the document lighting does not store the lock")
	)
	step("When the user unlocks and orbits", func():
		scene.get_node("%LockView").button_pressed = false
		_unlocked = light.basis
		camera_rig().orbit(Vector2(-30, 10))
	)
	step("Then the light does not move", func():
		expect(light.basis.is_equal_approx(_unlocked), "the unlocked light keeps its world direction")
	)
	step("When the user locks again and switches documents", func():
		scene.get_node("%LockView").button_pressed = true
		State.set_tabs([State.new_document()], 0)
	)
	step("Then the lock turns off", func():
		expect(not scene.get_node("%LockView").button_pressed, "the lock button turns off")
		expect(not scene.get_lighting_settings().view_locked, "the viewport lock turns off")
	)


func _environment_run() -> void:
	step("Given the editor viewport", func():
		_prepare()
	)
	step("When the user opens the environment row", func():
		scene.get_node("%EnvironmentMenu").button_pressed = true
	)
	step("Then the row shows", func():
		expect(scene.get_node("%EnvironmentBar").visible, "the environment row shows")
	)
	step("When the user enables the light direction tool", func():
		scene.get_node("%LightToggle").button_pressed = true
	)
	step("Then the light handle shows", func():
		expect(scene.get_node("%LightHandle").visible, "the light handle shows")
		expect(scene.get_node("%LightDirection").visible, "the light direction marker shows")
	)
	step("When the user closes the environment row", func():
		scene.get_node("%EnvironmentMenu").button_pressed = false
	)
	step("Then the light widget turns off", func():
		expect(not scene.get_node("%EnvironmentBar").visible, "the environment row hides")
		expect(not scene.get_node("%LightToggle").button_pressed, "the light direction button turns off")
		expect(not scene.get_node("%LightHandle").visible, "the light handle hides")
	)
	step("When the user reopens the row, enables the light, and turns the light off", func():
		scene.get_node("%EnvironmentMenu").button_pressed = true
		scene.get_node("%LightToggle").button_pressed = true
		scene.get_node("%LightToggle").button_pressed = false
	)
	step("Then the row stays open", func():
		expect(scene.get_node("%EnvironmentBar").visible, "the environment row stays open")
		expect(not scene.get_node("%LightHandle").visible, "the light handle hides")
	)
	step("When the user turns shadows off", func():
		scene.get_node("%Shadows").button_pressed = false
	)
	step("Then the light and the settings report no shadows", func():
		expect(not light.shadow_enabled, "the light stops casting shadows")
		expect(not scene.get_lighting_settings().shadows, "the settings report no shadows")
		scene.get_node("%Shadows").button_pressed = true
	)
	step("When the user enables the light direction and disables shading", func():
		scene.get_node("%LightToggle").button_pressed = true
		scene.get_node("%Shaded").button_pressed = false
	)
	step("Then the viewport renders unshaded and the other controls disable", func():
		expect(scene.get_node("VoxelRenderer").unshaded, "the voxel meshes draw unshaded")
		expect((editor_viewport() as SubViewport).debug_draw == Viewport.DEBUG_DRAW_DISABLED, "the debug mode stays off")
		expect(not scene.get_node("%Shaded").button_pressed, "the Shaded button shows unpressed")
		expect(not scene.get_node("%LightToggle").button_pressed, "the light direction turns off")
		expect(not scene.get_node("%LightHandle").visible, "the light handle hides")
		for name in ["LightToggle", "LockView", "LightColor", "AmbientColor", "Shadows", "Reset"]:
			expect(scene.get_node("%" + name).disabled, "%s disables while lighting is off" % name)
	)
	step("When the user restores shaded lighting", func():
		scene.get_node("%Shaded").button_pressed = true
	)
	step("Then the other controls enable", func():
		for name in ["LightToggle", "LockView", "LightColor", "AmbientColor", "Shadows", "Reset"]:
			expect(not scene.get_node("%" + name).disabled, "%s enables while lighting is on" % name)
	)
	step("When the user changes the lighting and resets", func():
		scene.get_node("%LightColor").color_changed.emit(Color(0, 1, 0))
		scene.get_node("%LockView").button_pressed = true
		scene.get_node("%Shadows").button_pressed = false
		scene.get_node("%Reset").pressed.emit()
	)
	step("Then the default lighting returns", func():
		var defaults: Dictionary = scene._default_lighting
		expect(light.light_color.is_equal_approx(defaults.color), "the light color returns to the default")
		expect(light.shadow_enabled == defaults.shadows, "the shadows return to the default")
		expect(not scene.get_node("%LockView").button_pressed, "the lock turns off")
		expect(scene.get_node("%Shaded").button_pressed, "shading turns on")
	)
