# Test Kit

A small test harness for Godot 4.7. It runs test scenes in one process and
reports each failure with a source line and a screenshot.

## Install

Copy `addons/test_kit/` into the project. No editor plugin is required.

## First test

Create `tests/smoke.test.tscn` with one root `Node` and attach
`tests/smoke.gd`:

```gdscript
extends "res://addons/test_kit/test_case.gd"

func _ready() -> void:
	test("adds two numbers", _adds, "adds")

func _adds() -> void:
	expect(1 + 1 == 2, "one plus one is two")
```

Run the suite:

```text
godot --path . -s res://addons/test_kit/run.gd
```

The runner finds every `*.test.tscn` under `res://`. It runs each scene in one
process and exits with code 0 or 1.

## Select a scene or a case

```text
godot --path . -s res://addons/test_kit/run.gd -- smoke
godot --path . -s res://addons/test_kit/run.gd -- adds
godot --path . -s res://addons/test_kit/run.gd -- smoke adds
```

A scene name selects every case in that scene. A case name selects every scene
that registers it. An unknown name stops the run.

## Test scene rules

- The scene file must end in `.test.tscn`.
- The root node must have a script that extends the test class.
- The root script can be an external `.gd` file or an inline GDScript.
- Keep each `test()` call on one line for case-name selection.
- A computed case name or a wrapped call is selectable by scene name only.
- A scene that registers no test fails at runtime.

## Hooks

```gdscript
func before_test() -> void:
	pass

func after_test() -> void:
	pass

func reset_environment() -> void:
	pass

func before_scene_free() -> void:
	pass
```

- `reset_environment()` runs before every case. A project adapter uses it to
  reset shared state.
- `before_test()` runs after the reset. A suite uses it for its own setup.
- `after_test()` runs after the body.
- `before_scene_free()` runs after the result and before the scene is freed.
- `before_test()` and `after_test()` can await.

## A project fixture

A test scene can instance its project scene. A project adapter finds it once.

`tests/test_base.tscn`:

```text
[node name="TestRoot" type="Node"]

[node name="Main" parent="." instance=ExtResource("1")]
```

`tests/test.gd`:

```gdscript
extends "res://addons/test_kit/test_case.gd"

var main: Node

func _enter_tree() -> void:
	main = get_node_or_null("Main")
```

A test scene inherits `tests/test_base.tscn` and puts its suite script on the
root. The fixture is part of the scene. The runner does not create it.

## Failures and reports

Reports are in `res://.tests/<scene key>/report.md`. A failed check includes
its source line, the source text, and a screenshot when a window is available.
Add `/.tests/` to `.gitignore`.

## Timeouts and stops

- Each case has a 10 second timeout by default. Set `timeout` on the scene
  script or `{"timeout": N}` on `test()`.
- The deadman covers the whole selected run.
- The runner stops after 3 failed scenes. Edit `MAX_FAILURES` in `run.gd`.
- A busy loop in a test blocks the suite. The per-case timer cannot interrupt
  it. Use a CI job timeout as the final guard.

## Windowed and headless runs

The runner uses the process mode of its own command. Run the suite windowed
when a test needs input, rendering, or screenshots. Run it with `--headless`
when every test is pure logic.

The runner does not scan engine output. A scene passes when its checks pass. A
script error is printed but does not fail the run.

## Limitations

- The runner reads the test scene's root script for case names. A missing or
  unreadable root script leaves the scene selectable by scene name only.
- Scenes share one process. A project adapter must reset its shared state.
- There is no parallel scene execution.
