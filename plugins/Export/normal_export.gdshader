shader_type spatial;
render_mode unshaded, depth_draw_opaque, fog_disabled;

// Writes the view-space surface normal for a normal map sheet. NORMAL and
// VERTEX are view space in fragment(). The color is the encoded normal, not a
// shaded color. The viewport output applies sRGB encoding, so write the linear
// value that encodes to the exact data byte.

vec3 srgb_to_linear(vec3 color) {
	vec3 low = color * (1.0 / 12.92);
	vec3 high = pow((color + vec3(0.055)) * (1.0 / 1.055), vec3(2.4));
	return vec3(
		color.r < 0.04045 ? low.r : high.r,
		color.g < 0.04045 ? low.g : high.g,
		color.b < 0.04045 ? low.b : high.b
	);
}

void fragment() {
	vec3 normal = NORMAL;
	float normal_length = length(normal);
	normal = normal_length > 0.00001 ? normal / normal_length : vec3(0.0, 0.0, 1.0);
	vec3 data = normal * 0.5 + 0.5;
	ALBEDO = OUTPUT_IS_SRGB ? data : srgb_to_linear(data);
	ALPHA = 1.0;
}
