extends RefCounted


const MAX_COLORS := 256
const ALPHA_THRESHOLD := 128
const HISTOGRAM_BITS := 6
const HISTOGRAM_SHIFT := 8 - HISTOGRAM_BITS
const HISTOGRAM_SIZE := 1 << (HISTOGRAM_BITS * 3)

var _colors := PackedInt32Array([0])
var _seen := {}
var _cache := {}


func _init(base_colors := PackedColorArray(), limit := MAX_COLORS) -> void:
	for color in base_colors:
		if _colors.size() >= limit:
			break
		if color.a <= 0.5:
			continue
		_add(color)


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


static func adaptive_colors(tiles: Array[Image], max_colors := MAX_COLORS - 1, max_samples := 1_000_000) -> PackedColorArray:
	var histogram := _build_histogram(tiles, max_samples)
	if histogram.is_empty():
		return PackedColorArray()
	var counts: PackedInt32Array = histogram[0]
	var reds: PackedInt32Array = histogram[1]
	var greens: PackedInt32Array = histogram[2]
	var blues: PackedInt32Array = histogram[3]
	var used: Array[int] = histogram[4]
	return _median_cut(counts, reds, greens, blues, used, max_colors)


static func _build_histogram(tiles: Array[Image], max_samples: int) -> Array:
	var counts := PackedInt32Array()
	var reds := PackedInt32Array()
	var greens := PackedInt32Array()
	var blues := PackedInt32Array()
	counts.resize(HISTOGRAM_SIZE)
	reds.resize(HISTOGRAM_SIZE)
	greens.resize(HISTOGRAM_SIZE)
	blues.resize(HISTOGRAM_SIZE)
	var total := 0
	for tile in tiles:
		total += tile.get_width() * tile.get_height()
	if total <= 0:
		return []
	var stride := maxi(1, total / max_samples)
	var sample := 0
	for tile in tiles:
		var data := tile.get_data()
		var offset := 0
		while offset < data.size():
			if sample == 0 and data[offset + 3] >= ALPHA_THRESHOLD:
				var red := data[offset]
				var green := data[offset + 1]
				var blue := data[offset + 2]
				var bin := ((red >> HISTOGRAM_SHIFT) << (HISTOGRAM_BITS * 2)) | ((green >> HISTOGRAM_SHIFT) << HISTOGRAM_BITS) | (blue >> HISTOGRAM_SHIFT)
				counts[bin] += 1
				reds[bin] += red
				greens[bin] += green
				blues[bin] += blue
			offset += 4
			sample += 1
			if sample >= stride:
				sample = 0
	var used: Array[int] = []
	for bin in HISTOGRAM_SIZE:
		if counts[bin] > 0:
			used.append(bin)
	if used.is_empty():
		return []
	return [counts, reds, greens, blues, used]


static func _median_cut(counts: PackedInt32Array, reds: PackedInt32Array, greens: PackedInt32Array, blues: PackedInt32Array, used: Array[int], max_colors: int) -> PackedColorArray:
	var boxes: Array[Dictionary] = []
	boxes.append(_make_box(used, counts, reds, greens, blues))
	while boxes.size() < max_colors:
		var selected := -1
		var selected_span := 0
		for index in boxes.size():
			var candidate: Dictionary = boxes[index]
			if candidate.bins.size() < 2:
				continue
			if candidate.span > selected_span:
				selected_span = candidate.span
				selected = index
		if selected < 0:
			break
		var box: Dictionary = boxes[selected]
		var channel: int = box.channel
		var entries: Array = []
		for bin in box.bins:
			entries.append([_channel_value(bin, channel, counts, reds, greens, blues), bin])
		entries.sort_custom(func(a, b): return a[0] < b[0])
		var count: int = box.count
		var half: int = count / 2
		var accumulated := 0
		var split := 0
		for index in entries.size():
			accumulated += counts[entries[index][1]]
			split = index + 1
			if accumulated >= half:
				break
		if split <= 0 or split >= entries.size():
			split = maxi(1, entries.size() / 2)
		var left: Array[int] = []
		var right: Array[int] = []
		for index in entries.size():
			if index < split:
				left.append(entries[index][1])
			else:
				right.append(entries[index][1])
		boxes.remove_at(selected)
		boxes.append(_make_box(left, counts, reds, greens, blues))
		boxes.append(_make_box(right, counts, reds, greens, blues))
	var colors := PackedColorArray()
	for box in boxes:
		var count: int = box.count
		if count <= 0:
			continue
		var red := 0
		var green := 0
		var blue := 0
		for bin in box.bins:
			red += reds[bin]
			green += greens[bin]
			blue += blues[bin]
		colors.append(Color8(roundi(float(red) / count), roundi(float(green) / count), roundi(float(blue) / count)))
	return colors


static func _make_box(bins: Array[int], counts: PackedInt32Array, reds: PackedInt32Array, greens: PackedInt32Array, blues: PackedInt32Array) -> Dictionary:
	var minimum := Vector3i(255, 255, 255)
	var maximum := Vector3i.ZERO
	var count := 0
	for bin in bins:
		var bin_count := counts[bin]
		count += bin_count
		var red := reds[bin] / bin_count
		var green := greens[bin] / bin_count
		var blue := blues[bin] / bin_count
		minimum.x = mini(minimum.x, red)
		minimum.y = mini(minimum.y, green)
		minimum.z = mini(minimum.z, blue)
		maximum.x = maxi(maximum.x, red)
		maximum.y = maxi(maximum.y, green)
		maximum.z = maxi(maximum.z, blue)
	var channel := 0
	var span := maximum.x - minimum.x
	if maximum.y - minimum.y > span:
		channel = 1
		span = maximum.y - minimum.y
	if maximum.z - minimum.z > span:
		channel = 2
		span = maximum.z - minimum.z
	return {"bins": bins, "count": count, "span": span, "channel": channel}


static func _channel_value(bin: int, channel: int, counts: PackedInt32Array, reds: PackedInt32Array, greens: PackedInt32Array, blues: PackedInt32Array) -> int:
	var count := counts[bin]
	if channel == 0:
		return reds[bin] / count
	if channel == 1:
		return greens[bin] / count
	return blues[bin] / count


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
