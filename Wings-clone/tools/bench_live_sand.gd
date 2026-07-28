## Замер: сколько стоит ЖИВОЙ тик SandSim на РЕАЛЬНОМ игровом уровне.
## Это go/no-go для всей затеи "живая клеточная физика в геймплее": весь расчёт
## идёт на CPU в GDScript, и если тик после взрыва стоит больше бюджета кадра
## (16.6 мс при 60 FPS), живой режим невозможен без переноса ядра в
## C++/GDExtension (Милстоун 2 roadmap.md) — тогда честнее это измерить и
## сказать, чем строить мост поверх заведомо неподъёмной цены.
##
## Все прогоны ОГРАНИЧЕНЫ по числу тиков, а не идут "до покоя". Первая версия
## бенча крутила while sim.is_active() и не завершилась за 5 минут — и это само
## по себе находка, а не случайность: вода с edge_creep_chance принципиально не
## обязана уснуть НАВСЕГДА (см. большой комментарий над SandSim._step_liquid —
## заведомо принятый компромисс), поэтому "тикать до покоя" на уровне с озёрами
## может не закончиться никогда. Для живого режима важна не сходимость, а цена
## одного тика и то, во что она упирается.
##
## Запуск: godot --headless --path Wings-clone res://tools/bench_live_sand.tscn
extends Node

const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const RULES := preload("res://data/level/default_gen.tres")

## Тот же размер, что у боевого уровня (level.gd::SAND_LEVEL_SIZE) — мерить надо
## на реальном масштабе, на игрушечном поле любая клеточная симуляция быстрая.
const LEVEL_SIZE := Vector2i(2700, 1350)
const LEVEL_SEED := 1337

## Радиусы воронок в ПИКСЕЛЯХ рельефа — как у настоящего оружия
## (data/weapons/*.tres: dumbfire ~6, bomb ~46 terrain_power/blast_radius).
const CRATER_PX_SMALL := 6
const CRATER_PX_BIG := 46

## Бюджет кадра при 60 FPS, мкс — с ним сравниваем результат.
const FRAME_BUDGET_USEC := 16666


func _ready() -> void:
	print("=== Бенч живого тика SandSim (%s) ===" % DisplayServer.get_name())
	print("Уровень %dx%d px, cell_px=%d" % [LEVEL_SIZE.x, LEVEL_SIZE.y, RULES.cell_px])

	var t0 := Time.get_ticks_usec()
	var built := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, LEVEL_SEED, RULES)
	var gen_usec := Time.get_ticks_usec() - t0
	var sim = built["sim"]
	var grid: Vector2i = built["grid"]
	print("Сетка %dx%d = %d клеток" % [grid.x, grid.y, grid.x * grid.y])
	print("Генерация: %.0f мс, попыток seed'а %d, оседание %d тиков" % [
		gen_usec / 1000.0, built["attempts"], built["settle_ticks"]])
	print("Играбельность: ok=%s %s" % [built["report"]["ok"], built["report"]["stats"]])
	print("Состояние сразу после генерации: is_active=%s" % sim.is_active())

	_bench_idle(sim)
	_bench_crater(sim, CRATER_PX_SMALL, "пулемёт", 200)
	_bench_crater(sim, CRATER_PX_BIG, "бомба", 400)
	# Полный скан — ПОСЛЕДНИМ: он трогает всё поле и портит состояние для
	# остальных замеров (после него dirty-rect уже не локальный).
	_bench_full_scan(sim)

	print("\n(бюджет кадра при 60 FPS = %.1f мс)" % (FRAME_BUDGET_USEC / 1000.0))
	get_tree().quit(0)


## 1. Холостой ход — сколько стоит тик, когда всё улеглось, и УЛЕГЛОСЬ ЛИ.
## Второе не менее важно первого: если осевший уровень сам по себе остаётся
## активным (вода), живой режим платит за него каждый кадр, ничего не показывая.
func _bench_idle(sim) -> void:
	var n := 300
	var active_ticks := 0
	var max_area := 0
	var t0 := Time.get_ticks_usec()
	for _i in n:
		sim.step()
		if sim.is_active():
			active_ticks += 1
			var r: Rect2i = sim.get_dirty_rect()
			max_area = maxi(max_area, r.size.x * r.size.y)
	var usec := Time.get_ticks_usec() - t0
	print("\n[холостой] %d тиков осевшего уровня: %.3f мс/тик" % [n, usec / 1000.0 / n])
	print("  активных тиков: %d из %d · макс. грязная площадь: %d клеток" % [
		active_ticks, n, max_area])


## 3. Потолок: полный скан всего поля (dirty-rect отключён).
func _bench_full_scan(sim) -> void:
	sim.force_full_scan = true
	var n := 5
	var t0 := Time.get_ticks_usec()
	for _i in n:
		sim.step()
	var usec := Time.get_ticks_usec() - t0
	sim.force_full_scan = false
	var per := usec / 1000.0 / n
	print("\n[полный скан] %.2f мс/тик  -> %s" % [
		per, "влезает в кадр" if per * 1000.0 < FRAME_BUDGET_USEC else "НЕ влезает в кадр"])


## 2. Реальная нагрузка: выбить воронку радиусом radius_px и тикать max_ticks раз.
func _bench_crater(sim, radius_px: int, label: String, max_ticks: int) -> void:
	var grid_r := maxi(radius_px / RULES.cell_px, 1)
	# Бьём в поверхность рельефа примерно в середине уровня — там есть что осыпать.
	# Явный тип: `sim` намеренно без аннотации (см. sand_level_gen.gd про
	# class_name), поэтому sim.width для компилятора — Variant, и := не выводится.
	var cx: int = int(sim.width) / 2
	var cy := _find_surface_row(sim, cx)
	if cy < 0:
		print("\n[%s] не нашёл поверхности в колонке %d — пропуск" % [label, cx])
		return

	var cleared := _clear_circle(sim, cx, cy, grid_r)

	var first_usec := 0
	var peak_usec := 0
	var total_usec := 0
	var settled_at := -1
	var max_area := 0
	for i in max_ticks:
		var t0 := Time.get_ticks_usec()
		sim.step()
		var dt := Time.get_ticks_usec() - t0
		if i == 0:
			first_usec = dt
		peak_usec = maxi(peak_usec, dt)
		total_usec += dt
		if sim.is_active():
			var r: Rect2i = sim.get_dirty_rect()
			max_area = maxi(max_area, r.size.x * r.size.y)
		elif settled_at < 0:
			settled_at = i + 1

	print("\n[%s] воронка r=%d px (%d клеток, стёрто %d) в (%d,%d):" % [
		label, radius_px, grid_r, cleared, cx, cy])
	print("  первый тик: %.3f мс · пиковый: %.3f мс · средний: %.3f мс (за %d тиков)" % [
		first_usec / 1000.0, peak_usec / 1000.0, total_usec / 1000.0 / max_ticks, max_ticks])
	print("  осел на тике: %s · макс. грязная площадь: %d клеток" % [
		settled_at if settled_at > 0 else "не осел", max_area])
	print("  вердикт по пику: %s" % [
		"влезает в кадр" if peak_usec < FRAME_BUDGET_USEC else "НЕ влезает — нужен бюджет тиков/кадр"])


## Верхняя непустая клетка колонки — "поверхность" рельефа.
func _find_surface_row(sim, x: int) -> int:
	for y in sim.height:
		if sim.get_cell(x, y) != 0:
			return y
	return -1


func _clear_circle(sim, cx: int, cy: int, r: int) -> int:
	var n := 0
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			var dx := x - cx
			var dy := y - cy
			if dx * dx + dy * dy <= r * r and sim.get_cell(x, y) != 0:
				sim.set_cell(x, y, 0)
				n += 1
	return n
