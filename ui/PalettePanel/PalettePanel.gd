class_name PalettePanel
extends VBoxContainer

const Swatch := preload("./Swatch.tscn")
const SwatchButtonGroup := preload("./SwatchButtonGroup.tres")
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

var _import_job: ImportJob

@onready var _swatch_grid: HFlowContainer = %SwatchGrid
@onready var _color_picker: ColorPicker = %ColorPicker
@onready var _color_picker_button: ColorPickerButton = %ColorPickerButton
@onready var _palette_menu: PopupMenu = %PaletteMenu.get_popup()


func _ready() -> void:
	%ImportDialog.filters = PackedStringArray([State.get_image_file_filter()])
	State.document_changed.connect(_rebuild_swatches)
	State.color_changed.connect(_on_color_changed)
	State.palette_changed.connect(_rebuild_swatches)
	State.default_palette_changed.connect(_sync_default_menu)
	State.activity_changed.connect(_sync_buttons)
	State.edit_context_changing.connect(_cancel_import)
	_palette_menu.add_item("Use default palette", PaletteAction.USE_DEFAULT)
	_palette_menu.add_item("Set current palette as default", PaletteAction.SAVE_DEFAULT)
	_palette_menu.set_item_tooltip(1, "Use this palette at startup and in new documents.")
	_palette_menu.id_pressed.connect(_on_palette_action)
	_sync_default_menu()
	
	_on_color_changed(State.current_color)
	_rebuild_swatches()


func _on_color_changed(color: Color) -> void:
	_color_picker.color = color
	_color_picker_button.color = color
	_select_current()


func _rebuild_swatches() -> void:
	for swatch in _swatch_grid.get_children():
		_swatch_grid.remove_child(swatch)
		swatch.queue_free()
	
	var palette := State.get_palette()
	for i in palette.size():
		var swatch = Swatch.instantiate()
		swatch.color = palette[i]
		swatch.toggled.connect(_pick_swatch.bind(palette[i]))
		_swatch_grid.add_child(swatch)
	_select_current()
	_sync_buttons()


func _pick_swatch(toggled_on:bool, color:Color) -> void:
	if toggled_on:
		State.set_color(color)

func _on_picker_color_changed(color: Color) -> void:
	State.set_color(color)


func _select_current() -> void:
	for swatch in _swatch_grid.get_children():
		(swatch as Button).set_pressed_no_signal((swatch.color as Color).is_equal_approx(State.current_color))


func _on_add_btn_pressed() -> void:
	State.add_color()


func _on_remove_btn_pressed() -> void:
	State.remove_color()


func _sync_buttons() -> void:
	var busy := State.edit_busy()
	%AddBtn.disabled = busy
	%RemoveBtn.disabled = busy
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
		push_error("Voxi: palette import failed: %s" % error_string(error))


func _on_export_file_selected(path: String) -> void:
	var error := export_palette(path)
	if error != OK and error != ERR_BUSY:
		push_error("Voxi: palette export failed: %s" % error_string(error))


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
		push_error("Voxi: default palette change failed: %s" % error_string(error))


func import_palette(path: String) -> Error:
	if State.edit_busy() or _import_job:
		return ERR_BUSY
	var document := State.document
	var job := ImportJob.new()
	job.path = path
	_import_job = job
	var operation_id := State.begin_operation("Importing palette", -1, true, self)
	job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Palette import")
	while not WorkerThreadPool.is_task_completed(job.worker_task_id):
		var progress := job.progress()
		State.update_operation(operation_id, progress[1], progress[2], progress[0])
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
	_import_job = null
	State.finish_operation(operation_id)
	if State.document != document or not job.checkpoint(0):
		return ERR_BUSY
	if job.error != OK:
		return job.error
	State.set_palette(job.colors)
	return OK


func export_palette(path: String) -> Error:
	if State.edit_busy():
		return ERR_BUSY
	var colors := State.get_palette()
	if colors.is_empty():
		return ERR_INVALID_DATA
	const SWATCH_SIZE := 16
	var columns := mini(16, colors.size())
	var rows := ceili(colors.size() / float(columns))
	if rows * SWATCH_SIZE > Image.MAX_HEIGHT:
		return ERR_INVALID_DATA
	var image := Image.create(columns * SWATCH_SIZE, rows * SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for index in colors.size():
		var position := Vector2i(index % columns, index / columns) * SWATCH_SIZE
		image.fill_rect(Rect2i(position, Vector2i.ONE * SWATCH_SIZE), colors[index])
	if path.get_extension().to_lower() != "png":
		path += ".png"
	return image.save_png(path)


func _cancel_import() -> void:
	if _import_job:
		_import_job.cancel()


func _exit_tree() -> void:
	if _import_job:
		_import_job.cancel()
		WorkerThreadPool.wait_for_task_completion(_import_job.worker_task_id)
	
