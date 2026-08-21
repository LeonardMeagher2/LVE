# AGENTS.md

Voxi is a Godot voxel-animation editor. Godot is the only toolchain. There is no build system, CI, or linter. [TASKS.md](TASKS.md) tracks the roadmap. Work on one active task at a time.

## Learnings

[NOTES.md](NOTES.md) records confirmed learnings about the engine, APIs, and workflow.

- Record a learning during the task that found it. Do not wait for a request.
- Verify the fact before you record it.
- Use one bullet per learning. Start the bullet with the date. Keep the sentence short and in STE.
- Do not record opinions, speculation, or obvious facts.

## Doc writing standard

Write all docs and commit messages in ASD-STE100 (Simplified Technical English). Follow these rules.

- Keep sentences short. Use under 20 words per sentence.
- Give one instruction per sentence.
- Use active voice. Use the imperative for instructions.
- Write the condition before the command.
- Use one meaning per word. Do not use synonyms.
- Use lists for sequences. Do not bury them in prose.
- Do not hedge. Use "must", "can", or "will". Do not use "should", "may", or "might".
- Do not omit "that" or articles. Omission creates ambiguity.
- Do not use semicolons. Start a new sentence.

## Run tests

Each `tests/*.tscn` and `tests/*.gd` pair is one user-behavior test (paint, undo, camera, ...). Run the whole suite with `res://tests/run_all.gd`. Run the runner headless. It launches each test windowed so failures save screenshots.

```
godot --headless --path "C:\Users\Leona\Desktop\Gamedev\Voxi" -s res://tests/run_all.gd
```

Run one test with:

```
godot --path "C:\Users\Leona\Desktop\Gamedev\Voxi" res://tests/paint.tscn
```

- The runner exits 0 when all tests pass. It exits non-zero when any test fails.
- Failures write a report and screenshots under `tests/artifacts/`.
- A windowed run is required for screenshots. `--headless` skips screenshot capture.
- The suite is the only verification step.

## Test harness

- `tests/test.gd` defines the `Test` base class. It extends `Node`. It exposes `test(description, callable)`, `step(description, callable)`, and `expect(cond, msg)`. `step` returns the callable result. The harness prints each test, step, and check result to the console as it runs. `tests/run_all.gd` runs each test scene as a subprocess.
- New tests extend `"res://tests/test.gd"` by path. Each test needs a matching `tests/<name>.tscn` scene with the script on the root node. `.gdignore` hides the tests folder, so its `class_name`s are not in the global cache.
- In `_ready()`, instantiate the scene. Add it with `get_tree().root.add_child.call_deferred(...)`. Call `test("...", _func)`. Defer the add because the root is busy setting up children during `_ready()`.
- The harness waits two frames before each test body. Put `await` calls in the test's `_run` function, not in step lambdas. The autoload singletons resolve because tests run as scenes.
- `expect` records all failures. It does not stop at the first failure. Failures write a report and screenshots under `tests/artifacts/`. The artifacts directory is gitignored.
- Each test has a default timeout of 10 seconds. Set `timeout` in `_ready()` to override it. A timed-out test fails and writes a report.

## BDD style

Write tests as behavior specs. Do not write code dumps.

- State the behavior in `test("...")`. Do not state the mechanism. Example: "can undo a brush stroke".
- When the test has real setup, structure the body with `step("Given ...", func)`, `step("When ...", func)`, and `step("Then ...", func)`.
- State the expectation in `expect(cond, "msg")`. Write the message in the affirmative. Describe the state that must hold, not the failure. Example: "stroke voxel present". Both args are required. `expect` calls inside a step appear under that step in the report.
- Steps capture local variables by value. Share state between steps with member variables.
- The description and messages appear verbatim in the report. Write them for a human reader.

## Godot quirks

Do not assume an API exists from memory. Validate API assumptions against the current stable docs. Use the `godot-docs` skill for validation.
