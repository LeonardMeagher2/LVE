extends SceneTree

# Checks the pure helpers without a test scene. Run it with:
#
#   godot --headless --path . -s res://addons/test_kit/selfcheck.gd

const KIT := preload("res://addons/test_kit/test_case.gd")

var _failed := 0


func _initialize() -> void:
	_check(KIT.scene_key("res://tests/player.test.tscn") == "player", "a tests scene key drops the folder")
	_check(KIT.scene_key("res://src/player/player.test.tscn") == "src/player/player", "a nested scene key keeps its folders")
	_check(KIT.artifact_dir("res://tests/player.test.tscn") == "res://.tests/player", "the artifact dir uses the scene key")

	var text := "test(\"a\", _a)\ntest(\"b\", _b, \"custom_b\")\ntest(\"c\", _c, \"custom_c\", {\"timeout\": 1.0})\n"
	var cases := KIT.scan_cases_text(text)
	_check(cases == ["a", "custom_b", "custom_c"], "literal case names are discovered")

	var scenes := {"group": ["case", "other"], "solo": []}
	var whole := KIT.build_entries(["group", "case"], scenes)
	var entries: Array = whole["entries"]
	_check(entries.size() == 1 and entries[0]["cases"].is_empty(), "a scene name dominates its case names")
	_check(whole["unknown"].is_empty(), "a known scene name has no unknown names")

	var selected := KIT.select_cases(["b"], [{"name": "a"}, {"name": "b"}])
	var picked: Array = selected["selected"]
	_check(picked.size() == 1 and picked[0]["name"] == "b", "a case name selects one case")

	var external_script := "user://test_kit_external.gd"
	var external_scene := "user://test_kit_external.test.tscn"
	var f := FileAccess.open(external_script, FileAccess.WRITE)
	f.store_string("extends Node\nfunc _ready():\n\ttest(\"external\", _external, \"external_case\")\n")
	f.close()
	f = FileAccess.open(external_scene, FileAccess.WRITE)
	f.store_string("[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"user://test_kit_external.gd\" id=\"1\"]\n\n[node name=\"Root\" type=\"Node\"]\nscript = ExtResource(\"1\")\n")
	f.close()
	_check(KIT.scan_cases(external_scene) == ["external_case"], "an external root script is read from the scene")

	var inline_scene := "user://test_kit_inline.test.tscn"
	f = FileAccess.open(inline_scene, FileAccess.WRITE)
	f.store_string("[gd_scene load_steps=2 format=3]\n\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = \"extends Node\\nfunc _ready():\\n\\ttest(\\\"inline\\\", _inline, \\\"inline_case\\\")\\n\"\n\n[node name=\"Root\" type=\"Node\"]\nscript = SubResource(\"1\")\n")
	f.close()
	_check(KIT.scan_cases(inline_scene) == ["inline_case"], "an inline root script is read from the scene")

	DirAccess.remove_absolute(external_scene)
	DirAccess.remove_absolute(external_script)
	DirAccess.remove_absolute(inline_scene)
	print("TEST KIT SELFCHECK: %s" % ("OK" if _failed == 0 else "FAILED"))
	quit(1 if _failed > 0 else 0)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  + %s" % message)
	else:
		print("  x %s" % message)
		_failed += 1
