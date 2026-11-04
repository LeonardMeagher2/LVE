extends "res://tests/terrain_tools.gd"

# The Smooth, material, and drain cases of the terrain tool matrix.
#
# The script extends the root case file, so every fixture, helper, and setup hook
# is shared and no case changes. The split keeps each scene inside its own
# deadline: the root runs the Build, Flatten, surface, gradient, Grab, and preview
# cases, and this scene runs the Smooth and drain cases. A case name still
# selects its own case, because the runner reads the registered names from the
# script.


func _ready() -> void:
	test("Smooth leaves a flat plate unchanged", _smooth_flat, "smooth_flat")
	test("Smooth lowers a spike without cutting through", _smooth_spike, "smooth_spike")
	test("Smooth raises a pit without overshoot", _smooth_pit, "smooth_pit")
	test("Smooth never seeds an empty floor", _smooth_empty, "smooth_empty")
	test("the Smooth controls show radius, strength, and no build direction", _smooth_controls, "smooth_controls")
	test("a Smooth stroke supports undo, redo, Escape, and a switch", _smooth_history, "smooth_history")
	test("the selection limits a Smooth stroke", _smooth_selection, "smooth_selection")
	test("symmetry mirrors a Smooth stroke", _smooth_symmetry, "smooth_symmetry")
	test("Smooth preserves surviving materials and fills with the local material", _smooth_materials, "smooth_materials")
	test("Smooth re-reads its plane as the surface changes", _smooth_adaptive, "smooth_adaptive")
	test("one Smooth dab applies its whole passes", _smooth_carry, "smooth_carry")
	test("Smooth keeps the outward sign on every orientation", _smooth_orientation, "smooth_orientation")
	test("Smooth symmetry across the normal axis keeps both sides", _smooth_symmetry_axis, "smooth_symmetry_axis")
	test("repeated Smooth re-reads of an unchanged ramp do not drift", _smooth_reread_stable, "smooth_reread_stable")
	test("a reentrant document swap during a Smooth signal is safe", _smooth_reentrant, "smooth_reentrant")
	test("Smooth rounds a convex cube corner and keeps the faces", _smooth_round_corner, "smooth_round_corner")
	test("Smooth softens a long convex edge, not only its corners", _smooth_round_edge, "smooth_round_edge")
	test("Smooth fills a concave inside corner", _smooth_round_concave, "smooth_round_concave")
	test("Smooth rounds a vertical edge from a side view", _smooth_round_vertical, "smooth_round_vertical")
	test("Smooth leaves a two-cell plate unchanged", _smooth_round_thick_plate, "smooth_round_thick_plate")
	test("Smooth rounds a staircase into a coherent ramp", _smooth_round_staircase, "smooth_round_staircase")
	test("a hold split across ticks rounds the same cells", _smooth_round_split, "smooth_round_split")
	test("the falloff scales the Smooth rounding rate", _smooth_weighted_falloff, "smooth_weighted_falloff")
	test("a cancelled Smooth job computes and publishes nothing", _smooth_job_cancel, "smooth_job_cancel")
	test("flatten raises each column with its own local material", _flatten_materials, "flatten_materials")
	test("flatten keeps the local material through symmetry and an empty seed", _flatten_material_symmetry, "flatten_material_symmetry")
	test("flatten raises downward with the local material on a signed normal", _flatten_material_signed, "flatten_material_signed")
	test("the strength sets the layer count of one dab", _strength_per_application, "strength_per_application")
	test("a weight below one half adds no layer", _falloff_fractional, "falloff_fractional")
	test("a held pointer never repeats a Build, Flatten, or Smooth dab", _stationary_no_repeat, "stationary_no_repeat")
	test("a worker dab burst drains to the frame-spaced result", _worker_dab_burst, "worker_dab_burst")
	test("Escape clears queued dabs and a stale worker cannot touch the next stroke", _cancel_stale_dabs, "cancel_stale_dabs")
	test("Smooth re-reads its plane on movement", _smooth_move_adaptive, "smooth_move_adaptive")
	test("a replay across different engine frame counts gives the same voxels", _frame_replay, "frame_replay")
	test("the lazy dab cursor yields the shared line path", _dab_path_iterator, "dab_path_iterator")
	test("a giant drag drains every accepted center over bounded frames", _giant_jump_drain, "giant_jump_drain")
	test("a first motion at the press position adds no Smooth dab", _smooth_first_motion_hold, "smooth_first_motion_hold")
	test("a 45 degree Smooth slope replay is delivery independent", _smooth_slope_replay, "smooth_slope_replay")
