extends RefCounted


const MAX_COLORS := 256
const CUBE_LEVELS := [0, 51, 102, 153, 204, 255]

var _colors := PackedInt32Array([0])
var _seen := {}
var _cache := {}


func _init(base_colors := PackedColorArray(), limit := MAX_COLORS, include_cube := true) -> void:
	for color in base_colors:
		if _colors.size() >= limit:
			break
		if color.a <= 0.5:
			continue
		_add(color)
	if not include_cube:
		return
	for red in CUBE_LEVELS:
		if _colors.size() >= limit:
			return
		for green in CUBE_LEVELS:
			if _colors.size() >= limit:
				return
			for blue in CUBE_LEVELS:
				if _colors.size() >= limit:
					return
				_add(Color8(red, green, blue))


func size() -> int:
	return _colors.size()


func is_empty() -> bool:
	return _colors.size() <= 1


func nearest(packed: int) -> int:
	var cached: int = _cache.get(packed, -1)
	if cached >= 0:
		return cached
	var best := _nearest(packed)
	_cache[packed] = best
	return best


func _nearest(packed: int) -> int:
	var red := packed & 255
	var green := (packed >> 8) & 255
	var blue := (packed >> 16) & 255
	var best := 0
	var best_distance := 1 << 30
	for index in range(1, _colors.size()):
		var entry := _colors[index]
		var dr := red - (entry & 255)
		var dg := green - ((entry >> 8) & 255)
		var db := blue - ((entry >> 16) & 255)
		var distance := dr * dr + dg * dg + db * db
		if distance < best_distance:
			best_distance = distance
			best = index
	return best


func packed_at(index: int) -> int:
	if index < 0 or index >= _colors.size():
		return 0
	return _colors[index]


static func pack(color: Color) -> int:
	var red := clampi(roundi(color.r * 255.0), 0, 255)
	var green := clampi(roundi(color.g * 255.0), 0, 255)
	var blue := clampi(roundi(color.b * 255.0), 0, 255)
	return red | (green << 8) | (blue << 16)


func _add(color: Color) -> void:
	var packed := pack(color)
	if _seen.has(packed):
		return
	_seen[packed] = true
	_colors.append(packed)
