# AGENTS.md

Voxi is a Godot 4.7.1 voxel-animation editor. Godot is the only toolchain. There is no build system, CI, or linter. `TASKS.md` tracks the roadmap. Work on one active task at a time.

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

Tests are Godot `SceneTree` scripts. Run them with `-s`. Run windowed, not `--headless`, so failures save screenshots.

```
godot --path "C:\Users\Leona\Desktop\Gamedev\Voxi" -s res://tests/smoke.gd
```

- Pass: `VOXI TEST OK`, exit 0.
- Failure: `VOXI TEST FAILED: N/M ... report.md`, exit 1.
- `--headless` works but skips screenshot capture.
- This run is the only verification step.

## Test harness

- `tests/test.gd` defines the `Test` base class. It extends `SceneTree`. It exposes `test(description, callable)` and `expect(cond, msg)`.
- New tests extend `"res://tests/test.gd"` by path. The global class cache is unreliable under `-s`.
- In `_initialize()`, instantiate the scene, add it to `root`, then call `test("...", _func)`.
- Await frames before touching node state. Use `for i in 2: await process_frame`. `_ready()` has not run during `_initialize`.
- `expect` records all failures. It does not stop at the first failure. Failures write `tests/artifacts/<testname>/report.md` and `fail_*.png`. The artifacts directory is gitignored.

## BDD style

Write tests as behavior specs. Do not write code dumps.

- State the behavior in `test("...")`. Do not state the mechanism. Example: "can undo a brush stroke".
- State the expectation in `expect(cond, "msg")`. Example: "stroke voxel missing". Both args are required.
- Use Given (setup) / When (act) / Then (assert) when the test has real setup.
- The description and messages appear verbatim in the report. Write them for a human reader.

## Godot 4.7.1 quirks

The Steam `4.7.1.stable` build diverges from the Godot docs. Use the `godot-docs` skill to verify APIs. Read `docs/godot47-api-notes.md` for confirmed divergences. Do this before you use rendering or UI APIs.
