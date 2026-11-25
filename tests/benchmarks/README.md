# Benchmarks

Run a benchmark scene from the project root.

```text
godot --path . res://tests/benchmarks/low_poly_models.tscn
```

Each scene prints its measurements. No scene is part of the test suite.

## low_poly_models

Build the prototype models in Low Poly mode.
The scene builds every chunk on `WorkerThreadPool`, as the renderer does.
It prints one line per frame and model.

Read `build_ms` as the parallel build time.
Read `verify_ms` as the weld, the open edge count, and the duplicate check.
The verification is serial and runs after the build.

Use these variables to change a run:

- `LVE_MODELS` selects models by name, separated by commas.
- `LVE_PROFILE` prints the mesher phase times for each frame.
- `LVE_NOWELD` skips the weld and the open edge check.

The model paths point outside the repository.
A missing file prints a skip line and the run continues.

## low_poly_screenshots

Write the low poly and voxel images to `docs/screenshots/lowpoly/`.
The scene renders a model without the editor UI.

## mesher_phases

Time the voxel mesher phases on a synthetic block.
