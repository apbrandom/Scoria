## Headless-проверка ЖИВОЙ физики рельефа (scripts/level/live_sand.gd): после
## того как оружие выбило воронку, материал над ней реально едет вниз, и это
## видно не только симуляции, но и рельефу — картинке и коллизии.
##
## Сцена собирается вручную (слои земли/камня заданы явно), а не берётся из
## SandLevelGen: тесту нужен ЗАВЕДОМО нависающий пласт над местом взрыва, а
## процедурный рельеф такого не гарантирует — проверка бы то ловила обвал, то
## нет, в зависимости от seed.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_live_sand.tscn
extends Node

const SAND_SIM := preload("res://scripts/sand/sand_sim.gd")
const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const LIVE_SAND := preload("res://scripts/level/live_sand.gd")
const RULES := preload("res://data/level/default_gen.tres")
const SETTINGS := preload("res://data/sand/live_sand.tres")
const PALETTE := preload("res://data/terrain/wings_classes.tres")
const M_SAND := preload("res://data/sand/sand.tres")
const M_STONE := preload("res://data/sand/stone.tres")
const M_WATER := preload("res://data/sand/water.tres")
const M_EARTH := preload("res://data/sand/earth.tres")

const GRID := Vector2i(40, 30)
## Строки сетки: небо / земля / каменное дно.
const SKY_ROWS := 15
const FLOOR_ROWS := 2
const SEED := 4242

## Сколько физ-кадров ждать оседания. Замер (tools/bench_live_sand.tscn) даёт
## ~12 тиков на воронку от бомбы на полноразмерном уровне; здесь сцена меньше,
## запас взят с большим избытком, чтобы тест не флейкал на медленной машине.
const SETTLE_FRAMES := 180

## Граница между "выщербина от пули" и "обвал пласта" в перекрашенных клетках.
## Измерено на этой сцене: мелкое попадание — 6 клеток, полноценный обвал — 154.
## Порог посередине с большим запасом в обе стороны, чтобы проверка ловила
## именно смену ПОРЯДКА величины, а не дрожала от точного числа.
const LOCAL_SLUMP_LIMIT := 30

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка живой физики рельефа (LiveSand, %s) ===" % DisplayServer.get_name())
	await _run()
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


# ---------------------------------------------------------------- стенд

## Собирает пару "симуляция + рельеф из неё" и мост между ними.
## Возвращает {"sim", "terrain", "live"}.
func _build() -> Dictionary:
	var cell_px: int = RULES.cell_px
	var size := Vector2i(GRID.x * cell_px, GRID.y * cell_px)

	var sim = SAND_SIM.new()
	sim.setup(GRID.x, GRID.y, [M_SAND, M_STONE, M_WATER, M_EARTH])
	for gy in GRID.y:
		for gx in GRID.x:
			if gy >= GRID.y - FLOOR_ROWS:
				sim.set_cell(gx, gy, SAND_LEVEL_GEN.STONE_ID)
			elif gy >= SKY_ROWS:
				sim.set_cell(gx, gy, SAND_LEVEL_GEN.EARTH_ID)

	# Слои выложены сразу в устойчивом виде (сплошные ряды), но set_cell честно
	# пометил область грязной — доводим до покоя, иначе первый же кадр теста
	# считал бы "шевеление" за последствие взрыва.
	var guard := 0
	while sim.is_active() and guard < 500:
		sim.step()
		guard += 1

	var imgs = SAND_LEVEL_GEN.bake_images(sim, GRID.x, GRID.y, size, PALETTE, SEED, RULES)

	var terrain := Terrain.new()
	terrain.palette = PALETTE
	terrain.immediate_rebuild = false
	add_child(terrain)
	terrain.load_level(imgs["visual"], imgs["mask"])

	var live = LIVE_SAND.new()
	live.name = "LiveSand"
	add_child(live)
	live.setup(terrain, sim, GRID, cell_px, SEED, SETTINGS)

	return {"sim": sim, "terrain": terrain, "live": live}


func _teardown(stand: Dictionary) -> void:
	stand["live"].queue_free()
	stand["terrain"].queue_free()


## Первая непустая клетка в колонке — "поверхность".
func _surface_row(sim, gx: int) -> int:
	for gy in GRID.y:
		if sim.get_cell(gx, gy) != 0:
			return gy
	return GRID.y


func _count(sim, id: int) -> int:
	return sim.count_material(id)


func _wait(frames: int) -> void:
	for _i in frames:
		await get_tree().physics_frame


# ---------------------------------------------------------------- проверки

func _run() -> void:
	await _test_idle_costs_nothing()
	await _test_collapse()
	await _test_small_carve_does_not_collapse()
	await _test_determinism()


## Осевший уровень не должен шевелиться сам по себе: ни одного перекрашенного
## пикселя за десятки кадров. Если это сломается, живой режим будет жечь кадр
## впустую на любом уровне, где ничего не происходит.
func _test_idle_costs_nothing() -> void:
	print("\n-- покой ничего не стоит --")
	var stand := _build()
	var live = stand["live"]
	_check("после сборки симуляция в покое", not stand["sim"].is_active())
	await _wait(60)
	_check("за 60 кадров ни одна клетка не перекрашена", live.stat_cells_repainted == 0,
		"перекрашено=%d, тиков=%d" % [live.stat_cells_repainted, live.stat_ticks])
	_teardown(stand)


## Главная проверка: воронка под пластом земли -> пласт съезжает вниз, и это
## видит не только симуляция, но и рельеф (класс пикселя + коллизия).
func _test_collapse() -> void:
	print("\n-- обвал после воронки --")
	var stand := _build()
	var sim = stand["sim"]
	var terrain: Terrain = stand["terrain"]
	var live = stand["live"]
	var cell_px: int = RULES.cell_px

	var col := GRID.x / 2
	var surface_before := _surface_row(sim, col)
	var earth_before := _count(sim, SAND_LEVEL_GEN.EARTH_ID)

	terrain.flush_dirty()
	var segments_before := terrain.total_segments()

	# Бьём в толщу земли ЗАМЕТНО ниже поверхности — так, чтобы над воронкой
	# остался нависающий пласт, которому некуда деться, кроме как вниз.
	var hit_row := SKY_ROWS + 6
	var center := Vector2i(col * cell_px + cell_px / 2, hit_row * cell_px + cell_px / 2)
	var carved := terrain.carve_circle(center, 22)
	_check("carve выбил пиксели рельефа", carved > 0, "пикселей=%d" % carved)
	_check("симуляция проснулась от carve", sim.is_active())

	var earth_after_carve := _count(sim, SAND_LEVEL_GEN.EARTH_ID)
	_check("carve убрал землю и из симуляции", earth_after_carve < earth_before,
		"было=%d стало=%d" % [earth_before, earth_after_carve])

	await _wait(SETTLE_FRAMES)

	_check("после оседания симуляция снова в покое", not sim.is_active(),
		"тиков=%d" % live.stat_ticks)
	_check("мост что-то перекрасил в рельефе", live.stat_cells_repainted > 0,
		"клеток=%d" % live.stat_cells_repainted)

	# Земля не появилась из ниоткуда и не испарилась при падении: carve — это
	# ЕДИНСТВЕННЫЙ источник убыли, дальше масса обязана сохраняться.
	_check("масса земли при осыпании сохранилась",
		_count(sim, SAND_LEVEL_GEN.EARTH_ID) == earth_after_carve,
		"после carve=%d после оседания=%d" % [
			earth_after_carve, _count(sim, SAND_LEVEL_GEN.EARTH_ID)])

	var surface_after := _surface_row(sim, col)
	_check("поверхность над воронкой просела", surface_after > surface_before,
		"было ряд %d, стало %d" % [surface_before, surface_after])

	# Рельеф обязан согласиться с симуляцией: там, где раньше была земля, а
	# теперь по симуляции пусто — в Terrain тоже должно быть пусто.
	var old_px := Vector2i(col * cell_px + cell_px / 2, surface_before * cell_px + cell_px / 2)
	_check("рельеф стал пустым там, откуда земля уехала",
		terrain.class_at(old_px) == TerrainPalette.Cls.EMPTY,
		"класс=%d" % terrain.class_at(old_px))
	var new_px := Vector2i(col * cell_px + cell_px / 2, surface_after * cell_px + cell_px / 2)
	_check("рельеф стал землёй там, куда она приехала",
		terrain.class_at(new_px) == TerrainPalette.Cls.NORMAL,
		"класс=%d" % terrain.class_at(new_px))

	terrain.flush_dirty()
	_check("коллизия пересобрана (число отрезков изменилось)",
		terrain.total_segments() != segments_before,
		"было=%d стало=%d" % [segments_before, terrain.total_segments()])

	_teardown(stand)


## Мелкое попадание (пулемёт) не должно ронять ПЛАСТ. Осыпать несколько клеток
## вокруг дырки — можно и нужно (порода выгрызается), а вот поверхность склона
## обязана остаться на месте, иначе очередь из пулемёта сносила бы гору.
##
## Изначально проверка требовала РОВНО НОЛЬ перекрашенных клеток, и это было
## неверное ожидание, а не баг моста: carve радиусом 2 px выбивает ~21 пиксель,
## и если они легли в одну клетку 6×6 — это 58% её площади, выше порога
## carve_clear_threshold, клетка законно рушится. Порог отделяет выщербину от
## обвала, а не "мелкое оружие" от "крупного" (см. LiveSandSettings).
func _test_small_carve_does_not_collapse() -> void:
	print("\n-- мелкое попадание не роняет пласт --")
	var stand := _build()
	var sim = stand["sim"]
	var terrain: Terrain = stand["terrain"]
	var live = stand["live"]
	var cell_px: int = RULES.cell_px

	var col := GRID.x / 2
	var surface_before := _surface_row(sim, col)
	var center := Vector2i(col * cell_px + cell_px / 2, (SKY_ROWS + 6) * cell_px + cell_px / 2)
	var carved := terrain.carve_circle(center, 2)
	_check("мелкий carve всё же тронул пиксели", carved > 0, "пикселей=%d" % carved)

	await _wait(60)
	_check("поверхность склона осталась на месте", _surface_row(sim, col) == surface_before,
		"было %d, стало %d" % [surface_before, _surface_row(sim, col)])
	# Порог "локально" с запасом: на этой сцене измеренное значение — 6 клеток.
	# Обвал пласта дал бы порядок в сотню (см. проверку выше: 154).
	_check("осыпалось лишь локально, а не пластом", live.stat_cells_repainted < LOCAL_SLUMP_LIMIT,
		"клеток=%d (предел %d)" % [live.stat_cells_repainted, LOCAL_SLUMP_LIMIT])
	_teardown(stand)


## Детерминизм: тот же старт + тот же carve + то же число кадров -> побитово
## равное поле. На этом стоит будущий сетевой PvP (хост и клиент тикают свои
## копии независимо), поэтому проверка не декоративная.
func _test_determinism() -> void:
	print("\n-- детерминизм живого тика --")
	var hashes: Array[int] = []
	var repainted: Array[int] = []
	for run in 2:
		var stand := _build()
		var cell_px: int = RULES.cell_px
		var center := Vector2i((GRID.x / 2) * cell_px + cell_px / 2,
			(SKY_ROWS + 6) * cell_px + cell_px / 2)
		stand["terrain"].carve_circle(center, 22)
		await _wait(SETTLE_FRAMES)
		hashes.append(stand["sim"].grid_hash())
		repainted.append(stand["live"].stat_cells_repainted)
		_teardown(stand)
	_check("два одинаковых прогона дали одинаковое поле", hashes[0] == hashes[1],
		"hash %d vs %d" % [hashes[0], hashes[1]])
	_check("и одинаковое число перекрашенных клеток", repainted[0] == repainted[1],
		"%d vs %d" % [repainted[0], repainted[1]])
