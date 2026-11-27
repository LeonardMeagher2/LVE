# Tool flow maps

Use these maps to compare the current tool flows.
Use the source links to check each implementation.

Source links name the symbol and omit line ranges.
Update the maps when a tool flow changes.

## Read the maps

Use a Markdown viewer with Mermaid support to display the graphs.

1. Start with the shared input, edit, preview, and rendering paths.
2. Select a tool family from the table.
3. Compare captured state, work queues, cancellation, and undo boundaries.
4. Check the proposed changes against each tool's required behavior.
5. Use the [cross-tool comparison](comparison.md) to find shared steps and required differences.
6. Use the [composition guide](composition.md) for the current A to H mechanisms.

| Map | Tools and paths |
| --- | --- |
| [Cross-tool comparison](comparison.md) | Shared steps, required differences, and review questions |
| [Composition guide](composition.md) | Current A to H mechanisms, signatures, ownership, and reuse limits |
| [Shared paths and utilities](shared-and-utilities.md) | Input routing, edit jobs, previews, model rendering, Plane, Symmetry, Eyedropper |
| [Drawing](drawing.md) | Brush, Eraser, Line, Stamp, Paint Brush, Dither Brush, Fill, Spray, Primitive |
| [Terrain](terrain.md) | Build, Flatten, Smooth |
| [Deform](deform.md) | Grab, Pose |
| [Transform, clipboard, and selection](transform-selection.md) | Move, Rotate, Scale, Paste, Copy, Cut, Box, Lasso, Wand |

## Diagram scope

- Read each Mermaid graph as a control flow, not a class diagram.
- Read main-thread and worker labels separately from tool stages.
- Distinguish replaceable hover requests from accepted edits.
- Distinguish input release, calculated results, committed edits, and installed surfaces.
- Keep tool-specific policies visible when comparing shared stages.
- Use the current code as evidence. These maps do not establish performance results.

## Review constraints

- Preserve camera navigation and accepted input.
- Preserve operation ownership, cancellation, and undo scope.
- Preserve selection, symmetry, materials, and placement rules.
- Reuse existing mechanisms before adding new abstractions.
- Measure complete tool flows before selecting performance changes.
- Keep unused helpers and planned features separate from runtime behavior.

See [GitHub issues](https://github.com/LeonardMeagher2/LVE/issues) for active work.
See [MEMORY.md](../../../MEMORY.md) for measured results and verified constraints.
