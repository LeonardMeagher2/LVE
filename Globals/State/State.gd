extends Node


signal document_changed()
signal document_deactivating()
signal cells_changed(layer: int, frame: int, affected: Array[Vector3i])
signal document_saved(document: VoxelDocument)
signal workspace_capture_requested()
signal chunks_changed(layer: int, frame: int, affected: Array[Vector3i])
signal frames_changed()
signal frame_changed()
signal layers_changed()
signal active_layer_changed()
signal notice(text: String)
signal is_playing_toggled(toggled_on:bool)
signal color_changed(color: Color)
signal material_changed()
signal palette_changed()
signal default_palette_changed()
signal selection_changed()
signal floor_plane_changed()
signal slice_changed()
signal size_changed()
signal symmetry_changed()
signal tag_changed()
signal activity_changed()
signal edit_context_changing()
signal model_settings_changed()
signal history_changed()
signal edit_state_changed()
signal tabs_changed()
signal active_tab_changed()

const OperationRegistry := preload("res://Globals/State/OperationRegistry.gd")
const SettingsStore := preload("res://Globals/State/SettingsStore.gd")
const DocumentSession := preload("res://Globals/State/DocumentSession.gd")
const SelectionState := preload("res://Globals/State/SelectionState.gd")
const MaterialState := preload("res://Globals/State/MaterialState.gd")
const EditSession := preload("res://Globals/State/EditSession.gd")
const EditingAids := preload("res://Globals/State/EditingAids.gd")
const Operation := OperationRegistry.Operation
const IMAGE_EXTENSIONS := SettingsStore.IMAGE_EXTENSIONS

const WORK_SLICE_US := 3000
const DEFAULT_PALETTE_PATH := MaterialState.DEFAULT_PALETTE_PATH
const DEFAULT_SYMMETRY_ORIGIN := EditingAids.DEFAULT_SYMMETRY_ORIGIN
const MAX_SLICE_LAYERS := EditingAids.MAX_SLICE_LAYERS

var operations := OperationRegistry.new()
var settings := SettingsStore.new()
var settings_path: String:
	get:
		return settings.settings_path
	set(value):
		settings.settings_path = value
var _plugin_host: PluginHost

var _erase_job: EraseJob
var _erase_operation_id := 0
var _erase_jobs: Array[EraseJob] = []

class EraseJob extends VoxelFrame.EditJob:
	var edited_frame: VoxelFrame
	var edited_layer := 0
	var selection_mask := {}
	var changed_chunks: Array[Vector3i] = []

	func run() -> void:
		stage("Preparing erase", selection_mask.size())
		var changes := {}
		var erased_material := VoxelFrame.material(Color.TRANSPARENT)
		var completed := 0
		for cell_position in selection_mask:
			changes[cell_position] = erased_material
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		stage("Erasing selection", changes.size())
		changed_chunks = edited_frame.set_cells(changes, self, erased_material)


var session := DocumentSession.new()
var selection_state := SelectionState.new()
var material_editing := MaterialState.new()
var edits := EditSession.new()
var aids := EditingAids.new()
var playback: AnimationPlayback:
	get:
		return session.playback
var tabs: Array[VoxelDocument]:
	get:
		return session.tabs
var active_tab: int:
	get:
		return session.active_tab
	set(value):
		session.active_tab = value
var document: VoxelDocument:
	get:
		return session.document
	set(value):
		set_document(value)

var current_frame: int:
	get:
		return playback.current_frame
	set(value):
		playback.current_frame = value

var is_playing: bool:
	get:
		return playback.is_playing
	set(value):
		playback.is_playing = value

var active_tag: int:
	get:
		return playback.active_tag
	set(value):
		playback.active_tag = value

var active_layer_index: int:
	get:
		return document.edit_layer
	set(value):
		set_active_layer(value)


func set_active_layer(index: int) -> void:
	if index < 0 or index >= document.layers.size() or index == document.edit_layer:
		return
	edit_context_changing.emit()
	_cancel_active_edit()
	document.edit_layer = index
	active_layer_changed.emit()


func _cancel_active_edit() -> void:
	var tx := edits.active_edit()
	if tx != null:
		cancel_edit(tx)


func active_layer_editable() -> bool:
	var layer := document.active_layer()
	return layer != null and layer.visible and not layer.locked


func set_layer_visible(index: int, value: bool, record_history := true) -> void:
	if index < 0 or index >= document.layers.size():
		return
	var layer := document.layers[index]
	if layer.visible == value:
		return
	if record_history:
		undo_redo.create_action("Show Layer" if value else "Hide Layer")
		undo_redo.add_undo_method(_apply_layer_visible.bind(layer, not value))
		undo_redo.add_do_method(_apply_layer_visible.bind(layer, value))
		_commit_history(false)
	_apply_layer_visible(layer, value)


func _apply_layer_visible(layer: VoxelLayer, value: bool) -> void:
	if layer.visible == value:
		return
	layer.visible = value
	document.invalidate_bounds()
	document.invalidate_composite()
	if not value and layer == document.active_layer():
		edit_context_changing.emit()
		_cancel_active_edit()
	layers_changed.emit()


func set_layer_locked(index: int, value: bool, record_history := true) -> void:
	if index < 0 or index >= document.layers.size():
		return
	var layer := document.layers[index]
	if layer.locked == value:
		return
	if record_history:
		undo_redo.create_action("Lock Layer" if value else "Unlock Layer")
		undo_redo.add_undo_method(_apply_layer_locked.bind(layer, not value))
		undo_redo.add_do_method(_apply_layer_locked.bind(layer, value))
		_commit_history(false)
	_apply_layer_locked(layer, value)


func _apply_layer_locked(layer: VoxelLayer, value: bool) -> void:
	if layer.locked == value:
		return
	layer.locked = value
	if value and layer == document.active_layer():
		edit_context_changing.emit()
		_cancel_active_edit()
	layers_changed.emit()


func add_layer(index := -1, layer_name := "") -> int:
	return _insert_layer(document.make_layer(layer_name), index, "Add Layer")


func duplicate_layer(index := -1) -> int:
	var source_index := document.edit_layer if index < 0 else index
	if source_index < 0 or source_index >= document.layers.size():
		return -1
	var source := document.layers[source_index]
	var layer := source.copy_layer()
	layer.name = source.name + " copy"
	return _insert_layer(layer, source_index + 1, "Duplicate Layer")


func _insert_layer(layer: VoxelLayer, index: int, action: String) -> int:
	var target := clampi(index if index >= 0 else document.edit_layer + 1, 0, document.layers.size())
	edit_context_changing.emit()
	_cancel_active_edit()
	var previous := document.active_layer()
	undo_redo.create_action(action)
	undo_redo.add_undo_method(_apply_layer_removed.bind(layer, previous))
	undo_redo.add_do_method(_apply_layer_inserted.bind(layer, target, layer))
	_commit_history(false)
	_apply_layer_inserted(layer, target, layer)
	return document.edit_layer


func _apply_layer_inserted(layer: VoxelLayer, index: int, active: VoxelLayer) -> void:
	if not document.layers.has(layer):
		document.layers.insert(clampi(index, 0, document.layers.size()), layer)
	var active_index := document.layers.find(active)
	document.edit_layer = active_index if active_index >= 0 else clampi(document.edit_layer, 0, document.layers.size() - 1)
	document.invalidate_bounds()
	document.invalidate_composite()
	layers_changed.emit()
	active_layer_changed.emit()


func delete_layer(index := -1) -> void:
	if document.layers.size() <= 1:
		return
	var target := document.edit_layer if index < 0 else index
	if target < 0 or target >= document.layers.size():
		return
	var removed := document.layers[target]
	if removed.locked:
		notice.emit("The layer is locked.")
		return
	var previous := document.active_layer()
	var next_active := document.layers[target - 1] if target > 0 else document.layers[target + 1]
	edit_context_changing.emit()
	_cancel_active_edit()
	undo_redo.create_action("Delete Layer")
	undo_redo.add_undo_method(_apply_layer_inserted.bind(removed, target, previous))
	undo_redo.add_do_method(_apply_layer_removed.bind(removed, next_active))
	_commit_history(false)
	_apply_layer_removed(removed, next_active)


func _apply_layer_removed(layer: VoxelLayer, active: VoxelLayer) -> void:
	var index := document.layers.find(layer)
	if index < 0:
		return
	document.layers.remove_at(index)
	var active_index := document.layers.find(active)
	document.edit_layer = active_index if active_index >= 0 else clampi(document.edit_layer, 0, document.layers.size() - 1)
	document.invalidate_bounds()
	document.invalidate_composite()
	layers_changed.emit()
	active_layer_changed.emit()


func rename_layer(index: int, layer_name: String) -> void:
	if index < 0 or index >= document.layers.size():
		return
	var name := layer_name.strip_edges()
	if name.is_empty():
		return
	name = name.left(1024)
	var layer := document.layers[index]
	if layer.name == name:
		return
	undo_redo.create_action("Rename Layer")
	undo_redo.add_undo_method(_apply_layer_name.bind(layer, layer.name))
	undo_redo.add_do_method(_apply_layer_name.bind(layer, name))
	_commit_history(false)
	_apply_layer_name(layer, name)


func _apply_layer_name(layer: VoxelLayer, layer_name: String) -> void:
	layer.name = layer_name
	layers_changed.emit()


func move_layer(from: int, to: int) -> void:
	var size := document.layers.size()
	if from < 0 or from >= size:
		return
	var target := clampi(to, 0, size - 1)
	if target == from:
		return
	edit_context_changing.emit()
	_cancel_active_edit()
	var before := document.layers.duplicate()
	var active := document.active_layer()
	var after := before.duplicate()
	var layer: VoxelLayer = after[from]
	after.remove_at(from)
	after.insert(target, layer)
	undo_redo.create_action("Move Layer")
	undo_redo.add_undo_method(_apply_layer_order.bind(before, active))
	undo_redo.add_do_method(_apply_layer_order.bind(after, active))
	_commit_history(false)
	_apply_layer_order(after, active)


func _apply_layer_order(order: Array, active: VoxelLayer) -> void:
	document.layers.assign(order)
	var active_index := document.layers.find(active)
	document.edit_layer = active_index if active_index >= 0 else clampi(document.edit_layer, 0, document.layers.size() - 1)
	document.invalidate_bounds()
	document.invalidate_composite()
	layers_changed.emit()
	active_layer_changed.emit()


func merge_layer_down(index := -1) -> void:
	var source_index := document.edit_layer if index < 0 else index
	if source_index <= 0 or source_index >= document.layers.size():
		return
	var source := document.layers[source_index]
	var target := document.layers[source_index - 1]
	if source.locked or target.locked:
		notice.emit("The layer is locked.")
		return
	edit_context_changing.emit()
	_cancel_active_edit()
	var previous := document.active_layer()
	var target_before: Array[VoxelFrame] = target.frames.duplicate()
	var merged: Array[VoxelFrame] = []
	for frame_index in target.frames.size():
		var cel := target.frames[frame_index].copy_frame()
		var changes := {}
		if frame_index < source.frames.size():
			for cell in source.frames[frame_index].positions():
				changes[cell] = source.frames[frame_index].get_material(cell)
		if not changes.is_empty():
			cel.set_cells(changes)
		merged.append(cel)
	undo_redo.create_action("Merge Layer Down")
	undo_redo.add_undo_method(_apply_merged_layer.bind(target, target_before, source, source_index, false, previous))
	undo_redo.add_do_method(_apply_merged_layer.bind(target, merged, source, source_index, true, target))
	var target_index := document.layers.find(target)
	for frame_index in source.frames.size():
		var cells := source.frames[frame_index].positions()
		if not cells.is_empty():
			cells_changed.emit(target_index, frame_index, cells)
	_commit_history(false)
	_apply_merged_layer(target, merged, source, source_index, true, target)


func _apply_merged_layer(target: VoxelLayer, target_frames: Array[VoxelFrame], source: VoxelLayer, source_index: int, remove_source: bool, active: VoxelLayer) -> void:
	target.frames.clear()
	target.frames.append_array(target_frames)
	if remove_source:
		var at := document.layers.find(source)
		if at >= 0:
			document.layers.remove_at(at)
	elif not document.layers.has(source):
		document.layers.insert(clampi(source_index, 0, document.layers.size()), source)
	var active_index := document.layers.find(active)
	document.edit_layer = active_index if active_index >= 0 else clampi(document.edit_layer, 0, document.layers.size() - 1)
	document.invalidate_bounds()
	document.invalidate_composite()
	layers_changed.emit()
	active_layer_changed.emit()


func move_selection_to_layer(target_index: int) -> void:
	if target_index < 0 or target_index >= document.layers.size() or target_index == document.edit_layer:
		return
	if not active_layer_editable():
		_emit_layer_notice()
		return
	var target := document.layers[target_index]
	if not target.visible or target.locked:
		notice.emit("The target layer is hidden." if not target.visible else "The target layer is locked.")
		return
	var frame_index := current_frame
	var source_cel := get_current_voxel_frame()
	var target_cel := document.cel(target_index, frame_index)
	if source_cel == null or target_cel == null:
		return
	var selected := selection.capture()
	var materials := {}
	if selected.is_empty():
		for cell in source_cel.positions():
			materials[cell] = source_cel.get_material(cell)
	else:
		for cell: Vector3i in selected:
			if source_cel.has(cell):
				materials[cell] = source_cel.get_material(cell)
	if materials.is_empty():
		return
	edit_context_changing.emit()
	_cancel_active_edit()
	var source_before := source_cel.capture()
	var target_before := target_cel.capture()
	var erased := VoxelFrame.material(Color.TRANSPARENT)
	var remove := {}
	for cell in materials:
		remove[cell] = erased
	source_cel.set_cells(remove)
	target_cel.set_cells(materials)
	document._bounds_dirty = true
	document.invalidate_composite()
	var source_layer := document.edit_layer
	undo_redo.create_action("Move to Layer")
	undo_redo.add_undo_method(_restore_moved_cells.bind(source_cel, target_cel, source_before, target_before))
	undo_redo.add_do_method(_restore_moved_cells.bind(source_cel, target_cel, source_cel.capture(), target_cel.capture()))
	_commit_history(false)
	var affected: Array[Vector3i] = []
	affected.assign(materials.keys())
	cells_changed.emit(source_layer, frame_index, affected)
	cells_changed.emit(target_index, frame_index, affected)
	notice.emit("Moved %d cells to %s." % [materials.size(), target.name])


func _restore_moved_cells(source_cel: VoxelFrame, target_cel: VoxelFrame, source_snapshot: Dictionary, target_snapshot: Dictionary) -> void:
	var source_location := document.find_cel(source_cel)
	var target_location := document.find_cel(target_cel)
	source_cel.restore(source_snapshot)
	target_cel.restore(target_snapshot)
	document._bounds_dirty = true
	document.invalidate_composite()
	var none: Array[Vector3i] = []
	if source_location.x >= 0:
		cells_changed.emit(source_location.x, source_location.y, none)
	if target_location.x >= 0:
		cells_changed.emit(target_location.x, target_location.y, none)
	selection_changed.emit()

var floor_axis: Vector3.Axis:
	get:
		return aids.floor_axis
	set(value):
		aids.floor_axis = value

var floor_index: int:
	get:
		return aids.floor_index
	set(value):
		aids.floor_index = value

var slice_enabled: bool:
	get:
		return aids.slice_enabled
	set(value):
		aids.slice_enabled = value

var slice_layers: int:
	get:
		return aids.slice_layers
	set(value):
		aids.slice_layers = value


func slice_first() -> int:
	return aids.slice_first()


func slice_last() -> int:
	return aids.slice_last()


func slice_count() -> int:
	return aids.slice_count()


func slice_level() -> float:
	return aids.slice_level()


func has_size() -> bool:
	return document.has_size()


func set_size(value: Vector3i, record_history := true) -> void:
	if edit_busy():
		return
	value = _clamp_size(value)
	if value == document.size:
		return
	var before := document.size
	_apply_size(value)
	if not record_history:
		return
	undo_redo.create_action("Set Document Size")
	undo_redo.add_undo_method(_apply_size.bind(before))
	undo_redo.add_do_method(_apply_size.bind(value))
	_commit_history(false)


func set_document_properties(smooth_normals: bool, size: Vector3i, record_history := true) -> void:
	if edit_busy():
		return
	size = _clamp_size(size)
	if document.smooth_normals == smooth_normals and document.size == size:
		return
	if record_history:
		var before_smooth := document.smooth_normals
		var before_size := document.size
		undo_redo.create_action("Set Document Properties")
		undo_redo.add_undo_method(_apply_document_properties.bind(before_smooth, before_size))
		undo_redo.add_do_method(_apply_document_properties.bind(smooth_normals, size))
		_commit_history(false)
	_apply_document_properties(smooth_normals, size)


func commit_document_properties(before_smooth: bool, before_size: Vector3i) -> void:
	var after_smooth := document.smooth_normals
	var after_size := document.size
	if before_smooth == after_smooth and before_size == after_size:
		return
	undo_redo.create_action("Set Document Properties")
	undo_redo.add_undo_method(_apply_document_properties.bind(before_smooth, before_size))
	undo_redo.add_do_method(_apply_document_properties.bind(after_smooth, after_size))
	_commit_history(false)


func commit_document_settings(before_smooth: bool, before_size: Vector3i, before_ao: float, before_style := 0) -> void:
	var after_smooth := document.smooth_normals
	var after_size := document.size
	var after_ao := document.ao_strength
	var after_style := document.mesh_style
	var properties_changed := before_smooth != after_smooth or before_size != after_size
	var ao_changed := not is_equal_approx(before_ao, after_ao)
	var style_changed := before_style != after_style
	if not properties_changed and not ao_changed and not style_changed:
		return
	undo_redo.create_action("Set Document Settings")
	if properties_changed:
		undo_redo.add_undo_method(_apply_document_properties.bind(before_smooth, before_size))
		undo_redo.add_do_method(_apply_document_properties.bind(after_smooth, after_size))
	if ao_changed:
		undo_redo.add_undo_method(_apply_ao_strength.bind(before_ao))
		undo_redo.add_do_method(_apply_ao_strength.bind(after_ao))
	if style_changed:
		undo_redo.add_undo_method(_apply_mesh_style.bind(before_style))
		undo_redo.add_do_method(_apply_mesh_style.bind(after_style))
	_commit_history(false)


func _apply_document_properties(smooth_normals: bool, size: Vector3i) -> void:
	var smooth_changed := document.smooth_normals != smooth_normals
	var size_was_changed := document.size != size
	document.smooth_normals = smooth_normals
	document.size = size
	if smooth_changed:
		model_settings_changed.emit()
	if size_was_changed:
		size_changed.emit()


func _apply_size(value: Vector3i) -> void:
	document.size = value
	size_changed.emit()


static func _clamp_size(value: Vector3i) -> Vector3i:
	return Vector3i(
		clampi(value.x, 0, VoxelDocument.MAX_DOCUMENT_SIZE),
		clampi(value.y, 0, VoxelDocument.MAX_DOCUMENT_SIZE),
		clampi(value.z, 0, VoxelDocument.MAX_DOCUMENT_SIZE),
	)

var symmetry_axes: int:
	get:
		return aids.symmetry_axes
	set(value):
		aids.symmetry_axes = value

var symmetry_origin: Vector3:
	get:
		return aids.symmetry_origin
	set(value):
		aids.symmetry_origin = value

var default_palette: Array[PackedFloat32Array]:
	get:
		return material_editing.default_palette
	set(value):
		material_editing.default_palette = value
var current_material: PackedFloat32Array:
	get:
		return material_editing.current_material
	set(value):
		material_editing.current_material = value
var current_palette_index: int:
	get:
		return material_editing.current_palette_index
	set(value):
		material_editing.current_palette_index = value
var current_color: Color:
	get:
		return material_editing.current_color
	set(value):
		material_editing.current_color = value
var selection: VoxelSelection:
	get:
		return selection_state.selection
var undo_redo: UndoRedo:
	get:
		return session.document.edit_history
var _erase_edit: VoxelEditTransaction


func _init() -> void:
	operations.activity_changed.connect(activity_changed.emit)
	session.palette_provider = _new_document_palette
	session.switch_blocked = _is_tab_switch_blocked
	session.on_deactivated = _before_document_replaced
	session.on_installed = _after_document_installed
	session.on_adopted = _after_document_adopted
	session.document_changed.connect(document_changed.emit)
	session.document_deactivating.connect(document_deactivating.emit)
	session.document_created.connect(_on_document_created)
	session.document_saved.connect(document_saved.emit)
	session.workspace_capture_requested.connect(workspace_capture_requested.emit)
	session.frames_changed.connect(frames_changed.emit)
	session.frame_changed.connect(frame_changed.emit)
	session.layers_changed.connect(layers_changed.emit)
	session.active_layer_changed.connect(active_layer_changed.emit)
	session.tag_changed.connect(tag_changed.emit)
	session.is_playing_toggled.connect(is_playing_toggled.emit)
	session.tabs_changed.connect(tabs_changed.emit)
	session.active_tab_changed.connect(active_tab_changed.emit)
	session.session_remember_requested.connect(_remember_app_session)
	session.document_changed.connect(_emit_document_view_signals)
	session.playback.frame_changing.connect(edit_context_changing.emit)
	selection_state.session = session
	selection_state.selection_changed.connect(selection_changed.emit)
	aids.session = session
	aids.selection_state = selection_state
	aids.floor_plane_changed.connect(floor_plane_changed.emit)
	aids.slice_changed.connect(slice_changed.emit)
	aids.symmetry_changed.connect(symmetry_changed.emit)
	material_editing.session = session
	material_editing.settings = settings
	material_editing.operations = operations
	material_editing.commit_history = _commit_history
	material_editing.history_apply = _apply_history_material
	material_editing.history_restore_palette = _restore_history_palette
	material_editing.color_changed.connect(color_changed.emit)
	material_editing.material_changed.connect(material_changed.emit)
	material_editing.palette_changed.connect(palette_changed.emit)
	material_editing.default_palette_changed.connect(default_palette_changed.emit)
	edits.session = session
	edits.selection_state = selection_state
	edits.aids = aids
	edits.commit_history = _commit_history
	edits.cells_changed = _emit_cells_changed
	edits.history_restore_chunks = _restore_history_chunks
	edits.edit_state_changed.connect(edit_state_changed.emit)

func _ready() -> void:
	operations.tree = get_tree()
	settings.tree = get_tree()
	migrate_settings()
	load_default_palette()
	document.palette = material_editing.copy_default_palette()
	material_editing.select_palette_entry(0)
	edit_context_changing.connect(_interrupt_erase)
	cells_changed.connect(func(_layer, _frame, _affected): stop())
	chunks_changed.connect(func(_layer, _frame, _affected): stop())
	cells_changed.connect(func(_layer, _frame, _affected): _mark_dirty())
	chunks_changed.connect(func(_layer, _frame, _affected): _mark_dirty())
	frames_changed.connect(_mark_dirty)
	layers_changed.connect(_mark_dirty)
	size_changed.connect(_mark_dirty)
	model_settings_changed.connect(_mark_dirty)
	palette_changed.connect(_mark_dirty)


func set_context(value: EditorContext) -> void:
	_get_plugin_host().context = value


var context: EditorContext:
	get:
		return _get_plugin_host().context


func clear_plugins() -> void:
	_get_plugin_host().clear_plugins()


func reset_plugins() -> void:
	_get_plugin_host().reset_plugins()


func _get_plugin_host() -> PluginHost:
	if _plugin_host == null:
		_plugin_host = PluginHost.new()
		_plugin_host.name = "PluginHost"
		add_child(_plugin_host)
	return _plugin_host


func new_document() -> VoxelDocument:
	return session.new_document()


func set_document(value: VoxelDocument) -> void:
	session.set_document(value)


func add_tab(value: VoxelDocument) -> int:
	return session.add_tab(value)


func open_tab(value: VoxelDocument) -> int:
	return session.open_tab(value)


func capture_workspace(document: VoxelDocument) -> void:
	session.capture_workspace(document)


func record_saved(document: VoxelDocument, path: String) -> void:
	session.record_saved(document, path)


func record_opened(document: VoxelDocument, path: String) -> void:
	session.record_opened(document, path)


func set_tabs(documents: Array[VoxelDocument], index: int = 0) -> void:
	session.set_tabs(documents, index)


func activate_tab(index: int) -> bool:
	return session.activate_tab(index)


func close_tab(index: int) -> bool:
	return session.close_tab(index)


func is_adopting() -> bool:
	return session.is_adopting()


func _new_document_palette() -> Array[PackedFloat32Array]:
	return material_editing.copy_default_palette()


func _is_tab_switch_blocked() -> bool:
	return edit_busy() or edits.active_edit() != null


func _before_document_replaced() -> void:
	material_editing.reset_edit()
	edit_context_changing.emit()
	operations.clear()
	edits._abandon_active_edit()


func _after_document_installed() -> void:
	material_editing.apply_current_material()


func _after_document_adopted() -> void:
	selection_state.notify_changed()
	history_changed.emit()
	edit_state_changed.emit()


func _emit_document_view_signals() -> void:
	size_changed.emit()
	palette_changed.emit()


func _emit_cells_changed(layer_index: int, frame_index: int, affected: Array[Vector3i]) -> void:
	cells_changed.emit(layer_index, frame_index, affected)


func _on_document_created() -> void:
	material_editing.select_palette_entry(0)


func _remember_app_session() -> void:
	if is_app_session():
		remember_session()


func _mark_dirty() -> void:
	if session.is_adopting() or session.tabs.is_empty() or session.document.edit_dirty:
		return
	session.document.edit_dirty = true
	tabs_changed.emit()


func mark_dirty() -> void:
	_mark_dirty()


func _commit_history(execute: bool = true) -> void:
	undo_redo.commit_action(execute)
	history_changed.emit()


func _apply_history_material(values: PackedFloat32Array) -> void:
	material_editing.apply_history_material(values)


func _restore_history_palette(snapshot: Dictionary) -> void:
	material_editing.restore_history_palette(snapshot)


func _restore_history_chunks(edited_frame: VoxelFrame, chunk_snapshot: Dictionary, selection_snapshot: Dictionary, selection_snapshot_masks: Dictionary = {}) -> void:
	edits.restore_history_chunks(edited_frame, chunk_snapshot, selection_snapshot, selection_snapshot_masks)


func undo() -> bool:
	if edits.active_edit() != null:
		return false
	var undone := undo_redo.undo()
	if undone:
		history_changed.emit()
	return undone


func redo() -> bool:
	if edits.active_edit() != null:
		return false
	var redone := undo_redo.redo()
	if redone:
		history_changed.emit()
	return redone


func add_plugin(plugin: VoxelPlugin) -> void:
	_get_plugin_host().add_plugin(plugin)

func remove_plugin(plugin: VoxelPlugin) -> void:
	_get_plugin_host().remove_plugin(plugin)


func paint(position: Vector3i, cell_material: PackedFloat32Array) -> void:
	if not active_layer_editable():
		return
	var painted: Array[Vector3i] = []
	if symmetry_axes == 0 and not slice_enabled and not document.has_size() and edits.active_edit() == null:
		document.paint(current_frame, position, cell_material)
		painted.append(position)
	else:
		var context := drawing_context()
		var changes := context.expand({position: cell_material}, get_current_voxel_frame(), false, null)
		get_current_voxel_frame().set_cells(changes)
		document._bounds_dirty = true
		painted.assign(changes.keys())
	if not painted.is_empty():
		cells_changed.emit(document.edit_layer, current_frame, painted)


func drawing_context() -> VoxelFrame.EditContext:
	return aids.drawing_context(edits.frozen_context())


func symmetry_transform(mask: int, origin: Vector3) -> Transform3D:
	return aids.symmetry_transform(mask, origin)


func selection_context() -> VoxelFrame.EditContext:
	return selection_state.selection_context(drawing_context())


func selection_region(region: VoxelSelection) -> VoxelSelection:
	return selection_state.selection_region(region, selection_context(), get_current_voxel_frame())


func begin_operation(label: String, total: int = -1, foreground: bool = false, operation_owner: Node = null, cancel_callback: Callable = Callable()) -> int:
	return operations.begin_operation(label, total, foreground, operation_owner, cancel_callback)


func cancel_operation(operation_id: int) -> bool:
	return operations.cancel_operation(operation_id)


func cancel_activity() -> bool:
	return operations.cancel_activity()


func update_operation(operation_id: int, completed: int, total: int = -1, phase: String = "", detail: String = "") -> void:
	operations.update_operation(operation_id, completed, total, phase, detail)


func finish_operation(operation_id: int) -> void:
	operations.finish_operation(operation_id)


func run_edit_job(job: VoxelFrame.EditJob, operation_id: int, task_name: String, on_frame: Callable = Callable()) -> void:
	await operations.run_edit_job(job, operation_id, task_name, on_frame)


func has_operation(operation_id: int) -> bool:
	return operations.has_operation(operation_id)


func get_activity() -> Operation:
	return operations.get_activity()


func activity_elapsed_ms() -> int:
	return operations.activity_elapsed_ms()


func edit_busy(requester: Node = null) -> bool:
	return operations.edit_busy(requester)


func begin_edit(frame_index: int = -1) -> VoxelEditTransaction:
	if not active_layer_editable():
		_emit_layer_notice()
		return null
	return edits.begin_edit(frame_index)


func _emit_layer_notice() -> void:
	var layer := document.active_layer()
	if layer == null:
		return
	if not layer.visible and layer.locked:
		notice.emit("The active layer is hidden and locked.")
	elif not layer.visible:
		notice.emit("The active layer is hidden.")
	else:
		notice.emit("The active layer is locked.")


func active_edit() -> VoxelEditTransaction:
	return edits.active_edit()


func finish_edit(tx: VoxelEditTransaction, action: String = "Stroke") -> void:
	edits.finish_edit(tx, action)


func finish_edit_collect(tx: VoxelEditTransaction) -> VoxelEditTransaction.Change:
	return edits.finish_edit_collect(tx)


func commit_changes(changes: Array, action: String = "Write Cells") -> void:
	edits.commit_changes(changes, action)


func cancel_changes(changes: Array) -> void:
	edits.cancel_changes(changes)


func cancel_edit(tx: VoxelEditTransaction) -> void:
	edits.cancel_edit(tx)


func has_cell(position: Vector3i) -> bool:
	return document.has_cell(current_frame, position)

func play():
	is_playing = true

func play_tag(i: int) -> void:
	active_tag = i
	is_playing = true

func stop():
	is_playing = false

func select_tag(i: int) -> void:
	active_tag = i

func deselect_tag() -> void:
	active_tag = -1


func _process(delta: float) -> void:
	operations.update()
	session.update(delta)

func set_color(color: Color) -> void:
	material_editing.set_color(color)


func set_material(value: PackedFloat32Array) -> void:
	material_editing.set_material(value)


func select_palette_entry(index: int) -> void:
	material_editing.select_palette_entry(index)


func apply_workspace_material(value: PackedFloat32Array) -> void:
	material_editing.apply_workspace_material(value)


func add_material() -> void:
	material_editing.add_material()


func get_color(index: int) -> Color:
	return document.get_color(index)


func get_color_at(position: Vector3i) -> Color:
	return document.get_color_at(current_frame, position)


func remove_palette_entry() -> void:
	material_editing.remove_palette_entry()


func get_palette() -> Array[PackedFloat32Array]:
	return material_editing.get_palette()


func set_palette(materials: Array[PackedFloat32Array], action_name: String = "Replace Palette") -> void:
	material_editing.set_palette(materials, action_name)


func move_palette_entry(from_index: int, to_index: int) -> void:
	material_editing.move_palette_entry(from_index, to_index)


func edit_material(value: PackedFloat32Array) -> void:
	material_editing.edit_material(value)


func begin_material_edit() -> void:
	material_editing.begin_material_edit()


func end_material_edit() -> void:
	material_editing.end_material_edit()


func cancel_material_edit() -> void:
	material_editing.cancel_material_edit()


func get_builtin_palette() -> Array[PackedFloat32Array]:
	return material_editing.get_builtin_palette()


func load_default_palette(path: String = DEFAULT_PALETTE_PATH) -> void:
	material_editing.load_default_palette(path)


func save_default_palette(path: String = DEFAULT_PALETTE_PATH) -> Error:
	return material_editing.save_default_palette(path)


func reset_default_palette(path: String = DEFAULT_PALETTE_PATH) -> Error:
	return material_editing.reset_default_palette(path)


func migrate_settings(target_path: String = "", legacy_paths: PackedStringArray = PackedStringArray()) -> Error:
	return settings.migrate_settings(target_path, legacy_paths)


func remember_document(path: String, config_path: String = "") -> void:
	settings.remember_document(path, config_path)


func forget_document(config_path: String = "") -> void:
	settings.forget_document(config_path)


func last_document_path(config_path: String = "") -> String:
	return settings.last_document_path(config_path)


func last_tabs(config_path: String = "") -> PackedStringArray:
	return settings.last_tabs(config_path)


func last_tab_index(config_path: String = "") -> int:
	return settings.last_tab_index(config_path)


func remember_session(config_path: String = "") -> void:
	settings.remember_session(tabs, active_tab, config_path)


func is_app_session() -> bool:
	return settings.is_app_session()


func get_image_file_filter() -> String:
	return settings.get_image_file_filter()


func load_image(path: String, image: Image) -> Error:
	var extension := path.get_extension().to_lower()
	var error: Error = OK
	if extension in ["dds", "ktx", "ktx2"]:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return FileAccess.get_open_error()
		var bytes := file.get_buffer(file.get_length())
		file.close()
		error = image.load_dds_from_buffer(bytes) if extension == "dds" else image.load_ktx_from_buffer(bytes)
	else:
		error = image.load(path)
	if error != OK:
		return error
	if image.is_compressed():
		return image.decompress()
	return OK

func can_edit(cell: Vector3i) -> bool:
	if selection.is_empty():
		return true
	return selection.contains(cell)


func clear_selection() -> void:
	selection_state.clear_selection()


func erase_selection() -> void:
	if selection.is_empty() or edit_busy():
		return
	if not active_layer_editable():
		_emit_layer_notice()
		return
	var edited_document := document
	var edited_frame := get_current_voxel_frame()
	var edited_layer := document.edit_layer
	_erase_edit = begin_edit()
	if _erase_edit == null:
		return
	var job := EraseJob.new()
	job.edited_frame = VoxelFrame.job_frame(edited_frame)
	job.edited_layer = edited_layer
	job.selection_mask = selection.capture()
	job.edit_context = _erase_edit.edit_context.duplicate()
	job.edit_context.bounded_axes = 0
	job.edit_context.selection = {}
	_erase_job = job
	var operation_id := begin_operation("Erasing selection", selection.count(), true, self, _interrupt_erase)
	_erase_operation_id = operation_id
	if selection.count() <= 4096:
		job.run()
	else:
		_erase_jobs.append(job)
		await run_edit_job(job, operation_id, "Erase selection")
		_erase_jobs.erase(job)
	if _erase_job != job:
		return
	if document != edited_document or get_current_voxel_frame() != edited_frame:
		_interrupt_erase()
		return
	edited_frame.apply_published(job.changed_chunks, job.edited_frame)
	document._bounds_dirty = true
	var erase_tx := _erase_edit
	_erase_edit = null
	_erase_job = null
	_erase_operation_id = 0
	finish_edit(erase_tx, "Erase Selection")
	if not job.changed_chunks.is_empty():
		chunks_changed.emit(job.edited_layer, current_frame, job.changed_chunks)
	finish_operation(operation_id)


func _interrupt_erase() -> void:
	if _erase_job == null:
		return
	_erase_job.cancel()
	_erase_job = null
	var erase_edit := _erase_edit
	_erase_edit = null
	var operation_id := _erase_operation_id
	_erase_operation_id = 0
	cancel_edit(erase_edit)
	finish_operation(operation_id)


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if cancel_activity():
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	for job in _erase_jobs:
		job.cancel()
		job.wait_for_worker()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		undo_redo.free()


func next_frame() -> void:
	var n := document.frame_count()
	current_frame = (current_frame + 1) % n


func prev_frame() -> void:
	current_frame = posmod(current_frame - 1, document.frame_count())

func get_frame_count() -> int:
	return document.frame_count()


func set_smooth_normals(value: bool) -> void:
	if edit_busy() or value == document.smooth_normals:
		return
	undo_redo.create_action("Set Smooth Normals")
	undo_redo.add_undo_method(_apply_smooth_normals.bind(document.smooth_normals))
	undo_redo.add_do_method(_apply_smooth_normals.bind(value))
	_commit_history(false)
	_apply_smooth_normals(value)


func _apply_smooth_normals(value: bool) -> void:
	document.smooth_normals = value
	model_settings_changed.emit()


func set_mesh_style(value: int, record_history := true) -> void:
	value = clampi(value, 0, 1)
	if edit_busy() or value == document.mesh_style:
		return
	if record_history:
		undo_redo.create_action("Set Mesh Style")
		undo_redo.add_undo_method(_apply_mesh_style.bind(document.mesh_style))
		undo_redo.add_do_method(_apply_mesh_style.bind(value))
		_commit_history(false)
	_apply_mesh_style(value)


func _apply_mesh_style(value: int) -> void:
	document.mesh_style = value
	model_settings_changed.emit()


func set_ao_strength(value: float, record_history := true) -> void:
	value = clampf(value, 0.0, 1.0)
	if edit_busy() or is_equal_approx(value, document.ao_strength):
		return
	if record_history:
		undo_redo.create_action("Set Ambient Occlusion")
		undo_redo.add_undo_method(_apply_ao_strength.bind(document.ao_strength))
		undo_redo.add_do_method(_apply_ao_strength.bind(value))
		_commit_history(false)
	_apply_ao_strength(value)


func commit_ao_strength(before: float) -> void:
	var after := document.ao_strength
	if is_equal_approx(before, after):
		return
	undo_redo.create_action("Set Ambient Occlusion")
	undo_redo.add_undo_method(_apply_ao_strength.bind(before))
	undo_redo.add_do_method(_apply_ao_strength.bind(after))
	_commit_history(false)


func _apply_ao_strength(value: float) -> void:
	document.ao_strength = value
	model_settings_changed.emit()


func get_voxel_frame(frame:int) -> VoxelFrame:
	return document.cel(document.edit_layer, frame)

func get_current_voxel_frame() -> VoxelFrame:
	return document.cel(document.edit_layer, current_frame)


func get_composite_voxel_frame(frame: int) -> VoxelFrame:
	return document.composite_frame(frame)


func add_frames(count: int, index := -1) -> void:
	var size := document.frame_count()
	var amount := clampi(count, 1, 256)
	var target := size if index < 0 else clampi(index, 0, size)
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	for added in amount:
		document.add_frame()
	if target < size:
		document.move_frame_block(size, amount, target)
	current_frame = clampi(target + amount - 1, 0, document.frame_count() - 1)
	_record_frame_action("Add Frame" if amount == 1 else "Add Frames", before, _frame_snapshot())


func add_frame() -> void:
	add_frames(1)


func duplicate_frame() -> void:
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	document.duplicate_frame(current_frame)
	current_frame += 1
	_record_frame_action("Duplicate Frame", before, _frame_snapshot())


func delete_frame() -> void:
	remove_frames([current_frame])


func remove_frames(indices: Array) -> void:
	var size := document.frame_count()
	var unique := {}
	for value in indices:
		if value is int or value is float:
			var index := int(value)
			if index >= 0 and index < size:
				unique[index] = true
	var descending: Array = unique.keys()
	if descending.is_empty() or descending.size() >= size:
		return
	descending.sort()
	descending.reverse()
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	var current := current_frame
	var removed_before_current := 0
	for index in descending:
		document.remove_frame(index)
		if index < current:
			removed_before_current += 1
	current_frame = clampi(current - removed_before_current, 0, document.frame_count() - 1)
	_record_frame_action("Delete Frame" if descending.size() == 1 else "Delete Frames", before, _frame_snapshot())


func move_frames(from: int, count: int, to: int) -> void:
	var size := document.frame_count()
	if count < 1 or from < 0 or from + count > size:
		return
	var target := clampi(to, 0, size - count)
	if target == from:
		return
	edit_context_changing.emit()
	var before := _frame_snapshot()
	document.move_frame_block(from, count, target)
	var current := current_frame
	if current >= from and current < from + count:
		current += target - from
	else:
		if current > from:
			current -= count
		if current >= target:
			current += count
	current_frame = clampi(current, 0, size - 1)
	_record_frame_action("Move Frame" if count == 1 else "Move Frames", before, _frame_snapshot())


func move_frame(from: int, to: int) -> void:
	move_frames(from, 1, to)


func _frame_snapshot() -> Dictionary:
	var layer_frames := []
	for layer in document.layers:
		layer_frames.append({"layer": layer, "frames": layer.frames.duplicate()})
	return {
		"layers": layer_frames,
		"delays": document.frame_delays.duplicate(),
		"ranges": _tag_ranges(),
		"current": current_frame,
	}


func _record_frame_action(action_name: String, before: Dictionary, after: Dictionary) -> void:
	undo_redo.create_action(action_name)
	undo_redo.add_undo_method(_restore_frame_layout.bind(before["layers"], before["delays"], before["ranges"], before["current"]))
	undo_redo.add_do_method(_restore_frame_layout.bind(after["layers"], after["delays"], after["ranges"], after["current"]))
	_commit_history(false)
	_restore_frame_layout(after["layers"], after["delays"], after["ranges"], after["current"])


func _restore_frame_layout(layer_frames: Array, delays: Array, ranges: Array[Vector2i], current: int) -> void:
	edit_context_changing.emit()
	for entry in layer_frames:
		var layer: VoxelLayer = entry.layer
		layer.frames.clear()
		layer.frames.append_array(entry.frames)
	document.frame_delays.clear()
	document.frame_delays.append_array(delays)
	_set_tag_ranges(ranges)
	document._bounds_dirty = true
	current_frame = clampi(current, 0, document.frame_count() - 1)
	frames_changed.emit()


func _tag_ranges() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for tag in document.tags:
		out.append(Vector2i(tag.from, tag.to))
	return out


func _set_tag_ranges(ranges: Array[Vector2i]) -> void:
	for i in mini(ranges.size(), document.tags.size()):
		var tag := document.tags[i]
		tag.from = ranges[i].x
		tag.to = ranges[i].y


func set_frame_delay(index: int, ms: int) -> void:
	set_frame_delays([index], ms)


func set_frame_delays(indices: Array, ms: int) -> void:
	var size := document.frame_count()
	var previous := {}
	for value in indices:
		if not (value is int or value is float):
			continue
		var index := int(value)
		if index < 0 or index >= size:
			continue
		if document.frame_delay(index) != ms:
			previous[index] = document.frame_delay(index)
	if previous.is_empty():
		return
	var next := {}
	for index in previous:
		next[index] = ms
	undo_redo.create_action("Set Frame Delay")
	undo_redo.add_undo_method(_apply_frame_delays.bind(previous))
	undo_redo.add_do_method(_apply_frame_delays.bind(next))
	_commit_history(false)
	_apply_frame_delays(next)


func _apply_frame_delays(delays: Dictionary) -> void:
	for index in delays:
		document.set_frame_delay(index, delays[index])
	_mark_dirty()
	frame_changed.emit()


func add_tag(tag_name: String, from: int = 0, to: int = -1, mode := AnimationTag.LoopMode.FORWARD, repeats := 0) -> void:
	var end := to
	if to < 0:
		end = document.frame_count() - 1
	var index := document.tags.size()
	var tag := AnimationTag.new()
	tag.name = tag_name
	tag.from = clampi(from, 0, document.frame_count() - 1)
	tag.to = clampi(end, tag.from, document.frame_count() - 1)
	tag.loop_mode = mode
	tag.repeats = repeats
	var prev_active := active_tag
	undo_redo.create_action("Add Tag")
	undo_redo.add_undo_method(_apply_tag_removed.bind(index, prev_active))
	undo_redo.add_do_method(_apply_tag_inserted.bind(index, tag, index))
	_commit_history(false)
	_apply_tag_inserted(index, tag, index)


func _apply_tag_inserted(index: int, tag: AnimationTag, active: int) -> void:
	document.tags.insert(index, tag)
	active_tag = active
	frames_changed.emit()


func _apply_tag_removed(index: int, active: int) -> void:
	document.tags.remove_at(index)
	active_tag = active
	frames_changed.emit()


func get_active_tag() -> AnimationTag:
	return document.get_tag(active_tag)

func get_tag(i: int) -> AnimationTag:
	return document.get_tag(i)

func remove_tag() -> void:
	if document.tags.size() <= 1 or active_tag < 0 or active_tag >= document.tags.size():
		return
	var index := active_tag
	var tag := document.get_tag(index)
	var new_active := clampi(index, -1, document.tags.size() - 2)
	undo_redo.create_action("Remove Tag")
	undo_redo.add_undo_method(_apply_tag_inserted.bind(index, tag, index))
	undo_redo.add_do_method(_apply_tag_removed.bind(index, new_active))
	_commit_history(false)
	_apply_tag_removed(index, new_active)

func set_tag_range(from: int, to: int, record_history: bool = true) -> void:
	var tag := get_active_tag()
	if tag == null:
		return
	var last := document.frame_count() - 1
	var new_from := clampi(from, 0, last)
	var new_to := clampi(to, new_from, last)
	if tag.from == new_from and tag.to == new_to:
		return
	var index := active_tag
	var previous_range := Vector2i(tag.from, tag.to)
	_apply_tag_range(index, new_from, new_to)
	if record_history:
		commit_tag_range(index, previous_range)


func commit_tag_range(index: int, previous_range: Vector2i) -> void:
	var tag := document.get_tag(index)
	if tag == null or previous_range == Vector2i(tag.from, tag.to):
		return
	undo_redo.create_action("Set Tag Range")
	undo_redo.add_undo_method(_apply_tag_range.bind(index, previous_range.x, previous_range.y))
	undo_redo.add_do_method(_apply_tag_range.bind(index, tag.from, tag.to))
	_commit_history(false)


func _apply_tag_range(index: int, from: int, to: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.from = from
	tag.to = to
	if is_playing:
		current_frame = clampi(current_frame, playback.first_frame(), playback.last_frame())
	_mark_dirty()
	tag_changed.emit()


func set_tag_loop(index: int, mode: int, repeats: int, set_repeats: bool) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	var mode_changed := tag.loop_mode != mode
	var repeats_changed := set_repeats and tag.repeats != repeats
	if not mode_changed and not repeats_changed:
		return
	undo_redo.create_action("Set Tag Loop")
	if mode_changed:
		undo_redo.add_undo_method(_apply_tag_loop_mode.bind(index, tag.loop_mode))
		undo_redo.add_do_method(_apply_tag_loop_mode.bind(index, mode))
	if repeats_changed:
		undo_redo.add_undo_method(_apply_tag_repeats.bind(index, tag.repeats))
		undo_redo.add_do_method(_apply_tag_repeats.bind(index, repeats))
	_commit_history(false)
	if mode_changed:
		_apply_tag_loop_mode(index, mode)
	if repeats_changed:
		_apply_tag_repeats(index, repeats)


func set_tag_loop_mode(index: int, mode: int) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.loop_mode == mode:
		return
	undo_redo.create_action("Set Loop Mode")
	undo_redo.add_undo_method(_apply_tag_loop_mode.bind(index, tag.loop_mode))
	undo_redo.add_do_method(_apply_tag_loop_mode.bind(index, mode))
	_commit_history(false)
	_apply_tag_loop_mode(index, mode)


func _apply_tag_loop_mode(index: int, mode: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.loop_mode = mode as AnimationTag.LoopMode
	_reset_playback_passes()
	_mark_dirty()
	tag_changed.emit()


func set_tag_repeats(index: int, value: int) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.repeats == value:
		return
	undo_redo.create_action("Set Repeats")
	undo_redo.add_undo_method(_apply_tag_repeats.bind(index, tag.repeats))
	undo_redo.add_do_method(_apply_tag_repeats.bind(index, value))
	_commit_history(false)
	_apply_tag_repeats(index, value)


func _apply_tag_repeats(index: int, value: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.repeats = value
	_reset_playback_passes()
	_mark_dirty()
	tag_changed.emit()


func _reset_playback_passes() -> void:
	if is_playing:
		playback.reset_passes()


func set_tag_name(index: int, tag_name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.name == tag_name:
		return
	undo_redo.create_action("Set Tag Name")
	undo_redo.add_undo_method(_apply_tag_name.bind(index, tag.name))
	undo_redo.add_do_method(_apply_tag_name.bind(index, tag_name))
	_commit_history(false)
	_apply_tag_name(index, tag_name)


func _apply_tag_name(index: int, tag_name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.name = tag_name
	_mark_dirty()
	tag_changed.emit()


func to_start() -> void:
	var tag := get_active_tag()
	if tag:
		current_frame = maxi(tag.from, 0)
	else:
		current_frame = 0

func to_end() -> void:
	var tag = get_active_tag()
	if tag:
		current_frame = mini(tag.to, document.frame_count() - 1)
	else:
		current_frame = document.frame_count() - 1
