## Ядро клеточной симуляции рельефа (falling-sand), первый милстоун "базы".
## Чистая логика без сцены/рендера — поэтому проверяется headless
## (tools/test_sand.gd): детерминизм, сохранение массы, оседание, корректность
## dirty-rect. Отрисовку/ввод берёт на себя tools/sand_playground.gd.
##
## Модель данных: поле _cells — байт на ячейку = id материала (0 = пусто).
## Мир по краям считается сплошной стеной (за границей падать некуда).
##
## ── Два свойства, на которых стоит вся будущая разработка ─────────────────
## 1. ДЕТЕРМИНИЗМ. При одинаковом стартовом _cells и одинаковом числе step()
##    результат побитово совпадает на любой машине: в решении о движении нет ни
##    одного float и ни одного Godot-рандома, единственный "random" — целочисленный
##    хеш _hash3(x,y,tick). Это то, что делает возможным сетевой replay carve
##    (второй столп проекта — PvP), поэтому нарушать его нельзя (см.
##    notes/terrain_research.md, notes/roadmap.md).
## 2. DIRTY-RECT ("покой = ноль работы"). Симулируем только прямоугольник, где
##    что-то реально двигалось в прошлый тик, расширенный на 1 клетку. Улёгшийся
##    рельеф не тикает вообще. Это ключевая оптимизация Noita и то, что делает
##    систему реальной на бюджете Steam Deck. Сейчас — один общий bbox; следующий
##    шаг масштабирования — dirty-флаги ПО ЧАНКАМ поверх существующей чанковой
##    нарезки (architecture.md §3), а не один прямоугольник на весь уровень.
## ─────────────────────────────────────────────────────────────────────────
extends RefCounted
class_name SandSim

## Дубль SandMaterial.Kind — намеренно, чтобы горячий цикл не дёргал class_name
## (свежий class_name может не резолвиться headless до пересборки кэша — грабля
## уже ловилась в проекте на TerrainDebris). Порядок обязан совпадать с enum Kind.
const KIND_EMPTY := 0
const KIND_SOLID := 1
const KIND_POWDER := 2
const KIND_LIQUID := 3
const KIND_GAS := 4

const EMPTY_ID := 0

var width: int = 0
var height: int = 0
## Счётчик тиков. Часть детерминированного состояния (влияет на направление
## прохода и на _hash3) — при сетевом replay должен совпадать у всех.
var tick: int = 0

## Диагностика/тест: заставить step() сканировать всё поле вместо dirty-rect.
## Результат ОБЯЗАН совпадать с обычным режимом (dirty-rect ничего не теряет) —
## именно это и проверяет тест корректности оптимизации.
var force_full_scan := false

var _cells: PackedByteArray
## Быстрые таблицы id -> свойство (чтобы в цикле не разыменовывать Resource).
var _kind_of: PackedByteArray
var _color_of: Array = []

## Грязный прямоугольник (включительно). _active=false — всё улеглось, работы нет.
var _active := false
var _dmin_x := 0
var _dmin_y := 0
var _dmax_x := 0
var _dmax_y := 0


## materials — массив SandMaterial (тип намеренно НЕ указан: избегаем class_name в
## сигнатуре по той же причине, что и KIND_* выше). Индексируем по m.id, поэтому
## порядок в массиве не важен, но id обязаны быть уникальны и включать id 0.
func setup(w: int, h: int, materials: Array) -> void:
	width = w
	height = h
	_cells = PackedByteArray()
	_cells.resize(w * h)  # resize заполняет нулями = всё EMPTY

	var max_id := 0
	for m in materials:
		max_id = maxi(max_id, m.id)
	_kind_of = PackedByteArray()
	_kind_of.resize(max_id + 1)
	_color_of = []
	_color_of.resize(max_id + 1)
	for i in _color_of.size():
		_color_of[i] = Color(0, 0, 0, 0)
	for m in materials:
		_kind_of[m.id] = m.kind
		_color_of[m.id] = m.color

	tick = 0
	_reset_dirty()


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func get_cell(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return EMPTY_ID
	return _cells[y * width + x]


## Поставить материал в ячейку и пометить её окрестность активной, чтобы со
## следующего тика симуляция её обработала (в т.ч. соседей, которым теперь есть
## куда падать).
func set_cell(x: int, y: int, id: int) -> void:
	if not in_bounds(x, y):
		return
	_cells[y * width + x] = id
	_mark_dirty(x, y)


## Залить прямоугольник (для тестов/песочницы). Клипуется по границам поля.
func fill_rect(x: int, y: int, w: int, h: int, id: int) -> void:
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			set_cell(xx, yy, id)


func is_active() -> bool:
	return _active


func get_dirty_rect() -> Rect2i:
	if not _active:
		return Rect2i(0, 0, 0, 0)
	return Rect2i(_dmin_x, _dmin_y, _dmax_x - _dmin_x + 1, _dmax_y - _dmin_y + 1)


## Один детерминированный тик симуляции.
func step() -> void:
	if not force_full_scan and not _active:
		# всё улеглось — нулевая работа, только двигаем время
		tick += 1
		return

	# границы прохода фиксируем ДО сброса грязного прямоугольника
	var x0 := 0
	var y0 := 0
	var x1 := width - 1
	var y1 := height - 1
	if not force_full_scan:
		x0 = _dmin_x
		y0 = _dmin_y
		x1 = _dmax_x
		y1 = _dmax_y
	_reset_dirty()

	# Снизу вверх: упавшая ячейка попадает в уже пройденный ряд и повторно за
	# этот тик не обрабатывается — порошок падает ровно на одну клетку за тик.
	# Направление по X чередуем по чётности тика, иначе песок систематически
	# сползает в одну сторону (детерминировано — зависит только от tick).
	var left_to_right := (tick & 1) == 0
	var y := y1
	while y >= y0:
		if left_to_right:
			var x := x0
			while x <= x1:
				_step_cell(x, y)
				x += 1
		else:
			var x := x1
			while x >= x0:
				_step_cell(x, y)
				x -= 1
		y -= 1

	tick += 1


func _step_cell(x: int, y: int) -> void:
	var id := _cells[y * width + x]
	if id == EMPTY_ID:
		return
	if _kind_of[id] == KIND_POWDER:
		_step_powder(x, y, id)
	# SOLID и (пока) прочие — неподвижны


## Порошок: вниз; если занято — по диагонали вниз, сторона выбирается
## детерминированным хешем (не рандомом). Даёт угол естественного откоса ~45°:
## зерно сползает по склону, пока под ним и обе диагонали не заняты.
func _step_powder(x: int, y: int, id: int) -> void:
	var below := y + 1
	if below >= height:
		return  # дно карты = стена, падать некуда

	if _is_empty(x, below):
		_swap(x, y, x, below, id)
		return

	# порядок диагоналей определяет детерминированный хеш
	var first_dx := -1 if (_hash3(x, y, tick) & 1) == 0 else 1
	if _is_empty(x + first_dx, below):
		_swap(x, y, x + first_dx, below, id)
		return
	if _is_empty(x - first_dx, below):
		_swap(x, y, x - first_dx, below, id)


## Пустая ли ячейка (за границей по X — стена, не пусто).
func _is_empty(x: int, y: int) -> bool:
	if x < 0 or x >= width:
		return false
	return _cells[y * width + x] == EMPTY_ID


func _swap(fx: int, fy: int, tx: int, ty: int, id: int) -> void:
	_cells[ty * width + tx] = id
	_cells[fy * width + fx] = EMPTY_ID
	# пометить оба места активными на следующий тик — иначе зерно над ушедшим и
	# соседи по склону "застынут" в воздухе
	_mark_dirty(fx, fy)
	_mark_dirty(tx, ty)


func _mark_dirty(x: int, y: int) -> void:
	var minx := maxi(x - 1, 0)
	var miny := maxi(y - 1, 0)
	var maxx := mini(x + 1, width - 1)
	var maxy := mini(y + 1, height - 1)
	if not _active:
		_dmin_x = minx
		_dmin_y = miny
		_dmax_x = maxx
		_dmax_y = maxy
		_active = true
	else:
		_dmin_x = mini(_dmin_x, minx)
		_dmin_y = mini(_dmin_y, miny)
		_dmax_x = maxi(_dmax_x, maxx)
		_dmax_y = maxi(_dmax_y, maxy)


func _reset_dirty() -> void:
	_active = false


## Целочисленный хеш-финализатор (в духе xxHash): перемешивает биты так, что
## младший бит хорошо распределён — простое (x^y^t)&1 давало бы шахматную
## систематику. Маска 0xFFFFFFFF держит значение в неотрицательном 32-битном
## диапазоне, одинаково на любой машине (детерминизм сети).
func _hash3(x: int, y: int, t: int) -> int:
	var h := (x * 374761393 + y * 668265263 + t * 2147483647) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return h


## ── Диагностика/тесты ────────────────────────────────────────────────────

## Сколько ячеек данного материала (проверка сохранения массы).
func count_material(id: int) -> int:
	var n := 0
	for b in _cells:
		if b == id:
			n += 1
	return n


## FNV-1a 32-бит по всему полю — дешёвая детерминированная подпись состояния
## для теста воспроизводимости (одинаковый старт + одинаковые тики -> равный хеш).
func grid_hash() -> int:
	var h := 0x811C9DC5
	for b in _cells:
		h = (h ^ b) & 0xFFFFFFFF
		h = (h * 0x01000193) & 0xFFFFFFFF
	return h


## RGBA8-байты всего поля для отрисовки (Image.create_from_data). Весь кадр
## целиком — для прототипа-песочницы этого достаточно (256² = мелочь).
func to_rgba_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(width * height * 4)
	for i in _cells.size():
		var c: Color = _color_of[_cells[i]]
		var o := i * 4
		out[o + 0] = int(round(c.r * 255.0))
		out[o + 1] = int(round(c.g * 255.0))
		out[o + 2] = int(round(c.b * 255.0))
		out[o + 3] = int(round(c.a * 255.0))
	return out
