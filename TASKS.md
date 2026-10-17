---
max_active: 1
---

# Roadmap

Keep one active task at a time. Keep all remaining features until the scope review.
Use Git history for completed work. See [NOTES.md](NOTES.md) for verified engine and workflow facts.
See [GLTF_EXPORT.md](GLTF_EXPORT.md) for the mesh export format and import settings.

## Verification

- [ ] Close the remaining implementation tasks
  - [ ] Ask the user to test the Transform and Plane tools manually
  - [ ] Run the full behavior suite and the final full suite for these changes:
    - Per-voxel materials and material swatches
    - Independent picker settings and palette entries
    - Shared planar cleanup in the viewport and exporter
  - Run the suites without another Godot instance using this project.
  - Clipboard and model settings popup checks previously failed in a suite but passed alone.
  - The latest recorded second suite run ended early with exit -1.
  - Keep full-material seams and the same polygon cleanup for flat and smooth shading.
  - Skip the optional Blender OBJ comparison when the reference file is absent.

## Tools

- [ ] Add the Extrude tool
  - Extrude selected voxels along the plane normal.
  - Set the distance with a drag.

## Rendering and performance

- [ ] Keep drawing responsive on large models
  - Measure with `tests/draw_latency.tscn`. It prints one line per stage.
  - The chunk surface build dominates drawing latency. The greedy mesh and the
    planar cleanup with atlas bake each take about half of one chunk build.
  - [x] Run chunk surface builds on most worker threads instead of two
  - [x] Rebuild only the changed chunks and the neighbors that mesh across a changed face
  - [x] Guard the rebuild scope with `tests/chunk_rebuild_scope.tscn`
  - [x] Skip empty chunk layers in the greedy mesh
  - [x] Guard the merged faces with `tests/planar_merge.tscn`
  - [ ] Limit the mesher scan to each plane's occupied rectangle
  - [ ] Sort planar region cells with a native sort instead of a script comparator
  - [ ] Compute each region's contours once instead of once for protection and once for triangulation
  - [ ] Reduce the triangle count around holes and notches
  - [ ] Reuse completed chunk geometry during preview shape changes
  - [ ] Divide large mesh installations across frames
  - Measured on a 32-cube with a cube brush of nine:
    - Visible latency per motion decreased from 420 ms to about 110 ms.
    - The longest frame gap decreased from 61 ms to about 9 ms.
    - A single-cell brush settles in about 6 ms per motion.
  - Measured per chunk build:
    - An empty chunk decreased from 7.5 ms to 0.06 ms.
    - A one-layer plate decreased from 8.2 ms to 6.2 ms.
    - A solid chunk stays at about 12.6 ms.
  - The planar cleanup still costs most of a build with many small material groups.
- [ ] Merge faces that the planar cleanup drops
  - A region whose outline visits a corner twice caused a fallback to one quad per cell.
  - A diagonal gap of cells produces that outline.
  - [x] Split a self-touching outline into simple loops instead of one quad per cell
  - A hole that touches the outline at a corner becomes a negative piece and opens below.
  - No three-by-three mask falls back now. Four did before the fix.
  - `tests/failed_greed.tscn` reports the effect on a reported document.
  - A 5 by 5 slab with a three-cell diagonal gap decreased from 92 to 56 triangles.
  - [ ] Reduce the triangle count around holes and notches
  - A one-cell hole raises a 16 by 16 plate from twelve triangles to forty.
  - `Geometry2D.triangulate_polygon()` fails on a unit square at 4096, so single
    cells there keep the correct one-quad fallback.
- [x] Mesh flat and smooth surfaces the same way
  - The mesher merged only flat faces. Smooth faces became one quad per voxel face
    and the cleanup merged them again.
  - The mesher now merges both. A smooth normal comes from the voxel lattice
    corner, read from the frame in the cleanup instead of interpolated per quad.
  - A smooth chunk build decreased from 25.9 ms to 21.7 ms on a solid model.
  - Material-heavy models are unchanged, because their faces cannot merge.
  - The viewport and the exporter still produce the same vertices and normals.
- [ ] Distribute expensive jobs across the available worker threads
  - Use chunk work groups for independent matching and edit work.
  - Preserve cancellation, bounded publication, and UI responsiveness.

## Import

- [ ] Import native Aseprite files

## Palette

- [ ] Select and move multiple swatches
  - Select multiple swatches with a drag.
  - Move the selected swatches to a new palette location with a drag.
- [ ] Add palette sorting
  - Reverse the swatch order.
  - Sort by hue, saturation, and brightness.
  - Sort by red, green, and blue.
- [ ] Create a gradient across selected swatches
  - Use the first and last selected swatches as the endpoints.
  - Replace the selected swatches between the endpoints.

## Primitives and stamps

- [ ] Add sphere, box, and cylinder fill primitives to a tool menu
- [ ] Place a saved voxel file as a stamp

## Onion skinning

- [ ] Show previous and next frames as ghosts behind the current frame
  - Add a toggle and a strength control.

## Responsive UI

- [ ] Adapt narrow layouts for phone use
