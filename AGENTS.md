# AGENTS.md

Voxi is a Godot voxel-animation editor. Godot is the only toolchain. [TASKS.md](TASKS.md) tracks the roadmap. Work on one active task at a time.

## Coding standards

Match the code around you. Before you write new code, read the adjacent files. Follow the patterns you find.

- Match the structure of the adjacent scenes, scripts, and folders.
- Reuse the shared resources and utilities. Do not create new ones.
- Keep the code obvious. Prefer readability over cleverness.
- When committing prefer simple commits over hunking

## Learnings

[NOTES.md](NOTES.md) records confirmed learnings about the engine, APIs, and workflow.

- Record a learning in the task that found it. Verify the fact before you record it.
- Use one dated bullet per learning. Keep it short and in STE.
- Do not record opinions, speculation, or obvious facts.

## Doc writing standard

Write all docs and commit messages in ASD-STE100 (Simplified Technical English).

- Keep sentences short. Use under 20 words per sentence.
- Give one instruction per sentence. Use the imperative for instructions.
- Write the condition before the command.
- Use one meaning per word. Do not use synonyms.
- Use lists for sequences. Do not bury them in prose.
- Do not hedge. Use "must", "can", or "will". Do not use "should", "may", or "might".
- Do not omit "that" or articles. Do not use semicolons.

## Run tests

Each `tests/*.tscn` and `tests/*.gd` pair is one user-behavior test (paint, undo, camera, ...).

Run only the tests that your change can affect. Pick them by feature area.

Run one test headless for a fast check:

```
godot --headless --path "C:\Users\Leona\Desktop\Gamedev\Voxi" res://tests/paint.tscn
```

Remove `--headless` from that command when you need a failure screenshot.

Run the full suite when your change touches shared code. Shared code includes state, document, tool base classes, and UI containers. Run it again before you close a task:

```
godot --headless --path "C:\Users\Leona\Desktop\Gamedev\Voxi" -s res://tests/run_all.gd
```

- The runner exits 0 when all tests pass. It exits non-zero when any test fails.
- Failures write a report and screenshots under `tests/artifacts/`.
- A windowed run is required for screenshots. `--headless` skips screenshot capture.
- Tests are the only verification step.

## Test harness

- `tests/test.gd` defines the `Test` base class. It extends `Node`. It exposes `test(description, callable)`, `step(description, callable)`, and `expect(cond, msg)`. `step` returns the callable result. The harness prints each test, step, and check result to the console as it runs.
- New tests extend `"res://tests/test.gd"` by path. Each test needs a matching `tests/<name>.tscn` scene with the script on the root node. `.gdignore` hides the tests folder, so its `class_name`s are not in the global cache.
- In `_ready()`, instantiate the scene. Add it with `get_tree().root.add_child.call_deferred(...)`. Call `test("...", _func)`. Defer the add because the root is busy setting up children during `_ready()`.
- The harness waits two frames before each test body. Put `await` calls in the test's `_run` function, not in step lambdas.
- `expect` records all failures. It does not stop at the first failure. A timed-out test fails. The default timeout is 10 seconds. Set `timeout` in `_ready()` to override it.

## BDD style

Write tests as behavior specs. Do not write code dumps.

- State the behavior in `test("...")`. Do not state the mechanism.
- When the test has real setup, structure the body with `step("Given ...", func)`, `step("When ...", func)`, and `step("Then ...", func)`.
- State the expectation in `expect(cond, "msg")`. Write the message in the affirmative. Describe the state that must hold, not the failure. Both args are required.
- Steps capture local variables by value. Share state between steps with member variables.
- Write the descriptions and messages for a human reader. They appear verbatim in the report.

## Godot quirks

Do not assume an API exists from memory. Validate API assumptions against the current stable docs. Use the `godot-docs` skill for validation.

## UI conventions

- Never set `focus_mode = 0` (FOCUS_NONE) on any control. Let Godot handle focus naturally.
- Never set `custom_minimum_size` on icon-only toolbar buttons. Let the layout container size them.
- Always set `icon_alignment = 1` (CENTER) on icon-only buttons.
