extends Resource

## The shared fill tool settings.
##
## The resource is shared by the fill option bar and the fill tool. The `changed`
## signal notifies its observers.

## Whether the fill floods the six face neighbors. A false value fills every
## matching cell in the frame.
@export var connected:bool = true :
	set(value):
		if value == connected:
			return
		connected = value
		emit_changed()
