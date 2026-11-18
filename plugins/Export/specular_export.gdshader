shader_type spatial;
render_mode unshaded, depth_draw_opaque, fog_disabled;

// Writes the specular data for a specular map sheet. The finish atlas stores
// roughness in green and metallic in blue. Red holds metallic and green holds
// shininess. The export pass moves green into the image alpha afterwards, so
// the geometry stays opaque during the render.

uniform sampler2D orm_texture : hint_default_black, filter_nearest, repeat_disable;
uniform bool has_orm = false;
uniform float intensity = 1.0;

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
	vec3 data = vec3(0.0);
	if (has_orm) {
		vec4 finish = texture(orm_texture, UV);
		data = vec3(finish.b * intensity, 1.0 - finish.g, 0.0);
	}
	ALBEDO = OUTPUT_IS_SRGB ? data : srgb_to_linear(data);
	ALPHA = 1.0;
}
