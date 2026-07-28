## Процедурный генератор уровня из ядра SandSim (falling-sand), а не из
## готового шумового рельефа (как TestLevelGen) — рельеф стартует как настоящая
## симуляция материалов (земля/песок/вода), досчитанная до покоя ОДИН РАЗ при
## генерации уровня. Дальше та же сетка либо остаётся статичной, либо
## продолжает жить в геймплее (scripts/level/live_sand.gd) — генератор про это
## не знает, он лишь отдаёт осевший `sim` вместе с картинками.
##
## Что здесь НЕ хардкодится (изменение 2026-07-28): форма уровня больше не
## задана константами в теле генератора — все числа (высота и размах профиля,
## частота холмов, размер и число озёр, песчаные дюны, кайма) приходят из
## LevelGenRules (`data/level/default_gen.tres`) КАК ДИАПАЗОНЫ, а конкретное
## значение разыгрывается детерминированным RNG по seed уровня. Отсюда
## «уровни чуть отличаются»: раньше все числа были одинаковые у любого seed,
## и менялся только узор шума.
##
## Играбельность при этом не отдана на волю случая: каждый разыгранный уровень
## проходит проверку инвариантов (_evaluate) — хватает ли открытого неба, не
## залит ли уровень водой, есть ли место под спавн в ОБЕИХ половинах карты, не
## упирается ли шпиль рельефа в потолок. Провалил — берём следующий seed
## (детерминированный шаг, не случайный), до rules.max_attempts раз. Если не
## сошлось ни разу — отдаём ЛУЧШИЙ из отвергнутых, а не роняем загрузку уровня.
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
## Правила по умолчанию. preload ресурса, а не голый class_name LevelGenRules —
## та же причина, что у комментария про class_name выше.
const DEFAULT_RULES := preload("res://data/level/default_gen.tres")

## Совпадает с id-полями соответствующих .tres (проверено, не по памяти):
## data/sand/sand.tres id=1, stone.tres id=2, water.tres id=3, earth.tres id=4.
const SAND_ID := 1
const STONE_ID := 2
const WATER_ID := 3
const EARTH_ID := 4

## Предохранитель: не тикать вечно, если что-то аномально не осядет. Не должно
## случиться на такой скромной сцене (см. devlog §38 — сопоставимый по масштабу
## объём воды устаканивался за ~3000 тиков при текущей настройке water.tres),
## но без крышки один неудачный seed мог бы подвесить загрузку уровня навсегда.
const MAX_SETTLE_TICKS := 20000

## Шаг между seed'ами при переборе попыток. Простое число, а не +1: соседние
## seed'ы у FastNoiseLite дают заметно похожий узор, и уровень-кандидат №2
## провалил бы те же инварианты, что и №1. Шаг простым числом разносит попытки.
const SEED_ATTEMPT_STEP := 7919


## Строит и досчитывает до покоя саму симуляцию — БЕЗ запекания в Image.
## Вынесено из generate() отдельно, потому что живой мост (scripts/level/
## live_sand.gd) забирает готовый осевший `sim` и продолжает тикать его в
## геймплее; generate() же ниже просто запекает тот же результат в картинки.
##
## Возвращает {"sim", "grid": Vector2i, "settle_ticks": int, "seed_used": int,
## "attempts": int, "report": Dictionary} — report см. _evaluate(),
## "attempts" — сколько попыток seed'а сделано всего (не порядковый номер
## выбранной), "seed_used" — seed того уровня, который в итоге отдан.
static func build_settled_sim(size: Vector2i, rng_seed: int, rules = null) -> Dictionary:
	if rules == null:
		rules = DEFAULT_RULES

	var best: Dictionary = {}
	var best_score := -1.0
	# Явные типы, а не := — `rules` намеренно без аннотации типа (см. шапку про
	# class_name), поэтому вывести тип из его поля компилятор не может.
	var attempts: int = rules.max_attempts

	for i in attempts:
		var seed_i: int = rng_seed + i * SEED_ATTEMPT_STEP
		var built := _build_once(size, seed_i, rules)
		var report: Dictionary = _evaluate(built["sim"], built["grid"], rules)
		built["seed_used"] = seed_i
		built["attempts"] = i + 1
		built["report"] = report
		if report["ok"]:
			return built
		# Не сошлось — запоминаем лучший из отвергнутых. Загрузка уровня не
		# должна падать из-за неудачной случайности: чуть менее удачный рельеф
		# лучше, чем чёрный экран (см. шапку файла).
		if report["score"] > best_score:
			best_score = report["score"]
			best = built

	# "attempts" везде означает СКОЛЬКО ПОПЫТОК СДЕЛАНО, а не на какой из них
	# остановились: в ветке выше это одно и то же (вышли сразу, как нашли), а
	# здесь перебор дошёл до конца, и лучший кандидат мог оказаться не последним.
	# Без этой строки поле молча значило бы разное в двух ветках одной функции.
	best["attempts"] = attempts
	return best


## Одна попытка: разыграть числа по seed и досчитать симуляцию до покоя.
static func _build_once(size: Vector2i, rng_seed: int, rules) -> Dictionary:
	var cell_px: int = rules.cell_px
	var grid_w := maxi(size.x / cell_px, 16)
	var grid_h := maxi(size.y / cell_px, 16)

	var p := _roll(rules, rng_seed, grid_w)

	var sim = SAND_SIM.new()
	sim.setup(grid_w, grid_h, [M_SAND, M_STONE, M_WATER, M_EARTH])

	var surface_row := _carve_initial_terrain(sim, grid_w, grid_h, rng_seed, rules, p)
	for lake in p["lakes"]:
		_carve_lake(sim, surface_row, grid_w, grid_h, rules,
			int(lake["cx"]), int(lake["half"]), int(lake["depth"]))

	var ticks := 0
	while sim.is_active() and ticks < MAX_SETTLE_TICKS:
		sim.step()
		ticks += 1

	# "Спящее тело" (SandSim.flatten_liquid_bodies, devlog §43) — флуд-филл +
	# мгновенный пересчёт объёма ВМЕСТО того, чтобы полагаться на то, что
	# локальная диффузия САМА дойдёт до плоского уровня за MAX_SETTLE_TICKS.
	# Озеро может числиться "осевшим" (is_active()==false, дребезга нет), но
	# оставаться холмом — потиковая сходимость к идеальной плоскости для
	# большого объёма требует значительно больше тиков, чем оседание вообще
	# (devlog §36-38). Один явный проход здесь решает это без изменения
	# бюджета MAX_SETTLE_TICKS.
	sim.flatten_liquid_bodies()

	return {"sim": sim, "grid": Vector2i(grid_w, grid_h), "settle_ticks": ticks, "params": p}


## Разыгрывает КОНКРЕТНЫЕ числа уровня из диапазонов LevelGenRules.
## RandomNumberGenerator с явным seed (не глобальный randf()) — тот же seed
## обязан дать тот же уровень: это нужно и тестам, и будущему сетевому матчу,
## где хост и клиент генерируют рельеф независимо по общему seed (roadmap.md).
static func _roll(rules, rng_seed: int, grid_w: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var p := {
		"surface_base": rng.randf_range(rules.surface_base_min, rules.surface_base_max),
		"surface_amplitude": rng.randf_range(rules.surface_amplitude_min, rules.surface_amplitude_max),
		"surface_frequency": rng.randf_range(rules.surface_frequency_min, rules.surface_frequency_max),
		"dune_threshold": rng.randf_range(rules.dune_threshold_min, rules.dune_threshold_max),
		"dune_depth": rng.randi_range(rules.dune_depth_min, rules.dune_depth_max),
	}

	# Озёра раскладываем по НЕПЕРЕСЕКАЮЩИМСЯ слотам равной ширины, а не по
	# свободным случайным точкам: два случайных центра регулярно накладывались
	# бы друг на друга и сливались в одно море на пол-карты (ровно тот случай,
	# который потом отвергнет проверка max_water_frac — дешевле не допускать).
	var lake_count := rng.randi_range(rules.lake_count_min, rules.lake_count_max)
	var lakes: Array = []
	if lake_count > 0:
		# Поля 12% с каждого края — озеро вплотную к нерушимой кайме выглядит
		# как обрезанное и мешает спавну у края карты.
		var span := grid_w * 0.76
		var slot := span / lake_count
		for i in lake_count:
			var slot_center := grid_w * 0.12 + slot * (i + 0.5)
			# Дрожание в пределах трети слота — озёра не выстроены по линейке,
			# но и не выходят за свой слот (то есть не пересекаются).
			var cx := slot_center + rng.randf_range(-slot / 3.0, slot / 3.0)
			var half_frac := rng.randf_range(rules.lake_half_min, rules.lake_half_max)
			# Полуширина ограничена половиной слота — иначе широкое озеро всё
			# равно дотянулось бы до соседнего, обнулив смысл слотов.
			var half := minf(grid_w * half_frac, slot * 0.5)
			lakes.append({
				"cx": cx,
				"half": half,
				"depth": rng.randi_range(rules.lake_depth_min, rules.lake_depth_max),
			})
	p["lakes"] = lakes
	return p


## Насыпает исходную форму ДО первого step(): холмистая поверхность (шум) —
## под ней земля, пятнами песчаные дюны сверху, кайма из камня по бокам/низу.
## Возвращает surface_row (профиль поверхности по колонкам) — нужен _carve_lake,
## чтобы находить действительно низкие места рельефа, а не рыть озеро вслепую.
static func _carve_initial_terrain(sim, grid_w: int, grid_h: int, rng_seed: int,
		rules, p: Dictionary) -> PackedInt32Array:
	var height_noise := FastNoiseLite.new()
	height_noise.seed = rng_seed
	height_noise.frequency = p["surface_frequency"]
	height_noise.fractal_octaves = rules.surface_octaves

	var patch_noise := FastNoiseLite.new()
	patch_noise.seed = rng_seed + 1
	patch_noise.frequency = 0.06

	var border: int = rules.border_cells
	var base_row := int(grid_h * float(p["surface_base"]))
	var amplitude: float = grid_h * float(p["surface_amplitude"])
	var dune_threshold: float = p["dune_threshold"]
	var dune_depth: int = p["dune_depth"]

	var surface_row := PackedInt32Array()
	surface_row.resize(grid_w)

	for gx in grid_w:
		var n := height_noise.get_noise_1d(float(gx))  # -1..1
		var row := base_row + int(n * amplitude)
		row = clampi(row, 2, grid_h - border - 2)
		surface_row[gx] = row

		var in_side_border := gx < border or gx >= grid_w - border
		for gy in range(row, grid_h):
			if in_side_border or gy >= grid_h - border:
				sim.set_cell(gx, gy, STONE_ID)
				continue
			# Верхний слой профиля местами — дюна песка поверх земли, как
			# настоящий рельеф "песок на грунте".
			var is_dune := gy < row + dune_depth and patch_noise.get_noise_2d(gx, gy) > dune_threshold
			sim.set_cell(gx, gy, SAND_ID if is_dune else EARTH_ID)

	return surface_row


## Находит самую низкую точку профиля в окне [cx-half, cx+half] и наливает
## туда воду от (lowest - depth) до локального дна каждой колонки окна — озеро
## физически сидит В понижении рельефа (колонки-холмы внутри того же окна,
## чей профиль ВЫШЕ уровня налива, водой не заливаются — торчат берегом).
static func _carve_lake(sim, surface_row: PackedInt32Array, grid_w: int, grid_h: int,
		rules, cx: int, half: int, depth: int) -> void:
	var border: int = rules.border_cells
	var x0 := maxi(cx - half, border + 1)
	var x1 := mini(cx + half, grid_w - border - 2)
	if x1 <= x0:
		return
	var lowest := 0
	for gx in range(x0, x1 + 1):
		lowest = maxi(lowest, surface_row[gx])
	var fill_top := maxi(lowest - depth, 2)
	for gx in range(x0, x1 + 1):
		var bottom := surface_row[gx]
		for gy in range(fill_top, bottom):
			sim.set_cell(gx, gy, WATER_ID)


# ---------------------------------------------------------------- играбельность

## Проверка сгенерированного уровня на пригодность к игре. Возвращает
## {"ok": bool, "score": float, "fails": Array[String], "stats": Dictionary}.
##
## score (0..1) — не «оценка красоты», а мера того, НАСКОЛЬКО уровень близок к
## проходному: нужна только чтобы выбрать наименее плохой вариант, если ни один
## seed не прошёл (см. build_settled_sim). Каждый инвариант даёт свою долю.
static func _evaluate(sim, grid: Vector2i, rules) -> Dictionary:
	var total := grid.x * grid.y
	var empty := 0
	var water := 0
	# Самая ВЫСОКАЯ точка рельефа (минимальный y непустой клетки по всем
	# колонкам) — она и определяет, остаётся ли над картой сплошное небо.
	var highest_row := grid.y
	for gx in grid.x:
		var found := false
		for gy in grid.y:
			var c: int = sim.get_cell(gx, gy)
			if c == 0:
				empty += 1
				continue
			if c == WATER_ID:
				water += 1
			if not found:
				highest_row = mini(highest_row, gy)
				found = true

	var open_frac := float(empty) / float(total)
	var water_frac := float(water) / float(total)
	var headroom_frac := float(highest_row) / float(grid.y)

	var radius_cells: int = maxi(int(rules.spawn_clear_radius_px) / int(rules.cell_px), 1)
	var spawn_left := _has_spawn_spot(sim, grid, 0, grid.x / 2, radius_cells)
	var spawn_right := _has_spawn_spot(sim, grid, grid.x / 2, grid.x, radius_cells)

	var fails: Array = []
	if open_frac < rules.min_open_sky_frac:
		fails.append("мало открытого пространства: %.2f < %.2f" % [open_frac, rules.min_open_sky_frac])
	if water_frac > rules.max_water_frac:
		fails.append("слишком много воды: %.2f > %.2f" % [water_frac, rules.max_water_frac])
	if headroom_frac < rules.min_sky_headroom_frac:
		fails.append("рельеф упирается в потолок: %.2f < %.2f" % [headroom_frac, rules.min_sky_headroom_frac])
	if not spawn_left:
		fails.append("нет места под спавн в левой половине")
	if not spawn_right:
		fails.append("нет места под спавн в правой половине")

	# Доли считаем "насколько выполнено", каждая зажата в 0..1, поровну весом.
	var s_open := clampf(open_frac / maxf(rules.min_open_sky_frac, 0.001), 0.0, 1.0)
	var s_water := clampf(rules.max_water_frac / maxf(water_frac, 0.001), 0.0, 1.0)
	var s_head := clampf(headroom_frac / maxf(rules.min_sky_headroom_frac, 0.001), 0.0, 1.0)
	var s_spawn := (1.0 if spawn_left else 0.0) + (1.0 if spawn_right else 0.0)
	var score := (s_open + s_water + s_head + s_spawn) / 5.0

	return {
		"ok": fails.is_empty(),
		"score": score,
		"fails": fails,
		"stats": {
			"open_frac": open_frac,
			"water_frac": water_frac,
			"headroom_frac": headroom_frac,
			"spawn_left": spawn_left,
			"spawn_right": spawn_right,
		},
	}


## Есть ли в полосе колонок [x_from, x_to) место, куда влезет корабль: круг
## радиусом radius клеток БЕЗ камня (камень carve не берёт — Terrain.
## find_clear_spawn исходит ровно из этого, см. его _has_unmovable_solid) и
## при этом уже преимущественно пустой. Второе условие не лишнее: без него
## «местом под спавн» считалась бы любая точка в толще земли — carve её,
## конечно, расчистит, но корабль появится в пузыре под землёй, а не в небе.
static func _has_spawn_spot(sim, grid: Vector2i, x_from: int, x_to: int, radius: int) -> bool:
	# Шаг = радиус: сканировать каждую клетку незачем (соседние круги почти
	# совпадают), а пропустить единственное подходящее место таким шагом нельзя —
	# любая свободная область размером с корабль накрывает хотя бы один узел.
	var step := maxi(radius, 1)
	var y := radius
	while y < grid.y - radius:
		var x := x_from + radius
		while x < x_to - radius:
			if _spot_is_clear(sim, x, y, radius):
				return true
			x += step
		y += step
	return false


static func _spot_is_clear(sim, cx: int, cy: int, radius: int) -> bool:
	var r2 := radius * radius
	var cells := 0
	var empty := 0
	for y in range(cy - radius, cy + radius + 1):
		for x in range(cx - radius, cx + radius + 1):
			var dx := x - cx
			var dy := y - cy
			if dx * dx + dy * dy > r2:
				continue
			var c: int = sim.get_cell(x, y)
			if c == STONE_ID:
				return false  # камень carve не уберёт — спавн тут невозможен
			cells += 1
			if c == 0:
				empty += 1
	# Не меньше половины круга уже воздух — то есть это небо/склон, а не толща.
	return cells > 0 and float(empty) / float(cells) >= 0.5


# ---------------------------------------------------------------- запекание

## Возвращает {"visual": Image, "mask": Image}, как и TestLevelGen.generate(),
## плюс "sim"/"grid"/"seed_used"/"report" — их берут живой мост (live_sand.gd) и
## диагностика; вызывающие, которым нужны только картинки, игнорируют лишние ключи.
static func generate(size: Vector2i, rng_seed: int, palette: TerrainPalette, rules = null) -> Dictionary:
	if rules == null:
		rules = DEFAULT_RULES
	var built := build_settled_sim(size, rng_seed, rules)
	var sim = built["sim"]
	var grid: Vector2i = built["grid"]

	var out := _bake_images(sim, grid.x, grid.y, size, palette, built["seed_used"], rules)
	out["sim"] = sim
	out["grid"] = grid
	out["seed_used"] = built["seed_used"]
	out["attempts"] = built["attempts"]
	out["report"] = built["report"]
	return out


## Клетка SandSim -> класс рельефа Terrain. SAND -> SOFT ("рыхлое", рвётся
## охотнее), EARTH -> NORMAL (основная "Земля"), STONE -> INDESTRUCTIBLE,
## WATER -> WATER (несолидный класс — с ним нельзя столкнуться физически,
## см. TerrainPalette.SOLID).
static func cls_of(sand_id: int) -> int:
	match sand_id:
		SAND_ID: return TerrainPalette.Cls.SOFT
		EARTH_ID: return TerrainPalette.Cls.NORMAL
		STONE_ID: return TerrainPalette.Cls.INDESTRUCTIBLE
		WATER_ID: return TerrainPalette.Cls.WATER
		_: return TerrainPalette.Cls.EMPTY


## Мелкая шумовая вариация цвета ВНУТРИ клетки — без неё блок CELL_PX×CELL_PX
## однотонный, и граница клеток читается как ровная сетка ("пиксель-арт"),
## что прямо противоречит заявленному HD-стилю проекта (CLAUDE.md). Тот же
## приём, что уже в TestLevelGen: один вызов FastNoiseLite.get_image() на весь
## холст (дёшево, С++), не get_noise_2d() на каждый пиксель (дорого в GDScript).
##
## Публичная (не с подчёркиванием), потому что тот же массив нужен ЖИВОМУ мосту
## (live_sand.gd): он перекрашивает осыпавшиеся клетки в геймплее и обязан брать
## детальный шум из того же источника с тем же seed, иначе свежая земля будет
## заметно отличаться по зерну от запечённой при генерации.
static func detail_noise_bytes(rng_seed: int, size: Vector2i) -> PackedByteArray:
	var n := FastNoiseLite.new()
	n.seed = rng_seed
	n.frequency = 0.15
	n.fractal_octaves = 1
	# FORMAT_L8, значения нормализованы в 0..255 (128 ~ ноль исходного шума)
	return n.get_image(size.x, size.y, false, false, true).get_data()


## Цвет одного пикселя рельефа по классу материала и значению детального шума.
## Вынесено из _bake_images отдельной функцией, потому что ЖИВОЙ мост
## (live_sand.gd) перекрашивает изменившиеся клетки в геймплее и обязан красить
## их ТЕМ ЖЕ правилом — иначе осыпавшаяся земля отличалась бы по цвету от
## нетронутой, и место обвала читалось бы как заплатка.
static func color_of(cls: int, detail: int) -> Color:
	var d := detail - 128
	match cls:
		TerrainPalette.Cls.EMPTY:
			return Color(0, 0, 0, 0)
		TerrainPalette.Cls.WATER:
			# Вода — без зернистого шума (это не сыпучий материал, ровная гладь
			# физически уместнее, как и в TestLevelGen).
			return Color8(24, 60, 190, 190)
		TerrainPalette.Cls.INDESTRUCTIBLE:
			var t := 120 + (d >> 3)
			return Color8(clampi(t, 0, 255), clampi(t, 0, 255), clampi(t + 6, 0, 255), 255)
		TerrainPalette.Cls.SOFT:
			return Color8(clampi(214 + (d >> 3), 0, 255), clampi(186 + (d >> 3), 0, 255),
				clampi(122 + (d >> 4), 0, 255), 255)
		_:  # NORMAL — земля, тёмный тёплый
			return Color8(clampi(122 + (d >> 2), 0, 255), clampi(82 + (d >> 3), 0, 255),
				clampi(46 + (d >> 4), 0, 255), 255)


## Разворачивает осевшую сетку SandSim в пиксельные Image (visual+mask) в
## разрешении output_size — каждая клетка становится блоком cell_px×cell_px,
## но цвет пикселя внутри блока модулируется шумом (см. _detail_noise_bytes),
## не одна плоская заливка на весь блок.
static func _bake_images(sim, grid_w: int, grid_h: int, output_size: Vector2i,
		palette: TerrainPalette, rng_seed: int, rules) -> Dictionary:
	var cell_px: int = rules.cell_px
	var w := output_size.x
	var h := output_size.y
	var vis := PackedByteArray(); vis.resize(w * h * 4)
	var msk := PackedByteArray(); msk.resize(w * h * 4)
	# +7 — отдельная соль от seed, который уже занят height_noise (rng_seed) и
	# patch_noise (rng_seed+1) в _carve_initial_terrain — не тот же узор шума.
	var detail := detail_noise_bytes(rng_seed + 7, output_size)

	var mr := PackedByteArray(); mr.resize(TerrainPalette.CLASS_COUNT)
	var mg := PackedByteArray(); mg.resize(TerrainPalette.CLASS_COUNT)
	var mb := PackedByteArray(); mb.resize(TerrainPalette.CLASS_COUNT)
	for cls in TerrainPalette.CLASS_COUNT:
		var v: int = palette.mask_rgb[cls]
		mr[cls] = (v >> 16) & 0xFF
		mg[cls] = (v >> 8) & 0xFF
		mb[cls] = v & 0xFF

	for gy in grid_h:
		var py0 := gy * cell_px
		var block_h := mini(cell_px, h - py0)
		if block_h <= 0:
			continue
		for gx in grid_w:
			var px0 := gx * cell_px
			var block_w := mini(cell_px, w - px0)
			if block_w <= 0:
				continue
			var cls := cls_of(sim.get_cell(gx, gy))
			var mask_r: int = mr[cls]
			var mask_g: int = mg[cls]
			var mask_b: int = mb[cls]
			for oy in block_h:
				var row := (py0 + oy) * w
				for ox in block_w:
					var pi := row + px0 + ox
					var c := color_of(cls, detail[pi])
					var o := pi * 4
					vis[o] = int(c.r8)
					vis[o + 1] = int(c.g8)
					vis[o + 2] = int(c.b8)
					vis[o + 3] = int(c.a8)
					msk[o] = mask_r; msk[o + 1] = mask_g; msk[o + 2] = mask_b; msk[o + 3] = 255

	return {
		"visual": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, vis),
		"mask": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, msk),
	}
