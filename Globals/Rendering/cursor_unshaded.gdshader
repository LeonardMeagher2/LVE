shader_type spatial;
render_mode unshaded;

// The cursor draws flat color. It wins an exact depth tie with the terrain by
// one view-space step, so the outline never z-fights the cell it points at.

uniform vec4 cursor_color : source_color = vec4(1.0);
// The depth step as a fraction of the view distance. A relative step stays
// above the depth resolution at every zoom.
uniform float depth_bias = 0.00001;

void vertex() {
	// Move the cursor toward the camera. The step is in view space, so it does
	// not depend on the depth convention of the renderer.
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.z += abs(view.z) * depth_bias;
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	ALBEDO = cursor_color.rgb;
	ALPHA = cursor_color.a;
}
