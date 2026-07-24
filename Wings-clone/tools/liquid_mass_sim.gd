class_name LiquidMassSim
extends RefCounted

## ПРОТОТИП (не боевой код, живёт только в tools/): клеточная жидкость на
## МОДЕЛИ МАССЫ, а не «клетка есть / клетки нет». Цель — доказать, что вода
## выравнивается в плоскость и умеет подниматься снизу вверх под давлением —
## то, чего принципиально не может текущий бинарный SandSim (см. большой
## комментарий над _step_liquid в scripts/sand/sand_sim.gd и раздел «вода —
## холм, не плоское озеро» в notes/terrain_research.md).
##
## Алгоритм — канонический mass-conservation cellular automaton
## (W-Shadow 2009 «Simple Fluid Simulation With Cellular Automata»,
## https://w-shadow.com/blog/2009/09/01/simple-fluid-simulation/ — взят ТОЛЬКО
## алгоритм/формулы, не код; учиться по опубликованному туториалу CLAUDE.md
## прямо разрешает). У каждой клетки не булев флаг, а ВЕЛИЧИНА массы; за тик
## клетка перегоняет излишек вниз, вбок к более пустому соседу и — ГЛАВНОЕ —
## ВВЕРХ, когда клетка под ней переполнена (давление). Именно переток вверх и
## даёт выравнивание в плоскость, которого нет у бинарного правила.
##
## КЛЮЧЕВАЯ АДАПТАЦИЯ ПОД НАШ ПРОЕКТ — ЦЕЛОЧИСЛЕННАЯ FIXED-POINT МАССА.
## Оригинал на float. Float-арифметика (деления, формула равновесия) может
## разойтись между машинами/компиляторами → рассинхрон сетевого replay, а сеть
## для нас — второй столп проекта (architecture.md). Поэтому вся масса здесь —
## целые числа в единицах SCALE (SCALE = «1.0 клетка воды»). Никаких float в
## решениях о перетоке вообще → результат бит-в-бит одинаков везде. Это НЕ
## косметика, это то, ради чего мы вообще выбрали CPU, а не GPU.

## Разрешение массы: 1.0 «полная клетка» = SCALE целочисленных единиц.
## 4096 = запас в ~12 бит, хватает на плавный градиент давления и заведомо не
## переполняет int64 в квадратичной ветке равновесия (см. _stable_bottom).
const SCALE := 4096

const MAX_MASS := SCALE                       # 1.0 — норма непережатой клетки
const MAX_COMPRESS := 82                       # 0.02*SCALE — сколько сверх нормы
                                               # может держать нижняя клетка на
                                               # каждую клетку столба над ней
const MIN_FLOW := 41                           # 0.01*SCALE — переток крупнее
                                               # этого сглаживаем (гасим дребезг)
const MAX_SPEED := SCALE                       # не больше 1.0 массы за тик за раз
                                               # (устойчивость, как MaxSpeed у W-Shadow)

var width := 0
var height := 0
var _mass: PackedInt32Array                    # текущее состояние (читаем отсюда)
var _next: PackedInt32Array                    # следующее (пишем сюда); двойной
                                               # буфер → порядок обхода клеток не
                                               # влияет на результат (детерминизм)
var _solid: PackedByteArray                    # 1 = стена/земля: воду не держит,
                                               # переток сквозь неё запрещён


func setup(w: int, h: int) -> void:
	width = w
	height = h
	_mass = PackedInt32Array(); _mass.resize(w * h)
	_next = PackedInt32Array(); _next.resize(w * h)
	_solid = PackedByteArray(); _solid.resize(w * h)


func _idx(x: int, y: int) -> int:
	return y * width + x


func set_solid(x: int, y: int, v: bool) -> void:
	_solid[_idx(x, y)] = 1 if v else 0


func is_solid(x: int, y: int) -> bool:
	return _solid[_idx(x, y)] != 0


## Добавить массу в клетку (в единицах SCALE). Для тестов/заливки.
func add_mass(x: int, y: int, amount: int) -> void:
	_mass[_idx(x, y)] += amount


func get_mass(x: int, y: int) -> int:
	return _mass[_idx(x, y)]


## Суммарная масса всей сетки — инвариант: ДОЛЖНА сохраняться ровно (мы
## сознательно НЕ зануляем «почти сухие» клетки, в отличие от оригинала, где
## это теряло крохи массы — точное сохранение важнее для теста и для будущей
## сетевой сверки, чем экономия на околонулевых клетках).
func total_mass() -> int:
	var s := 0
	for m in _mass:
		s += m
	return s


## Сколько массы ДОЛЖНО остаться в НИЖНЕЙ из двух вертикально соседних клеток
## при суммарной массе total на двоих. Точная целочисленная калька формулы
## W-Shadow get_stable_state_b, все три ветки:
##  - total ≤ 1: нижняя хочет быть полной (1.0); фактический переток всё равно
##    ограничен наличным остатком выше по коду — сохранение массы не нарушается;
##  - 1 < total < 2.02: плавный переход, квадратичная формула (давление ещё мягкое);
##  - total ≥ 2.02: делим пополам с добавкой сжатия (обе клетки пережаты).
## Всё в единицах SCALE. MAX_MASS*MAX_MASS = 16.7М, слагаемое total*MAX_COMPRESS
## ~ единицы миллионов — с запасом влезает в int64 GDScript.
func _stable_bottom(total: int) -> int:
	if total <= MAX_MASS:
		return MAX_MASS
	if total < 2 * MAX_MASS + MAX_COMPRESS:
		return (MAX_MASS * MAX_MASS + total * MAX_COMPRESS) / (MAX_MASS + MAX_COMPRESS)
	return (total + MAX_COMPRESS) / 2


## Один тик симуляции. Читаем из _mass, пишем в _next, потом меняем местами.
func step() -> void:
	# _next начинается как копия текущего состояния; каждая клетка ТОЛЬКО
	# вычитает из себя отданное и добавляет соседям полученное → глобальная
	# масса сохраняется тождественно, а порядок обхода не важен.
	for i in _mass.size():
		_next[i] = _mass[i]

	for y in height:
		for x in width:
			var i := _idx(x, y)
			if _solid[i] != 0:
				continue
			var remaining := _mass[i]
			if remaining <= 0:
				continue  # сухой клетке нечего отдавать; заполнится от соседей

			# 1. ВНИЗ (в клетку под собой), пока туда что-то помещается.
			if y + 1 < height and _solid[_idx(x, y + 1)] == 0:
				var below := _idx(x, y + 1)
				var flow := _stable_bottom(remaining + _mass[below]) - _mass[below]
				if flow > MIN_FLOW:
					flow = flow / 2  # сглаживание: не выплёскиваем всё разом
				flow = clampi(flow, 0, mini(MAX_SPEED, remaining))
				if flow > 0:
					_next[i] -= flow
					_next[below] += flow
					remaining -= flow

			# 2. ВЛЕВО — выравнивание с более пустым соседом по ряду (1/4 разницы).
			if remaining > 0 and x - 1 >= 0 and _solid[_idx(x - 1, y)] == 0:
				var left := _idx(x - 1, y)
				var flow := (remaining - _mass[left]) / 4
				if flow > MIN_FLOW:
					flow = flow / 2
				flow = clampi(flow, 0, remaining)
				if flow > 0:
					_next[i] -= flow
					_next[left] += flow
					remaining -= flow

			# 3. ВПРАВО — симметрично влево.
			if remaining > 0 and x + 1 < width and _solid[_idx(x + 1, y)] == 0:
				var right := _idx(x + 1, y)
				var flow := (remaining - _mass[right]) / 4
				if flow > MIN_FLOW:
					flow = flow / 2
				flow = clampi(flow, 0, remaining)
				if flow > 0:
					_next[i] -= flow
					_next[right] += flow
					remaining -= flow

			# 4. ВВЕРХ (излишек над равновесием давит в клетку сверху). ЭТО и есть
			# то, чего бинарное правило не умеет — благодаря этому вода
			# поднимается на дальней стороне и тело выравнивается в плоскость.
			if remaining > 0 and y - 1 >= 0 and _solid[_idx(x, y - 1)] == 0:
				var above := _idx(x, y - 1)
				var flow := remaining - _stable_bottom(remaining + _mass[above])
				if flow > MIN_FLOW:
					flow = flow / 2
				flow = clampi(flow, 0, mini(MAX_SPEED, remaining))
				if flow > 0:
					_next[i] -= flow
					_next[above] += flow
					remaining -= flow

	var tmp := _mass
	_mass = _next
	_next = tmp


## Верхняя граница воды в колонке x — индекс самой верхней клетки, где массы
## заметно больше нуля (для проверок «плоскости» и «сообщающихся сосудов»).
## Возврат height, если колонка сухая.
func water_top_row(x: int, threshold: int) -> int:
	for y in height:
		if _solid[_idx(x, y)] == 0 and _mass[_idx(x, y)] >= threshold:
			return y
	return height


## Суммарная масса в колонке x — для проверки «все колонки выровнялись».
func column_mass(x: int) -> int:
	var s := 0
	for y in height:
		s += _mass[_idx(x, y)]
	return s
