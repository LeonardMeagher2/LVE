class_name PalettePanel
extends VBoxContainer

const Swatch := preload("./Swatch.tscn")
const SwatchButtonGroup := preload("./SwatchButtonGroup.tres")
const IMAGE_SWATCH_SIZE := 16
const PALETTE_PNG_CHUNK := "lvPL"
enum PaletteAction { USE_DEFAULT, SAVE_DEFAULT, RESET_DEFAULT }

class ImportJob extends VoxelFrame.EditJob:
	var path := ""
	var colors := PackedColorArray()
	var error: Error = OK

	func run() -> void:
		var image := Image.new()
		error = State.load_image(path, image)
		if error != OK:
			return
		# Exported palettes name their tile count. Read transparent entries without
		# confusing them with padding or an arbitrary tiled image.
		if _read_tiles(image):
			return
		stage("Reading palette colors", image.get_width() * image.get_height())
		var seen := {}
		var completed := 0
		for y in image.get_height():
			for x in image.get_width():
				var color := image.get_pixel(x, y)
				if color.a > 0.0 and not seen.has(color):
					seen[color] = true
					colors.append(color)
				completed += 1
				if completed % 4096 == 0 and not checkpoint(completed):
					return
		checkpoint(completed)
		if colors.is_empty():
			error = ERR_INVALID_DATA

	func _read_tiles(image: Image) -> bool:
		var count := _tile_count()
		if count <= 0:
			return false
		var columns := mini(16, count)
		if image.get_size() != Vector2i(columns, ceili(count / float(columns))) * IMAGE_SWATCH_SIZE:
			return false
		var tiles := PackedColorArray()
		stage("Reading palette swatches", count)
		for index in count:
			var origin := Vector2i(index % columns, index / columns) * IMAGE_SWATCH_SIZE
			var color := image.get_pixelv(origin)
			for y in IMAGE_SWATCH_SIZE:
				for x in IMAGE_SWATCH_SIZE:
					if image.get_pixelv(origin + Vector2i(x, y)) != color:
						return false
			tiles.append(color)
			if not checkpoint(tiles.size()):
				return true
		colors = tiles
		return true

	func _tile_count() -> int:
		if path.get_extension().to_lower() != "png":
			return 0
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.size() < 8 or bytes.slice(0, 8) != PackedByteArray(VoxelDocument.PNG_SIGNATURE):
			return 0
		var offset := 8
		while offset + 12 <= bytes.size():
			var length := VoxelDocument._u32_be(bytes, offset)
			if length > bytes.size() - offset - 12:
				return 0
			if bytes.slice(offset + 4, offset + 8).get_string_from_ascii() == PALETTE_PNG_CHUNK:
				if length != 4 or VoxelDocument._crc32(bytes.slice(offset + 4, offset + 12)) != VoxelDocument._u32_be(bytes, offset + 12):
					return 0
				var count := VoxelDocument._u32_be(bytes, offset + 8)
				return count if count <= VoxelDocument.MAX_PALETTE_COLORS else 0
			offset += length + 12
		return 0

var _import_job: ImportJob
var _syncing := false
var _applying_control := false
var _editing_drag := false
var _control_edit_revision := 0
var _value_edit_control: Button
var _value_edit_document: VoxelDocument
var _value_edit_index := -1

@onready var _swatch_grid: HFlowContainer = %SwatchGrid
@onready var _color_picker: ColorPicker = %ColorPicker
@onready var _color_picker_button: ColorPickerButton = %ColorPickerButton
@onready var _palette_menu: PopupMenu = %PaletteMenu.get_popup()


func _ready() -> void:
	%ImportDialog.filters = PackedStringArray([State.get_image_file_filter()])
	State.document_changed.connect(_on_document_changed)
	State.material_changed.connect(_on_material_changed)
	State.palette_changed.connect(_rebuild_swatches)
	State.default_palette_changed.connect(_sync_default_menu)
	State.activity_changed.connect(_sync_buttons)
	State.edit_context_changing.connect(_cancel_import)
	_palette_menu.add_item("Use default palette", PaletteAction.USE_DEFAULT)
	_palette_menu.add_item("Set current palette as default", PaletteAction.SAVE_DEFAULT)
	_palette_menu.set_item_tooltip(1, "Use this palette at startup and in new documents.")
	_palette_menu.id_pressed.connect(_on_palette_action)
	_sync_default_menu()
	
	_color_picker_button.pressed.connect(_begin_control_edit)
	_color_picker_button.popup_closed.connect(_on_color_popup_closed)
	for field in [%EmissionStrength, %Metallic, %Roughness]:
		field.edit_started.connect(_begin_value_edit.bind(field))
		field.edit_finished.connect(_end_value_edit.bind(field))
	_on_material_changed()
	_rebuild_swatches()


func _on_material_changed() -> void:
	# An outside change replaces the edit target. Close stale number entry only then.
	if _value_edit_control and not _applying_control and (_value_edit_document != State.document or _value_edit_index != State.current_palette_index):
		_reset_value_edit()
	_syncing = true
	var material := State.current_material
	_color_picker.color = State.current_color
	_color_picker_button.color = State.current_color
	var emission := Color(material[VoxelFrame.MATERIAL_EMISSION], material[VoxelFrame.MATERIAL_EMISSION + 1], material[VoxelFrame.MATERIAL_EMISSION + 2])
	var color := State.current_color
	var maximum := maxf(color.r, maxf(color.g, color.b))
	var strength := maxf(emission.r, maxf(emission.g, emission.b)) / maximum if maximum > 0.0 else 0.0
	%EmissionStrength.set_value_no_signal(strength)
	%Metallic.set_value_no_signal(material[VoxelFrame.MATERIAL_METALLIC])
	%Roughness.set_value_no_signal(material[VoxelFrame.MATERIAL_ROUGHNESS])
	_syncing = false
	_select_current()
	_sync_buttons()


func _on_document_changed() -> void:
	_reset_value_edit()
	_editing_drag = false
	_control_edit_revision += 1
	_on_material_changed()
	_rebuild_swatches()


func _rebuild_swatches() -> void:
	for swatch in _swatch_grid.get_children():
		_swatch_grid.remove_child(swatch)
		swatch.queue_free()
	
	var palette := State.get_palette()
	for i in palette.size():
		var swatch = Swatch.instantiate()
		swatch.cell_material = palette[i]
		swatch.palette_index = i
		swatch.thumbnail_renderer = %MaterialThumbnails
		swatch.toggled.connect(_pick_swatch.bind(i))
		_swatch_grid.add_child(swatch)
	_select_current()
	_sync_buttons()


func _pick_swatch(toggled_on: bool, index: int) -> void:
	if toggled_on:
		State.select_palette_entry(index)

func _on_picker_color_changed(color: Color) -> void:
	if _syncing:
		return
	var material := State.current_material
	material[0] = color.r
	material[1] = color.g
	material[2] = color.b
	material[3] = color.a
	material[VoxelFrame.MATERIAL_EMISSION] = color.r * %EmissionStrength.value
	material[VoxelFrame.MATERIAL_EMISSION + 1] = color.g * %EmissionStrength.value
	material[VoxelFrame.MATERIAL_EMISSION + 2] = color.b * %EmissionStrength.value
	_apply_control_material(material)


func _on_emission_strength_changed(strength: float) -> void:
	if _syncing:
		return
	var material := State.current_material
	var color := State.current_color
	material[VoxelFrame.MATERIAL_EMISSION] = color.r * strength
	material[VoxelFrame.MATERIAL_EMISSION + 1] = color.g * strength
	material[VoxelFrame.MATERIAL_EMISSION + 2] = color.b * strength
	_apply_control_material(material)


func _on_metallic_changed(value: float) -> void:
	if _syncing:
		return
	var material := State.current_material
	material[VoxelFrame.MATERIAL_METALLIC] = value
	_apply_control_material(material)


func _on_roughness_changed(value: float) -> void:
	if _syncing:
		return
	var material := State.current_material
	material[VoxelFrame.MATERIAL_ROUGHNESS] = value
	_apply_control_material(material)


func _apply_control_material(material: PackedFloat32Array) -> void:
	# Mark own edits, so a live change does not close the entry that makes it.
	_applying_control = true
	State.edit_material(material)
	_applying_control = false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _color_picker.get_global_rect().has_point(event.position):
				_editing_drag = true
				_begin_control_edit()
		elif _editing_drag:
			_editing_drag = false
			# The control handles its final value after this input callback.
			_finish_control_edit.call_deferred(_control_edit_revision)


func _on_color_popup_closed() -> void:
	if not _editing_drag:
		_finish_control_edit.call_deferred(_control_edit_revision)


func _begin_value_edit(control: Button) -> void:
	if _value_edit_control and _value_edit_control != control:
		_reset_value_edit()
	_begin_control_edit()
	_value_edit_control = control
	_value_edit_document = State.document
	_value_edit_index = State.current_palette_index


func _end_value_edit(cancelled: bool, control: Button) -> void:
	if _value_edit_control != control:
		return
	_reset_value_edit()
	if cancelled:
		State.cancel_material_edit()
	else:
		State.end_material_edit()


func _reset_value_edit() -> void:
	if is_instance_valid(_value_edit_control):
		_value_edit_control.reset_edit()
	_value_edit_control = null
	_value_edit_document = null
	_value_edit_index = -1


func _begin_control_edit() -> void:
	State.end_material_edit()
	_control_edit_revision += 1
	State.begin_material_edit()


func _finish_control_edit(revision: int) -> void:
	if revision == _control_edit_revision and not _editing_drag:
		State.end_material_edit()


func _select_current() -> void:
	for swatch in _swatch_grid.get_children():
		(swatch as Button).set_pressed_no_signal(swatch.palette_index == State.current_palette_index)


func _on_add_btn_pressed() -> void:
	State.add_material()


func _on_remove_btn_pressed() -> void:
	State.remove_palette_entry()


func _sync_buttons() -> void:
	var busy := State.edit_busy()
	if busy and _value_edit_control:
		_reset_value_edit()
		State.end_material_edit()
	%AddBtn.disabled = busy
	%RemoveBtn.disabled = busy or State.current_palette_index < 0
	_color_picker_button.disabled = busy
	_color_picker.mouse_filter = Control.MOUSE_FILTER_IGNORE if busy else Control.MOUSE_FILTER_STOP
	for field in [%EmissionStrength, %Metallic, %Roughness]:
		field.editable = not busy
	%ImportBtn.disabled = busy
	%ExportBtn.disabled = busy or State.get_palette().is_empty()
	%PaletteMenu.visible = State.get_palette() != State.get_builtin_palette()
	_palette_menu.set_item_disabled(0, busy)
	_palette_menu.set_item_disabled(1, busy or State.get_palette().is_empty())
	var reset_index := _palette_menu.get_item_index(PaletteAction.RESET_DEFAULT)
	if reset_index != -1:
		_palette_menu.set_item_disabled(reset_index, busy)


func _sync_default_menu() -> void:
	var reset_index := _palette_menu.get_item_index(PaletteAction.RESET_DEFAULT)
	if State.default_palette != State.get_builtin_palette():
		if reset_index == -1:
			_palette_menu.add_item("Restore built-in default", PaletteAction.RESET_DEFAULT)
			reset_index = _palette_menu.get_item_index(PaletteAction.RESET_DEFAULT)
			_palette_menu.set_item_tooltip(reset_index, "Use the built-in palette at startup and in new documents.")
	elif reset_index != -1:
		_palette_menu.remove_item(reset_index)
	_sync_buttons()


func _on_import_btn_pressed() -> void:
	%ImportDialog.popup_centered()


func _on_export_btn_pressed() -> void:
	%ExportDialog.popup_centered()


func _on_import_file_selected(path: String) -> void:
	var error := await import_palette(path)
	if error != OK and error != ERR_BUSY:
		push_error("LVE: palette import failed: %s" % error_string(error))


func _on_export_file_selected(path: String) -> void:
	var error := export_palette(path)
	if error != OK and error != ERR_BUSY:
		push_error("LVE: palette export failed: %s" % error_string(error))


func _on_palette_action(id: int) -> void:
	var error: Error = OK
	match id:
		PaletteAction.USE_DEFAULT:
			State.set_palette(State.default_palette)
		PaletteAction.SAVE_DEFAULT:
			error = State.save_default_palette()
		PaletteAction.RESET_DEFAULT:
			error = State.reset_default_palette()
	if error != OK and error != ERR_BUSY:
		push_error("LVE: default palette change failed: %s" % error_string(error))


func import_palette(path: String) -> Error:
	if State.edit_busy() or _import_job:
		return ERR_BUSY
	var document := State.document
	var job := ImportJob.new()
	job.path = path
	_import_job = job
	var operation_id := State.begin_operation("Importing palette", -1, true, self)
	await State.run_edit_job(job, operation_id, "Palette import")
	_import_job = null
	State.finish_operation(operation_id)
	if State.document != document or not job.checkpoint(0):
		return ERR_BUSY
	if job.error != OK:
		return job.error
	var materials: Array[PackedFloat32Array] = []
	for color in job.colors:
		materials.append(VoxelFrame.material(color))
	if not VoxelDocument.valid_palette(materials):
		return ERR_INVALID_DATA
	State.set_palette(materials)
	return OK


func export_palette(path: String) -> Error:
	if State.edit_busy():
		return ERR_BUSY
	var materials := State.get_palette()
	if materials.is_empty():
		return ERR_INVALID_DATA
	const SWATCH_SIZE := 16
	var columns := mini(16, materials.size())
	var rows := ceili(materials.size() / float(columns))
	if rows * SWATCH_SIZE > Image.MAX_HEIGHT:
		return ERR_INVALID_DATA
	var image := Image.create(columns * SWATCH_SIZE, rows * SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for index in materials.size():
		var cell_position := Vector2i(index % columns, floori(index / float(columns))) * SWATCH_SIZE
		image.fill_rect(Rect2i(cell_position, Vector2i.ONE * SWATCH_SIZE), VoxelFrame.material_color(materials[index]))
	if path.get_extension().to_lower() != "png":
		path += ".png"
	var png := image.save_png_to_buffer()
	if png.is_empty():
		return ERR_CANT_CREATE
	var result := png.slice(0, png.size() - 12)
	var chunk := PALETTE_PNG_CHUNK.to_ascii_buffer()
	VoxelDocument._append_u32_be(chunk, materials.size())
	VoxelDocument._append_u32_be(result, 4)
	result.append_array(chunk)
	VoxelDocument._append_u32_be(result, VoxelDocument._crc32(chunk))
	result.append_array(png.slice(png.size() - 12))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(result)
	return file.get_error()


func _cancel_import() -> void:
	if _import_job:
		_import_job.cancel()


func _exit_tree() -> void:
	_reset_value_edit()
	State.end_material_edit()
	if _import_job:
		_import_job.cancel()
		_import_job.wait_for_worker()
	
