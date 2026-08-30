extends Resource

@export var connected:bool = true :
	set(value):
		if value == connected:
			return
		connected = value
		emit_changed()
