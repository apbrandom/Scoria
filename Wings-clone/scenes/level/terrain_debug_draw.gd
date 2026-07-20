## Отрисовка реальных отрезков коллизии рельефа поверх картинки.
## Нужна, чтобы глазами убедиться: контуры воронок есть, фантомных стен
## на границах чанков нет.
class_name TerrainDebugDraw
extends Node2D

var terrain: Terrain
var show_chunk_grid := true

const SEGMENT_COLOR := Color(1.0, 0.25, 0.25, 0.9)
const GRID_COLOR := Color(0.3, 0.8, 1.0, 0.25)


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	if terrain == null:
		return
	for c in terrain.get_chunks():
		var off := c.position
		if show_chunk_grid:
			draw_rect(Rect2(off, Vector2(c.cw, c.ch)), GRID_COLOR, false, 1.0)
		var segs := c.get_segments()
		var i := 0
		while i + 1 < segs.size():
			draw_line(segs[i] + off, segs[i + 1] + off, SEGMENT_COLOR, 1.0)
			i += 2
