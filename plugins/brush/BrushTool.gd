extends VoxelTool

var _settings := preload("./settings.tres")
var _filter := PixelPerfectStroke.new()

func _ready() -> void:
	State.color_changed.connect(_on_color_changed)
	_on_color_changed(State.current_color)
	
func _on_color_changed(color:Color) -> void:
	($Cursor.material_override as StandardMaterial3D).albedo_color = color

func begin_stroke() -> void:
	super.begin_stroke()
	_filter.reset()


func _apply_stroke_to(to: Vector3i) -> void:
	if not _settings.pixel_perfect:
		super._apply_stroke_to(to)
		return
	for c in _filter.feed(to):
		_apply_pick(c, _hit_at(c))


func _end() -> void:
	if _settings.pixel_perfect:
		for c in _filter.flush():
			_apply_pick(c, _hit_at(c))
	super._end()


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var pick := super._pick_start(origin, dir)
	if _settings.mode == _settings.BrushMode.PAINT or pick.add_target == VoxelPicking.NONE:
		return pick
	pick.target = pick.add_target
	pick.plane = VoxelPicking.view_plane(pick.target, origin, _forward())
	return pick


func pick_drag(request: PickRequest) -> PickResult:
	if not _settings.mode == _settings.BrushMode.PAINT:
		return super.pick_drag(request)
	return VoxelPicking.start_pick(request.origin, request.dir, request.cells, request.forward)


func apply(target: Vector3i, hit: Vector3i) -> bool:
	var pos := target
	if _settings.mode == _settings.BrushMode.PAINT:
		pos = hit
		if not State.has_cell(pos) :
			return false
	if not State.can_edit(pos):
		return false
	State.paint(pos, State.current_color)
	return true

func update_visual(pick: PickResult) -> void:
	if _settings.mode == _settings.BrushMode.PAINT and not State.has_cell(pick.target):
		visible = false
		return
	super(pick)
