extends RefCounted

## Pure helpers for the falloff weight of one brush.
##
## The weight falls from one at the center of the brush to zero at its edge. A
## caller passes a size in cells, and the radius is half of it, so an even size
## keeps its half-cell center. The helper reads plain values and holds no state,
## so a worker can run it.

## Returns the falloff weight of one distance from the brush center.
##
## [param size] is the brush width in cells, [param falloff] runs from a flat one
## to a smooth zero at the edge, and [param inner] keeps a full weight inside that
## distance. A radius of zero returns one, so a degenerate brush never divides.
static func weight_at(distance: float, size: float, falloff: float, inner := 0.0) -> float:
	var radius := size * 0.5
	if radius <= 0.0:
		return 1.0
	var start := clampf(inner, 0.0, radius)
	var span := radius - start
	if span <= 0.0:
		return 1.0
	var t := clampf((distance - start) / span, 0.0, 1.0)
	var smooth := 1.0 - (t * t * (3.0 - 2.0 * t))
	return lerpf(1.0, smooth, clampf(falloff, 0.0, 1.0))
