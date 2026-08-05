## Порционная сборка уровня (LevelBuildJob) — то, на чём стоит полоса загрузки.
##
## Главная проверка здесь одна и она же самая важная: нарезка на порции НЕ
## меняет результат. Уровень обязан получаться бит-в-бит одинаковым независимо
## от того, собрали его одним куском или за сто шагов по 5 мс — иначе в сетевом
## матче хост и клиент разъедутся по рельефу просто потому, что у них разный
## FPS (architecture.md → «Сеть: модель синхронизации»).
##
## Запуск: godot --headless --path Wings-clone res://tools/test_loading.tscn
extends Node

const JOB := preload("res://scripts/level/level_build_job.gd")
const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const PALETTE_PATH := "res://data/terrain/wings_classes.tres"

## Меньше боевого 2700x1350: проверяемое свойство (нарезка не меняет результат)
## от размера не зависит, а прогон делает несколько полных сборок подряд —
## на боевом размере тест стоил бы минуту вместо секунд. Полный размер уже
## закрыт отдельно в test_sand_level_gen.gd и test_sand_level_boot.gd.
const SIZE := Vector2i(1200, 600)
const SEED := 20260731

var _pass := 0
var _fail := 0
var _palette: TerrainPalette


func _ready() -> void:
	print("=== Проверка порционной сборки уровня (LevelBuildJob) ===")
	_palette = load(PALETTE_PATH) as TerrainPalette
	_test_slicing_is_transparent()
	_test_progress_is_sane()
	_test_sim_only_mode()
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


## Собирает уровень мелкими порциями и возвращает job + число сделанных шагов.
func _build_sliced(budget_usec: int) -> Array:
	var job := JOB.new()
	job.setup(SIZE, SEED, _palette)
	var steps := 0
	# Предохранитель: если step() перестанет двигать состояние, тест обязан
	# упасть по счётчику, а не висеть вечно (headless некому прервать).
	while not job.is_done() and steps < 100000:
		job.step(budget_usec)
		steps += 1
	return [job, steps]


func _test_slicing_is_transparent() -> void:
	print("\n-- нарезка не меняет результат --")

	var whole := JOB.new()
	whole.setup(SIZE, SEED, _palette)
	whole.step(0)  # 0 = без ограничения, всё за один вызов
	var a := whole.result()

	var sliced_pair := _build_sliced(2000)  # 2 мс на шаг — заведомо мельче фазы
	var job = sliced_pair[0]
	var steps: int = sliced_pair[1]
	var b: Dictionary = job.result()

	_check("порционная сборка вообще дошла до конца", job.is_done())
	_check("сборка реально разбилась на много шагов (а не схлопнулась в один)",
		steps > 10, "шагов: %d" % steps)

	var va: Image = a["visual"]
	var vb: Image = b["visual"]
	_check("visual бит-в-бит совпадает с несегментированной сборкой",
		va.get_data() == vb.get_data(),
		"размеры: %s против %s" % [va.get_size(), vb.get_size()])

	var ma: Image = a["mask"]
	var mb: Image = b["mask"]
	_check("mask бит-в-бит совпадает", ma.get_data() == mb.get_data())

	_check("выбран тот же seed", a["seed_used"] == b["seed_used"],
		"%d против %d" % [a["seed_used"], b["seed_used"]])
	_check("столько же попыток перебора", a["attempts"] == b["attempts"],
		"%d против %d" % [a["attempts"], b["attempts"]])
	_check("базы встали в те же точки", a["bases"] == b["bases"],
		"%s против %s" % [a["bases"], b["bases"]])

	# Та же проверка со стороны публичного входа: SandLevelGen.generate() теперь
	# сам крутит job, и его результат обязан совпасть с ручной сборкой.
	var via_api := SAND_LEVEL_GEN.generate(SIZE, SEED, _palette)
	var vc: Image = via_api["visual"]
	_check("SandLevelGen.generate() даёт тот же уровень",
		vc.get_data() == va.get_data())

	# Разный размер порции — разное число шагов, но результат обязан совпасть:
	# именно это ломается, если в порционный код просочится зависимость от
	# того, где именно прошла граница шага.
	var coarse_pair := _build_sliced(20000)  # 20 мс на шаг
	var coarse: Dictionary = coarse_pair[0].result()
	var vd: Image = coarse["visual"]
	_check("другой размер порции — тот же результат", vd.get_data() == va.get_data(),
		"шагов: %d против %d" % [coarse_pair[1], steps])


func _test_progress_is_sane() -> void:
	print("\n-- прогресс годится для полосы загрузки --")

	var job := JOB.new()
	job.setup(SIZE, SEED, _palette)

	var start := job.progress()
	_check("в начале прогресс не отрицательный и не полный",
		start >= 0.0 and start < 1.0, "progress=%.3f" % start)
	_check("до конца работы is_done() == false", not job.is_done())

	var prev := start
	var monotonic := true
	var in_range := true
	var phases := {}
	var steps := 0
	while not job.is_done() and steps < 100000:
		job.step(2000)
		steps += 1
		var p := job.progress()
		if p < prev - 0.0001:
			monotonic = false
		if p < 0.0 or p > 1.0:
			in_range = false
		prev = p
		phases[job.phase_text()] = true

	_check("прогресс не убывает по ходу сборки", monotonic)
	_check("прогресс всё время в пределах 0..1", in_range)
	_check("в конце прогресс ровно 1.0", is_equal_approx(job.progress(), 1.0),
		"progress=%.3f" % job.progress())
	# Подпись под полосой обязана меняться: одна и та же строка на все 3 секунды
	# читается как затык ровно так же, как неподвижная полоса.
	_check("подпись фазы менялась по ходу сборки", phases.size() >= 2,
		"фаз: %s" % [phases.keys()])


func _test_sim_only_mode() -> void:
	print("\n-- режим без запекания (build_settled_sim) --")

	var job := JOB.new()
	job.setup(SIZE, SEED, null)  # без палитры — картинки не нужны
	job.step(0)
	var sim_only := job.sim_result()

	_check("без палитры job заканчивается на фазе симуляции", job.is_done())
	_check("картинки при этом не запекались",
		not sim_only.has("visual") and not sim_only.has("mask"))
	_check("осевшая симуляция отдана", sim_only.has("sim") and sim_only["sim"] != null)
	_check("базы размещены и в этом режиме", sim_only.has("bases"))

	# Публичный вход build_settled_sim() обязан давать ровно то же самое:
	# им пользуются замеры и тесты рельефа, которым картинки не нужны.
	var via_api := SAND_LEVEL_GEN.build_settled_sim(SIZE, SEED)
	_check("build_settled_sim() выбирает тот же seed",
		via_api["seed_used"] == sim_only["seed_used"],
		"%d против %d" % [via_api["seed_used"], sim_only["seed_used"]])
	_check("build_settled_sim() даёт ту же сетку бит-в-бит",
		via_api["sim"].grid_hash() == sim_only["sim"].grid_hash())
