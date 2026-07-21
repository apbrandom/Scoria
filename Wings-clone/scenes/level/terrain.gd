## Разрушаемый рельеф: битмап-источник истины + чанки со StaticBody2D,
## коллизия которых пересобирается через BitMap.opaque_to_polygons().
##
## Три параллельные структуры:
##   _class      — PackedByteArray на весь уровень, класс материала на пиксель.
##                 Глобальная, потому что геймплей спрашивает материал в произвольной
##                 мировой точке (вода, огонь, течения — см. notes/architecture.md §3).
##   chunk.vis_bytes   — RGBA8 по чанкам, отрисовка.
##   chunk.solid_bytes — LA8 по чанкам, альфа = твёрдость, вход для BitMap.
##
## Почему _class это PackedByteArray, а не Image FORMAT_R8 (как было в плане):
## Image.get_pixelv() возвращает Color — это аллокация и конверсия в float на каждое
## чтение. В цикле по воронке (до ~30k пикселей) разница принципиальная, а чтение
## байта из PackedByteArray — сырое индексирование. Image остаётся там, где он и нужен:
## отрисовка и вход в BitMap.
class_name Terrain
extends Node2D

signal carved(area: Rect2i)

@export var palette: TerrainPalette

@export_group("Chunking")
## Сторона чанка в пикселях рельефа.
@export var chunk_size: int = 128
## Во сколько раз маска коллизии грубее картинки.
## 2 — по замерам (tools/bench_terrain.gd) лучший компромисс: точность кромки
## почти как при 1 (96.9% лучей в пределах 3 px против 97.0%), а пересборка втрое
## дешевле.
@export_range(1, 8) var collision_downscale: int = 2
## Упрощение контура в opaque_to_polygons. Больше — меньше отрезков, грубее край.
## 0.5 срезает ~half отрезков почти без потери точности; на 2.0 точность заметно
## падает (84.6% против 96.9%).
@export var polygon_epsilon: float = 0.5

@export_group("Rebuild")
## Сколько чанков пересобирать за кадр, чтобы большой взрыв не давал спайк.
@export var max_chunk_rebuilds_per_frame: int = 4
## Пересобирать сразу в carve, не откладывая на кадр (используется бенчмарком).
@export var immediate_rebuild: bool = false

var size: Vector2i
var chunk_count: int:
	get: return _chunks.size()

var _class: PackedByteArray
var _chunks: Array[TerrainChunk] = []
var _cols := 0
var _rows := 0
var _dirty: Dictionary = {}

# --- телеметрия, микросекунды; сбрасывается stats_reset() ---
var stat_solid_image_usec := 0
var stat_bitmap_usec := 0
var stat_polygons_usec := 0
var stat_apply_usec := 0
var stat_texture_usec := 0
var stat_rebuilds := 0
## Сколько вырожденных контуров отсеяно (см. TerrainChunk.apply_polygons).
var stat_rejected_polys := 0


func _ready() -> void:
	add_to_group(&"terrain")


func stats_reset() -> void:
	stat_solid_image_usec = 0
	stat_bitmap_usec = 0
	stat_polygons_usec = 0
	stat_apply_usec = 0
	stat_texture_usec = 0
	stat_rebuilds = 0
	stat_rejected_polys = 0


# ---------------------------------------------------------------- загрузка

## visual — картинка уровня (альфа = форма). mask — опциональная карта классов
## в палитре TerrainPalette.mask_rgb. Без маски всё непрозрачное считается
## default_solid_class, прозрачное — EMPTY.
func load_level(visual: Image, mask: Image = null) -> Dictionary:
	assert(palette != null, "Terrain.palette не задан")
	var t_total := Time.get_ticks_usec()

	var src := visual
	if src.get_format() != Image.FORMAT_RGBA8:
		src = src.duplicate()
		src.convert(Image.FORMAT_RGBA8)
	size = src.get_size()
	var n := size.x * size.y

	# --- карта классов + полноразмерная маска твёрдости ---
	var t0 := Time.get_ticks_usec()
	_class.resize(n)
	var solid_full := PackedByteArray()
	solid_full.resize(n * 2)
	# инвертированная маска — для трассировки контуров дырок, см. TerrainChunk.empty_bytes
	var empty_full := PackedByteArray()
	empty_full.resize(n * 2)
	var solid_tbl := TerrainPalette.SOLID

	if mask != null:
		var m := mask
		if m.get_format() != Image.FORMAT_RGBA8:
			m = m.duplicate()
			m.convert(Image.FORMAT_RGBA8)
		assert(m.get_size() == size, "Размер mask.png не совпадает с visual.png")
		var md := m.get_data()
		var lut := palette.build_rgb555_lut()
		for i in n:
			var o := i * 4
			var key := ((md[o] >> 3) << 10) | ((md[o + 1] >> 3) << 5) | (md[o + 2] >> 3)
			var c := lut[key]
			_class[i] = c
			var so := i * 2
			if solid_tbl[c] != 0:
				solid_full[so] = 255
				solid_full[so + 1] = 255
			else:
				empty_full[so] = 255
				empty_full[so + 1] = 255
	else:
		var vd := src.get_data()
		var fill := palette.default_solid_class
		for i in n:
			var so := i * 2
			if vd[i * 4 + 3] >= 128:
				_class[i] = fill
				solid_full[so] = 255
				solid_full[so + 1] = 255
			else:
				_class[i] = TerrainPalette.Cls.EMPTY
				empty_full[so] = 255
				empty_full[so + 1] = 255
	var t_classmap := Time.get_ticks_usec() - t0

	# --- чанки ---
	t0 = Time.get_ticks_usec()
	_clear_chunks()
	_cols = ceili(float(size.x) / chunk_size)
	_rows = ceili(float(size.y) / chunk_size)
	var solid_img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_LA8, solid_full)
	var empty_img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_LA8, empty_full)
	for cy in _rows:
		for cx in _cols:
			var ox := cx * chunk_size
			var oy := cy * chunk_size
			var cw := mini(chunk_size, size.x - ox)
			var chh := mini(chunk_size, size.y - oy)
			var chunk := TerrainChunk.new()
			chunk.name = "Chunk_%d_%d" % [cx, cy]
			chunk.setup(cw, chh, Vector2i(ox, oy))
			add_child(chunk)
			# нарезка через blit_rect — целиком на стороне C++
			var sub_v := Image.create_empty(cw, chh, false, Image.FORMAT_RGBA8)
			sub_v.blit_rect(src, Rect2i(ox, oy, cw, chh), Vector2i.ZERO)
			chunk.vis_bytes = sub_v.get_data()
			var sub_s := Image.create_empty(cw, chh, false, Image.FORMAT_LA8)
			sub_s.blit_rect(solid_img, Rect2i(ox, oy, cw, chh), Vector2i.ZERO)
			chunk.solid_bytes = sub_s.get_data()
			var sub_e := Image.create_empty(cw, chh, false, Image.FORMAT_LA8)
			sub_e.blit_rect(empty_img, Rect2i(ox, oy, cw, chh), Vector2i.ZERO)
			chunk.empty_bytes = sub_e.get_data()
			_chunks.append(chunk)
			chunk.refresh_texture()
			_rebuild_collision(chunk)
	var t_chunks := Time.get_ticks_usec() - t0

	return {
		"total_usec": Time.get_ticks_usec() - t_total,
		"classmap_usec": t_classmap,
		"chunks_usec": t_chunks,
		"chunks": _chunks.size(),
		"grid": "%dx%d" % [_cols, _rows],
	}


func _clear_chunks() -> void:
	for c in _chunks:
		remove_child(c)
		c.free()
	_chunks.clear()
	_dirty.clear()


# ---------------------------------------------------------------- запросы

func class_at(p: Vector2i) -> int:
	if p.x < 0 or p.y < 0 or p.x >= size.x or p.y >= size.y:
		return TerrainPalette.Cls.EMPTY
	return _class[p.y * size.x + p.x]


func is_solid_at(p: Vector2i) -> bool:
	return TerrainPalette.SOLID[class_at(p)] != 0


# ---------------------------------------------------------------- разрушение

## Выбивает круг. Возвращает число реально изменённых пикселей.
## Радиус масштабируется по классу материала (SOFT рвётся шире, INDESTRUCTIBLE не рвётся).
func carve_circle(center: Vector2i, radius: int) -> int:
	var carvable := TerrainPalette.CARVABLE
	var carve_scale := TerrainPalette.CARVE_SCALE
	# максимальный радиус с учётом самого «мягкого» материала
	var r_max := int(ceil(radius * 1.6))
	var x0 := maxi(center.x - r_max, 0)
	var x1 := mini(center.x + r_max, size.x - 1)
	var y0 := maxi(center.y - r_max, 0)
	var y1 := mini(center.y + r_max, size.y - 1)
	if x1 < x0 or y1 < y0:
		return 0

	var changed := 0
	var cx0 := x0 / chunk_size
	var cx1 := x1 / chunk_size
	var cy0 := y0 / chunk_size
	var cy1 := y1 / chunk_size

	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var ci := cy * _cols + cx
			var chunk: TerrainChunk = _chunks[ci]
			var ox := cx * chunk_size
			var oy := cy * chunk_size
			var lx0 := maxi(x0 - ox, 0)
			var lx1 := mini(x1 - ox, chunk.cw - 1)
			var ly0 := maxi(y0 - oy, 0)
			var ly1 := mini(y1 - oy, chunk.ch - 1)
			if lx1 < lx0 or ly1 < ly0:
				continue

			# Локальные копии: индексная запись в chunk.vis_bytes[...] напрямую
			# заставляла бы GDScript копировать массив на каждый пиксель (COW).
			# Здесь копия происходит один раз на чанк.
			var vb := chunk.vis_bytes
			var sb := chunk.solid_bytes
			var eb := chunk.empty_bytes
			var touched := false

			for ly in range(ly0, ly1 + 1):
				var gy := oy + ly
				var dy := gy - center.y
				var dy2 := dy * dy
				var grow := gy * size.x
				var crow := ly * chunk.cw
				for lx in range(lx0, lx1 + 1):
					var gx := ox + lx
					var dx := gx - center.x
					var d2 := dx * dx + dy2
					var gi := grow + gx
					var c := _class[gi]
					if carvable[c] == 0:
						continue
					var rr := radius * carve_scale[c]
					if d2 > rr * rr:
						continue
					_class[gi] = TerrainPalette.Cls.EMPTY
					var li := crow + lx
					vb[li * 4 + 3] = 0
					sb[li * 2 + 1] = 0
					eb[li * 2] = 255
					eb[li * 2 + 1] = 255
					touched = true
					changed += 1

			if touched:
				chunk.vis_bytes = vb
				chunk.solid_bytes = sb
				chunk.empty_bytes = eb
				_dirty[ci] = true

	if changed > 0:
		carved.emit(Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1))
		# immediate_rebuild пересобирает коллизию сразу — но менять форму StaticBody
		# НЕЛЬЗЯ во время флаша физических запросов (внутри _integrate_forces,
		# body_entered, area-колбэков): Godot роняет "Can't change state while
		# flushing queries". Если carve пришёл из такого колбэка (крэш корабля,
		# взрыв снаряда), откладываем пересборку на _process даже в immediate-режиме.
		# Обычные вызовы (бенч, загрузка, спавн) идут вне физ-кадра —
		# Engine.is_in_physics_frame() там false — и пересобираются сразу, как раньше.
		# Инвариант: форма коллизии рельефа никогда не меняется внутри флаша запросов.
		if immediate_rebuild and not Engine.is_in_physics_frame():
			flush_dirty()
	return changed


## Пересобирает все грязные чанки немедленно. Возвращает их число.
func flush_dirty() -> int:
	var n := _dirty.size()
	for ci in _dirty:
		_rebuild_chunk(_chunks[ci])
	_dirty.clear()
	return n


func _process(_delta: float) -> void:
	# В immediate-режиме _dirty обычно пуст (carve пересобрал сразу), сюда не доходим.
	# Но если carve случился внутри физ-колбэка, пересборка отложена сюда даже в
	# immediate-режиме (см. carve_circle) — доедаем здесь, вне флаша запросов.
	if _dirty.is_empty():
		return
	var budget := max_chunk_rebuilds_per_frame
	var done: Array = []
	for ci in _dirty:
		if budget <= 0:
			break
		_rebuild_chunk(_chunks[ci])
		done.append(ci)
		budget -= 1
	for ci in done:
		_dirty.erase(ci)


func _rebuild_chunk(chunk: TerrainChunk) -> void:
	var t0 := Time.get_ticks_usec()
	chunk.refresh_texture()
	stat_texture_usec += Time.get_ticks_usec() - t0
	_rebuild_collision(chunk)
	stat_rebuilds += 1


## Собирает коллизию чанка из ДВУХ трассировок:
##   - маска твёрдого  -> внешние контуры массивов породы;
##   - маска пустого   -> внешние контуры пустот, то есть как раз контуры дырок,
##                        которые первая трассировка теряет.
## Вместе они дают полный набор границ «камень/пустота». Оба набора вешаются как
## CollisionPolygon2D в режиме BUILD_SEGMENTS (см. TerrainChunk.apply_polygons).
func _rebuild_collision(chunk: TerrainChunk) -> void:
	var t0 := Time.get_ticks_usec()
	var solid_img := chunk.build_solid_image(collision_downscale)
	var empty_img := chunk.build_empty_image(collision_downscale)
	stat_solid_image_usec += Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var bm_solid := BitMap.new()
	bm_solid.create_from_image_alpha(solid_img, 0.5)
	var bm_empty := BitMap.new()
	bm_empty.create_from_image_alpha(empty_img, 0.5)
	stat_bitmap_usec += Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var isize := solid_img.get_size()
	var rect := Rect2i(Vector2i.ZERO, isize)
	var solid_contours := bm_solid.opaque_to_polygons(rect, polygon_epsilon)
	var empty_contours := bm_empty.opaque_to_polygons(rect, polygon_epsilon)
	stat_polygons_usec += Time.get_ticks_usec() - t0

	# Контур ОБЯЗАН замкнуться по краю трассируемого прямоугольника. Для маски
	# пустоты такое ребро — фантомная стена поперёк открытого воздуха на границе
	# чанков (проверено в tools/diag_polygons.gd, часть C). Отбрасываем их.
	#
	# У маски твёрдого такие рёбра, наоборот, оставляем: если камень доходит до
	# края чанка, а у соседа там пустота, то настоящая поверхность и есть эта
	# граница. Обратный случай (пустота по обе стороны) даёт у твёрдой маски
	# отсутствие ребра, а у пустой — отброшенное ребро, то есть стены не будет,
	# как и требуется.
	t0 = Time.get_ticks_usec()
	var segs := PackedVector2Array()
	var f := float(collision_downscale)
	chunk.last_rejected = 0
	_append_segments(segs, solid_contours, f, false, isize)
	_append_segments(segs, empty_contours, f, true, isize)
	chunk.apply_segments(segs)
	stat_apply_usec += Time.get_ticks_usec() - t0
	stat_rejected_polys += chunk.last_rejected


func _append_segments(out: PackedVector2Array, contours: Array, factor: float,
		drop_border: bool, isize: Vector2i) -> void:
	var w := float(isize.x)
	var h := float(isize.y)
	for c in contours:
		var poly: PackedVector2Array = c
		var n := poly.size()
		if n < 2:
			continue
		for i in n:
			var a := poly[i]
			var b := poly[(i + 1) % n]
			if drop_border and _on_rect_border(a, b, w, h):
				continue
			out.append(a * factor)
			out.append(b * factor)


static func _on_rect_border(a: Vector2, b: Vector2, w: float, h: float) -> bool:
	if is_equal_approx(a.x, b.x) and (is_zero_approx(a.x) or is_equal_approx(a.x, w)):
		return true
	if is_equal_approx(a.y, b.y) and (is_zero_approx(a.y) or is_equal_approx(a.y, h)):
		return true
	return false


# ---------------------------------------------------------------- спавн

## Ищет случайную точку, где после расчистки радиуса radius вокруг нет ни
## одного твёрдого пикселя, и расчищает её. Не полагается на фиксированную
## точку + carve_circle — carve_circle физически не может сдвинуть класс,
## у которого CARVABLE=0 (Камень и т.п., см. terrain_palette.gd): если такой
## класс окажется ровно в точке спавна, "расчистка" там молча ничего не
## сделает, и появление будет каждый раз замуровано в текстуре. Вместо этого
## перебираем случайные точки и берём первую, где несдвигаемого твёрдого нет
## вообще — тогда carve_circle гарантированно домоет всё остальное (обычную
## разрушаемую породу).
## margin — отступ от края уровня, px. attempts — сколько точек перебрать,
## прежде чем сдаться. Возвращает найденную точку (уже расчищенную) или
## Vector2i(-1, -1), если за attempts попыток ничего не нашлось.
func find_clear_spawn(radius: int, margin: int = 0, attempts: int = 30) -> Vector2i:
	var x0 := margin + radius
	var x1 := maxi(size.x - margin - radius - 1, x0)
	var y0 := margin + radius
	var y1 := maxi(size.y - margin - radius - 1, y0)
	for _i in attempts:
		var p := Vector2i(randi_range(x0, x1), randi_range(y0, y1))
		if not _has_unmovable_solid(p, radius):
			carve_circle(p, radius)
			flush_dirty()
			return p
	return Vector2i(-1, -1)


## Есть ли в радиусе center твёрдый пиксель, который carve_circle не может
## убрать (SOLID=1, но CARVABLE=0 — Камень и подобное). Обычная разрушаемая
## порода (SOLID=1, CARVABLE=1) не считается — её carve_circle расчистит сам.
func _has_unmovable_solid(center: Vector2i, radius: int) -> bool:
	var solid := TerrainPalette.SOLID
	var carvable := TerrainPalette.CARVABLE
	var r2 := radius * radius
	var y0 := maxi(center.y - radius, 0)
	var y1 := mini(center.y + radius, size.y - 1)
	var x0 := maxi(center.x - radius, 0)
	var x1 := mini(center.x + radius, size.x - 1)
	for y in range(y0, y1 + 1):
		var dy := y - center.y
		var dy2 := dy * dy
		var row := y * size.x
		for x in range(x0, x1 + 1):
			var dx := x - center.x
			if dx * dx + dy2 > r2:
				continue
			var c := _class[row + x]
			if solid[c] != 0 and carvable[c] == 0:
				return true
	return false


# ---------------------------------------------------------------- отладка

func total_segments() -> int:
	var n := 0
	for c in _chunks:
		n += c.segment_count()
	return n


func get_chunks() -> Array[TerrainChunk]:
	return _chunks


## Сколько чанков ждёт пересборки.
func dirty_count() -> int:
	return _dirty.size()


func count_solid() -> int:
	var solid := TerrainPalette.SOLID
	var n := 0
	for i in _class.size():
		if solid[_class[i]] != 0:
			n += 1
	return n
