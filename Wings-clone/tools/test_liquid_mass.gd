## Headless-проверка ПРОТОТИПА жидкости на модели массы (LiquidMassSim) — без окна.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_liquid_mass.tscn
##
## Проверяем ровно то, ради чего этот прототип и заведён — свойства, которых
## принципиально НЕ может дать бинарный SandSim (см. notes/terrain_research.md,
## раздел «вода — холм, не плоское озеро»):
##  - СОХРАНЕНИЕ МАССЫ ровно (целочисленно, без потерь на околонулевых клетках);
##  - ВЫРАВНИВАНИЕ В ПЛОСКОСТЬ на ровном дне (все колонки — равная масса);
##  - СООБЩАЮЩИЕСЯ СОСУДЫ: залили воду только слева — она поднимается СПРАВА до
##    того же уровня (переток вверх под давлением; бинарное правило так не умеет);
##  - ДЕТЕРМИНИЗМ: тот же старт + число тиков -> побитово равные массивы (нужно
##    для будущего сетевого replay; тут даже сильнее, чем у SandSim — вообще нет
##    случайности, только целочисленная арифметика).
extends Node

const LIQUID_SIM := preload("res://tools/liquid_mass_sim.gd")

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка прототипа жидкости на массе (LiquidMassSim, %s) ===" % DisplayServer.get_name())
	_test_mass_conservation()
	_test_levels_flat_on_flat_floor()
	_test_communicating_vessels_rise_on_far_side()
	_test_determinism()
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(cond: bool, name: String, extra: String = "") -> void:
	if cond:
		_pass += 1
		print("  [OK] %s" % name)
	else:
		_fail += 1
		print("  [ПРОВАЛ] %s%s" % [name, ("  — " + extra) if extra != "" else ""])


## Рамка-«коробка» по периметру: стенки не пропускают воду наружу.
func _make_box(sim: RefCounted, w: int, h: int) -> void:
	sim.setup(w, h)
	for x in w:
		sim.set_solid(x, 0, true)
		sim.set_solid(x, h - 1, true)
	for y in h:
		sim.set_solid(0, y, true)
		sim.set_solid(w - 1, y, true)


func _test_mass_conservation() -> void:
	var sim := LIQUID_SIM.new()
	_make_box(sim, 30, 24)
	# налить неровный объём в несколько колонок — специально несимметрично
	for x in range(5, 12):
		for y in range(3, 10):
			sim.add_mass(x, y, sim.MAX_MASS)
	sim.add_mass(20, 4, sim.MAX_MASS * 3)  # переполненная клетка — проверить сжатие
	var before := sim.total_mass()
	for _t in 2000:
		sim.step()
	var after := sim.total_mass()
	_check(before == after, "масса сохраняется ровно за 2000 тиков",
		"было %d, стало %d" % [before, after])


func _test_levels_flat_on_flat_floor() -> void:
	var w := 40
	var h := 30
	var sim := LIQUID_SIM.new()
	_make_box(sim, w, h)
	# налить компактную кучу у центра сверху — должна растечься в ровный слой
	var total_cells := 0
	for x in range(15, 25):
		for y in range(3, 15):
			sim.add_mass(x, y, sim.MAX_MASS)
			total_cells += 1
	for _t in 4000:
		sim.step()
	# в равновесии на ровном дне масса каждой ВНУТРЕННЕЙ колонки должна быть
	# почти одинакова (плоская поверхность). Считаем разброс.
	var lo := 1 << 62
	var hi := -1
	for x in range(1, w - 1):
		var cm := sim.column_mass(x)
		lo = mini(lo, cm)
		hi = maxi(hi, cm)
	var spread := hi - lo
	# допуск: в пределах массы одной клетки на колонку (верхний слой у колонок
	# может отличаться на неполную клетку — это и есть «плоско»).
	_check(spread <= sim.MAX_MASS, "вода выравнивается в плоскость (разброс колонок ≤ 1 клетки)",
		"разброс %d при MAX_MASS %d" % [spread, sim.MAX_MASS])


func _test_communicating_vessels_rise_on_far_side() -> void:
	var w := 40
	var h := 30
	var sim := LIQUID_SIM.new()
	_make_box(sim, w, h)
	# перегородка по центру, НЕ доходящая до дна: зазор снизу соединяет камеры.
	for y in range(1, 26):
		sim.set_solid(20, y, true)  # стена y=1..25, дно h-1=29, открыто y=26..28
	# налить воду ТОЛЬКО в левую камеру
	for x in range(3, 18):
		for y in range(6, 25):
			sim.add_mass(x, y, sim.MAX_MASS)
	for _t in 6000:
		sim.step()
	var thr := sim.MAX_MASS / 2  # «клетка залита», если массы хотя бы полклетки
	var left_top := sim.water_top_row(10, thr)   # верх воды слева
	var right_top := sim.water_top_row(30, thr)  # верх воды справа
	# справа изначально было СУХО. Успех = справа реально поднялась вода (не у дна)
	# и её уровень совпал с левым в пределах пары клеток.
	var right_has_water := right_top < h - 3
	var levels_match := absi(left_top - right_top) <= 2
	_check(right_has_water and levels_match,
		"сообщающиеся сосуды: вода поднялась справа до уровня слева",
		"верх слева y=%d, верх справа y=%d" % [left_top, right_top])


func _test_determinism() -> void:
	var a := _run_scenario()
	var b := _run_scenario()
	var same := a == b  # PackedInt32Array сравнивается поэлементно
	_check(same, "детерминизм: два прогона дают побитово равные массивы")


## Сценарий для теста детерминизма — тот же старт, фиксированное число тиков.
func _run_scenario() -> PackedInt32Array:
	var sim := LIQUID_SIM.new()
	_make_box(sim, 32, 24)
	for x in range(4, 20):
		for y in range(3, 12):
			sim.add_mass(x, y, sim.MAX_MASS)
	sim.add_mass(25, 5, sim.MAX_MASS * 2)
	for _t in 1500:
		sim.step()
	var out := PackedInt32Array()
	out.resize(32 * 24)
	for y in 24:
		for x in 32:
			out[y * 32 + x] = sim.get_mass(x, y)
	return out
