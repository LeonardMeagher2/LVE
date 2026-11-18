shader_type canvas_item;

// Lights the sheet preview with the normal map. The light itself is a
// PointLight2D. This shader only supplies the base color and the normal map.
// The ambient term makes the pointer light visible. The unshaded preview uses
// the default canvas shader instead.

uniform sampler2D normal_map : hint_default_black, filter_nearest, repeat_disable;
uniform sampler2D specular_map : hint_default_black, filter_nearest, repeat_disable;
uniform bool has_normal = false;
uniform bool has_specular = false;
uniform float specular_intensity = 1.0;
uniform float ambient = 0.65;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec3 normal = has_normal ? texture(normal_map, UV).rgb : vec3(0.5, 0.5, 1.0);
	COLOR = vec4(base.rgb * ambient, base.a);
	NORMAL_MAP = normal;
}

void light() {
	float cNdotL = max(0.0, dot(NORMAL, LIGHT_DIRECTION));
	vec4 specular = has_specular ? texture(specular_map, UV) : vec4(0.0);
	vec3 view = vec3(0.0, 0.0, 1.0);
	vec3 half_vec = normalize(view + LIGHT_DIRECTION);
	float shininess = exp2(15.0 * specular.a + 1.0) * 0.25;
	float cNdotH = max(0.0, dot(NORMAL, half_vec));
	float blinn = pow(cNdotH, shininess);
	blinn *= (shininess + 8.0) * (1.0 / (8.0 * PI));
	float cNdotV = max(0.0, dot(NORMAL, view));
	float reflection = blinn / max(4.0 * cNdotV * cNdotL, 0.75);
	vec3 diffuse = LIGHT_COLOR.rgb * COLOR.rgb * cNdotL;
	vec3 shine = specular.rgb * LIGHT_COLOR.rgb * reflection * specular_intensity;
	LIGHT = vec4((diffuse + shine) * LIGHT_ENERGY, LIGHT_COLOR.a);
}
