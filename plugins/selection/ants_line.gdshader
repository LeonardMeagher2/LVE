shader_type canvas_item;

// Marching ants for a screen-space Line2D outline.
// UV.x is the distance along the line divided by the line width, so the dash
// size below is in pixels. The line's width must match width_px.

uniform vec4 frame_color : source_color = vec4(1.0);
uniform vec4 ant_color : source_color = vec4(0.25, 0.25, 0.25, 1.0);
uniform float width_px = 1.0;
uniform float dash_px = 5.0;
uniform float speed_px = 20.0;

void fragment() {
	float distance_px = UV.x * width_px;
	float period = dash_px * 2.0;
	float march = mod(distance_px + TIME * speed_px, period);
	COLOR = march < dash_px ? frame_color : ant_color;
}
