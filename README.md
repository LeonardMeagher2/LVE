# Leonard's Voxel Editor

**Made with LVE.**

Create voxel art and animation with Leonard the flamingo.

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

## Icon

Leonard is the flamingo in `icon.svg`.
The vector icon preserves the source image's pixel edges, colors, and transparency.
