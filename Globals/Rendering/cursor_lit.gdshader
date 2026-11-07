shader_type spatial;
render_mode cull_disabled;

// The solid brush cursor lights like a voxel, so it matches the cells it will
// paint. It wins an exact depth tie with the terrain by one view-space step, so
// the surface never z-fights the cell it covers. A vertex color, when present,
// multiplies the cursor color the way a voxel material does. It is stored in
// sRGB, so the shader decodes it before the multiply.

uniform vec4 cursor_color : source_color = vec4(1.0);
uniform vec4 emission_color : source_color = vec4(0.0);
uniform float metallic = 0.0;
uniform float roughness = 1.0;
uniform bool use_vertex_color = true;
// A mirrored instance has a negative scale, so the mesh normal points inward.
// The mirror cursor flips it back before the lighting runs.
uniform bool flip_normal = false;
// Drop the faces that point away from the camera. A cursor that surrounds the
// camera would otherwise fill the screen with its inner walls. A mirrored
// instance has reversed winding, so its outside is the GPU back face.
uniform bool flip_front = false;
// The depth step as a fraction of the view distance. A relative step stays
// above the depth resolution at every zoom.
uniform float depth_bias = 0.00001;

// Decodes one sRGB color to linear. The shader language has no built-in.
vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void vertex() {
	// Move the cursor toward the camera. The step is in view space, so it does
	// not depend on the depth convention of the renderer.
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.z += abs(view.z) * depth_bias;
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	if (FRONT_FACING == flip_front) {
		discard;
	}
	if (flip_normal) {
		NORMAL = -NORMAL;
	}
	vec3 albedo = cursor_color.rgb;
	if (use_vertex_color) {
		albedo *= srgb_to_linear(COLOR.rgb);
	}
	ALBEDO = albedo;
	ALPHA = cursor_color.a;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	EMISSION = emission_color.rgb;
	RIM = 0.05;
	RIM_TINT = 0.39;
}
