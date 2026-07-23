## Headless-проверка ядра клеточной симуляции (SandSim) — без окна.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_sand.tscn
##
## Проверяем ровно те инварианты, на которых стоит вся дальнейшая разработка
## (см. шапку scripts/sand/sand_sim.gd):
##  - ДЕТЕРМИНИЗМ (одинаковый старт + тики -> побитово равное поле) — без него
##    невозможен сетевой replay carve (PvP);
##  - КОРРЕКТНОСТЬ DIRTY-RECT (оптимизация "покой = ноль работы" не теряет
##    обновлений: результат равен полному сканированию поля);
##  - сохранение массы (песок не появляется и не исчезает);
##  - оседание в кучу с углом откоса и симметрией (эмерджентность без дрейфа);
##  - камень (SOLID) держит песок и границы поля не протекают.
##
## Материалы грузим preload'ом .tres ПО ПУТИ — не через class_name SandMaterial
## (та же предосторожность против headless-кэша, что и в остальном проекте).
extends Node

const SAND_SIM := preload("res://scripts/sand/sand_sim.gd")
const SAND_MATERIAL_SCRIPT := preload("res://resources/sand_material.gd")
const M_EMPTY := preload("res://data/sand/empty.tres")
const M_SAND := preload("res://data/sand/sand.tres")
const M_STONE := preload("res://data/sand/stone.tres")
const M_WATER := preload("res://data/sand/water.tres")
const M_EARTH := preload("res://data/sand/earth.tres")
const M_WOOD := preload("res://data/sand/wood.tres")
const M_FIRE := preload("res://data/sand/fire.tres")

const SAND_ID := 1
const STONE_ID := 2
const WATER_ID := 3
const EARTH_ID := 4
const WOOD_ID := 5
const FIRE_ID := 6

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка клеточной симуляции SandSim (%s) ===" % DisplayServer.get_name())
	_test_determinism()
	_test_dirty_rect_matches_full_scan()
	_test_mass_conservation()
	_test_settles_to_rest()
	_test_pile_spread_and_symmetry()
	_test_solid_floor_holds()
	# --- милстоун 3: материалы ---
	_test_water_settles_flatter_than_sand()
	_test_powder_sinks_in_water()
	_test_fire_consumes_wood()
	_test_lone_fire_burns_out()
	_test_water_extinguishes_fire()
	_test_determinism_all_materials()
	_test_dirty_rect_with_reactions()
	# --- фидбек по итогам первой сборки: вязкость воды, гравитация дерева ---
	_test_viscosity_slows_water()
	_test_wood_falls_when_unsupported()
	_test_wood_stays_when_supported()
	_test_wood_falls_as_rigid_group()
	_test_wood_fall_blocked_by_obstacle()
	_test_falling_wood_determinism()
	_test_wood_fall_dirty_rect_matches_full()
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


func _materials() -> Array:
	return [M_EMPTY, M_SAND, M_STONE, M_WATER, M_EARTH, M_WOOD, M_FIRE]


## Стартовая раскладка для тестов детерминизма/массы: пол из камня снизу + блок
## песка с парой дырок (чтобы динамика была нетривиальной), одна и та же всегда.
func _make_scene() -> Object:
	var sim: Object = SAND_SIM.new()
	sim.setup(48, 48, _materials())
	sim.fill_rect(0, 44, 48, 4, STONE_ID)        # дно
	sim.fill_rect(14, 6, 20, 14, SAND_ID)        # блок песка
	sim.set_cell(20, 12, 0)                       # дырки внутри блока
	sim.set_cell(27, 15, 0)
	sim.set_cell(23, 9, 0)
	return sim


func _run(sim: Object, steps: int) -> void:
	for _i in steps:
		sim.step()


# 1. Детерминизм: два прогона из одинакового старта дают побитово равное поле.
#    Плюс страховка: другой старт даёт ДРУГОЙ хеш (не константа-заглушка).
func _test_determinism() -> void:
	var a := _make_scene()
	var b := _make_scene()
	_run(a, 400)
	_run(b, 400)
	var ha: int = a.grid_hash()
	var hb: int = b.grid_hash()
	_check("детерминизм: два одинаковых прогона совпадают", ha == hb,
		"hashA=%d hashB=%d" % [ha, hb])

	var c := _make_scene()
	c.set_cell(5, 5, SAND_ID)  # одно лишнее зерно В ПУСТОТЕ сбоку от блока
	_run(c, 400)
	_check("детерминизм: изменённый старт даёт другой результат", c.grid_hash() != ha,
		"иначе хеш нечувствителен к входу")


# 2. Dirty-rect ничего не теряет: пошагово сравниваем обычный режим с полным
#    сканированием всего поля — поле обязано совпадать на КАЖДОМ тике.
func _test_dirty_rect_matches_full_scan() -> void:
	var opt := _make_scene()
	var full := _make_scene()
	full.force_full_scan = true
	var diverged_at := -1
	for i in 400:
		opt.step()
		full.step()
		if opt.grid_hash() != full.grid_hash():
			diverged_at = i
			break
	_check("dirty-rect == полное сканирование (оптимизация ничего не теряет)",
		diverged_at == -1, "разошлись на тике %d" % diverged_at)


# 3. Сохранение массы: песок только двигается, не рождается и не исчезает;
#    камень неподвижен и тоже сохраняется.
func _test_mass_conservation() -> void:
	var sim := _make_scene()
	var sand0: int = sim.count_material(SAND_ID)
	var stone0: int = sim.count_material(STONE_ID)
	_run(sim, 400)
	var sand1: int = sim.count_material(SAND_ID)
	var stone1: int = sim.count_material(STONE_ID)
	_check("масса песка сохранена", sand0 == sand1, "было %d, стало %d" % [sand0, sand1])
	_check("масса камня сохранена", stone0 == stone1, "было %d, стало %d" % [stone0, stone1])


# 4. Оседание: после конечного числа тиков всё улеглось -> симуляция сама
#    выключается (is_active == false), т.е. "покой = ноль работы".
func _test_settles_to_rest() -> void:
	var sim := _make_scene()
	var settled_at := -1
	for i in 4000:
		sim.step()
		if not sim.is_active():
			settled_at = i
			break
	_check("система оседает в покой за конечное время", settled_at != -1,
		"не улеглось за 4000 тиков" if settled_at == -1 else "улеглось на тике %d" % settled_at)


# 5. Куча: узкий столб песка над полом растекается в симметричный треугольник
#    (угол откоса), масса сохраняется, ничего не уходит вбок за границу.
func _test_pile_spread_and_symmetry() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(64, 64, _materials())
	sim.fill_rect(0, 60, 64, 4, STONE_ID)  # пол
	var col_x := 32
	sim.fill_rect(col_x, 38, 1, 20, SAND_ID)  # столб из 20 зёрен, шириной 1
	var grains: int = sim.count_material(SAND_ID)

	for _i in 4000:
		sim.step()
		if not sim.is_active():
			break

	# границы кучи по X среди осевшего песка
	var min_x := 64
	var max_x := -1
	var below_floor := 0
	for y in 64:
		for x in 64:
			if sim.get_cell(x, y) == SAND_ID:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				if y >= 60:
					below_floor += 1

	var base_w := max_x - min_x + 1
	var left := col_x - min_x
	var right := max_x - col_x

	_check("куча растеклась шире столба (угол откоса)", base_w >= 5,
		"ширина основания %d клеток" % base_w)
	_check("куча симметрична относительно центра", absi(left - right) <= 2,
		"влево %d, вправо %d" % [left, right])
	_check("масса песка в куче сохранена", sim.count_material(SAND_ID) == grains,
		"было %d, стало %d" % [grains, sim.count_material(SAND_ID)])
	_check("песок не просочился сквозь пол", below_floor == 0,
		"под полом %d зёрен" % below_floor)


# 6. SOLID держит форму: под сплошным полом песка нет; количество камня и его
#    расположение не изменились (камень не падает сам).
func _test_solid_floor_holds() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(32, 32, _materials())
	sim.fill_rect(0, 20, 32, 1, STONE_ID)   # тонкий пол в один пиксель
	sim.fill_rect(10, 4, 12, 10, SAND_ID)   # песок над ним
	var stone_row_before := 0
	for x in 32:
		if sim.get_cell(x, 20) == STONE_ID:
			stone_row_before += 1
	_run(sim, 800)
	var stone_row_after := 0
	var leaked := 0
	for x in 32:
		if sim.get_cell(x, 20) == STONE_ID:
			stone_row_after += 1
		for y in range(21, 32):
			if sim.get_cell(x, y) == SAND_ID:
				leaked += 1
	_check("тонкий пол из камня не сдвинулся", stone_row_before == stone_row_after and stone_row_after == 32,
		"камня в ряду: было %d, стало %d" % [stone_row_before, stone_row_after])
	_check("песок не проваливается сквозь пол в 1 клетку", leaked == 0,
		"под полом %d зёрен песка" % leaked)


# ── милстоун 3: материалы ──────────────────────────────────────────────────

func _run_to_rest(sim: Object, cap: int) -> int:
	for i in cap:
		sim.step()
		if not sim.is_active():
			return i
	return -1


## [min_x, max_x, min_y, max_y, count] по всем ячейкам материала id.
func _bbox(sim: Object, id: int) -> Array:
	var w: int = sim.width
	var h: int = sim.height
	var minx := 1 << 30
	var maxx := -1
	var miny := 1 << 30
	var maxy := -1
	var n := 0
	for y in h:
		for x in w:
			if sim.get_cell(x, y) == id:
				minx = mini(minx, x); maxx = maxi(maxx, x)
				miny = mini(miny, y); maxy = maxi(maxy, y)
				n += 1
	return [minx, maxx, miny, maxy, n]


func _avg_y(sim: Object, id: int) -> float:
	var w: int = sim.width
	var h: int = sim.height
	var sum := 0.0
	var n := 0
	for y in h:
		for x in w:
			if sim.get_cell(x, y) == id:
				sum += y
				n += 1
	return sum / n if n > 0 else -1.0


## Столб из 20 клеток материала id над полом -> [тиков до покоя, высота, ширина, масса].
func _settle_column(id: int) -> Array:
	var sim: Object = SAND_SIM.new()
	sim.setup(64, 48, _materials())
	sim.fill_rect(0, 44, 64, 4, STONE_ID)
	sim.fill_rect(32, 20, 1, 20, id)
	var t := _run_to_rest(sim, 6000)
	var bb := _bbox(sim, id)
	var height: int = (bb[3] - bb[2] + 1) if bb[4] > 0 else 0
	var base: int = (bb[1] - bb[0] + 1) if bb[4] > 0 else 0
	return [t, height, base, bb[4]]


# Вода оседает площе и шире, чем песок той же массы — так жидкость отличается от
# сыпучего (у песка угол откоса ~45°, вода разравнивается почти в плоскость).
func _test_water_settles_flatter_than_sand() -> void:
	var s := _settle_column(SAND_ID)
	var w := _settle_column(WATER_ID)
	_check("песок оседает в покой", s[0] != -1, "тиков %d" % s[0])
	_check("вода оседает в покой", w[0] != -1, "тиков %d" % w[0])
	_check("масса воды сохранена (20)", w[3] == 20, "стало %d" % w[3])
	_check("вода площе песка (высота меньше)", w[1] < s[1],
		"высота воды %d, песка %d" % [w[1], s[1]])
	_check("лужа воды шире кучи песка", w[2] >= s[2],
		"ширина воды %d, песка %d" % [w[2], s[2]])


# Песок плотнее воды -> тонет сквозь неё на дно, вода всплывает наверх.
func _test_powder_sinks_in_water() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(30, 40, _materials())
	sim.fill_rect(0, 30, 30, 2, STONE_ID)   # пол
	sim.fill_rect(9, 12, 1, 18, STONE_ID)    # левая стенка
	sim.fill_rect(20, 12, 1, 18, STONE_ID)   # правая стенка
	sim.fill_rect(10, 22, 10, 8, WATER_ID)   # вода в контейнере (80)
	sim.fill_rect(13, 14, 4, 2, SAND_ID)     # песок сверху (8)
	var water0: int = sim.count_material(WATER_ID)
	var sand0: int = sim.count_material(SAND_ID)
	var t := _run_to_rest(sim, 6000)
	var sy := _avg_y(sim, SAND_ID)
	var wy := _avg_y(sim, WATER_ID)
	_check("вода+песок оседают в покой", t != -1, "тиков %d" % t)
	_check("масса воды сохранена", sim.count_material(WATER_ID) == water0,
		"было %d, стало %d" % [water0, sim.count_material(WATER_ID)])
	_check("масса песка сохранена", sim.count_material(SAND_ID) == sand0,
		"было %d, стало %d" % [sand0, sim.count_material(SAND_ID)])
	_check("песок утонул ниже воды (плотность)", sy > wy,
		"средняя y песка %.1f, воды %.1f" % [sy, wy])


# Огонь поджигает дерево, распространяется по нему и полностью его сжигает,
# после чего гаснет сам (нет топлива) -> система оседает. Дерево падает
# (SandMaterial.falls) -> балка стоит НА ПОЛУ, не парит, иначе она успеет
# упасть раньше, чем огонь до неё доберётся (реальная грабля, найдена этим же
# тестом на предыдущей версии сценария после включения falls=true).
func _test_fire_consumes_wood() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(30, 20, _materials())
	sim.fill_rect(0, 18, 30, 2, STONE_ID)  # пол
	sim.fill_rect(5, 16, 15, 2, WOOD_ID)   # балка дерева (30 клеток) на полу
	var wood0: int = sim.count_material(WOOD_ID)
	sim.set_cell(4, 16, FIRE_ID)            # поджечь слева на той же высоте
	var t := _run_to_rest(sim, 3000)
	_check("дерево изначально было (30)", wood0 == 30, "было %d" % wood0)
	_check("огонь+дерево оседают (всё выгорело)", t != -1, "тиков %d" % t)
	_check("дерево полностью сгорело", sim.count_material(WOOD_ID) == 0,
		"осталось %d" % sim.count_material(WOOD_ID))
	_check("огонь потух после выгорания", sim.count_material(FIRE_ID) == 0,
		"осталось %d" % sim.count_material(FIRE_ID))


# Огонь без топлива гаснет за свою жизнь (burn_life) и не остаётся навсегда.
func _test_lone_fire_burns_out() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(12, 12, _materials())
	sim.set_cell(6, 6, FIRE_ID)
	var t := _run_to_rest(sim, 200)
	_check("одинокий огонь без топлива гаснет", t != -1 and sim.count_material(FIRE_ID) == 0,
		"тиков до покоя %d, огня осталось %d" % [t, sim.count_material(FIRE_ID)])


# Вода тушит соседний огонь и экранирует дерево за собой.
func _test_water_extinguishes_fire() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(20, 10, _materials())
	sim.fill_rect(0, 6, 20, 1, STONE_ID)   # пол, чтобы вода не падала
	sim.set_cell(5, 5, WOOD_ID)
	sim.set_cell(6, 5, WATER_ID)
	sim.set_cell(7, 5, FIRE_ID)
	var t := _run_to_rest(sim, 200)
	_check("система с тушением оседает", t != -1, "тиков %d" % t)
	_check("вода потушила огонь", sim.count_material(FIRE_ID) == 0,
		"огня осталось %d" % sim.count_material(FIRE_ID))
	_check("дерево за водой уцелело (экран)", sim.count_material(WOOD_ID) == 1,
		"дерева осталось %d" % sim.count_material(WOOD_ID))
	_check("вода на месте", sim.count_material(WATER_ID) == 1,
		"воды осталось %d" % sim.count_material(WATER_ID))


## Богатая смесь всех материалов + горящее дерево — для детерминизма и dirty-rect.
func _make_mixed() -> Object:
	var sim: Object = SAND_SIM.new()
	sim.setup(40, 40, _materials())
	sim.fill_rect(0, 35, 40, 5, STONE_ID)   # пол
	sim.fill_rect(5, 10, 8, 6, SAND_ID)
	sim.fill_rect(20, 8, 6, 6, EARTH_ID)
	sim.fill_rect(28, 20, 8, 6, WATER_ID)
	sim.fill_rect(10, 28, 12, 2, WOOD_ID)
	sim.set_cell(10, 27, FIRE_ID)            # поджечь дерево
	return sim


func _test_determinism_all_materials() -> void:
	var a := _make_mixed()
	var b := _make_mixed()
	for _i in 300:
		a.step()
		b.step()
	_check("детерминизм со всеми материалами (вода/огонь/дерево)",
		a.grid_hash() == b.grid_hash(),
		"hashA=%d hashB=%d" % [a.grid_hash(), b.grid_hash()])


func _test_dirty_rect_with_reactions() -> void:
	var opt := _make_mixed()
	var full := _make_mixed()
	full.force_full_scan = true
	var diverged_at := -1
	for i in 300:
		opt.step()
		full.step()
		if opt.grid_hash() != full.grid_hash():
			diverged_at = i
			break
	_check("dirty-rect == полный проход и с реакциями (вода/огонь)",
		diverged_at == -1, "разошлись на тике %d" % diverged_at)


# ── фидбек: вязкость воды, гравитация дерева ───────────────────────────────

# Два материала-жидкости, отличающиеся ТОЛЬКО вязкостью — вязкая должна
# откликаться медленнее (больше тиков до покоя) на абсолютно той же сцене.
# Материалы строим в коде (не через .tres) — единственный способ получить два
# варианта одного kind с разными числами без создания лишних файлов ресурсов.
func _test_viscosity_slows_water() -> void:
	var thin: Object = SAND_MATERIAL_SCRIPT.new()
	thin.id = 3
	thin.kind = 3  # LIQUID
	thin.color = Color(0.2, 0.4, 0.9, 1)
	thin.viscosity = 0.0

	var thick: Object = SAND_MATERIAL_SCRIPT.new()
	thick.id = 3
	thick.kind = 3
	thick.color = Color(0.2, 0.4, 0.9, 1)
	thick.viscosity = 0.9

	var sim_thin: Object = SAND_SIM.new()
	sim_thin.setup(40, 30, [M_EMPTY, M_STONE, thin])
	sim_thin.fill_rect(0, 26, 40, 4, STONE_ID)
	sim_thin.fill_rect(18, 10, 4, 16, 3)

	var sim_thick: Object = SAND_SIM.new()
	sim_thick.setup(40, 30, [M_EMPTY, M_STONE, thick])
	sim_thick.fill_rect(0, 26, 40, 4, STONE_ID)
	sim_thick.fill_rect(18, 10, 4, 16, 3)

	var t_thin := _run_to_rest(sim_thin, 4000)
	var t_thick := _run_to_rest(sim_thick, 4000)
	_check("маловязкая вода оседает", t_thin != -1, "тиков %d" % t_thin)
	_check("вязкая вода оседает", t_thick != -1, "тиков %d" % t_thick)
	_check("вязкость реально замедляет отклик (больше тиков до покоя)",
		t_thick > t_thin, "маловязкая %d тиков, вязкая %d тиков" % [t_thin, t_thick])


# Дерево в воздухе, пола вообще нет — должно упасть до самого дна мира
# (гравитация подействовала, а не "парит" как раньше).
func _test_wood_falls_when_unsupported() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(20, 20, _materials())
	sim.fill_rect(5, 2, 6, 2, WOOD_ID)  # балка в воздухе, опоры нет вообще
	var wood0: int = sim.count_material(WOOD_ID)
	var t := _run_to_rest(sim, 200)
	_check("дерево в воздухе оседает (падает до дна)", t != -1, "тиков %d" % t)
	var max_y := -1
	for y in 20:
		for x in 20:
			if sim.get_cell(x, y) == WOOD_ID:
				max_y = maxi(max_y, y)
	_check("дерево упало до самого дна мира", max_y == 19,
		"нижний ряд балки на y=%d (ожидали 19)" % max_y)
	_check("масса дерева сохранена при падении", sim.count_material(WOOD_ID) == wood0,
		"было %d, стало %d" % [wood0, sim.count_material(WOOD_ID)])


# Дерево прямо на полу — не должно шевелиться вообще (уже есть опора).
func _test_wood_stays_when_supported() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(20, 20, _materials())
	sim.fill_rect(0, 15, 20, 5, STONE_ID)  # пол
	sim.fill_rect(5, 13, 6, 2, WOOD_ID)    # балка прямо на полу
	var before: Array = []
	for y in 20:
		for x in 20:
			if sim.get_cell(x, y) == WOOD_ID:
				before.append(Vector2i(x, y))
	for _i in 100:
		sim.step()
	var after: Array = []
	for y in 20:
		for x in 20:
			if sim.get_cell(x, y) == WOOD_ID:
				after.append(Vector2i(x, y))
	_check("дерево на опоре не падает (позиции не изменились)", before == after,
		"было %d клеток, стало %d" % [before.size(), after.size()])


# Балка над полом с зазором — должна упасть и приземлиться, СОХРАНИВ форму
# (весь прямоугольник целиком, не рассыпавшись на отдельные зёрна) — это и
# отличает SOLID+falls (дерево) от POWDER (песок сыплется зерном).
func _test_wood_falls_as_rigid_group() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(20, 20, _materials())
	sim.fill_rect(0, 15, 20, 5, STONE_ID)  # пол на y=15..19
	sim.fill_rect(5, 5, 6, 2, WOOD_ID)     # балка 6x2 высоко в воздухе
	var t := _run_to_rest(sim, 200)
	_check("дерево над полом оседает", t != -1, "тиков %d" % t)
	var cells := {}
	for y in 20:
		for x in 20:
			if sim.get_cell(x, y) == WOOD_ID:
				cells[Vector2i(x, y)] = true
	var shape_ok := cells.size() == 12
	if shape_ok:
		for yy in range(13, 15):
			for xx in range(5, 11):
				if not cells.has(Vector2i(xx, yy)):
					shape_ok = false
	_check("балка приземлилась целиком, сохранив форму 6x2 (не рассыпалась)", shape_ok,
		"клеток дерева после падения: %d" % cells.size())


# Выступ точно под серединой балки — жёсткое тело не может продавить
# препятствие частично, значит балка не сдвинется ВООБЩЕ (не только в месте
# препятствия — целиком, ни один край тоже).
func _test_wood_fall_blocked_by_obstacle() -> void:
	var sim: Object = SAND_SIM.new()
	sim.setup(20, 20, _materials())
	sim.fill_rect(0, 15, 20, 5, STONE_ID)  # пол
	sim.set_cell(8, 9, STONE_ID)            # выступ прямо под серединой балки
	sim.fill_rect(5, 8, 6, 1, WOOD_ID)      # балка 6x1 на y=8, упирается в выступ
	var before: Array = []
	for x in 20:
		if sim.get_cell(x, 8) == WOOD_ID:
			before.append(x)
	for _i in 50:
		sim.step()
	var after: Array = []
	for x in 20:
		if sim.get_cell(x, 8) == WOOD_ID:
			after.append(x)
	_check("балка, упёртая выступом, не падает частично (осталась на месте)",
		before == after, "было %s, стало %s" % [before, after])


func _test_falling_wood_determinism() -> void:
	var a: Object = SAND_SIM.new()
	a.setup(24, 24, _materials())
	a.fill_rect(0, 20, 24, 4, STONE_ID)
	a.fill_rect(6, 4, 8, 3, WOOD_ID)
	var b: Object = SAND_SIM.new()
	b.setup(24, 24, _materials())
	b.fill_rect(0, 20, 24, 4, STONE_ID)
	b.fill_rect(6, 4, 8, 3, WOOD_ID)
	for _i in 100:
		a.step()
		b.step()
	_check("падение дерева детерминировано", a.grid_hash() == b.grid_hash(),
		"hashA=%d hashB=%d" % [a.grid_hash(), b.grid_hash()])


func _test_wood_fall_dirty_rect_matches_full() -> void:
	var opt: Object = SAND_SIM.new()
	opt.setup(24, 24, _materials())
	opt.fill_rect(0, 20, 24, 4, STONE_ID)
	opt.set_cell(12, 19, STONE_ID)  # выступ — балка ляжет неровно/частично
	opt.fill_rect(6, 4, 8, 3, WOOD_ID)

	var full: Object = SAND_SIM.new()
	full.setup(24, 24, _materials())
	full.fill_rect(0, 20, 24, 4, STONE_ID)
	full.set_cell(12, 19, STONE_ID)
	full.fill_rect(6, 4, 8, 3, WOOD_ID)
	full.force_full_scan = true

	var diverged_at := -1
	for i in 200:
		opt.step()
		full.step()
		if opt.grid_hash() != full.grid_hash():
			diverged_at = i
			break
	_check("dirty-rect == полный проход при падении дерева", diverged_at == -1,
		"разошлись на тике %d" % diverged_at)
