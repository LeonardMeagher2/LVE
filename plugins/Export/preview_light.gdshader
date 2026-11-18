shader_type canvas_item;

// Lights the sheet preview with the normal map. The light itself is a
// PointLight2D. This shader only supplies the base color and the normal map.
// The ambient term makes the pointer light visible. The unshaded preview uses
// the default canvas shader instead.

uniform sampler2D normal_map : hint_default_black, filter_nearest, repeat_disable;
uniform bool has_normal = false;
uniform float ambient = 0.65;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec3 normal = has_normal ? texture(normal_map, UV).rgb : vec3(0.5, 0.5, 1.0);
	COLOR = vec4(base.rgb * ambient, base.a);
	NORMAL_MAP = normal;
}
