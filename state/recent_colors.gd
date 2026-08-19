class_name RecentColors
extends RefCounted

const MAX := 12

var colors: Array[Color] = []


func add(c: Color) -> void:
	if colors.has(c):
		colors.erase(c)
	colors.push_front(c)
	while colors.size() > MAX:
		colors.pop_back()


func clear() -> void:
	colors.clear()
