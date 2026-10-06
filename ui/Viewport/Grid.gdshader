shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform vec4 line_color : source_color = vec4(0.65, 0.65, 0.65, 0.8);
uniform int floor_axis = 1;

varying vec2 grid_position;

void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	int u = (floor_axis + 1) % 3;
	int v = (floor_axis + 2) % 3;
	grid_position = vec2(world_position[u], world_position[v]) + vec2(0.5);
}

float grid_coverage(vec2 footprint, float spacing) {
	vec2 coordinates = grid_position / spacing;
	vec2 distance_to_line = abs(fract(coordinates - vec2(0.5)) - vec2(0.5));
	vec2 pixels_from_line = distance_to_line / (footprint / spacing);
	vec2 coverage = vec2(1.0) - smoothstep(vec2(0.0), vec2(1.0), pixels_from_line);
	return max(coverage.x, coverage.y);
}

void fragment() {
	vec2 footprint = max(fwidth(grid_position), vec2(0.0001));
	float level = max(0.0, log2(max(footprint.x, footprint.y) * 24.0) * 0.5);
	float spacing = pow(4.0, floor(level));
	float transition = smoothstep(0.0, 1.0, fract(level));
	float coverage = mix(grid_coverage(footprint, spacing), grid_coverage(footprint, spacing * 4.0), transition);
	ALBEDO = line_color.rgb;
	ALPHA = line_color.a * coverage;
}
