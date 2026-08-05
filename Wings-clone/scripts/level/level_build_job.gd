## Сборка уровня ПОРЦИЯМИ вместо одного неделимого вызова.
##
## Зачем: заход в уровень стоит ~3.8 с (замер tools/diag_load_cost.gd, M1 Max,
## 2700x1350), и всё это время окно не перерисовывается — заказчик читает это
## как «игра зависла». Полоса загрузки без порционности бессмысленна: рисовать
## её некому, пока главный поток занят одним длинным вызовом.
##
## Почему НЕ поток (Thread): рельеф обязан получаться бит-в-бит одинаковым у
## хоста и клиента по общему seed (architecture.md → «Сеть»), а половина работы
## (сборка чанков и коллизии Terrain) всё равно обязана идти в главном потоке —
## трогает дерево сцены и текстуры. Порционность даёт то же ощущение живого
## окна, но без единого разделяемого состояния между потоками.
##
## Порядок работы внутри при этом ТОЧНО ТОТ ЖЕ, что был у синхронного кода:
## нарезка на порции не меняет ни одного вычисления, только вставляет паузы
## между ними. Это не рассуждение, а закреплено тестом
## `tools/test_loading.gd` («порциями = одним куском, бит-в-бит»).
##
## Единственная реализация сборки уровня: SandLevelGen.generate() и
## build_settled_sim() — тонкие обёртки, которые крутят этот же job без
## ограничения бюджета (см. sand_level_gen.gd). Второй копии алгоритма рядом
## сознательно нет.
class_name LevelBuildJob
extends RefCounted

## Односторонняя зависимость: job знает генератор, генератор про job узнаёт
## только в рантайме через load() (см. sand_level_gen.gd) — иначе два preload
## друг на друга образуют цикл, который GDScript не разбирает.
const GEN := preload("res://scripts/level/sand_level_gen.gd")

enum Phase { SIM, BAKE, DONE }

## Доли фаз в общем прогрессе — не на глаз, а по замеру tools/diag_load_cost.gd:
## симуляция 798 мс, запекание 2337 мс (округлено до 1/4 и 3/4). Ошибка в этих
## числах не ломает сборку, только делает ход полосы неравномерным.
const W_SIM := 0.25
const W_BAKE := 0.75

## Неделимая порция запекания — столько строк СЕТКИ за раз. Одна строка ~10 мс
## (2337 мс / 225 строк), то есть порция мельче кадра: бюджет кадра решает,
## сколько порций уместится, а не эта константа.
const BAKE_ROWS_CHUNK := 1

var _size: Vector2i
var _seed: int
var _palette: TerrainPalette
var _rules
var _phase := Phase.SIM

# --- фаза SIM: перебор seed'ов, как в прежнем build_settled_sim ---
var _attempt := 0
var _best: Dictionary = {}
var _best_score := -1.0
var _built: Dictionary = {}

# --- фаза BAKE: разворот осевшей сетки в пиксельные Image ---
## Буферы — поля объекта, а НЕ аргументы функций: PackedByteArray в GDScript
## значимый тип, при передаче в функцию правка ушла бы в копию и потерялась.
var _vis := PackedByteArray()
var _msk := PackedByteArray()
var _detail := PackedByteArray()
var _mask_r := PackedByteArray()
var _mask_g := PackedByteArray()
var _mask_b := PackedByteArray()
var _bake_gy := 0
var _grid: Vector2i
var _out_w := 0
var _out_h := 0
var _cell_px := 0


## palette == null — запекать не нужно (вызывающему хватает осевшей симуляции,
## так работает build_settled_sim); job тогда заканчивается после фазы SIM.
func setup(size: Vector2i, rng_seed: int, palette: TerrainPalette, rules = null) -> void:
	_size = size
	_seed = rng_seed
	_palette = palette
	_rules = rules if rules != null else GEN.DEFAULT_RULES


## Запечь ГОТОВУЮ сетку, минуя генерацию — для кода, который собрал симуляцию
## сам (инструменты и тесты рельефа, где уровень выкладывается руками, чтобы
## проверяемая ситуация была воспроизводимой, а не выпала случайно).
func setup_bake(sim, grid: Vector2i, size: Vector2i, palette: TerrainPalette,
		rng_seed: int, rules = null) -> void:
	setup(size, rng_seed, palette, rules)
	_grid = grid
	_built = {"sim": sim, "grid": grid, "seed_used": rng_seed}
	_begin_bake()
	_phase = Phase.BAKE


## Отработать не дольше budget_usec микросекунд, но МИНИМУМ одну неделимую
## порцию — иначе при нулевом бюджете job не сдвинулся бы никогда.
## budget_usec <= 0 — без ограничения, до полного конца (синхронный режим).
func step(budget_usec: int) -> void:
	var deadline := Time.get_ticks_usec() + budget_usec
	while _phase != Phase.DONE:
		match _phase:
			Phase.SIM: _step_sim()
			Phase.BAKE: _step_bake()
		if budget_usec > 0 and Time.get_ticks_usec() >= deadline:
			return


func is_done() -> bool:
	return _phase == Phase.DONE


## 0..1 для полосы загрузки. Внутри фазы SIM честного «сколько осталось» не
## существует: перебор кончается, как только seed прошёл проверку играбельности,
## а не на фиксированной попытке. Показываем долю израсходованных попыток —
## полоса при удачном seed'е прыгнет вперёд, и это честнее, чем плавно ползти
## к числу, которое ничего не значит.
func progress() -> float:
	match _phase:
		Phase.SIM:
			var max_attempts: float = maxf(float(_rules.max_attempts), 1.0)
			return W_SIM * minf(_attempt / max_attempts, 1.0)
		Phase.BAKE:
			var rows := maxf(float(_grid.y), 1.0)
			return W_SIM + W_BAKE * minf(_bake_gy / rows, 1.0)
		_:
			return 1.0


## Подпись под полосой. Номер попытки виден нарочно: если генератору попалась
## череда неиграбельных seed'ов, заказчик увидит, что идёт перебор, а не затык.
func phase_text() -> String:
	match _phase:
		Phase.SIM:
			return "Генерация рельефа (попытка %d)" % (_attempt + 1)
		Phase.BAKE:
			return "Отрисовка материалов"
		_:
			return "Готово"


## Результат фазы SIM — то же, что прежде возвращал build_settled_sim().
func sim_result() -> Dictionary:
	return _built


## Полный результат — то же, что прежде возвращал generate().
func result() -> Dictionary:
	return _built


# ------------------------------------------------------------------ фаза SIM

## Одна попытка seed'а за порцию. Мельче резать нечего: _build_once — это
## раскладка рельефа и оседание до покоя, промежуточное состояние ни для чего
## не годится (уровень-полуфабрикат нельзя ни показать, ни проверить).
func _step_sim() -> void:
	var seed_i: int = _seed + _attempt * GEN.SEED_ATTEMPT_STEP
	var built := GEN._build_once(_size, seed_i, _rules)
	var report: Dictionary = GEN._evaluate(built["sim"], built["grid"], _rules)
	built["seed_used"] = seed_i
	built["attempts"] = _attempt + 1
	built["report"] = report
	_attempt += 1

	if report["ok"]:
		_finish_sim(built)
		return

	# Не сошлось — запоминаем лучший из отвергнутых. Загрузка уровня не должна
	# падать из-за неудачной случайности (тот же довод, что был в
	# build_settled_sim): чуть менее удачный рельеф лучше, чем чёрный экран.
	if report["score"] > _best_score:
		_best_score = report["score"]
		_best = built

	var max_attempts: int = _rules.max_attempts
	if _attempt >= max_attempts:
		# "attempts" везде значит СКОЛЬКО ПОПЫТОК СДЕЛАНО, а не на какой
		# остановились: здесь перебор дошёл до конца, и лучший кандидат мог
		# оказаться не последним.
		_best["attempts"] = max_attempts
		_finish_sim(_best)


func _finish_sim(built: Dictionary) -> void:
	_built = GEN._place_bases(built, _rules)
	_grid = _built["grid"]
	if _palette == null:
		_phase = Phase.DONE
		return
	_begin_bake()
	_phase = Phase.BAKE


# ----------------------------------------------------------------- фаза BAKE

func _begin_bake() -> void:
	_cell_px = _rules.cell_px
	_out_w = _size.x
	_out_h = _size.y
	_vis.resize(_out_w * _out_h * 4)
	_msk.resize(_out_w * _out_h * 4)
	# +7 — отдельная соль от seed, который уже занят height_noise (seed_used) и
	# patch_noise (seed_used+1) в _carve_initial_terrain: не тот же узор шума.
	_detail = GEN.detail_noise_bytes(int(_built["seed_used"]) + 7, _size)

	_mask_r.resize(TerrainPalette.CLASS_COUNT)
	_mask_g.resize(TerrainPalette.CLASS_COUNT)
	_mask_b.resize(TerrainPalette.CLASS_COUNT)
	for cls in TerrainPalette.CLASS_COUNT:
		var v: int = _palette.mask_rgb[cls]
		_mask_r[cls] = (v >> 16) & 0xFF
		_mask_g[cls] = (v >> 8) & 0xFF
		_mask_b[cls] = v & 0xFF
	_bake_gy = 0


func _step_bake() -> void:
	var sim = _built["sim"]
	var to_gy := mini(_bake_gy + BAKE_ROWS_CHUNK, _grid.y)
	while _bake_gy < to_gy:
		_bake_row(sim, _bake_gy)
		_bake_gy += 1
	if _bake_gy >= _grid.y:
		_finish_bake()


## Одна строка СЕТКИ (не пикселей): клетка разворачивается в блок
## cell_px×cell_px, но цвет внутри блока модулируется детальным шумом — не одна
## плоская заливка, иначе граница клеток читалась бы как ровная сетка
## («пиксель-арт»), что прямо противоречит HD-стилю проекта (CLAUDE.md).
func _bake_row(sim, gy: int) -> void:
	var py0 := gy * _cell_px
	var block_h := mini(_cell_px, _out_h - py0)
	if block_h <= 0:
		return
	for gx in _grid.x:
		var px0 := gx * _cell_px
		var block_w := mini(_cell_px, _out_w - px0)
		if block_w <= 0:
			continue
		var cls: int = GEN.cls_of(sim.get_cell(gx, gy))
		var mr: int = _mask_r[cls]
		var mg: int = _mask_g[cls]
		var mb: int = _mask_b[cls]
		for oy in block_h:
			var row := (py0 + oy) * _out_w
			for ox in block_w:
				var pi := row + px0 + ox
				var c: Color = GEN.color_of(cls, _detail[pi])
				var o := pi * 4
				_vis[o] = int(c.r8)
				_vis[o + 1] = int(c.g8)
				_vis[o + 2] = int(c.b8)
				_vis[o + 3] = int(c.a8)
				_msk[o] = mr; _msk[o + 1] = mg; _msk[o + 2] = mb; _msk[o + 3] = 255


func _finish_bake() -> void:
	_built["visual"] = Image.create_from_data(
		_out_w, _out_h, false, Image.FORMAT_RGBA8, _vis)
	_built["mask"] = Image.create_from_data(
		_out_w, _out_h, false, Image.FORMAT_RGBA8, _msk)
	# Буферы больше не нужны, а это десятки мегабайт на уровень — отпускаем
	# сразу, а не когда job соберётся сборщиком мусора где-то в геймплее.
	_vis = PackedByteArray()
	_msk = PackedByteArray()
	_detail = PackedByteArray()
	_phase = Phase.DONE
