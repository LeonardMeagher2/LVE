# AGENTS.md

Leonard's Voxel Editor is a Godot voxel-animation editor. Godot is the only toolchain.

## Workflow

- Use [docs/agents/TASKS.md](docs/agents/TASKS.md) for the roadmap.
- Read adjacent files before editing. Follow their structure and style.
- Reuse suitable resources, utilities, and engine features.
- Add abstractions only for a concrete need. Explain non-obvious choices and their tradeoffs.
- When committing, prefer whole-file staging over partial staging.
- Record verified engine and workflow learnings in [docs/agents/MEMORY.md](docs/agents/MEMORY.md) during the task that finds them.
- Read [docs/agents/PLAN.md](docs/agents/PLAN.md) for the product-lens audit.
- Use [docs/agents/tool-flows/README.md](docs/agents/tool-flows/README.md) for current tool behavior.
- Use [docs/agents/research/tools/README.md](docs/agents/research/tools/README.md) for evidence and design notes.

## Documentation

Write documentation and commit messages in ASD-STE100 (Simplified Technical English).

- Keep sentences under 20 words. Give one instruction per sentence.
- Use imperative instructions. Put conditions before commands. Use lists for sequences.
- Use consistent terms. Include articles and necessary uses of "that".
- Use "must", "can", or "will" instead of "should", "may", or "might". Do not use semicolons.

## GDScript design

Use the `godot-docs` skill to verify API assumptions against the current stable documentation.

### Structure and state

- Keep execution state separate from shared Resources. Before mutation or duplication, identify which objects and nested data remain shared.
- Pass operation-specific dependencies explicitly. Reserve Autoloads for application-wide responsibilities.
- Use parentage for natural lifetime and spatial relationships. Avoid dependencies on unrelated tree paths.
- Restore previous values after temporary changes. Define the scope of events and undo history.

### Lifecycle and timing

- Keep exported setters safe before `_ready()`. Child nodes do not necessarily exist yet.
- Clean up subscriptions and external registrations. Avoid duplicate connections on tree re-entry.
- Node parentage controls lifetime. The `owner` property controls inclusion in saved scenes.
- Free Nodes outside an owning tree explicitly. Break RefCounted reference cycles.
- Use elapsed time for behavior measured in seconds. Fixed per-frame interpolation is not frame-rate independent.
- After each `await`, verify target validity and that the operation is still current.
- Define asynchronous cancellation and completion. Distinguish finished input, calculated results, and fully consumed output.
- Disabling processing does not cancel waits, disconnect signals, or prevent direct calls.
- Use deferred calls only for a specific timing need. Deferred execution is not parallel execution.

### Authoring and performance

- Describe valid exported values with types, hints, ranges, and configuration warnings.
- Separate `@tool` editor previews from runtime side effects.
- Reuse calculations when execution, estimation, and previews follow the same rules.
- Prefer events over polling. Update derived data when inputs change and define cache invalidation.
- When custom Resource properties change, emit `changed` if observers require notification.
- Optimize measured costs. Combine repeated rebuild requests when needed.

## UI conventions

- Never set `focus_mode = 0` (FOCUS_NONE) on controls.
- Never set `custom_minimum_size` on icon-only toolbar buttons. Let the container size them.
- Set `icon_alignment = 1` (CENTER) on icon-only buttons.
- Handle mouse input in `_gui_input`. The GUI keeps the pointer on the pressed control until the release, and it must see the release to clear that state. A mouse event consumed in `_input` stops before the GUI.

## Verification

Run commands from the project root.

- Run the affected tests after changes and before closing a task.
- For documentation-only changes, review the text and diff. Tests are not required.

Run one behavior test:

```text
godot --path . res://tests/paint_strokes.tscn -- paint
```

Run the full suite:

```text
godot --headless --path . -s res://tests/run_all.gd
```

Run named scenes or legacy test names:

```text
godot --headless --path . -s res://tests/run_all.gd -- paint line brush_modes
```

Reports are in `tests/artifacts/`. The runner exits non-zero on failure.
The runner opens each child scene on screen 0. Tests in one group share a child process.
Run a test scene with a window. The runner never passes `--headless` to a child, and the coordinator is the only headless process.
A headless scene cannot draw, take a failure screenshot, or use the clipboard, focus, or popup paths.
A headless scene that records no check fails, so a skipped case never reports success.
To select tests inside a scene, add their names after `--`. A scene name selects its entire group.

### Writing tests

- Follow `tests/test.gd` and adjacent tests. Each test script needs a matching scene with that script on its root.
- Extend `"res://tests/test.gd"` by path. The tests folder is excluded from the global class cache.
- Register each behavior in `_ready()` with `test(description, callable, name)`. Use a unique name within the file.
- Keep related tests in one file. Share fixtures and helpers without sharing execution state.
- Override `_setup_test()` and `_cleanup_test()` to isolate each test. The harness awaits both hooks.
- Keep each test selectable alone or in another order. The runner reads case names from the `test()` calls, so no alias table exists. Name each case after its old scene when a scene merges.
- A case that records no check fails. Set `allow_no_checks` before `test()` only for a print-only probe.
- Use `step("Given ...", func)`, `step("When ...", func)`, and `step("Then ...", func)` for setup, actions, and checks.
- Use `expect(condition, message)` with an affirmative description of the required state.
- Put waits in the test body, not step lambdas. Use member variables for state shared between steps.
- The harness waits two frames before each test. Its per-test watchdog covers setup, the test body, and cleanup.
- Set `timeout` before each registration when the default 10 seconds is insufficient. Each test keeps its registered deadline.
- Keep the separate scene deadline unchanged.
