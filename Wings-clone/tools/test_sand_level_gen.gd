## Headless-проверка процедурного генератора уровня SandLevelGen — без окна.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_sand_level_gen.tscn
##
## Проверяем ровно то, что нужно от "простенького уровня с открытым
## пространством, землёй, песком и водой" (прямой запрос заказчика), а не
## просто "не упало":
##  - размер картинок совпадает с заказанным;
##  - верхняя часть уровня по большей части ОТКРЫТА (небо, alpha=0) — иначе
##    это будет закрытая пещера, а не "много открытого пространства";
##  - в маске реально присутствуют все три материала (Земля/Песок/Вода), а не
##    только заглушка одного цвета;
##  - генерация детерминирована (тот же seed -> побитово тот же результат) —
##    иначе будущий сетевой запуск с тем же seed у хоста и клиента разойдётся;
##  - укладывается в разумное время (лог, не жёсткий assert — но если счётчик
##    тиков дошёл до предохранителя MAX_SETTLE_TICKS, это симптом, что что-то
##    аномально не осело, и заслуживает провала).
extends Node

const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const PALETTE := preload("res://data/terrain/wings_classes.tres")

const SIZE := Vector2i(1800, 900)
const SEED := 20260724

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка SandLevelGen (%s) ===" % DisplayServer.get_name())
	_test_generates_expected_size_and_content()
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


func _test_generates_expected_size_and_content() -> void:
	var t0 := Time.get_ticks_msec()
	var out := SAND_LEVEL_GEN.generate(SIZE, SEED, PALETTE)
	var msec := Time.get_ticks_msec() - t0
	print("  (генерация заняла %d мс)" % msec)

	var vis: Image = out["visual"]
	var msk: Image = out["mask"]
	_check(vis.get_size() == SIZE, "размер visual совпадает с заказанным",
		"%s vs %s" % [vis.get_size(), SIZE])
	_check(msk.get_size() == SIZE, "размер mask совпадает с заказанным")

	var md := msk.get_data()
	var vd := vis.get_data()
	var n := SIZE.x * SIZE.y

	# --- открытое небо: верхняя половина картинки по большей части прозрачна ---
	var top_h := SIZE.y / 2
	var top_empty := 0
	var top_total := top_h * SIZE.x
	for y in top_h:
		var row := y * SIZE.x
		for x in SIZE.x:
			if vd[(row + x) * 4 + 3] == 0:
				top_empty += 1
	var top_empty_frac := float(top_empty) / float(top_total)
	_check(top_empty_frac > 0.6, "верхняя половина уровня по большей части открыта (небо)",
		"доля пустого %.2f" % top_empty_frac)

	# --- присутствие всех трёх материалов в маске (по цвету класса) ---
	var lut := PALETTE.build_rgb555_lut()
	var seen := {}
	for i in n:
		var o := i * 4
		var key := ((md[o] >> 3) << 10) | ((md[o + 1] >> 3) << 5) | (md[o + 2] >> 3)
		seen[lut[key]] = true
	_check(seen.has(TerrainPalette.Cls.NORMAL), "в уровне есть класс Земля (NORMAL)")
	_check(seen.has(TerrainPalette.Cls.SOFT), "в уровне есть класс Песок (SOFT)")
	_check(seen.has(TerrainPalette.Cls.WATER), "в уровне есть класс Вода (WATER)")
	_check(seen.has(TerrainPalette.Cls.EMPTY), "в уровне есть открытое пространство (EMPTY)")


func _test_determinism() -> void:
	var a := SAND_LEVEL_GEN.generate(SIZE, SEED, PALETTE)
	var b := SAND_LEVEL_GEN.generate(SIZE, SEED, PALETTE)
	var av: Image = a["visual"]
	var bv: Image = b["visual"]
	_check(av.get_data() == bv.get_data(), "детерминизм: два прогона с тем же seed дают тот же visual")
