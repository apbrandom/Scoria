## Живая клеточная физика рельефа в геймплее: мост между SandSim (кто и куда
## сыпется) и Terrain (что видно и обо что бьётся корабль).
##
## Это недостающая половина Милстоуна 4 (roadmap.md): SandLevelGen уже осаживал
## симуляцию ОДИН РАЗ при генерации и выбрасывал её, а рельеф дальше жил как
## статичный битмап. Здесь та же самая осевшая симуляция не выбрасывается, а
## продолжает тикать в кадре — земля и песок реально осыпаются после взрыва.
##
## ── Кто кому источник истины ────────────────────────────────────────────────
## Сознательное решение (2026-07-28): Terrain НЕ удаляется и НЕ переписывается.
## SandSim становится источником истины для ДВИЖЕНИЯ материала, Terrain остаётся
## рендером и мостом коллизии. Причины:
##  · обратимо — рубильник LiveSandSettings.enabled возвращает прежнее поведение;
##  · весь остальной код (carve от оружия, урон по классам, спавн, обломки,
##    сетевой replay carve) продолжает работать без единой правки;
##  · roadmap.md прямо запрещает сносить Terrain без решения заказчика.
##
## ── Два разрешения, и почему это нормально ──────────────────────────────────
## Рельеф попиксельный, симуляция — по клеткам cell_px×cell_px (сейчас 6). Это
## НЕ баг, а осознанный компромисс: попиксельная симуляция на уровне 2700×1350
## это 3.6 млн клеток, что в GDScript неподъёмно (замер полного скана уже на
## 101 тыс. клеток — 72 мс на кадр, tools/bench_live_sand.tscn).
## Следствия, которые надо держать в голове:
##  · carve мельче клетки (пулемёт) НЕ обрушает склон — см.
##    LiveSandSettings.carve_clear_threshold, это правильно, а не потеря;
##  · когда клетка сдвинулась, её блок пикселей перерисовывается ЦЕЛИКОМ, то
##    есть осыпь квантуется по сетке клеток. Мелкий рваный край от предыдущих
##    попаданий в этом месте затирается — цена того, что осыпь вообще есть.
##
## ── Цена (замерено, tools/bench_live_sand.tscn, M1 Max) ─────────────────────
## Осевший уровень: 0.000 мс/тик, 0 активных тиков из 300 — "покой = ноль
## работы" держится, простой уровень не стоит ничего. Воронка от пулемёта: пик
## 0.077 мс, оседает за 5 тиков. Воронка от бомбы: пик 0.198 мс, за 12 тиков.
## Потолок (полный скан всего поля) — 72 мс, в кадр не влезает, поэтому важно,
## что до него доходит только патологический случай (см. warn_dirty_cells).
extends Node

const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const DEFAULT_SETTINGS := preload("res://data/sand/live_sand.tres")

var terrain: Terrain = null
## SandSim — тип намеренно не указан (та же причина, что в sand_level_gen.gd:
## голый class_name не всегда резолвится headless до пересборки кэша).
var sim = null
var settings = DEFAULT_SETTINGS

var _grid: Vector2i
var _cell_px := 6
## Детальный шум цвета на весь уровень — тот же массив и тот же seed, что при
## запекании (SandLevelGen.detail_noise_bytes), иначе перекрашенная клетка
## отличалась бы зерном от соседней нетронутой.
var _detail: PackedByteArray
## Снимок предыдущего состояния клеток: сравнивая с ним, перекрашиваем ТОЛЬКО
## реально изменившиеся клетки, а не весь грязный прямоугольник. Разница
## принципиальна в худшем случае: прямоугольник может растянуться на весь
## уровень (он один на всю симуляцию), а изменившихся клеток при этом — десятки.
var _prev: PackedByteArray
## Переиспользуемый буфер цветов одного блока (cell_px*cell_px*4) — чтобы не
## аллоцировать PackedByteArray на каждую перекрашенную клетку.
var _block_rgba: PackedByteArray

# --- телеметрия для HUD/тестов ---
var stat_ticks := 0
var stat_cells_repainted := 0
var stat_worst_area := 0
var stat_last_tick_usec := 0


## sim/grid/seed_used приходят из SandLevelGen.generate() — тот самый осевший
## объект, который раньше выбрасывался после запекания картинок.
func setup(p_terrain: Terrain, p_sim, p_grid: Vector2i, p_cell_px: int,
		p_detail_seed: int, p_settings = null) -> void:
	terrain = p_terrain
	sim = p_sim
	_grid = p_grid
	_cell_px = p_cell_px
	if p_settings != null:
		settings = p_settings

	# +7 — та же соль, что в SandLevelGen._bake_images: иначе зерно не совпадёт.
	_detail = SAND_LEVEL_GEN.detail_noise_bytes(p_detail_seed + 7, terrain.size)

	_prev = PackedByteArray()
	_prev.resize(_grid.x * _grid.y)
	for y in _grid.y:
		var row := y * _grid.x
		for x in _grid.x:
			_prev[row + x] = sim.get_cell(x, y)

	_block_rgba = PackedByteArray()
	_block_rgba.resize(_cell_px * _cell_px * 4)

	# Разрушение рельефа оружием/кораблём приходит сюда событием: сам carve
	# правит только пиксели Terrain, а симуляция обязана узнать, что опоры не
	# стало, иначе земля продолжит висеть в воздухе над воронкой.
	terrain.carved.connect(_on_terrain_carved)


func _physics_process(_delta: float) -> void:
	if not settings.enabled or sim == null:
		return
	var t0 := Time.get_ticks_usec()
	var ticks: int = settings.ticks_per_frame
	for _i in ticks:
		if not sim.is_active():
			break  # "покой = ноль работы": осевший уровень не стоит ничего
		var area := _tick_once()
		stat_worst_area = maxi(stat_worst_area, area)
	stat_last_tick_usec = Time.get_ticks_usec() - t0


## Один тик симуляции + перенос изменившихся клеток в рельеф.
## Возвращает площадь грязного прямоугольника (для телеметрии).
func _tick_once() -> int:
	sim.step()
	stat_ticks += 1
	if not sim.is_active():
		return 0
	# После step() грязный прямоугольник описывает ИМЕННО этот тик: step()
	# сбрасывает область в начале и заново помечает её на каждом перемещении
	# (SandSim._mark_dirty вызывается и для источника, и для приёмника хода),
	# поэтому всё, что изменилось, лежит внутри — брать область до тика и
	# расширять её вручную не нужно.
	var r: Rect2i = sim.get_dirty_rect()
	_sync_rect(r)
	return r.size.x * r.size.y


## Переносит в Terrain те клетки прямоугольника, что реально изменились.
func _sync_rect(r: Rect2i) -> void:
	var x0 := maxi(r.position.x, 0)
	var y0 := maxi(r.position.y, 0)
	var x1 := mini(r.position.x + r.size.x, _grid.x)
	var y1 := mini(r.position.y + r.size.y, _grid.y)
	for y in range(y0, y1):
		var row := y * _grid.x
		for x in range(x0, x1):
			var now: int = sim.get_cell(x, y)
			if _prev[row + x] == now:
				continue
			_prev[row + x] = now
			_paint_cell(x, y, now)
			stat_cells_repainted += 1


## Перекрашивает один блок пикселей рельефа под новый материал клетки.
func _paint_cell(gx: int, gy: int, sand_id: int) -> void:
	var cls: int = SAND_LEVEL_GEN.cls_of(sand_id)
	var px0 := gx * _cell_px
	var py0 := gy * _cell_px
	var w := terrain.size.x
	var buf := _block_rgba
	for oy in _cell_px:
		var py := py0 + oy
		if py >= terrain.size.y:
			break
		var drow := py * w
		var brow := oy * _cell_px
		for ox in _cell_px:
			var px := px0 + ox
			if px >= w:
				break
			var c := SAND_LEVEL_GEN.color_of(cls, _detail[drow + px])
			var o := (brow + ox) * 4
			buf[o] = int(c.r8)
			buf[o + 1] = int(c.g8)
			buf[o + 2] = int(c.b8)
			buf[o + 3] = int(c.a8)
	_block_rgba = buf
	terrain.write_block(Rect2i(px0, py0, _cell_px, _cell_px), cls, buf)


## Разрушение пришло от оружия/столкновения: перенести дыру ИЗ рельефа В
## симуляцию, чтобы материал над воронкой потерял опору и поехал вниз.
##
## Направление именно такое (рельеф -> симуляция), а не наоборот, потому что
## carve уже посчитал всё, что умеет только он: шумный край воронки, разный
## радиус по классу материала, неразрушаемый камень. Пересказывать эту логику
## второй раз в клеточных координатах значило бы завести второй источник истины,
## который неизбежно разъедется с первым.
func _on_terrain_carved(_center: Vector2i, _radius: int, area: Rect2i) -> void:
	if not settings.enabled or sim == null:
		return
	var gx0 := maxi(area.position.x / _cell_px, 0)
	var gy0 := maxi(area.position.y / _cell_px, 0)
	var gx1 := mini((area.position.x + area.size.x) / _cell_px + 1, _grid.x)
	var gy1 := mini((area.position.y + area.size.y) / _cell_px + 1, _grid.y)
	var threshold: float = settings.carve_clear_threshold
	for gy in range(gy0, gy1):
		var row := gy * _grid.x
		for gx in range(gx0, gx1):
			if sim.get_cell(gx, gy) == 0:
				continue
			if _empty_fraction(gx, gy) < threshold:
				continue
			sim.set_cell(gx, gy, 0)
			# Снимок тоже обновляем: пиксели рельефа уже стёр сам carve, и
			# перекрашивать этот блок ещё раз не нужно — без этой строки
			# _sync_rect на следующем тике счёл бы клетку "изменившейся" и
			# затёр бы шумный край воронки ровным блоком.
			_prev[row + gx] = 0


## Какая доля пикселей клетки уже пуста в рельефе.
func _empty_fraction(gx: int, gy: int) -> float:
	var px0 := gx * _cell_px
	var py0 := gy * _cell_px
	var total := 0
	var empty := 0
	for oy in _cell_px:
		var py := py0 + oy
		if py >= terrain.size.y:
			break
		for ox in _cell_px:
			var px := px0 + ox
			if px >= terrain.size.x:
				break
			total += 1
			if terrain.class_at(Vector2i(px, py)) == TerrainPalette.Cls.EMPTY:
				empty += 1
	return 0.0 if total == 0 else float(empty) / float(total)


## Для HUD/диагностики: активна ли симуляция прямо сейчас и чем занята.
func status_line() -> String:
	if not settings.enabled:
		return "живой рельеф: выключен"
	var r: Rect2i = sim.get_dirty_rect() if sim != null else Rect2i()
	return "живой рельеф: %s · тиков %d · клеток перекрашено %d · область %dx%d%s" % [
		"осыпается" if sim != null and sim.is_active() else "покой",
		stat_ticks, stat_cells_repainted, r.size.x, r.size.y,
		"  ⚠ широкая область" if stat_worst_area > settings.warn_dirty_cells else ""]
