# Agent and contributor notes

Read [AGENTS.md](../../AGENTS.md) first.
These notes give the development context for people and agents.

- [Roadmap](../../TASKS.md)
- [Verified memory](../../MEMORY.md)
- [Tool flow maps](tool-flows/README.md)
- [Tool research](research/tools/README.md)

## Releases

The version in `project.godot` is the release source of truth.
Set `application/config/version` and push the change to `main`.
The release workflow exports every runnable preset in `export_presets.cfg`.
It skips a version that already has a release.

The tests are in `tests/`.
The release workflow is in `.github/workflows/release.yml`.
