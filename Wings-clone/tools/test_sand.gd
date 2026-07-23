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
const M_EMPTY := preload("res://data/sand/empty.tres")
const M_SAND := preload("res://data/sand/sand.tres")
const M_STONE := preload("res://data/sand/stone.tres")

const SAND_ID := 1
const STONE_ID := 2

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
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


func _materials() -> Array:
	return [M_EMPTY, M_SAND, M_STONE]


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
