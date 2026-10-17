# AGENTS.md

Leonard's Voxel Editor is a Godot voxel-animation editor. Godot is the only toolchain.

## Workflow

- Use [TASKS.md](TASKS.md) for the roadmap. Work on one active task at a time.
- Read adjacent files before editing. Follow their structure and style.
- Use the smallest design that solves the current problem. Reuse suitable resources, utilities, and engine features.
- Add abstractions only for a concrete need. Explain non-obvious choices and their tradeoffs.
- When committing, prefer whole-file staging over partial staging.
- Record verified engine and workflow learnings in [NOTES.md](NOTES.md) during the task that finds them.
- Use one short, dated bullet per learning. Exclude opinions and obvious facts.

## Documentation

Write documentation and commit messages in ASD-STE100 (Simplified Technical English).

- Keep sentences under 20 words. Give one instruction per sentence.
- Use imperative instructions. Put conditions before commands. Use lists for sequences.
- Use consistent terms. Include articles and necessary uses of "that".
- Use "must", "can", or "will" instead of "should", "may", or "might". Do not use semicolons.

## GDScript design

Use the `godot-docs` skill to verify API assumptions against the current stable documentation.

### Structure and state

- Use Nodes for scene-tree behavior, engine callbacks, input, and spatial relationships.
- Use Resources for reusable definitions and saved assets. Use RefCounted objects for temporary logic without tree membership.
- Use inheritance for specialization. Use composition for capabilities that vary independently.
- Keep execution state separate from shared Resources. Before mutation or duplication, identify which objects and nested data remain shared.
- Use direct calls for known receivers, signals for events, and groups for role-based discovery.
- Pass operation-specific dependencies explicitly. Reserve Autoloads for application-wide responsibilities.
- Use parentage for natural lifetime and spatial relationships. Avoid dependencies on unrelated tree paths.
- Keep reusable components focused. Put workflow ordering and policy in the responsible component.
- Restore previous values after temporary changes. Define the scope of events and undo history.

### Lifecycle and timing

- Keep exported setters safe before `_ready()`. Child nodes do not necessarily exist yet.
- Clean up subscriptions and external registrations. Avoid duplicate connections on tree re-entry.
- Node parentage controls lifetime. The `owner` property controls inclusion in saved scenes.
- Free Nodes outside an owning tree explicitly. Break RefCounted reference cycles.
- Use physics callbacks for physics, frame callbacks for frame updates, and events for discrete changes.
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

## Verification

Run commands from the project root.

- Run the tests affected by the change.
- For shared code changes, run the full suite. Shared code includes state, documents, tool bases, and UI containers.
- Run the full suite again before closing a task.
- For documentation-only changes, review the text and diff. Tests are not required.

Run one behavior test:

```text
godot --headless --path . res://tests/paint.tscn
```

Run the full suite:

```text
godot --headless --path . -s res://tests/run_all.gd
```

Reports are in `tests/artifacts/`. The runner exits non-zero on failure.
For failure screenshots, remove `--headless`.

### Writing tests

- Follow `tests/test.gd` and adjacent tests. Each test script needs a matching scene with that script on its root.
- Extend `"res://tests/test.gd"` by path. The tests folder is excluded from the global class cache.
- In `_ready()`, defer adding the tested scene to the tree. Register the behavior with `test(description, callable)`.
- Use `step("Given ...", func)`, `step("When ...", func)`, and `step("Then ...", func)` for setup, actions, and checks.
- Use `expect(condition, message)` with an affirmative description of the required state.
- Put waits in the test body, not step lambdas. Use member variables for state shared between steps.
- The harness waits two frames before each test. Override `timeout` in `_ready()` when the default 10 seconds is insufficient.
