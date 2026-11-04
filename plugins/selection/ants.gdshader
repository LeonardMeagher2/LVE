shader_type spatial;
render_mode unshaded, cull_disabled;

varying float along;

uniform vec4 frame_color : source_color = vec4(0.0,0.0,0.0,1.0);
uniform vec4 ant_color : source_color = vec4(1.0);
uniform float spacing : hint_range(2.0, 40.0) = 20.0;
uniform float speed : hint_range(0.0, 100.0) = 20.0;
uniform float scale = 1.0;
uniform float depth_bias = 0.00001;

void vertex() {
	along = float(mod(float(VERTEX_ID), 2.0));
	// The outline wins an exact depth tie with the terrain by one view-space step.
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.z += abs(view.z) * depth_bias;
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	float d_along = max(fwidth(along), 1e-5);
	float march = along / d_along + TIME * speed;
	float pos = mod(march, spacing * scale);
	float on = step(pos, spacing * 0.5 * scale);
	ALBEDO = mix(frame_color.rgb, ant_color.rgb, on);
}