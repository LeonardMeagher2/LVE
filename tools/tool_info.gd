class_name ToolInfo
extends Resource

@export var id := ""
@export var display_name := ""
@export var icon: Texture2D = null
@export var tooltip := ""
@export var group := ""
@export_file_path("*.tscn") var scene: String
