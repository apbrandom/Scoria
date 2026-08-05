## Замер: из чего складывается пауза при заходе в уровень.
##
## Заказчик: «кажется, что игра зависает» — между кликом в меню и первым кадром
## уровня Level._ready() делает всю работу подряд, и окно всё это время не
## перерисовывается. Прежде чем рисовать полосу загрузки, надо знать ЧЕМ она
## должна заполняться: если 95% времени — один неделимый вызов, полоса будет
## врать (застрянет на одном месте и всё равно будет выглядеть зависанием).
##
## Меряем ровно те фазы, которые Level._ready() выполняет по порядку.
extends Node

const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const LIVE_SAND := preload("res://scripts/level/live_sand.gd")
const PALETTE_PATH := "res://data/terrain/wings_classes.tres"
## Тот же размер, что в реальной игре (scenes/level/level.gd).
const LEVEL_SIZE := Vector2i(2700, 1350)
## Фиксированный seed — замер должен быть сравнимым между прогонами.
const SEED := 1337


func _ready() -> void:
	var palette := load(PALETTE_PATH) as TerrainPalette

	var t_all := Time.get_ticks_usec()

	var t0 := Time.get_ticks_usec()
	var built := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, SEED)
	var us_sim := Time.get_ticks_usec() - t0

	var sim = built["sim"]
	var grid: Vector2i = built["grid"]

	t0 = Time.get_ticks_usec()
	var baked := SAND_LEVEL_GEN.bake_images(sim, grid.x, grid.y, LEVEL_SIZE, palette,
		built["seed_used"], SAND_LEVEL_GEN.DEFAULT_RULES)
	var us_bake := Time.get_ticks_usec() - t0

	var terrain := Terrain.new()
	terrain.palette = palette
	terrain.immediate_rebuild = false
	add_child(terrain)

	t0 = Time.get_ticks_usec()
	var load_stats := terrain.load_level(baked["visual"], baked["mask"])
	var us_terrain := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var live := LIVE_SAND.new()
	var live_on: bool = live.settings.enabled
	if live_on:
		add_child(live)
		live.setup(terrain, sim, grid, SAND_LEVEL_GEN.DEFAULT_RULES.cell_px, built["seed_used"])
	else:
		live.free()
	var us_live := Time.get_ticks_usec() - t0

	var us_all := Time.get_ticks_usec() - t_all

	print("=== Цена захода в уровень (%dx%d, seed %d) ===" % [
		LEVEL_SIZE.x, LEVEL_SIZE.y, SEED])
	_row("SandSim: генерация+оседание+базы", us_sim, us_all)
	_row("Запекание visual/mask", us_bake, us_all)
	_row("Terrain.load_level (чанки+коллизия)", us_terrain, us_all)
	_row("LiveSand.setup" + ("" if live_on else " (выключен)"), us_live, us_all)
	print("  ─────────────────────────────────────────")
	print("  ИТОГО: %.0f мс" % (us_all / 1000.0))
	print("")
	print("  попыток seed'а: %d, тиков оседания: %d" % [built["attempts"], built["settle_ticks"]])
	print("  внутри load_level: карта классов %.0f мс, чанки %.0f мс (%d шт, %s)" % [
		load_stats["classmap_usec"] / 1000.0, load_stats["chunks_usec"] / 1000.0,
		load_stats["chunks"], load_stats["grid"]])

	terrain.queue_free()
	if live_on:
		live.queue_free()
	await _measure_real_load()
	get_tree().quit(0)


## Главная проверка смысла экрана загрузки: во время сборки уровня главный поток
## обязан РЕГУЛЯРНО отдавать управление, иначе рисовать полосу некому и она
## бессмысленна. Меряем самую длинную паузу между кадрами — это и есть то, что
## игрок воспринимает как «подвисло».
func _measure_real_load() -> void:
	print("\n=== Настоящая загрузка level.tscn: паузы между кадрами ===")
	var level: Node = load("res://scenes/level/level.tscn").instantiate()
	add_child(level)

	var gaps: Array[float] = []
	var last := Time.get_ticks_usec()
	var t_start := last
	while not level.is_world_ready():
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		gaps.append((now - last) / 1000.0)
		last = now

	var worst := 0.0
	var over_100 := 0
	for g in gaps:
		worst = maxf(worst, g)
		if g > 100.0:
			over_100 += 1

	print("  кадров за загрузку: %d" % gaps.size())
	print("  общее время: %.0f мс" % ((Time.get_ticks_usec() - t_start) / 1000.0))
	print("  САМАЯ ДЛИННАЯ пауза без кадра: %.0f мс" % worst)
	print("  пауз длиннее 100 мс: %d" % over_100)
	print("  (до правки таких кадров не было вообще — одна пауза на всю загрузку)")
	level.queue_free()


func _row(label: String, usec: int, total_usec: int) -> void:
	var pct := 100.0 * usec / maxf(total_usec, 1.0)
	print("  %-38s %7.0f мс  %5.1f%%" % [label, usec / 1000.0, pct])
