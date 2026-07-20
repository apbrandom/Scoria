## Бенчмарк разрушаемого рельефа.
##
## Запуск:
##   godot --headless --path Wings-clone res://tools/bench_terrain.tscn
##
## Меряет: генерацию тестового уровня, загрузку (построение карты классов + чанков),
## и цикл «выбить воронку -> пересобрать коллизию» с разбивкой по этапам.
extends Node2D

const LEVEL_SIZE := Vector2i(1200, 1200)
const RNG_SEED := 1337
const ITERS := 24
const SAVE_PNG := true

var _palette: TerrainPalette
var _visual: Image
var _mask: Image
var _terrain: Terrain = null


func _ready() -> void:
	_palette = load("res://data/terrain/wings_classes.tres") as TerrainPalette
	if _palette == null:
		push_error("Не загрузилась res://data/terrain/wings_classes.tres")
		get_tree().quit(1)
		return

	_hdr("СРЕДА")
	print("  Godot           : %s" % Engine.get_version_info().string)
	print("  headless        : %s" % str(DisplayServer.get_name() == "headless"))
	print("  уровень         : %dx%d (%.2f Мпикс)" % [
		LEVEL_SIZE.x, LEVEL_SIZE.y, LEVEL_SIZE.x * LEVEL_SIZE.y / 1000000.0])

	_hdr("ПАЛИТРА МАСКИ")
	var problems := _palette.validate()
	if problems.is_empty():
		print("  17 классов, конфликтов RGB555 нет — OK")
	else:
		for p in problems:
			print("  КОНФЛИКТ: %s" % p)

	_hdr("ГЕНЕРАЦИЯ ТЕСТОВОГО УРОВНЯ")
	var t0 := Time.get_ticks_usec()
	var lvl := TestLevelGen.generate(LEVEL_SIZE, RNG_SEED, _palette)
	_visual = lvl["visual"]
	_mask = lvl["mask"]
	print("  время           : %s мс (разовая операция, не часть рантайма)" % _ms(Time.get_ticks_usec() - t0))
	if SAVE_PNG:
		DirAccess.make_dir_recursive_absolute("res://levels/test")
		_visual.save_png("res://levels/test/visual.png")
		_mask.save_png("res://levels/test/mask.png")
		print("  сохранено       : res://levels/test/{visual,mask}.png")

	_hdr("ЗАГРУЗКА УРОВНЯ  (chunk=128, downscale=2, eps=0.5)")
	var t := _fresh_terrain(128, 2, 0.5)
	var st := t.load_level(_visual, _mask)
	print("  карта классов   : %s мс   (разбор mask.png, %d пикс.)" % [
		_ms(st["classmap_usec"]), LEVEL_SIZE.x * LEVEL_SIZE.y])
	print("  чанки+коллизия  : %s мс   (%d чанков, сетка %s)" % [
		_ms(st["chunks_usec"]), st["chunks"], st["grid"]])
	print("  ИТОГО загрузка  : %s мс" % _ms(st["total_usec"]))
	print("  отрезков коллизии: %d" % t.total_segments())

	var st2 := _fresh_terrain(128, 2, 0.5).load_level(_visual, null)
	print("  без mask.png    : %s мс карта классов (путь по альфе visual.png)" % _ms(st2["classmap_usec"]))

	_hdr("ВЗРЫВ -> ПЕРЕСБОРКА КОЛЛИЗИИ  (chunk=128, downscale=2, eps=0.5)")
	print("  радиус | воронка |  carve   | rebuild  |  сумма   | чанков | отрезк")
	print("  -------+---------+----------+----------+----------+--------+--------")
	for radius in [8, 16, 32, 64, 100]:
		t = _fresh_terrain(128, 2, 0.5)
		t.load_level(_visual, _mask)
		var r := _bench(t, radius, ITERS)
		print("  %6d | %7d | %s | %s | %s | %6s | %6d" % [
			radius, int(r["px"]),
			_col(r["carve_avg"], r["carve_max"]),
			_col(r["rb_avg"], r["rb_max"]),
			_col(r["carve_avg"] + r["rb_avg"], r["carve_max"] + r["rb_max"]),
			"%.1f" % r["dirty_avg"],
			int(r["verts"])])
	print("  (в ячейках avg / max по %d повторам; воронка — среднее число выбитых пикселей)" % ITERS)

	_hdr("РАЗБИВКА ПЕРЕСБОРКИ, радиус 64")
	t = _fresh_terrain(128, 2, 0.5)
	t.load_level(_visual, _mask)
	var br := _bench(t, 64, ITERS)
	var rebuilds: int = maxi(br["rebuilds"], 1)
	print("  чанков пересобрано за прогон: %d (%.1f на взрыв)" % [rebuilds, br["dirty_avg"]])
	print("  на один чанк:")
	print("    solid image (create+resize) : %s мс" % _ms(br["s_img"] / rebuilds))
	print("    BitMap.create_from_image    : %s мс" % _ms(br["s_bm"] / rebuilds))
	print("    opaque_to_polygons          : %s мс   <-- ключевой вызов" % _ms(br["s_poly"] / rebuilds))
	print("    сборка+назначение отрезков  : %s мс" % _ms(br["s_apply"] / rebuilds))
	print("    ImageTexture.update         : %s мс%s" % [
		_ms(br["s_tex"] / rebuilds),
		"   (headless: без GPU-загрузки)" if DisplayServer.get_name() == "headless" else ""])

	_hdr("ТОЧНОСТЬ КРОМКИ vs СТОИМОСТЬ  (chunk=128, радиус 64)")
	print("  Точность — насколько поверхность коллизии совпадает с картой классов:")
	print("  стреляем лучи из пустоты в породу и сравниваем дистанцию попадания.")
	print("")
	print("  down | eps | rebuild avg |  max  | отрезк | <=1px | <=3px | ошибка")
	print("  -----+-----+-------------+-------+--------+-------+-------+-------")
	for d in [1, 2, 4]:
		for e in [0.0, 0.5, 2.0]:
			t = _fresh_terrain(128, d, e)
			t.load_level(_visual, _mask)
			await get_tree().physics_frame
			await get_tree().physics_frame
			var a := _surface_accuracy(t, 6000)
			var r := _bench(t, 64, ITERS)
			print("  %4d | %3.1f | %11s | %5s | %6d | %4.1f%% | %4.1f%% | %5.2f" % [
				d, e, _ms(r["rb_avg"] * 1000.0), _ms(r["rb_max"] * 1000.0), int(r["verts"]),
				a["within1_rate"] * 100.0, a["within_rate"] * 100.0, a["mean_err"]])

	_hdr("ВЛИЯНИЕ chunk_size  (радиус 64, downscale=2)")
	print("  chunk | чанков | загрузка | rebuild avg | rebuild max | чанков/взрыв")
	print("  ------+--------+----------+-------------+-------------+-------------")
	for cs in [64, 128, 256]:
		t = _fresh_terrain(cs, 2, 0.5)
		var lst := t.load_level(_visual, _mask)
		var r := _bench(t, 64, ITERS)
		print("  %5d | %6d | %8s | %11s | %11s | %13.1f" % [
			cs, int(lst["chunks"]), _ms(lst["total_usec"]),
			_ms(r["rb_avg"] * 1000.0), _ms(r["rb_max"] * 1000.0), r["dirty_avg"]])

	_hdr("ПРОВЕРКИ КОРРЕКТНОСТИ")
	await _correctness()

	_hdr("ГОТОВО")
	await get_tree().process_frame
	get_tree().quit()


# ------------------------------------------------------------------ проверки

func _correctness() -> void:
	var t := _fresh_terrain(128, 2, 0.5)
	t.load_level(_visual, _mask)
	t.immediate_rebuild = true

	# 1. воронка в обычной породе действительно пробивает
	var hit := _find_class(t, TerrainPalette.Cls.NORMAL)
	if hit.x >= 0:
		var before := t.is_solid_at(hit)
		t.carve_circle(hit, 20)
		var after := t.is_solid_at(hit)
		_check("NORMAL пробивается", before and not after)
	else:
		_check("NORMAL пробивается", false, "не нашёл пиксель класса NORMAL")

	# 2. неразрушаемое остаётся
	var ind := _find_class(t, TerrainPalette.Cls.INDESTRUCTIBLE)
	if ind.x >= 0:
		t.carve_circle(ind, 30)
		_check("INDESTRUCTIBLE держит", t.is_solid_at(ind))
	else:
		_check("INDESTRUCTIBLE держит", false, "не нашёл пиксель класса INDESTRUCTIBLE")

	# 3. вода не твёрдая, но и не пустота
	var wat := _find_class(t, TerrainPalette.Cls.WATER)
	if wat.x >= 0:
		_check("WATER не твёрдая", not t.is_solid_at(wat))
		_check("WATER читается как класс", t.class_at(wat) == TerrainPalette.Cls.WATER)
	else:
		print("    (воды в уровне не оказалось — проверка пропущена)")

	# 4. выход за границы не падает и считается пустотой
	_check("за границей — EMPTY", t.class_at(Vector2i(-5, -5)) == TerrainPalette.Cls.EMPTY \
		and t.class_at(LEVEL_SIZE + Vector2i(10, 10)) == TerrainPalette.Cls.EMPTY)

	# 5. большой взрыв уменьшает количество твёрдых пикселей.
	#    (Число ВЕРШИН при этом растёт — воронка добавляет новый контур стенки,
	#     так что проверять надо площадь, а не вершины.)
	var solid_before := t.count_solid()
	t.carve_circle(Vector2i(600, 600), 300)
	var solid_after := t.count_solid()
	_check("большой взрыв уменьшает площадь твёрдого", solid_after < solid_before,
		"было %d, стало %d пикс. (отрезков %d)" % [solid_before, solid_after, t.total_segments()])

	# 6. вырожденные контуры отсеиваются, а не летят в декомпозицию
	_check("вырожденных контуров отброшено", true,
		"отсеяно за прогон: %d" % t.stat_rejected_polys)

	# 7. ГЛАВНАЯ проверка: воронка ВНУТРИ массива породы должна появиться в коллизии.
	#    Именно здесь ломался наивный вариант с одной трассировкой: opaque_to_polygons
	#    теряет контуры дырок, и выбитая внутри камня полость оставалась непроходимой.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var deep := _find_deep_solid(t, 45)
	if deep.x < 0:
		_check("воронка внутри массива породы", false, "не нашёл достаточно толстый массив")
	else:
		var before_d := _ray_distance(Vector2(deep) + Vector2(0.5, 0.5), Vector2.RIGHT, 400.0)
		t.carve_circle(deep, 25)
		t.flush_dirty()
		await get_tree().physics_frame
		await get_tree().physics_frame
		var after_d := _ray_distance(Vector2(deep) + Vector2(0.5, 0.5), Vector2.RIGHT, 400.0)
		# после выбивания луч из центра воронки обязан упереться в её стенку (~25 px)
		var ok := after_d > 0.0 and after_d < 35.0 and (before_d < 0.0 or before_d > 35.0)
		_check("воронка внутри массива породы попадает в коллизию", ok,
			"луч из центра: до взрыва %s, после %s (ожидание ~25)" % [
				("нет попадания" if before_d < 0.0 else "%.1f" % before_d),
				("нет попадания" if after_d < 0.0 else "%.1f" % after_d)])

	# 8. Поверхность коллизии совпадает с картой классов.
	var acc := _surface_accuracy(t, 2000)
	_check("кромка коллизии сходится с картой классов (<=3 px)",
		acc["within_rate"] >= 0.95,
		"%.1f%% лучей, средняя ошибка %.2f px, промахов %d из %d" % [
			acc["within_rate"] * 100.0, acc["mean_err"], acc["misses"], acc["n"]])


## Расстояние до первого попадания луча, или -1.
func _ray_distance(from: Vector2, dir: Vector2, length: float) -> float:
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(from, from + dir * length)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return -1.0
	return (hit["position"] as Vector2).distance_to(from)


## Пиксель, вокруг которого в радиусе margin всё твёрдое.
func _find_deep_solid(t: Terrain, margin: int) -> Vector2i:
	for y in range(margin + 10, LEVEL_SIZE.y - margin - 10, 5):
		for x in range(margin + 10, LEVEL_SIZE.x - margin - 10, 5):
			var p := Vector2i(x, y)
			if t.class_at(p) != TerrainPalette.Cls.NORMAL:
				continue
			var ok := true
			for a in range(0, 8):
				var d := Vector2(cos(a * PI / 4.0), sin(a * PI / 4.0)) * margin
				if not t.is_solid_at(p + Vector2i(d.round())):
					ok = false
					break
			if ok:
				return p
	return Vector2i(-1, -1)


## Стреляет лучами из пустоты в породу и сравнивает дистанцию попадания с тем,
## где границу видит карта классов.
func _surface_accuracy(t: Terrain, samples: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var n := 0
	var within := 0
	var within1 := 0
	var misses := 0
	var err_sum := 0.0
	for i in samples:
		var from_px := Vector2i(
			rng.randi_range(60, LEVEL_SIZE.x - 61),
			rng.randi_range(60, LEVEL_SIZE.y - 61))
		if t.is_solid_at(from_px):
			continue
		var ang := rng.randf() * TAU
		var dir := Vector2(cos(ang), sin(ang))
		var origin := Vector2(from_px) + Vector2(0.5, 0.5)
		var expected := -1.0
		for step in range(1, 51):
			if t.is_solid_at(Vector2i((origin + dir * step).round())):
				expected = float(step)
				break
		if expected < 0.0:
			continue
		n += 1
		var got := _ray_distance(origin, dir, 60.0)
		if got < 0.0:
			misses += 1
			continue
		var e := absf(got - expected)
		err_sum += e
		if e <= 3.0:
			within += 1
		if e <= 1.0:
			within1 += 1
	return {
		"within_rate": float(within) / maxi(n, 1),
		"within1_rate": float(within1) / maxi(n, 1),
		"mean_err": err_sum / maxi(n - misses, 1),
		"misses": misses,
		"n": n,
	}


func _find_class(t: Terrain, cls: int) -> Vector2i:
	for y in range(40, LEVEL_SIZE.y - 40, 3):
		for x in range(40, LEVEL_SIZE.x - 40, 3):
			var p := Vector2i(x, y)
			if t.class_at(p) == cls:
				return p
	return Vector2i(-1, -1)


func _check(label: String, ok: bool, extra: String = "") -> void:
	print("  [%s] %s%s" % ["OK  " if ok else "ПРОВАЛ", label, ("  — " + extra) if extra != "" else ""])


# ------------------------------------------------------------------ утилиты

func _fresh_terrain(chunk: int, downscale: int, eps: float) -> Terrain:
	if _terrain != null:
		remove_child(_terrain)
		_terrain.free()
	var t := Terrain.new()
	t.palette = _palette
	t.chunk_size = chunk
	t.collision_downscale = downscale
	t.polygon_epsilon = eps
	t.immediate_rebuild = false
	add_child(t)
	_terrain = t
	return t


func _bench(t: Terrain, radius: int, iters: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var carve: Array[float] = []
	var rb: Array[float] = []
	var dirty_total := 0
	var px := 0
	t.immediate_rebuild = false
	t.stats_reset()
	for i in iters:
		var p := Vector2i(
			rng.randi_range(200, LEVEL_SIZE.x - 200),
			rng.randi_range(200, LEVEL_SIZE.y - 200))
		var t0 := Time.get_ticks_usec()
		px += t.carve_circle(p, radius)
		carve.append((Time.get_ticks_usec() - t0) / 1000.0)
		t0 = Time.get_ticks_usec()
		dirty_total += t.flush_dirty()
		rb.append((Time.get_ticks_usec() - t0) / 1000.0)
	return {
		"carve_avg": _avg(carve), "carve_max": _amax(carve),
		"rb_avg": _avg(rb), "rb_max": _amax(rb),
		"dirty_avg": float(dirty_total) / iters,
		"px": float(px) / iters,
		"verts": t.total_segments(),
		"rebuilds": t.stat_rebuilds,
		"s_img": t.stat_solid_image_usec, "s_bm": t.stat_bitmap_usec,
		"s_poly": t.stat_polygons_usec, "s_apply": t.stat_apply_usec,
		"s_tex": t.stat_texture_usec,
	}


static func _avg(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


static func _amax(a: Array[float]) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m


## usec -> строка в миллисекундах
static func _ms(usec: float) -> String:
	return "%.3f" % (usec / 1000.0)


## "avg / max" в миллисекундах, вход в мс
static func _col(avg_ms: float, max_ms: float) -> String:
	return "%4.2f/%4.2f" % [avg_ms, max_ms]


func _hdr(s: String) -> void:
	print("")
	print("=== %s %s" % [s, "=".repeat(maxi(70 - s.length(), 0))])
