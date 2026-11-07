# State machines

This file lists the explicit and implicit state machines of Leonard's Voxel
Editor. Each entry gives its states, invariants, and transition table. The
issue register ranks the confirmed bugs and records the regression evidence.

The code has few `enum` state variables. Most state is a set of flags, handles,
revision counters, and worker task ids. This file treats each such set as one
machine only when one owner changes it and other code reads it.

## How to read this document

- **State** is a named combination of fields. The fields are listed once.
- **Invariant** is a rule that every reachable state must satisfy.
- **Guard** is the test that allows a transition.
- **Effect** is the work and the signals of the transition.
- The issue ids `SM-A`, `SM-B`, and `SM-C` group related fixes. See
  [Issue register](#issue-register).

## Evidence

The regression cases are in `tests/state_machines.gd`. Run them with:

```text
godot --headless --path . -s res://tests/run_all.gd -- state_machines
```

The file paths and symbol names name the current code. Line numbers are not
used, because they move when the code changes.

## Issue register

| Issue | Priority | Machines | Confirmed defect | Fix | Regression cases |
| --- | --- | --- | --- | --- | --- |
| SM-A | High | edit transaction, history, all tools | `State.undo()` and `State.redo()` ran while an edit was open. The edit start snapshot then described a state outside the linear history. | `State.undo` and `State.redo` refuse an open edit. A new `edit_state_changed` signal disables the menu buttons. | `undo_open_edit`, `history_buttons_open_edit` |
| SM-B | Medium | playback | One `update()` advanced at most one frame and dropped the elapsed remainder. A finite repeat on a one-frame tag never finished. | Apply every covered frame duration and keep the remainder. Count one pass for a one-frame tag. | `playback_catch_up`, `playback_single_stop` |
| SM-C | Low | tag editing, undo history | `State.remove_tag()` used `active_tag` without checking it. With no active tag it removed the last tag and recorded a null entry in the undo action. | Refuse the removal when no valid tag is active. | `remove_tag_without_active` |

### SM-A detail

Reachable path:

1. Draw one stroke. The stroke commits one history action.
2. Start a Move or Rotate drag. The tool opens an edit. A pending transform keeps
   the edit open after the pointer release and has no foreground operation, so
   `edit_busy()` is false.
3. Press the Undo shortcut. The button was enabled. `State.undo()` replaced the
   frame chunks with an older action and cleared the redo stack.
4. Commit the transform. `VoxelEditTransaction.finish()` compared the state
   before the transform with the post-undo frame. It recorded the undo as the
   transform result.

The same interleaving was reachable during a held brush stroke. `edit_busy()`
does not include `_active_edit` because a tool must keep its own edit during
input. The guard therefore belongs in the history methods, not in
`edit_busy()`.

Before the fix, `tests/state_machines.gd` failed these checks:
`undo is refused while an edit owns the frame`, `the committed action stays`,
`the open edit keeps its change`, and `the history stack is unchanged`.

### SM-B detail

`AnimationPlayback.update()` previously did this:

```gdscript
_play_elapsed += delta
if _play_elapsed >= _current_delay():
    _play_elapsed = 0.0
    advance()
```

The reset lost the part of `delta` above the frame duration. A 1 ms animation
under a 16 ms render delta advanced one frame per 16 ms. The playback speed
depended on the render frame rate.

`advance()` also returned at once when `first_frame() == last_frame()`. A tag
with a finite repeat count never incremented `_play_passes`. The playback stayed
in `playing` forever and the Play control stayed pressed.

Before the fix, `playback_catch_up` and `playback_single_stop` failed.

### SM-C detail

`remove_tag()` assumed `active_tag` named a tag. `State.deselect_tag()` is a
public method and sets `active_tag = -1`. With two or more tags the removal ran
`document.tags.remove_at(-1)`, which removed the last tag. The undo action then
held a null tag.

The tag UI disables the delete action when no tag is active. The method itself
did not enforce the same rule. Before the fix, `remove_tag_without_active`
failed the size check, both identity checks, and the history check.

---

## M1. Operation list

Owner: `State.gd` (`Operation`, `_operations`, `_next_operation_id`).

### States

| State | Fields |
| --- | --- |
| No operation | `_operations` is empty. `_activity_started_ms` is zero. |
| Active | One `Operation` with a unique `id`, `label`, `total`, `foreground`, and `owner_ref`. |
| Cancellable | Active, and `_cancel_callback` is valid. |
| Cancel requested | Active, and `cancel_requested` is true. The owner must finish it. |
| Finished | The id is removed from `_operations`. The id is never reused. |

### Invariants

- One id names one operation for the life of the process.
- `finish_operation` is idempotent for an unknown or finished id.
- `cancel_operation` accepts one request only. A second request returns false.
- A foreground operation blocks edits for every requester except its owner.
- An operation whose owner is freed is finished in `State._process`.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| No operation | `begin_operation` | always | Active | Set the start time when the list was empty. Emit `activity_changed`. |
| Active | `update_operation` | id known and values differ | Active | Write progress. Emit `activity_changed`. |
| Active | `cancel_operation` | `can_cancel()` | Cancel requested | Set the flag. Emit the signal. Call the callback. |
| Cancel requested | `cancel_operation` | always | Cancel requested | Return false. No second callback. |
| Active or cancel requested | `finish_operation` | id known | Finished | Erase the id. Clear the start time when empty. Emit the signal. |
| Active | Owner freed | `owner_ref.get_ref() == null` | Finished | `_process` finishes the id. |

---

## M2. Edit transaction

Owner: `VoxelEditTransaction.gd`. Holders: `State._active_edit` and one tool
handle.

### States

| State | Fields |
| --- | --- |
| Absent | `State._active_edit == null`. A tool handle is null or closed. |
| Open | `State._active_edit == tx`, `tx._closed == false`. `tx` holds the document, the frame, the frozen context, and the start snapshots. |
| Closed by finish | `tx._closed == true`. The result is a `Change` or null. Live references are released. |
| Closed by cancel | `tx._closed == true`. The result is a `Rollback`. Live references are released. |
| Closed by abandon | `tx._closed == true`. No result. Live references are released. |

### Invariants

- At most one edit is open.
- Only the open transaction can close. `State.finish_edit` and `State.cancel_edit`
  compare the handle identity.
- A closed transaction holds no document, frame, or selection reference.
- The start snapshot is frozen. A later write copies a shared chunk or a shared
  selection first.
- A history action binds the frozen `Change`, never the live transaction.
- A history change must not run while an edit is open (SM-A).

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Absent | `begin_edit` | no open edit, current frame exists | Open | Capture chunks, selection, and context. Emit `edit_state_changed`. |
| Open | `finish_edit(tx)` | `tx == _active_edit` | Closed by finish | Clear the active handle. Capture the end state. Record one action when the content or selection changed. Emit `edit_state_changed`. |
| Open | `cancel_edit(tx)` | `tx == _active_edit` | Closed by cancel | Clear the handle. Restore the start chunks and selection. Emit `edit_state_changed`. |
| Open | document replaced | always | Closed by abandon | Close without restore. Emit `edit_state_changed`. |
| Open | `undo` or `redo` | always | Open | Return false. No history change (SM-A). |
| Closed | any close call | always | Closed | Return without a second restore or history action. |

---

## M3. Stroke batch pipeline

Owner: `StrokeTool.gd`. Used by the brush, paintbrush, spray, line, and paste.

### States

| State | Fields |
| --- | --- |
| Idle | `_edit == null`, `_job == null`, `_pending_centers` is empty. |
| Open, empty | `_edit != null` and no batch runs. |
| Queued | `_pending_centers` is non-empty and no batch runs. `_run_stroke` starts. |
| Inline batch | `_job != null`, `job.worker_task_id == -1`. The batch runs in the input or queue call. |
| Worker batch | `_job != null`, `job.worker_task_id >= 0`. One tracked operation exists. |
| Ending | `_end_requested` is true. New centers are refused. |
| Closing | The last batch published. `_finish_stroke` runs. |

### Invariants

- One runner owns one stroke at a time. `_job` is the runner token.
- Every accepted center is consumed in order. No accepted center is dropped.
- A batch publishes only when `_job == job`, the document and frame still match,
  and the job was not cancelled.
- A cancelled batch never publishes a partial frame.
- Escape and an edit context change roll the whole stroke back.
- A tool switch ends a stamp stroke like a release. Line and paste override this
  policy (M7).
- A press is refused while the tool still holds an edit or a batch.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | left press | pick hits, `open_stroke()` non-null | Open | Capture settings and context. Stamp the press center. |
| Open | motion with a different target | stroke active, left mask | Queued | Append crossed centers. |
| Queued | runner | `_job == null` | Inline or worker | Build one job. Stamp or await `State.run_edit_job`. |
| Inline or worker | batch done | `_job == job` | Open or Queued | Publish changed chunks by location. Continue the loop. |
| Open or Queued | release | `_job == null` | Closing | `_finish_stroke`. Close the edit with one history action. |
| Open or Queued | release | `_job != null` | Ending | Set `_end_requested`. Close after the last batch. |
| Any open | Escape or context change | always | Idle | Cancel the job. Abort the edit. Restore the start snapshot. |
| Any open | document or frame replaced | `_on_history_changed` or context | Idle | Cancel the job. The next batch must not use the old snapshot. |

---

## M4. Streamed fill

Owner: `FillTool.gd`.

### States

| State | Fields |
| --- | --- |
| Idle | `_fill_running == false`, `_stroke_active == false`, no open edit. |
| Open | `_stroke_active == true`, `_edit != null`, seeds wait in `_pending_seeds`. |
| Running | `_fill_running == true`. One coroutine owns `_fill_revision`. |
| Streaming | One `FillJob` in `_search_jobs` with a bounded queue. `_batch_cursor` consumes it. |
| Release pending | `_release_pending == true`. The stroke closes after the running fill. |
| Cancelled | `_fill_revision` advanced. Jobs are cancelled. The edit is rolled back. |

### Invariants

- One fill revision owns the queue, the cursor, and the chunk notifications.
- A coroutine whose revision is stale writes no tool state and emits no chunks.
- A cancelled stroke restores its whole start snapshot.
- The worker queue is cancelled before its join. A full queue cannot block the join.
- One undo action covers the whole stroke, including every streamed slice.
- The final chunk notification is forced, even when the cadence holds it back.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | press on a fillable cell | hit, editable, material differs | Open | Open the edit. Capture the material and the connected option. Enqueue one seed. |
| Open | seed available | `_fill_current`, small work | Running | Fill inline. Publish changed chunks. |
| Open | seed available | `_fill_current`, large work | Streaming | Start one worker. Apply bounded slices. |
| Streaming | slice applied | current revision | Streaming | Write one slice. Coalesce chunk ids. |
| Streaming | worker done and cursor done | current revision | Open or Closing | Cancel the queue. Join. Reset the cursor. |
| Any | release | `_fill_running == false` | Closing | Close the stroke and record one action. |
| Any | release | `_fill_running == true` | Release pending | Set the flag. Close after the drain. |
| Any | Escape, context change, or tool switch | always | Cancelled | Advance the revision. Cancel jobs. Roll back. Finish the operation. |

---

## M5. Streamed wand selection

Owner: `WandSelectTool.gd`.

### States

| State | Fields |
| --- | --- |
| Idle | `_job == null`, `_edit == null`, `_retired_jobs` empty. |
| Small search | `_job != null`, no worker. It runs and finishes in one call. |
| Streaming | `_job != null`, `_edit != null`, one worker and one bounded queue. |
| Finalizing | The worker is done. The batch cursor is drained. |
| Retired | `_job == null`. The cancelled job waits in `_retired_jobs` for its join. |

### Invariants

- One job owns the live selection updates.
- A slice applies only while `_selection_current(job)` is true.
- The final result and the streamed cells agree.
- One undo action covers the whole selection change.
- A cancelled job keeps a live context subscription until its worker joins.
- The queue is cancelled before the join, so a full queue cannot strand the worker.
- A tool switch keeps the stream. A frame or document change cancels it.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | left press on an occupied cell | not busy, hit exists | Small or Streaming | Capture the seed, material, mode, and context. |
| Small search | `_job.run()` | always | Finalizing | Build the result. |
| Streaming | worker pushes a batch | queue not cancelled | Streaming | Enqueue the batch. The producer waits when the queue is full. |
| Streaming | per-frame service | `_selection_current` | Streaming | Merge bounded slices. Publish the selection. |
| Streaming | worker done and cursor done | `_selection_current` | Finalizing | Cancel the queue. Join. |
| Finalizing | finish | `_job == job` | Idle | Restore the exact result. Close the edit. |
| Any active | Escape, context change, or cancel | always | Retired | Cancel the job. Roll back the edit. Reap the worker. |
| Retired | worker completes | always | Idle | Join once. Remove from `_retired_jobs`. |

---

## M6. Transform gesture

Owner: `TransformTool.gd`. Move, rotate, and scale share it.

### States

| State | Fields |
| --- | --- |
| Idle | `_dragging == false`, `_pending == false`, no edit. |
| Grab waiting | `_grab_waiting == true`. A press waits for the source job or a preview. |
| Dragging | `_dragging == true`, `_edit != null`. |
| Preview running | `_preview_running == true`, `_operation_id != 0`. |
| Pending | `_pending == true`, `_edit != null`. The preview stays applied. |
| Commit requested | `_commit_requested == true`. A commit waits for the preview. |
| Closed | The edit is finished or cancelled. |

### Invariants

- One edit spans the drags and the pending state.
- A preview publishes only for the current revision and context.
- A drag after the first re-anchors on the destination cells.
- A tool switch commits the pending transform.
- Escape cancels the transform and restores the start snapshot.
- Undo and redo are refused while the edit is open (SM-A).

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | left press | source count > 0, edit opened | Grab waiting | Start the source job. |
| Grab waiting | source ready | same input revision and context | Dragging | Capture the source cells and start the grab. |
| Dragging | motion past the click slop | context valid | Preview running | Apply one preview job. |
| Preview running | preview done | current revision | Dragging | Publish by location. Track the destination. |
| Dragging | release | `_dragged` | Pending | Keep the preview and the edit open. |
| Dragging | release | no drag | Idle | Close the empty edit. Open the numeric dialog for Move. |
| Pending | Enter, Commit, or tool switch | `_preview_running == false` | Closed | Close the edit as one history action. |
| Any active | Escape or context change | always | Closed | Cancel the preview. Roll back the edit. |
| Any open | undo or redo | `_active_edit != null` | Any open | Refused (SM-A). |

---

## M7. Line and paste placement

Owner: `LineTool.gd` and `PasteTool.gd`.

### States

| State | Fields |
| --- | --- |
| Idle | `_anchor == NONE`, no preview. |
| Anchored | `_anchor != NONE`, `_line_snapshot` frozen. |
| Preview queued or running | `_job != null`, `_revision` incremented for the newest request. |
| Preview ready | `_preview_result != null`, revision equals `_revision`. |
| Commit requested | `_commit_requested == true`. The commit waits for the newest preview. |
| Closed | The preview is published as one action, or cancelled. |

### Invariants

- A preview job publishes only when `_job == job`, the revision is current, and
  the anchor still exists.
- The preview writes its own job frame. It never writes the live frame.
- A commit publishes only the newest preview.
- A tool switch discards an unfinished line. A paste stays until its cancel.
- A frame or document change discards the placement.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | first press or paste placement | pick hits | Anchored | Freeze the snapshot and capture the settings. |
| Anchored | pointer move or second press | not commit requested | Preview queued | Increment the revision. Cancel the old job. |
| Preview running | job done | revision current, context valid | Preview ready | Cache the result and show it. |
| Preview ready | Enter or click | preview ready | Closed | Publish by location. Close the edit as one action. |
| Any | Escape, context change, or settings change | always | Idle | Cancel the preview. Clear the snapshot. |
| Preview running | tool switch | always | Idle | Cancel and join. A paste keeps its placement operation. |

---

## M8. Terrain stroke and drain

Owner: `TerrainTool.gd`.

### States

| State | Fields |
| --- | --- |
| Idle | `_edit == null`, `_drain_active == false`, no job. |
| Open | `_edit == _stroke_tx`, `_stroke_id` fixed, accepted segments queue. |
| Draining | `_drain_active == true`, `_drain_stroke_id == _stroke_id`. |
| Worker dab | One of `_tick_job`, `_grab_job`, or `_smooth_job` is non-null. |
| Ending | `_end_requested == true`. The drain closes after the queue and jobs. |
| Cancelled | `_stroke_tx == null`, jobs cancelled, start snapshot restored. |

### Invariants

- One stroke id and one transaction token identify the live stroke.
- A zombie drain that resumes after a frame yield cannot retire a newer drain.
- Every dab job publishes only through `_job_is_current(job)`.
- A dab job reads its own frame snapshot and copies a chunk before a write.
- A cancelled stroke restores its complete start snapshot.
- The stroke closes only after the accepted path is empty and no job runs.
- A press cannot join a stroke that is still finishing.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | left press | edit opened, pick valid | Open | Capture the plane, camera family, settings, and context. Apply the press dab. |
| Open | motion crosses a cell | visible move, ray moved | Open | Append one segment. Start the drain. |
| Open or Draining | dab available | `_busy() == false` | Inline or Worker dab | Apply one dab or start one prep batch. |
| Worker dab | job done | `_job_is_current(job)` | Open or Draining | Publish changed chunks. Merge tracked columns. Continue the drain. |
| Open or Ending | queue empty and no job | `_end_requested` | Closing | Close the edit with one action. |
| Any open | Escape, history change, or context change | always | Cancelled | Cancel jobs. Clear accepted input. Roll back. |
| Cancelled | drain resume | token mismatch | Cancelled | Return without touching the new stroke. |

---

## M9. Spray sampling, hover, and click

Owner: `SprayTool.gd`.

### States

| State | Fields |
| --- | --- |
| Idle | No batch, no hover job, no stroke job. |
| Hover requested | `_hover_request` is not empty. Epoch fixed. |
| Hover running | `_hover_sample_job != null`. |
| Hover installed | `_batch_center` names the shown batch and `_preview_version` matches. |
| Stroke open | `_edit != null`, `_stroke_active == true`. |
| Intent queue | `_pending_intents` is non-empty. `_intent_running` can be true. |
| Sample running | `_sample_job != null`. One tracked operation exists. |
| Write pipeline | Brush batches drain through `_pending_centers`, `_job`, and `_edit`. |
| Click ending | `_pending_end == true`. The reroll waits for the last write. |

### Invariants

- A hover result installs only when its epoch is current and the frame and
  context still match.
- A stroke result installs only when its job is current and the edit is the same
  transaction.
- The random state advances only for the current epoch.
- A press paints only a visible batch that the tool owns.
- An accepted stroke cell is never dropped.
- A click rerolls the next preview only after the accepted write closed.
- The selection index cache never accepts a stale selection dictionary.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | pointer over a cell | cheap estimate | Hover installed | Sample inline. Show the exact batch. |
| Idle | pointer over a cell | large estimate | Hover requested | Capture the request. Start one worker. |
| Hover requested | worker free | no stroke | Hover running | Start the job. |
| Hover running | job done | epoch current, frame and context match | Hover installed | Adopt the batch. Commit the random state. |
| Hover installed | left press | owned visible batch | Stroke open | Open the edit. Paint the visible batch. |
| Stroke open | motion to a new cell | cheap estimate | Stroke open | Sample and paint inline. |
| Stroke open | motion to a new cell | large estimate | Intent queue | Queue one captured intent. |
| Intent queue | runner free | edit still current | Sample running | Run one sample job. |
| Sample running | job done | job current, edit current | Intent queue or Write pipeline | Adopt the batch. Queue its cells. |
| Stroke open or Write pipeline | release | no pending write | Click ending | Close the edit. Reroll the preview. |
| Any | Escape, history change, or context change | always | Idle | Cancel samples. Roll back. Hide the preview. |

---

## M10. Preview mesh requests

Owner: `VoxelPreview.gd`.

### States

| State | Fields |
| --- | --- |
| Idle | `_pending_cells` empty, no job, hidden or a shown box. |
| Pending debounce | `_pending_cells` non-empty, `_request_due_ms` in the future. |
| Inline | The job runs in the request call. |
| Worker | `_preview_job != null`, `worker_task_id >= 0`. |
| Installed | `_installed_revision` names the shown surface, `_installed_cells` is immutable. |
| Stream | `_stream_job != null` or `_stream_has_pending` is true. |
| Cleared | `visible == false`, the installed cells and token are empty. |

### Invariants

- A strict request cancels the running job.
- A coalescing request keeps the running job and installs results in request order.
- A worker installs only when its revision is current, or when the coalescing
  rule allows a newer intermediate result.
- A clear advances the revision past every running job. A hidden preview cannot
  reappear.
- A stream installs only while its epoch is current.
- A cache hit reports the token of the request that asked for it.
- The installed cells never change after install.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | `show_voxels` or `show_selection` | non-empty cells, request differs | Pending or Worker | Freeze the cells. Build or look up the cache. |
| Pending debounce | due time reached | no job | Worker | Start one job. |
| Worker | task completed | revision current | Installed | Install. Cache the strict surface. |
| Worker | task completed | coalescing, newer than installed, strict alive | Installed | Install one intermediate surface. |
| Any | cache hit | equal cells and color key | Installed | Install the cached mesh. Report the new token. |
| Any | clear or `show_cell` | always | Cleared | Cancel. Advance the revision. Hide. |
| Any | progressive selection | always | Stream | Cancel the strict job. Queue the newest snapshot. |
| Stream | job done | epoch current | Installed or Stream | Install one intermediate outline. Start the newest. |

---

## M11. Chunk surface renderer

Owner: `VoxelRenderer.gd`.

### States

| State | Fields |
| --- | --- |
| No request | No entry in `_pending_surface_keys` or `_inflight_surface_keys`. |
| Pending | `_pending_surface_keys[location]` holds the newest wanted key. |
| In-flight | `_inflight_surface_keys[location]` holds the key this view can install. |
| Build running | `_surface_jobs[key]` holds one shared builder. |
| Displayed | `_displayed_surface_keys[location]` names the visible mesh. |
| Lost | The key left the cache and the job map. The eligibility is dropped. |
| Retired | The chunk left the frame. The instance waits for `queue_free`. |

### Invariants

- One chunk owns at most one in-flight key in one view.
- A context change clears every in-flight eligibility.
- The old mesh stays visible until the replacement is ready.
- A completed shared result installs before the newest request launches.
- The work slice bounds one update. Truncated work continues on the next frame.
- The shared cache and job map are used on the main thread only.
- The last renderer joins every shared job before it clears the shared maps.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| No request | `_request` | the displayed key differs | Pending | Store the newest key. Keep the old mesh. |
| Pending | update, no in-flight | job limit allows | In-flight | Snapshot the frame once. Start one builder. |
| Pending | update, same key cached | always | Displayed | Install from the cache. Touch the entry. |
| Pending | update, another view builds the key | job map has the key | In-flight | Adopt the shared result. |
| In-flight | update, cache has the key | pending still holds the location | Displayed | Install. Drop the eligibility. |
| In-flight | update, cache and job map both lack the key | always | Lost | Drop the eligibility. The pending request follows. |
| Any | rebuild or context change | always | Pending | Clear in-flight. Request every chunk again. |
| Any | chunk removed | always | Retired | Hide the instance. Retire it. Drop the in-flight key. |
| Any | last renderer exits | `_active_renderer_count == 0` | No request | Join every shared job. Clear the shared maps. |

---

## M12. Frame chunks and snapshots

Owner: `VoxelFrame.gd` (`chunks`, `_shared_chunks`, `Chunk`).

### States

| State | Fields |
| --- | --- |
| Live, unshared | The chunk is in `chunks` and not in `_shared_chunks`. |
| Live, shared | The chunk is in `chunks` and in `_shared_chunks`. A snapshot holds it. |
| Copied for write | A new chunk object replaced the shared object at the location. The marker is gone. |
| Removed | The location is absent. The snapshot can still hold the old object. |

### Invariants

- A shared chunk is immutable. The first write copies it.
- A snapshot never changes after it is returned.
- `capture()` marks every live chunk shared.
- `copy_chunks()` marks the requested chunks shared in the source.
- `job_frame()` marks every chunk shared in its own dictionary. The caller must
  not write the source while the job runs.
- `apply_published()` keeps the copy-on-write marker of a chunk the job did not
  write. It clears the marker of a chunk the job wrote.
- A bounds cache is valid only for the chunk count and the write history that
  built it.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Live, unshared | `capture` | always | Live, shared | Copy the chunk map. Mark every live chunk shared. |
| Live, shared | single write | location in `_shared_chunks` | Copied for write | Copy the chunk. Erase the marker. Mutate the copy. |
| Live, shared | batch write | location in `_shared_chunks` | Copied for write | Copy once. Erase the marker. Apply the batch. |
| Copied for write | `apply_published` | published marker absent | Live, unshared | Adopt the chunk. Clear the source marker. |
| Live, shared | `apply_published` | published marker present | Live, shared | Adopt the shared chunk. Keep the marker. |
| Any | full-chunk erase | always | Removed | Erase the location and its marker. |

---

## M13. Playback

Owner: `AnimationPlayback.gd`. `State.playback` is the live instance.

### States

| State | Fields |
| --- | --- |
| Stopped | `is_playing == false`. |
| Playing forward | `is_playing == true`, mode forward or ping-pong forward. |
| Playing reverse | `is_playing == true`, mode reverse or ping-pong reverse. |
| Finished | A finite repeat count reached. `is_playing` is set false. |

### Invariants

- `current_frame` stays inside the document range.
- A playback step keeps the frame inside the active tag range. An external frame
  write can leave it outside until the next step restarts at the boundary.
- `_play_passes` counts completed loops.
- A finite repeat stops the playback on the last displayed frame.
- The elapsed time carried between frames is not discarded (SM-B).
- A single-frame tag can complete a pass (SM-B).
- A very long stall cannot grow the catch-up loop without a bound.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Stopped | `is_playing = true` | always | Playing | Restart at the tag boundary. Reset passes and direction. |
| Playing | `update(delta)` | elapsed covers a frame duration | Playing | Apply every covered frame. Keep the remainder. |
| Playing | `advance` reaches the range end | repeats > 0 and passes reached | Finished | Set `is_playing = false`. |
| Playing | `advance` on a single-frame tag | repeats > 0 and passes reached | Finished | Count one pass and stop. |
| Playing | tag or range changes | always | Playing | Restart inside the new range. |
| Playing | `is_playing = false` | always | Stopped | Clear the clock. |
| Playing | frame outside the range | always | Playing | Restart at the boundary. |

---

## M14. Export and import

Owner: `ExportPlugin.gd`, `GLTFExport.gd`, `ImageImportPlugin.gd`, and the
clipboard runners.

### States

| State | Fields |
| --- | --- |
| Idle | `_exporting == false`, `_preview_running == false`, no job. |
| Export running | `_exporting == true`, one foreground operation, `_export_viewport` set. |
| Export cancelling | `_cancel_requested == true`. The worker checks its flag. |
| Preview queued | `_preview_due_ms` in the future. `_model_dirty` can be true. |
| Preview running | `_preview_running == true`, `_preview_operation_id != 0`. |
| Import running | `_import_job` or `_copy_job` non-null, one foreground operation. |
| Finished | The job is joined, the operation is finished, and the viewer is freed. |

### Invariants

- One export runs at a time. `_exporting` and `_export_job` both guard it.
- One import or copy runs at a time.
- A result installs only for the same document and current frame.
- A stale result never replaces a newer one.
- The operation finishes exactly once. A cancel and the runner can both finish it.
- A cancelled worker is joined before its viewport is freed.
- The preview clock resets only on a content change, not on a frame change.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Idle | export request | not busy, valid range | Export running | Freeze the frames. Start the foreground operation. |
| Export running | Escape or Cancel | operation is cancellable | Export cancelling | Set the cancel flag. Cancel the worker. |
| Export cancelling | worker done | always | Finished | Join. Free the viewport. Finish the operation. |
| Idle | content change | preview visible | Preview queued | Increment the revision. Set the due time. |
| Preview queued | due time reached | not busy, display available | Preview running | Render bounded tiles. |
| Preview running | render done | revision current | Finished | Install the texture. Finish the operation. |
| Preview running | document or view change | revision differs | Finished | Drop the image. Free the viewport. |
| Idle | import or copy request | not busy | Import running | Freeze the source. Start the foreground operation. |
| Import running | job done | same document and frame | Finished | Install the document, pattern, or cut. |
| Import running | document or frame change | always | Finished | Drop the result. Finish the operation. |

---

## M15. Palette and value controls

Owner: `PalettePanel.gd`, `ValueButton.gd`, `MaterialThumbnails.gd`, and
`Swatch.gd`.

### States

| State | Fields |
| --- | --- |
| Material gesture closed | `_material_edit_document == null`. |
| Material gesture open | `_material_edit_document == document`. One action covers the gesture. |
| Value edit idle | `_editing == false`, `_pointer_down == false`, `_dragging == false`. |
| Value edit pressed | `_editing == true`, entry hidden. |
| Value drag | `_dragging == true`. The fill bar shows. |
| Value entry | The `LineEdit` is visible and focused. |
| Thumbnail idle | `_rendering == false`, `_pending` empty. |
| Thumbnail running | `_rendering == true`. One controller renders in queue order. |

### Invariants

- One material gesture is open at a time.
- A cancelled gesture restores the start material and records no history.
- An outside material change closes a stale value edit.
- A value edit that is reset by a busy state does not leave the material gesture open.
- A thumbnail request returns a cached texture or null. The ready signal names
  the key. A stale key never updates a swatch.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| Gesture closed | control press or value edit start | not busy | Gesture open | Begin one history scope. |
| Gesture open | control release or value edit end | same control | Gesture closed | End the scope. Record one action. |
| Gesture open | Escape or document change | always | Gesture closed | Cancel. Restore the start material. |
| Value idle | left press | editable | Pressed | Emit `edit_started`. Grab focus. |
| Pressed | motion past 4 px | left mask | Drag | Show the fill. Snap the value. |
| Pressed | release without drag | always | Entry | Open and select the text. |
| Drag or Entry | release, submit, or focus loss | always | Idle | Apply or cancel. Emit `edit_finished`. |
| Thumbnail idle | request | key not cached | Thumbnail running | Defer one render pass. |
| Thumbnail running | render done | revision current | Thumbnail idle | Emit `thumbnail_ready` for each key. |

---

## M16. Worker task lifecycle

This sub-machine appears in every job. The owner of the job supplies the policy.

### States

| State | Fields |
| --- | --- |
| No task | `worker_task_id == -1`. |
| Running | `worker_task_id >= 0`, `is_task_completed` is false. |
| Completed, not joined | `worker_task_id >= 0`, `is_task_completed` is true. |
| Joined | `worker_task_id == -1` after `wait_for_worker()`. |
| Cancelled | `cancel_requested == true`. The worker stops at its next checkpoint. |

### Invariants

- `wait_for_worker()` is idempotent. It never cancels the job and resets the id.
- A cancelled task is still joined. The pool has no cancel call.
- A bounded queue is cancelled before the producer join. A full queue cannot block.
- The main thread retires the id. A worker never writes `worker_task_id`.
- A stale result keeps its handle until its runner or teardown joins it once.

### Transitions

| From | Event | Guard | To | Effect |
| --- | --- | --- | --- | --- |
| No task | `add_task` | always | Running | Store the id. |
| Running | task completes | always | Completed | The worker stopped at a checkpoint or finished. |
| Running or Completed | `cancel` | always | Cancelled | Set the flag. Wake a bounded queue if one exists. |
| Completed or Cancelled | `wait_for_worker` | `worker_task_id >= 0` | Joined | Wait. Reset the id. |
| Joined | `wait_for_worker` | always | Joined | Return at once. |

---

## Deliberate policies (not defects)

- `_active_edit` is one slot. A tool keeps its own edit during input. The history
  methods enforce the history rule instead of `edit_busy()` (SM-A).
- A tool switch keeps accepted work. The stroke, fill, wand, terrain, and export
  runners continue after the node leaves the tree. Only the optional hover stops.
- A strict preview request is latest-only. A coalescing cursor installs
  intermediate results in request order. The token names the request, not the
  cache entry.
- A frame snapshot is copy-on-write. A job frame shares chunks and writes its own
  copies. The caller must not write the source while the job runs.
- A worker result is advisory until the identity, the context, and the revision
  still match. A stale result never replaces a newer one.
- The mesh and surface caches are bounded. Eviction drops an entry, not a live
  job. A lost result is rebuilt through the pending request.

## Residual risks (not confirmed)

These are not reachable through the current UI. They are listed so a future
change can check them.

- The chunk surface key uses the `Chunk` instance id and the voxel revision. A
  freed chunk can share an id with a new chunk. A cache entry for the old chunk
  could then match the new one. The chance is low and the cache is bounded.
- `VoxelPreview` deduplicates a strict request by cells and flags, not by token.
  An equal request keeps the installed token. The current callers compare the
  cell set, not the token identity, so the surface stays correct.
- `ValueButton.reset_edit()` suppresses `edit_finished` when a listener resets
  the control. `PalettePanel._sync_buttons()` ends the material gesture on the
  same busy transition, so no gesture stays open.
- `TransformTool` disconnects its context subscription from a later idle path.
  `_exit_tree()` still reports `is_inside_tree() == true`. The extra connection
  is harmless and the guarded connect prevents a duplicate.

## Verification log

All commands run from the project root.

| Date | Command | Result |
| --- | --- | --- |
| 2026-11-07 | `godot --headless --path . -s res://tests/run_all.gd -- state_machines` | Failed before the fixes on the four cases above. Passed after the fixes. |
| 2026-11-07 | `godot --headless --path . -s res://tests/run_all.gd -- editor_chrome playback tag_controls tag_group tag_range tag_grip_focus edit_transaction` | 7 scenes passed. |
| 2026-11-07 | `godot --headless --path . -s res://tests/run_all.gd -- transform_workflow move_dialog frame_local_queries terrain_input` | 4 scenes passed. |
| 2026-11-07 | `godot --headless --path . -s res://tests/run_all.gd` (full suite) | 150 of 152 scenes passed. `export_workspace` assumed one update advanced one frame. The new catch-up can wrap a two-frame loop. The test now counts frame changes. `transform_worker_lifecycle` printed the Windows clipboard platform error from the clipboard poll. Both scenes passed alone after the fix. The full suite was not rerun after the two test-only edits. |
| 2026-11-07 | `godot --headless --path . -s res://tests/run_all.gd -- harness export_workspace transform_worker_lifecycle state_machines` | 4 scenes passed. The runner now ignores the busy-clipboard platform error. |

The state machine suite adds about 5 s to the suite. It keeps the shared Main
scene and uses the windowed child process like the other behavior scenes.
