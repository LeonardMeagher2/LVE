# Layers and the timeline

## Layers

A layer is an ordered group of cels. Each layer has one cel for every frame. The top layer draws over the layers below it.

The active layer takes every edit. Select a layer before you paint, fill, or move voxels.

A hidden layer leaves the view, the frame thumbnails, and the export. Its cells stay in the document.

A locked layer refuses edits, deletes, merges, and target moves. You can still select, rename, reorder, and show or hide it.

## Timeline layout

```text
[ playback | frame buttons | tag controls ]
[ Layers toolbar ]
[ tag range row ]
[ layer names | cel grid ]
[ timeline handle ]
[ frame thumbnails and delays ]
```

- The layer names stay at the left. The cel grid scrolls right with the frames.
- The layer names and the cel grid scroll down together.
- The tag range row sits above the cells.
- The frame thumbnails sit below the cells.
- Drag the line above the thumbnails to resize the thumbnail strip.
- Drag the strip below its compact size to hide the thumbnails.
- Double-click the line to hide or show the thumbnails.
- Drag the line above the timeline to resize the timeline.
- Drag the timeline below its minimum to collapse it.
- Double-click the line to collapse or restore the timeline.
- The app remembers both heights.

The thumbnails stop growing when they reach their width. A wider strip only adds space.

## Layer commands

The Layers toolbar holds these commands.

- **Add** adds a blank layer above the active layer.
- **Duplicate** copies the layer and every cel. The copy name adds " copy".
- **Delete** removes the layer. The app keeps at least one layer.
- **More** holds rename, merge, and move commands.

The layer menu also holds these commands.

- **Rename Layer** opens a name dialog. Double-click a layer name for the same dialog. The name cannot be empty.
- **Merge Down** merges the layer into the layer below. The merge covers every frame. The upper cell wins an overlap. The app refuses the bottom layer and a locked source or target.
- **Move Selection to Layer** moves the selected cells to another layer in the same frame. An empty selection moves the whole cel. The app refuses a hidden or locked target.

Drag a layer name onto another layer row to reorder the layers. The layer keeps its cels, name, visibility, and lock.

## Visibility and lock

- The eye button shows or hides the layer.
- The lock button allows or refuses edits.
- Both changes support undo and redo.

## Active layer and cels

- Click a layer name to select the layer.
- Click a cel to select its layer and frame.
- A filled cel shows a marker. An empty cel is blank.
- The active cel and the active layer are highlighted.

## Save, export, and agent access

- The document saves every layer, its cels, and its state.
- An older document loads as one layer.
- Export uses the visible layers. Hidden layers stay out.
- The agent tools can list, select, add, duplicate, delete, rename, reorder, merge, show, hide, lock, and move cels between layers.
- Use the agent tools to read one layer's cells or to render one layer.
- See [MCP.md](MCP.md) for the agent tools.

## Limits

- The document keeps at least one layer and one frame.
- Every layer has one cel for every frame.
- A locked layer still allows selection, rename, reorder, and visibility changes.
