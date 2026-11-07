shader_type canvas_item;
render_mode blend_mix;

// Darkens every screen pixel outside the projected document box. The viewport
// sends the convex hull of the projected box corners, so the mask follows the
// box in every view.

uniform vec2 hull[8];
uniform int hull_count = 0;
uniform vec4 shade_color : source_color = vec4(0.0, 0.0, 0.0, 0.4);

bool inside_hull(vec2 point) {
	if (hull_count < 3) {
		return false;
	}
	bool inside = false;
	for (int index = 0; index < 8; index++) {
		if (index >= hull_count) {
			break;
		}
		int next = (index + 1) % hull_count;
		vec2 start = hull[index];
		vec2 end = hull[next];
		if ((start.y > point.y) != (end.y > point.y)) {
			float cross_x = (end.x - start.x) * (point.y - start.y) / (end.y - start.y) + start.x;
			if (point.x < cross_x) {
				inside = !inside;
			}
		}
	}
	return inside;
}

void fragment() {
	if (inside_hull(UV)) {
		discard;
	}
	COLOR = shade_color;
}
