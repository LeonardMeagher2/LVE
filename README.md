# Leonard's Voxel Editor

**Made with LVE.**

Create voxel art and animation.

## Document files

- Save `.lve` files for compact binary documents.
- Save `.lve.png` files for documents with a rendered first-frame preview.
- Open either format to restore the complete animation and saved settings.
- Share the original PNG file as an attachment to preserve its document data.

If a PNG has no valid document data, the editor imports its visible image.
The filename does not determine whether a PNG contains a document.

See [docs/DOCUMENT_FORMAT.md](docs/DOCUMENT_FORMAT.md) for the format specification.

## Run the editor

1. Import `project.godot` in Godot 4.7.2.
2. Run the main scene.

Godot is the only toolchain.

## Releases

The version in `project.godot` is the release source of truth.
Set `application/config/version` and push the change to `main`.
The release workflow exports every runnable preset in `export_presets.cfg`.
It publishes one asset for each preset and does not build a version that already has a release.
Each asset is named after the export platform and architecture.
Add a Windows, Linux, macOS, or Web preset in Godot and mark it runnable to add that platform to the next release.

Download the latest build:

- Windows: <https://github.com/LeonardMeagher2/LVE/releases/latest/download/LVE-windows-x86_64.zip>
- Linux: <https://github.com/LeonardMeagher2/LVE/releases/latest/download/LVE-linux-x86_64.zip>

## Tool flows

Use the [tool flow maps](docs/tool-flows/README.md) to compare tools and review shared behavior.

See [tool research](docs/research/tools/README.md) for evidence reviews and bounded experiments.

## Icon

The vector icon in `icon.svg` preserves the source image's pixel edges, colors, and transparency.
