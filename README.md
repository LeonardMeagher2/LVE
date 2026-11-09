# Leonard's Voxel Editor

Create voxel art and animation.

- [Download for Windows](https://github.com/LeonardMeagher2/LVE/releases/latest/download/LVE-windows-x86_64.zip)
- [Download for Linux](https://github.com/LeonardMeagher2/LVE/releases/latest/download/LVE-linux-x86_64.zip)

![Leonard's Voxel Editor with the Flamingo document](docs/lve-editor.png)

LVE is a voxel editor for 3D pixel art and animation.
Paint and sculpt voxels, set per-voxel materials, and animate frames with tags.
Export a low-poly glTF mesh or a sprite sheet.

## Features

- Paint, erase, fill, spray, and pick colors.
- Build, dig, flatten, smooth, and grab terrain.
- Select, move, rotate, and scale voxels.
- Mirror and slice the model while you work.
- Animate frames with tags, loops, and playback.
- Set albedo, metallic, roughness, and emission per voxel.
- Export glTF, GLB, and sprite sheets.
- Save compact `.lve` documents or `.lve.png` files with a preview.

## Download and run

1. Download the build for your platform.
2. Extract the archive.
3. Run `LVE.exe` on Windows or `LVE` on Linux.

The builds are standalone. You do not need Godot to run the editor.

Windows and Linux builds are available now.

## Document files

- `.lve` is a compact binary document.
- `.lve.png` adds a rendered first-frame preview.
- Open either format to restore the animation and saved settings.
- Share the original PNG file to preserve its document data.

See [docs/DOCUMENT_FORMAT.md](docs/DOCUMENT_FORMAT.md) for the format.

## Feedback

Open an issue for bugs and feature requests:
<https://github.com/LeonardMeagher2/LVE/issues>

## Development

LVE uses Godot 4.7.2. Godot is the only toolchain.

1. Import `project.godot` in Godot 4.7.2.
2. Run the main scene.

### Tests

Run one behavior test:

```text
godot --path . res://tests/paint_strokes.tscn -- paint
```

Run the full suite:

```text
godot --headless --path . -s res://tests/run_all.gd
```

### Releases

The version in `project.godot` is the release source of truth.
Set `application/config/version` and push the change to `main`.
The release workflow exports every runnable preset in `export_presets.cfg`.
It skips a version that already has a release.
Add a platform preset in Godot and mark it runnable to include it.

### Icon

The vector icon in `icon.svg` preserves the source image's pixel edges, colors, and transparency.

## License

MIT. See [LICENSE](LICENSE).
