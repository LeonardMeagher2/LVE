# LVE document format

Leonard's Voxel Editor uses one document encoding in two file types.

- `.lve` contains the binary document.
- `.lve.png` contains a PNG preview and the same binary document.

**Made with LVE.**

## Binary envelope

Version 3 uses this 16-byte header.
Header integers use little-endian byte order.

| Offset | Bytes | Contents |
| --- | --- | --- |
| 0 | 4 | Signature: `4C 56 45 00`, or `LVE` and a zero byte |
| 4 | 4 | Unsigned format version: `3` |
| 8 | 4 | Unsigned payload byte count |
| 12 | 4 | Unsigned CRC-32 of the payload |
| 16 | Variable | Godot 4 Variant binary payload |

The CRC uses the PNG CRC-32 algorithm.
The CRC detects accidental corruption.
The CRC does not authenticate a file.

The payload has no additional compression.
Octree leaves keep uniform voxel regions compact.
The Variant encoding is Godot-specific.

## Payload schema

The payload is an untyped dictionary with string keys.
All document fields are required.

| Key | Type | Contents |
| --- | --- | --- |
| `palette` | Untyped array | Ordered `PackedFloat32Array` material entries |
| `frames` | Untyped array | Frame dictionaries |
| `tags` | Untyped array | Animation tag dictionaries |
| `smooth_normals` | Boolean | Model shading option |
| `lighting` | Untyped dictionary | Editor lighting settings |
| `export` | Untyped dictionary | Export workspace settings |

Each frame has these fields.

| Key | Type | Contents |
| --- | --- | --- |
| `delay_ms` | Integer | Frame duration in milliseconds |
| `voxels` | Untyped array | `[3, chunk_records]` |

Each material holds nine floats: color RGBA, emission RGB, metallic, and roughness.
Palette entries and voxels use the same material layout.
The palette combines entries only when all nine values match.
Voxels store their own values, not palette indices.
Editing a swatch changes future strokes, not existing voxels.
The palette controls use the voxel color multiplied by emission strength for emission RGB.
Older independent emission RGB values remain stored until the color or emission strength changes.

Each chunk record is `[location, materials, nodes]`.

- `location` is a `Vector3i` chunk coordinate.
- Each chunk contains 16 × 16 × 16 voxel positions.
- `materials` is a `PackedFloat32Array` with nine floats per material.
- Material index zero contains an empty material with Godot's `Color.TRANSPARENT`.
- `nodes` is a `PackedInt32Array` in depth-first order.
- A nonnegative node is a uniform leaf with that material index.
- A node of `-1` has eight children.
- Each child has half the parent's region size.
- Child index bits select X, Y, and Z offsets, in that order.
- No node can subdivide a one-voxel region.
- Every node must belong to the chunk tree.

The loader also reads document versions 1 and 2.
Their color palettes receive black emission, metallic 0, and roughness 1.
The loader also reads voxel storage versions 1 and 2.
Saving writes the current versions.

Palette PNG export stores colors only.
It does not store emission, metallic, or roughness.
The private `lvPL` PNG chunk stores the entry count, not material settings.
The importer uses this count to retain transparent colors from exported 16-pixel tiles.
Same-color variants become identical default materials after color-only import and combine into one swatch.

Each tag has `name`, `from`, `to`, `loop_mode`, and `repeats` fields.
Frame ranges are inclusive.
Loop modes are forward, reverse, ping-pong, and reverse ping-pong, numbered zero through three.
A repeat count of zero means continuous playback.

Editor lighting supports `basis`, `color`, and `ambient_color`.
Color alpha stores the editor light strength.
Editor shading and shadow view options are not document settings.

Export settings support these keys.

- `view`, `sprite_ortho`, `automatic_size`, and `frame_size`
- `turntable`, `views`, `metadata`, and `center`
- `model_tag` and `sheet_tag`, with `-1` for all tags
- `lighting` and `camera`

Export lighting requires `basis`, `color`, `energy`, `ambient_color`, `ambient_energy`, `shadows`, and `shaded`.
It also supports `view_locked` and `view_basis`.
Export camera settings support `yaw`, `pitch`, `distance`, `initial_distance`, `target`, `orthographic`, and `fov`.
Settings dictionaries can be empty when the document uses defaults.
If export lighting exists, its required fields must be present.

The file excludes script references, resources, source paths, geometry caches, selection, and undo history.

## PNG container

The PNG uses a transparent 256 × 256 preview of the first frame.
The preview uses saved editor lighting and an orthographic isometric camera.
Empty first frames produce transparent previews.

The private ancillary chunk type is `lvED`.
Its data is the complete binary envelope and payload described above.
The writer places one document chunk immediately before `IEND`.
Chunk lengths and CRC values use PNG's big-endian byte order.

The chunk name marks the data as unsafe to copy after pixel changes.
PNG editors can remove the chunk.
Image services can remove the chunk during resizing or re-encoding.

For every PNG, the Open command checks the document chunk first.
If its data is valid, the command opens the complete document.
Otherwise, the command imports the visible image through the Image importer.
Duplicate document chunks are invalid.
The `.lve.png` suffix identifies the file to users but is not required for loading.

## Validation and limits

The loader checks the envelope and CRC before decoding the payload.
It checks Variant types, counts, lengths, and nesting before calling `bytes_to_var()`.
It rejects objects, script-typed containers, and unsupported Variant types.
It validates all frames before expanding octree leaves into voxel dictionaries.

The current format uses these limits.

| Item | Limit |
| --- | --- |
| Complete file | 64 MiB |
| Animation frames | 10,000 |
| Animation tags | 10,000 |
| Tag name | 1,024 characters |
| Palette entries | 65,536 |
| Occupied voxels across all frames | 4,194,304 |
| Chunk records per frame | 65,536 |
| Absolute chunk coordinate on each axis | 65,535 |
| Materials per chunk, including the empty entry | 4,097 |
| Octree nodes per chunk | 4,681 |
| Variant nesting | 16 levels |
| Decoded Variant values | 1,000,000 |
| Frame duration | 1 through 86,400,000 milliseconds |
| Finite repeat count | 1 through 1,000,000 |

Voxel and palette material components must be finite and between zero and one.
Light color components and strengths must be finite and between zero and sixteen.
Lighting bases must be finite and invertible.
Camera and export values must satisfy their supported ranges.

Unsupported versions and invalid binary documents leave the current document unchanged.
Saving writes a temporary file beside the destination.
The writer replaces the destination only after the temporary write succeeds.
The document's save path changes only after the replacement succeeds.

The editor does not import `.tres` documents.

## References

- [Godot Variant binary serialization](https://docs.godotengine.org/en/stable/tutorials/io/binary_serialization_api.html)
- [PNG chunk naming](https://www.w3.org/TR/png-3/#5Chunk-naming-conventions)
