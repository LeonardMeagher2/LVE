shader_type spatial;
render_mode unshaded, cull_disabled;

varying float along;

uniform vec4 ant_color : source_color = vec4(1.0);
uniform float ant_spacing_px : hint_range(2.0, 40.0) = 20.0;   // screen px between ants
uniform float dash_px : hint_range(1.0, 30.0) = 10.0;           // dash length in px
uniform float speed_px : hint_range(0.0, 100.0) = 40.0;        // march speed in px/s

void vertex() {
	// Per-edge 0..1 param, no baked data.
	along = float(mod(float(VERTEX_ID), 2.0));
}

void fragment() {
	// along per screen pixel, from fragment derivatives.
	vec2 d_along = vec2(dFdx(along), dFdy(along));
	float along_per_px = max(length(d_along), 1e-5);
	// march position in pixels so spacing is constant on screen.
	float march_px = along / along_per_px + TIME * speed_px;
	float pos_px = mod(march_px, ant_spacing_px);
	float on = step(pos_px, dash_px);
	ALBEDO = ant_color.rgb;
	ALPHA = on * ant_color.a;
}