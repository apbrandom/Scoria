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

## preload по пути, а не голый идентификатор TerrainDebris: класс новый, и до
## первого пересканирования проекта редактором (который ведёт
## .godot/global_script_class_cache.cfg) голый class_name из другого скрипта
## иногда не резолвится headless-запуском ("Identifier not declared"), хотя сам
## файл валиден. preload по пути не зависит от этого кэша вообще.
const TerrainDebrisScript := preload("res://scenes/fx/terrain_debris.gd")
const TerrainDustScript := preload("res://scenes/fx/terrain_dust.gd")

## Пока без подписчиков в коде — заранее заведённый семантический шов для
## будущей сетевой репликации carve по reliable_ordered @rpc (roadmap.md:
## «Carve рельефа по @rpc + локальный детерминированный replay»): у хоста
## этот сигнал станет источником события "что разослать", а не поводом для
## нового способа узнавать о разрушении.
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

@export_group("Форма воронки")
## 0 — идеальный круг. Больше — радиус воронки гуляет по углу (органический,
## "осыпавшийся" край вместо циркуля). Заказчик одобрил трогать форму воронки
## явно (notes/terrain_research.md, ночь 2026-07-22 -> 2026-07-23) — раньше это
## было решение только заказчика, теперь применяем напрямую.
@export_range(0.0, 0.5, 0.01) var edge_noise_amplitude: float = 0.18
## "Частота" шума по кругу — сколько примерно лепестков/бугров укладывается
## на полную окружность. Меньше 1 — почти незаметно, больше 6-8 — мелкая рябь
## вместо крупных неровностей. Подобрано на глаз через
## tools/terrain_playground.gd --autocarve --shots=.
@export_range(0.5, 8.0, 0.1) var edge_noise_frequency: float = 3.0

## Физический слой декоративных обломков (см. scenes/fx/terrain_debris.gd) —
## отдельный от геймплейного слоя по умолчанию (корабль/снаряды/рельеф сидят на
## слое 1, project.godot [layer_names]). У обломков collision_mask=0 (ни с чем
## не сталкиваются), так что сам факт "своего слоя" тут скорее документация
## (одно однозначное число вместо магической "2" в нескольких местах), чем
## необходимость — но задел на будущее, если что-то захочет выбирать обломки
## через физический слой (например, VFX-запрос), уже есть.
const DEBRIS_LAYER := 2

@export_group("Обломки")
## Сколько обломков одновременно держим на сцене СРАЗУ ПО ВСЕМ триггерам
## (оружие + столкновения корабля) — жёсткий кап, при превышении старейший
## обломок удаляется (FIFO), см. _spawn_debris(). При хотсите 8 игроков,
## стреляющих одновременно, это единственное, что не даёт узлам копиться
## бесконтрольно и проседать FPS (замеры — tools/bench_debris.gd, notes/devlog.md §18).
@export_range(8, 256, 4) var max_debris: int = 64

@export_subgroup("Оружие")
## Сколько обломков на одно попадание, которое РЕАЛЬНО что-то выбило из рельефа
## (см. spawn_weapon_debris — попадание в Камень не даёт обломков вовсе).
@export_range(0, 20, 1) var weapon_debris_min: int = 3
@export_range(0, 20, 1) var weapon_debris_max: int = 8
## Скорость разлёта — намеренно скромная (не 60-180, как в первом заходе):
## воронка от пулемёта после правки terrain_power (2026-07-21, см.
## notes/devlog.md §19) — всего несколько px, обломки на скорости 60-180 px/с
## успевали улететь на 100+ px за время жизни — визуально выглядело как
## "обломки в случайном месте", не связанные с местом попадания. Ниже — чтобы
## обломки читались как "отсюда", а не разлетались по пол-экрана.
@export_range(0.0, 500.0, 5.0, "suffix:px/с") var weapon_debris_speed_min: float = 15.0
@export_range(0.0, 500.0, 5.0, "suffix:px/с") var weapon_debris_speed_max: float = 45.0

@export_subgroup("Столкновение корабля")
## Заметно меньше оружия — это пыль от удара корпусом, не разлёт от взрыва:
## энергия удара в основном уходит в урон кораблю (crash_damage), не в разлёт
## породы. Срабатывает при ЛЮБОМ засчитанном столкновении (в отличие от оружия) —
## удар о неразрушаемый Камень тоже поднимает пыль, просто камень не крошится.
@export_range(0, 20, 1) var crash_debris_min: int = 1
@export_range(0, 20, 1) var crash_debris_max: int = 3
@export_range(0.0, 500.0, 5.0, "suffix:px/с") var crash_debris_speed_min: float = 20.0
@export_range(0.0, 500.0, 5.0, "suffix:px/с") var crash_debris_speed_max: float = 70.0

@export_subgroup("Общее")
@export_range(0.1, 5.0, 0.1, "suffix:с") var debris_lifetime_min: float = 0.8
@export_range(0.1, 5.0, 0.1, "suffix:с") var debris_lifetime_max: float = 1.6

var size: Vector2i
var chunk_count: int:
	get: return _chunks.size()

var _class: PackedByteArray
var _chunks: Array[TerrainChunk] = []
var _cols := 0
var _rows := 0
var _dirty: Dictionary = {}
## Живые обломки, в порядке спавна (голова = старейший) — см. _spawn_debris().
var _debris: Array[Node2D] = []
## Заявки на спавн обломков, ещё не создавшие узел — см. _spawn_debris() и
## _drain_pending_debris() (дренаж в _process(), тот же приём, что и у _dirty).
## Array, а не Array[Dictionary]: типизация здесь не окупается ради строкового
## доступа по ключу ниже.
var _pending_debris: Array = []
## Заявки на разовый пшик пыли (см. scenes/fx/terrain_dust.gd) — та же причина
## отложенности до _process, что и у _pending_debris (add_child внутри флаша
## физ-запросов запрещён движком). Array мест: {"at": Vector2, "color": Color}.
var _pending_dust: Array = []

## Шум формы воронки — фиксированный seed (не Godot-рандом): угол одинаково
## "рвёт" край каждый раз для одного и того же center, иначе будущий сетевой
## replay carve (roadmap.md: "детерминированный replay") разошёлся бы между
## хостом и клиентом. Ленивая инициализация — сцены без единого carve (главное
## меню, чистые юнит-тесты) не платят за FastNoiseLite впустую.
var _edge_noise: FastNoiseLite = null

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

## Ленивая инициализация детерминированного шума края воронки (см. _edge_noise).
## seed фиксирован константой, а не Godot-рандомом — тот же center должен давать
## тот же неровный край каждый раз (важно для будущего сетевого replay carve).
func _get_edge_noise() -> FastNoiseLite:
	if _edge_noise == null:
		_edge_noise = FastNoiseLite.new()
		_edge_noise.seed = 20260722
		_edge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	return _edge_noise


## EDGE_SAMPLES — таблица множителей радиуса по углу, строится один раз на
## carve_circle (не на пиксель — get_noise_2d дороже одного индексирования
## массива, а пикселей в воронке до ~30k). 64 — достаточно гладко для амплитуды
## и частоты в разумных пределах (@export выше), крупнее не давало заметной
## разницы на глаз через --autocarve --shots=.
const EDGE_SAMPLES := 64


## Таблица edge_mult[i] = множитель радиуса на угле TAU*i/EDGE_SAMPLES.
## Шум сэмплится вдоль окружности в noise-пространстве (cos/sin * frequency) —
## стандартный приём для гладкого "оборачивающегося" 1D-сигнала по кругу без
## разрыва на стыке 0/TAU. center подмешан (сильно уменьшенный), чтобы разные
## воронки на уровне не были одним и тем же узором, повёрнутым/сдвинутым.
func _build_edge_mult_table(center: Vector2i) -> PackedFloat32Array:
	var table := PackedFloat32Array()
	table.resize(EDGE_SAMPLES)
	if edge_noise_amplitude <= 0.0:
		table.fill(1.0)
		return table
	var noise := _get_edge_noise()
	var cox := center.x * 0.013
	var coy := center.y * 0.013
	for i in EDGE_SAMPLES:
		var a := TAU * i / EDGE_SAMPLES
		var nx := cos(a) * edge_noise_frequency + cox
		var ny := sin(a) * edge_noise_frequency + coy
		var n := noise.get_noise_2d(nx, ny)  # -1..1
		table[i] = 1.0 + n * edge_noise_amplitude
	return table


## Выбивает круг (с органическим шумным краем, см. edge_noise_*). Возвращает
## число реально изменённых пикселей. Радиус масштабируется по классу материала
## (SOFT рвётся шире, INDESTRUCTIBLE не рвётся) и по углу (см. _build_edge_mult_table).
func carve_circle(center: Vector2i, radius: int) -> int:
	var carvable := TerrainPalette.CARVABLE
	var carve_scale := TerrainPalette.CARVE_SCALE
	# максимальный радиус с учётом самого «мягкого» материала — считаем от
	# ЖИВОГО максимума CARVE_SCALE (PackedFloat32Array не даёт .max() в 4.7,
	# отсюда ручной цикл), а не от захардкоженного 1.6: тот был буквальным
	# слепком текущего SOFT (resources/terrain_palette.gd) и молча перестал
	# бы совпадать, подними кто-то в будущем множитель материала выше —
	# carve тогда обрезал бы бокс сканирования и терял пиксели без ошибки.
	var max_scale := 0.0
	for s in carve_scale:
		max_scale = maxf(max_scale, s)
	# +edge_noise_amplitude — на самых "выпуклых" углах реальный радиус может
	# превысить номинал max_scale, иначе бокс сканирования обрежет пиксели,
	# которые шум должен был вырезать, без ошибки (тот же класс бага, что и
	# комментарий про max_scale чуть выше).
	var r_max := int(ceil(radius * max_scale * (1.0 + edge_noise_amplitude)))
	var x0 := maxi(center.x - r_max, 0)
	var x1 := mini(center.x + r_max, size.x - 1)
	var y0 := maxi(center.y - r_max, 0)
	var y1 := mini(center.y + r_max, size.y - 1)
	if x1 < x0 or y1 < y0:
		return 0

	var edge_mult := _build_edge_mult_table(center)

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
					# Угол через atan2(dy,dx) — тот же атан, что и везде в проекте
					# (Ship.aim_angle и т.п.), не отдельное соглашение по знакам.
					var angle := atan2(dy, dx)
					var idx := int(fposmod(angle, TAU) / TAU * EDGE_SAMPLES) % EDGE_SAMPLES
					var rr := radius * carve_scale[c] * edge_mult[idx]
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


# ---------------------------------------------------------------- обломки

## Обломки от попадания оружия — вызывать ТОЛЬКО если carve_circle реально
## что-то выбил (changed > 0, см. Explosion._carve_terrain): попадание в
## неразрушаемый Камень (CARVABLE=0) не крошит рельеф, значит и "оторвавшихся
## кусков породы" быть не должно — сам метод этого не проверяет, ответственность
## вызывающего (он и так уже знает changed, второй раз считать не нужно).
## at — мировые координаты (не локальные Terrain). cls — класс материала в точке
## попадания, только для цвета обломков.
func spawn_weapon_debris(at: Vector2, cls: int) -> void:
	_spawn_debris(at, randi_range(weapon_debris_min, weapon_debris_max),
		weapon_debris_speed_min, weapon_debris_speed_max, cls)
	_spawn_dust(at, cls)


## Обломки/пыль от столкновения корабля с рельефом — заметно меньше оружейных
## (см. @export-группу "Столкновение корабля" выше) и, в отличие от оружия,
## срабатывают при ЛЮБОМ засчитанном столкновении независимо от того, выбило ли
## carve хоть пиксель: удар корпусом о Камень тоже поднимает пыль, просто камень
## при этом не крошится (см. Ship._integrate_forces).
func spawn_crash_debris(at: Vector2, cls: int) -> void:
	_spawn_debris(at, randi_range(crash_debris_min, crash_debris_max),
		crash_debris_speed_min, crash_debris_speed_max, cls)
	_spawn_dust(at, cls)


## Оба вызывающих (Explosion — из body_entered снаряда, Ship — из
## _integrate_forces при столкновении) в реальной игре срабатывают ИЗНУТРИ
## физ-колбэка. add_child() нового RigidBody2D там запрещён тем же правилом,
## что и пересборка коллизии рельефа (см. carve_circle выше): "Can't change
## state while flushing queries" — проверено на реальном пути через diag_combat
## и на крэше корабля. Решение — ТА ЖЕ схема, что уже отработана для _dirty
## чанков в этом файле (append в очередь здесь, реальная работа — в _process,
## заведомо вне флаша запросов): просто добавляем заявку в очередь, тяжёлая
## часть (instantiate/add_child/impulse) — в _drain_pending_debris() ниже.
## call_deferred() сюда НЕ пошёл сознательно: на пачке заявок подряд (взрыв —
## это 3-8 штук разом) его фактический момент исполнения оказался
## непредсказуем на практике (проверено — иногда откладывался до выгрузки
## сцены), тогда как _process() уже доказанно детерминирован в этом кодовой
## базе (та же логика годами держит _dirty).
func _spawn_debris(at: Vector2, count: int, speed_min: float, speed_max: float, cls: int) -> void:
	if count <= 0:
		return
	var color := palette.get_mask_color(cls) if palette != null else Color(0.5, 0.3, 0.1)
	for _i in count:
		_pending_debris.append({
			"at": at,
			"speed": randf_range(speed_min, speed_max),
			"lifetime": randf_range(debris_lifetime_min, debris_lifetime_max),
			"color": color,
		})


## Ставит в очередь одноразовый пшик пыли (см. scenes/fx/terrain_dust.gd) —
## та же схема отложенного спавна, что и у _spawn_debris (add_child внутри
## флаша физ-запросов запрещён). cls — только для цвета (palette.get_mask_color).
func _spawn_dust(at: Vector2, cls: int) -> void:
	var color := palette.get_mask_color(cls) if palette != null else Color(0.5, 0.3, 0.1)
	_pending_dust.append({"at": at, "color": color})


func _drain_pending_dust() -> void:
	if _pending_dust.is_empty():
		return
	for req in _pending_dust:
		var d := TerrainDustScript.new()
		get_parent().add_child(d)
		d.global_position = req["at"]
		d.setup(req["color"])
	_pending_dust.clear()


func _drain_pending_debris() -> void:
	if _pending_debris.is_empty():
		return
	for req in _pending_debris:
		_evict_oldest_if_full()
		var d := TerrainDebrisScript.new()
		d.setup(req["color"], req["lifetime"])
		d.tree_exiting.connect(_on_debris_freed.bind(d))
		get_parent().add_child(d)
		d.global_position = req["at"]
		var dir := Vector2.RIGHT.rotated(randf() * TAU)
		d.apply_central_impulse(dir * req["speed"])
		_debris.append(d)
	_pending_debris.clear()


## Жёсткий кап вместо пула объектов: на этих масштабах (десятки обломков разом,
## не тысячи) разница в стоимости instantiate/free пренебрежима (замеры —
## tools/bench_debris.gd), а пул RigidBody2D пришлось бы аккуратно сбрасывать
## (позиция/скорость/вращение/альфа/таймер) при переиспользовании — лишняя
## сложность без измеримой выгоды на этом масштабе.
func _evict_oldest_if_full() -> void:
	while _debris.size() >= max_debris:
		var oldest: Node2D = _debris.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


## erase() безопасен даже если узел уже убран (например, _evict_oldest_if_full
## только что сделал pop_front для этого же узла) — Array.erase() на
## отсутствующем элементе просто ничего не делает, без ошибки.
func _on_debris_freed(d: Node2D) -> void:
	_debris.erase(d)


func _process(_delta: float) -> void:
	_drain_pending_debris()
	_drain_pending_dust()

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
