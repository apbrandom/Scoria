## Headless-проверка ПРАВИЛ генерации уровня (resources/level_gen_rules.gd +
## перебор попыток в SandLevelGen): уровни от разных seed'ов реально разные, но
## каждый из них играбелен, а один и тот же seed по-прежнему даёт один и тот же
## уровень.
##
## Зачем отдельно от test_sand_level_gen.gd: тот проверяет ОДИН уровень
## (правильные форматы картинок, детерминизм, наличие материалов). Здесь предмет
## проверки другой — сама вариативность и то, что фильтр играбельности не
## декоративный: случайность в генераторе без такого фильтра рано или поздно
## выдаст уровень без неба или залитый водой, и поймать это должен тест, а не
## заказчик в игре.
##
## Меряем на симуляции (build_settled_sim), без запекания картинок: инварианты
## играбельности живут в клетках, а Image здесь ничего не добавил бы, кроме
## секунд на прогон.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_level_rules.tscn
extends Node

const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const RULES := preload("res://data/level/default_gen.tres")

## Размер боевого уровня (level.gd::SAND_LEVEL_SIZE) — проверять надо тот, в
## который реально играют: на другом масштабе доли (небо/вода) выходят другие.
const LEVEL_SIZE := Vector2i(2700, 1350)
## Сколько разных seed'ов прогнать. Компромисс: больше — надёжнее статистика,
## но каждый уровень это ~0.3-0.5 с оседания.
const SEED_COUNT := 16

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка правил генерации уровня (%s) ===" % DisplayServer.get_name())
	_test_all_seeds_playable()
	_test_levels_differ()
	_test_same_seed_reproduces()
	_test_impossible_rules_do_not_crash()
	_test_stricter_rules_still_pass()
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


## Список seed'ов, разнесённых заведомо больше, чем шагом перебора попыток
## внутри генератора — иначе половина "разных" запусков попала бы в те же
## кандидаты, что генератор уже перебрал сам.
func _seeds() -> Array[int]:
	var out: Array[int] = []
	for i in SEED_COUNT:
		out.append(1000 + i * 104729)
	return out


## Главное: КАЖДЫЙ разыгранный уровень проходит фильтр играбельности.
func _test_all_seeds_playable() -> void:
	print("\n-- каждый seed даёт играбельный уровень --")
	var bad: Array[String] = []
	var attempts_total := 0
	var worst_attempts := 0
	for s in _seeds():
		var built := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, s, RULES)
		var report: Dictionary = built["report"]
		attempts_total += built["attempts"]
		worst_attempts = maxi(worst_attempts, built["attempts"])
		if not report["ok"]:
			bad.append("seed %d: %s" % [s, ", ".join(PackedStringArray(report["fails"]))])
	_check("все %d уровней играбельны" % SEED_COUNT, bad.is_empty(),
		"провалы: %s" % ("нет" if bad.is_empty() else str(bad)))
	# Если фильтру почти всегда нужен перебор, значит диапазоны в .tres выкручены
	# так, что случайный уровень обычно негоден — это стоит увидеть числом.
	_check("перебор попыток не стал нормой",
		float(attempts_total) / SEED_COUNT < 2.0,
		"в среднем %.2f попытки, худший случай %d" % [
			float(attempts_total) / SEED_COUNT, worst_attempts])


## Уровни обязаны РАЗЛИЧАТЬСЯ — ради этого всё и затевалось.
func _test_levels_differ() -> void:
	print("\n-- уровни от разных seed'ов различаются --")
	var hashes := {}
	var water_fracs: Array[float] = []
	for s in _seeds():
		var built := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, s, RULES)
		hashes[built["sim"].grid_hash()] = true
		water_fracs.append(built["report"]["stats"]["open_frac"])
	_check("все %d полей уникальны" % SEED_COUNT, hashes.size() == SEED_COUNT,
		"уникальных хешей: %d" % hashes.size())

	# Уникальный хеш ловит только "поля не побитово равны" — этого мало: узор
	# шума меняется от seed'а и в старом генераторе, где ВСЕ числа были
	# захардкожены. Настоящая вариативность — это разброс самих характеристик
	# уровня, поэтому смотрим на размах доли открытого пространства.
	var lo := water_fracs[0]
	var hi := water_fracs[0]
	for v in water_fracs:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_check("форма уровней реально гуляет, а не только узор шума", hi - lo > 0.02,
		"доля открытого пространства: от %.3f до %.3f (размах %.3f)" % [lo, hi, hi - lo])


## Тот же seed — тот же уровень. На этом стоят и тесты, и будущий сетевой матч
## (хост и клиент генерируют рельеф независимо по общему seed).
func _test_same_seed_reproduces() -> void:
	print("\n-- один seed воспроизводит один уровень --")
	var a := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, 777, RULES)
	var b := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, 777, RULES)
	_check("поля совпали побитово", a["sim"].grid_hash() == b["sim"].grid_hash(),
		"hash %d vs %d" % [a["sim"].grid_hash(), b["sim"].grid_hash()])
	_check("выбран тот же seed после перебора попыток", a["seed_used"] == b["seed_used"],
		"%d vs %d" % [a["seed_used"], b["seed_used"]])


## Заведомо невыполнимые правила не должны ронять загрузку уровня: генератор
## обязан отдать ЛУЧШИЙ из отвергнутых и честно сказать, что тот не прошёл.
## Это не теоретическая ситуация — достаточно неудачно выкрутить .tres.
func _test_impossible_rules_do_not_crash() -> void:
	print("\n-- невыполнимые правила не роняют генерацию --")
	var hard = RULES.duplicate()
	hard.min_open_sky_frac = 0.99   # столько неба не бывает: под ним ещё и рельеф
	hard.max_attempts = 3           # не тратить весь бюджет на заведомо провальное
	var built := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, 31337, hard)
	_check("генератор всё равно вернул уровень", built.has("sim") and built["sim"] != null)
	_check("и честно пометил его как непрошедший", not built["report"]["ok"],
		"провалы: %s" % str(built["report"]["fails"]))
	_check("перебрал все отведённые попытки", built["attempts"] == hard.max_attempts,
		"попыток=%d" % built["attempts"])


## Обратная проверка к предыдущей: если правила ужесточить, но в разумных
## пределах, фильтр обязан их вытянуть перебором, а не сдаться. Иначе тест выше
## проходил бы даже на сломанном переборе (который всегда возвращает "не ок").
func _test_stricter_rules_still_pass() -> void:
	print("\n-- умеренно строгие правила вытягиваются перебором --")
	var strict = RULES.duplicate()
	strict.max_water_frac = 0.02      # заметно строже дефолтных 0.12
	strict.min_open_sky_frac = 0.45   # строже дефолтных 0.35
	var built := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, 5150, strict)
	var report: Dictionary = built["report"]
	_check("строгие правила выполнены", report["ok"],
		"попыток=%d провалы=%s" % [built["attempts"], str(report["fails"])])
	if report["ok"]:
		var stats: Dictionary = report["stats"]
		_check("вода уложилась в новый лимит", stats["water_frac"] <= strict.max_water_frac,
			"%.4f <= %.4f" % [stats["water_frac"], strict.max_water_frac])
		_check("открытого пространства не меньше нового минимума",
			stats["open_frac"] >= strict.min_open_sky_frac,
			"%.4f >= %.4f" % [stats["open_frac"], strict.min_open_sky_frac])
