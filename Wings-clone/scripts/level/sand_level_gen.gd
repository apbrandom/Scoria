## Процедурный генератор уровня из ядра SandSim (falling-sand), а не из
## готового шумового рельефа (как TestLevelGen) — рельеф стартует как настоящая
## симуляция материалов (земля/песок/вода), досчитанная до покоя ОДИН РАЗ при
## генерации уровня ("статичный старт" — решение заказчика, не живая симуляция
## во время полёта: см. notes/terrain_research.md, "Прототип: жидкость на
## модели МАССЫ"). Дальше уровень ведёт себя как обычный разрушаемый рельеф
## (Terrain.carve_circle) — тот же путь, что и у остальных уровней, никакой
## живой симуляции в кадре полёта нет.
##
## Интерфейс НАРОЧНО совпадает с TestLevelGen.generate() — падает в то же
## место в Level.gd (level.gd просто выбирает, какой генератор вызвать).
##
## class_name намеренно НЕ объявлен (в отличие от TestLevelGen) — вызывающий
## код (level.gd) свежий, а голый идентификатор нового класса не всегда
## резолвится headless-запуском до пересборки .godot/global_script_class_cache.cfg
## (грабля уже не раз ловилась в проекте, см. terrain.gd::TerrainDebrisScript);
## вызывающий берёт preload по пути.
extends RefCounted

const SAND_SIM := preload("res://scripts/sand/sand_sim.gd")
const M_SAND := preload("res://data/sand/sand.tres")
const M_STONE := preload("res://data/sand/stone.tres")
const M_WATER := preload("res://data/sand/water.tres")
const M_EARTH := preload("res://data/sand/earth.tres")

## Совпадает с id-полями соответствующих .tres (проверено, не по памяти):
## data/sand/sand.tres id=1, stone.tres id=2, water.tres id=3, earth.tres id=4.
const SAND_ID := 1
const STONE_ID := 2
const WATER_ID := 3
const EARTH_ID := 4

## Сколько терраин-пикселей на одну клетку SandSim. Больше — крупнее и дешевле
## (меньше клеток на тот же видимый размер уровня), меньше — детальнее рельеф.
const CELL_PX := 6

## Предохранитель: не тикать вечно, если что-то аномально не осядет. Не должно
## случиться на такой скромной сцене (см. devlog §38 — сопоставимый по масштабу
## объём воды устаканивался за ~3000 тиков при текущей настройке water.tres),
## но без крышки один неудачный seed мог бы подвесить загрузку уровня навсегда.
const MAX_SETTLE_TICKS := 20000

## Толщина нерушимой каймы (в клетках SandSim) слева/справа/снизу — не даёт
## кораблю вылететь за пределы уровня и провалиться под пол. Верх НАМЕРЕННО
## без каймы (открытое небо — прямой запрос заказчика "много открытого
## пространства"), в отличие от TestLevelGen, где уровень — замкнутая пещера.
const BORDER_CELLS := 3


## Возвращает {"visual": Image, "mask": Image}, как и TestLevelGen.generate().
static func generate(size: Vector2i, rng_seed: int, palette: TerrainPalette) -> Dictionary:
	var grid_w := maxi(size.x / CELL_PX, 16)
	var grid_h := maxi(size.y / CELL_PX, 16)

	var sim = SAND_SIM.new()
	sim.setup(grid_w, grid_h, [M_SAND, M_STONE, M_WATER, M_EARTH])

	var surface_row := _carve_initial_terrain(sim, grid_w, grid_h, rng_seed)
	_carve_lake(sim, surface_row, grid_w, grid_h, int(grid_w * 0.28), int(grid_w * 0.12))
	_carve_lake(sim, surface_row, grid_w, grid_h, int(grid_w * 0.68), int(grid_w * 0.14))

	var ticks := 0
	while sim.is_active() and ticks < MAX_SETTLE_TICKS:
		sim.step()
		ticks += 1

	return _bake_images(sim, grid_w, grid_h, size, palette)


## Насыпает исходную форму ДО первого step(): холмистая поверхность (шум) —
## под ней земля, пятнами песчаные дюны сверху, кайма из камня по бокам/низу.
## Возвращает surface_row (профиль поверхности по колонкам) — нужен _carve_lake,
## чтобы находить действительно низкие места рельефа, а не рыть озеро вслепую.
static func _carve_initial_terrain(sim, grid_w: int, grid_h: int, rng_seed: int) -> PackedInt32Array:
	var height_noise := FastNoiseLite.new()
	height_noise.seed = rng_seed
	height_noise.frequency = 0.02
	height_noise.fractal_octaves = 3

	var patch_noise := FastNoiseLite.new()
	patch_noise.seed = rng_seed + 1
	patch_noise.frequency = 0.06

	# Средняя линия поверхности — на 55% высоты, чтобы над рельефом осталось
	# много открытого неба (явный запрос заказчика "открытое пространство").
	var base_row := int(grid_h * 0.55)
	var amplitude := grid_h * 0.12

	var surface_row := PackedInt32Array()
	surface_row.resize(grid_w)

	for gx in grid_w:
		var n := height_noise.get_noise_1d(float(gx))  # -1..1
		var row := base_row + int(n * amplitude)
		row = clampi(row, 2, grid_h - BORDER_CELLS - 2)
		surface_row[gx] = row

		var in_side_border := gx < BORDER_CELLS or gx >= grid_w - BORDER_CELLS
		for gy in range(row, grid_h):
			if in_side_border or gy >= grid_h - BORDER_CELLS:
				sim.set_cell(gx, gy, STONE_ID)
				continue
			# Верхний слой профиля (первые ~5 клеток вглубь) местами — дюна
			# песка поверх земли, как настоящий рельеф "песок на грунте".
			var is_dune := gy < row + 5 and patch_noise.get_noise_2d(gx, gy) > 0.15
			sim.set_cell(gx, gy, SAND_ID if is_dune else EARTH_ID)

	return surface_row


## Находит самую низкую точку профиля в окне [cx-half, cx+half] и наливает
## туда воду от (lowest - 6) до локального дна каждой колонки окна — озеро
## физически сидит В понижении рельефа (колонки-холмы внутри того же окна,
## чей профиль ВЫШЕ уровня налива, водой не заливаются — торчат берегом).
static func _carve_lake(sim, surface_row: PackedInt32Array, grid_w: int, grid_h: int,
		cx: int, half: int) -> void:
	var x0 := maxi(cx - half, BORDER_CELLS + 1)
	var x1 := mini(cx + half, grid_w - BORDER_CELLS - 2)
	if x1 <= x0:
		return
	var lowest := 0
	for gx in range(x0, x1 + 1):
		lowest = maxi(lowest, surface_row[gx])
	var fill_top := maxi(lowest - 6, 2)
	for gx in range(x0, x1 + 1):
		var bottom := surface_row[gx]
		for gy in range(fill_top, bottom):
			sim.set_cell(gx, gy, WATER_ID)


## Клетка SandSim -> класс рельефа Terrain. SAND -> SOFT ("рыхлое", рвётся
## охотнее), EARTH -> NORMAL (основная "Земля"), STONE -> INDESTRUCTIBLE,
## WATER -> WATER (несолидный класс — с ним нельзя столкнуться физически,
## см. TerrainPalette.SOLID).
static func _cls_of(sand_id: int) -> int:
	match sand_id:
		SAND_ID: return TerrainPalette.Cls.SOFT
		EARTH_ID: return TerrainPalette.Cls.NORMAL
		STONE_ID: return TerrainPalette.Cls.INDESTRUCTIBLE
		WATER_ID: return TerrainPalette.Cls.WATER
		_: return TerrainPalette.Cls.EMPTY


## Разворачивает осевшую сетку SandSim в пиксельные Image (visual+mask) в
## разрешении output_size — каждая клетка становится блоком CELL_PX×CELL_PX.
static func _bake_images(sim, grid_w: int, grid_h: int, output_size: Vector2i,
		palette: TerrainPalette) -> Dictionary:
	var w := output_size.x
	var h := output_size.y
	var vis := PackedByteArray(); vis.resize(w * h * 4)
	var msk := PackedByteArray(); msk.resize(w * h * 4)

	var mr := PackedByteArray(); mr.resize(TerrainPalette.CLASS_COUNT)
	var mg := PackedByteArray(); mg.resize(TerrainPalette.CLASS_COUNT)
	var mb := PackedByteArray(); mb.resize(TerrainPalette.CLASS_COUNT)
	for cls in TerrainPalette.CLASS_COUNT:
		var v: int = palette.mask_rgb[cls]
		mr[cls] = (v >> 16) & 0xFF
		mg[cls] = (v >> 8) & 0xFF
		mb[cls] = v & 0xFF

	for gy in grid_h:
		var py0 := gy * CELL_PX
		var block_h := mini(CELL_PX, h - py0)
		if block_h <= 0:
			continue
		for gx in grid_w:
			var px0 := gx * CELL_PX
			var block_w := mini(CELL_PX, w - px0)
			if block_w <= 0:
				continue
			var cls := _cls_of(sim.get_cell(gx, gy))
			var r := 0
			var g := 0
			var b := 0
			var a := 255
			match cls:
				TerrainPalette.Cls.EMPTY:
					a = 0
				TerrainPalette.Cls.WATER:
					r = 24; g = 60; b = 190; a = 190
				TerrainPalette.Cls.INDESTRUCTIBLE:
					r = 120; g = 120; b = 128
				TerrainPalette.Cls.SOFT:
					r = 214; g = 186; b = 122  # песок — светлый тёплый
				_:  # NORMAL — земля
					r = 122; g = 82; b = 46
			for oy in block_h:
				var row := (py0 + oy) * w
				for ox in block_w:
					var o := (row + px0 + ox) * 4
					vis[o] = r; vis[o + 1] = g; vis[o + 2] = b; vis[o + 3] = a
					msk[o] = mr[cls]; msk[o + 1] = mg[cls]; msk[o + 2] = mb[cls]; msk[o + 3] = 255

	return {
		"visual": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, vis),
		"mask": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, msk),
	}
