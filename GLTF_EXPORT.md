# glTF export

## Export a document

1. Select **Export** in the MenuBar.
2. Select **All tags** or an animation tag.
3. To center the model, enable **Center**.
4. To preview the animation, select **Play**.
5. Select **Export glTF / GLB...**.
6. Select a file format.
7. Select a path and save the file.
8. To return to the editor, select **Export** again.

- `.glb` stores the scene, geometry, textures, and animation data in one file.
- `.gltf` stores the scene in JSON and creates a separate `.bin` file and PNG textures.
- Keep the `.bin` file and texture files beside the `.gltf` file.

The shared export plugin is in `plugins/Export/`.
Preview playback preserves the editor frame and camera.

## Scale animation

The export uses only core glTF scale tracks.
Each active frame has a scale of one.
Each inactive frame has a scale of zero.
The file contains no visibility animation tracks.
The animation requires no extension.

Inactive rest frames use a small non-zero scale to prevent Godot quaternion errors.
Animation keys still use exact zero scale.

## Frame animation

The export contains one mesh per non-empty voxel frame.
Frame meshes are direct children of the model root.
Empty frames keep their frame delays.
Each frame mesh uses one surface and one material.
Each frame has its own albedo, finish, and emission atlases.
The albedo atlas stores sRGB colors and preserves alpha.
The finish atlas stores roughness in green and metallic in blue.
The emission atlas stores normalized sRGB emission.
Emission above one uses the standard `KHR_materials_emissive_strength` extension.
Textures use nearest filtering without mipmaps.
Each island has a one-pixel gutter that repeats its edge samples.
Each distinct voxel material uses one texel, regardless of face area.
All faces with that full material share the texel center.
Each atlas dimension has a 4096-pixel limit.
If an atlas cannot fit, the export returns an error before writing files.

With **Center** enabled, all frame meshes use one offset from their combined bounds.
With **Center** disabled, all frame meshes keep their document coordinates.
Relative frame positions remain the same.

With **All tags**, the export contains one clip per animation tag.
With one selected tag, the export contains only that tag's frames and clip.
Scale animation uses glTF `STEP` interpolation.
This permits different geometry in each frame.
All frame geometry remains in memory.

Reverse tags store reversed frame sequences.
Ping-pong tags store forward and reverse frame sequences.
Finite repeat counts are baked into the clip.
Tags with a zero repeat count store one cycle.
Their clip names end in `_loop`.
Godot imports these clips with linear looping enabled.
Ping-pong motion is already baked into the linear cycle.
Finite clips remain one-shot.

glTF 2.0 does not define playback looping or automatic playback.
Clip names replace unsupported characters and use suffixes when names repeat.
Finite clip names avoid Godot's automatic loop-name markers.
Other applications can require their own loop setting.

## Final mesh simplification

The worker simplifies each frame before export.
The worker welds vertices within 0.00001 voxel units before simplification.
The worker dissolves coplanar faces within full-material seams.
Color, alpha, emission, metallic, and roughness changes define those seams.
Polygon boundaries retain silhouettes, cavities, and seam junctions.
The pass uses sparse face masks instead of scanning empty frame bounds.
The worker triangulates the remaining polygon boundaries, including regions around holes.
Internal diagonal changes improve triangle shape without adding vertices or crossing material seams.
Flat and smooth shading use the same polygon cleanup rules.
Smooth shading retains the original normals at surviving corners.
Removing interior vertices can change normal interpolation without changing the silhouette.
The final mesh shares indexed vertices when their position, normal, and material sample match.

The viewport and exporter use the same planar cleanup and atlas code.
The viewport keeps separate chunks for local edits.
The exporter also merges faces across chunk boundaries.

A solid 64-cubed block uses six export quads instead of 96 chunk quads.
The resulting flat mesh has twelve triangles and twenty-four vertices.
The smooth mesh also has twelve triangles and shares eight corner vertices.
A block split into two color regions keeps its material seam and uses twenty triangles.

## Import into Godot

1. Enable **Animation > Import**.
2. Set **Animation > FPS** to a rate that represents every frame boundary.
3. Disable **Animation > Trimming** to preserve the first and last frame delays.
4. Disable **Animation > Remove Immutable Tracks** to preserve inactive frames when clips change.
5. Select a clip in the imported `AnimationPlayer`.
6. For infinite tags, keep the imported linear loop mode.

For exact integer-millisecond scale delays, use 1000 FPS.
Higher scale bake rates use more memory.

For runtime import, use the same settings:

```gdscript
var document := GLTFDocument.new()
var state := GLTFState.new()
var error := document.append_from_file(path, state)
if error == OK:
	var scene := document.generate_scene(state, 1000.0, false, false)
	add_child(scene)
```

## Sources

- [glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)
- [Khronos mesh-sequence discussion](https://github.com/KhronosGroup/glTF/issues/2175)
- [Godot runtime glTF loading and saving](https://docs.godotengine.org/en/stable/tutorials/io/runtime_file_loading_and_saving.html)
- [Godot GLTFDocument](https://docs.godotengine.org/en/stable/classes/class_gltfdocument.html)
- [Godot animation import settings](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/import_configuration.html)
