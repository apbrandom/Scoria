## Ядро клеточной симуляции рельефа (falling-sand). Милстоуны 1+3.
## Чистая логика без сцены/рендера — проверяется headless (tools/test_sand.gd):
## детерминизм, сохранение массы, оседание, корректность dirty-rect, поведение
## воды/огня. Отрисовку/ввод берёт tools/sand_playground.gd.
##
## Модель данных:
##  - _cells — байт на ячейку = id материала (0 = пусто). Источник истины мира.
##  - _aux — байт на ячейку = состояние (сейчас: остаток жизни огня). У остальных
##    материалов не используется.
##  - мир по краям = сплошная стена (за границей падать/течь некуда).
##
## ── Три свойства, на которых стоит вся дальнейшая разработка ────────────────
## 1. ДЕТЕРМИНИЗМ. Одинаковый старт + одинаковое число step() -> побитово равное
##    поле на любой машине: в решениях о движении/реакциях нет ни float, ни
##    Godot-рандома, единственный "random" — целочисленный хеш _hash3(x,y,tick).
##    Это делает возможным сетевой replay (PvP), поэтому нарушать нельзя.
## 2. DIRTY-RECT ("покой = ноль работы"). Тикаем только прямоугольник, где что-то
##    двигалось/горело в прошлый тик (+1 клетка). Улёгшийся рельеф не считается.
##    Проверка force_full_scan гарантирует, что оптимизация ничего не теряет.
## 3. ОДНО ДВИЖЕНИЕ ЗА ТИК. _moved_at[i]==tick помечает ячейку, уже сдвинутую в
##    этот тик, — иначе жидкость (двигается вбок В ТОМ ЖЕ ряду) обрабатывалась бы
##    повторно. Штамп сравнивается с tick, поэтому массив не нужно чистить каждый
##    тик (что убило бы свойство "покой = ноль работы").
## ─────────────────────────────────────────────────────────────────────────
extends RefCounted
class_name SandSim

## Дубль SandMaterial.Kind — намеренно, чтобы горячий цикл не дёргал class_name
## (свежий class_name не всегда резолвится headless до пересборки кэша — грабля
## уже ловилась в проекте на TerrainDebris). Порядок обязан совпадать с enum Kind.
const KIND_EMPTY := 0
const KIND_SOLID := 1
const KIND_POWDER := 2
const KIND_LIQUID := 3
const KIND_GAS := 4
const KIND_FIRE := 5

const EMPTY_ID := 0

var width: int = 0
var height: int = 0
## Счётчик тиков. Часть детерминированного состояния (влияет на направление
## прохода и на _hash3) — при сетевом replay должен совпадать у всех.
var tick: int = 0

## Диагностика/тест: сканировать всё поле вместо dirty-rect. Результат ОБЯЗАН
## совпадать с обычным режимом (dirty-rect ничего не теряет) — это и проверяется.
var force_full_scan := false

var _cells: PackedByteArray
var _aux: PackedByteArray          # состояние ячейки (жизнь огня); 0 у прочих
var _moved_at: PackedInt32Array    # номер тика, когда ячейку последний раз двигали

## Быстрые таблицы id -> свойство (чтобы в цикле не разыменовывать Resource).
var _kind_of: PackedByteArray
var _density_of: PackedFloat32Array
var _flammable_of: PackedByteArray
var _burnlife_of: PackedInt32Array
var _color_of: Array = []
## id материала с kind==FIRE (во что превращается горючее и что ставит кисть
## огня). -1, если в наборе огня нет — тогда логика огня не работает.
var _fire_id := -1

## Грязный прямоугольник (включительно). _active=false — всё улеглось, работы нет.
var _active := false
var _dmin_x := 0
var _dmin_y := 0
var _dmax_x := 0
var _dmax_y := 0


## materials — массив SandMaterial (тип намеренно НЕ указан: избегаем class_name в
## сигнатуре по той же причине, что и KIND_* выше). Индексируем по m.id.
func setup(w: int, h: int, materials: Array) -> void:
	width = w
	height = h
	_cells = PackedByteArray()
	_cells.resize(w * h)          # нулями = всё EMPTY
	_aux = PackedByteArray()
	_aux.resize(w * h)            # нулями = нет состояния
	_moved_at = PackedInt32Array()
	_moved_at.resize(w * h)
	_moved_at.fill(-1)            # никого не двигали (tick стартует с 0)

	var max_id := 0
	for m in materials:
		max_id = maxi(max_id, m.id)
	_kind_of = PackedByteArray();       _kind_of.resize(max_id + 1)
	_density_of = PackedFloat32Array(); _density_of.resize(max_id + 1)
	_flammable_of = PackedByteArray();  _flammable_of.resize(max_id + 1)
	_burnlife_of = PackedInt32Array();  _burnlife_of.resize(max_id + 1)
	_color_of = []; _color_of.resize(max_id + 1)
	for i in _color_of.size():
		_color_of[i] = Color(0, 0, 0, 0)
	_fire_id = -1
	for m in materials:
		_kind_of[m.id] = m.kind
		_density_of[m.id] = m.density
		_flammable_of[m.id] = 1 if m.flammable else 0
		_burnlife_of[m.id] = m.burn_life
		_color_of[m.id] = m.color
		if m.kind == KIND_FIRE:
			_fire_id = m.id

	tick = 0
	_reset_dirty()


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func get_cell(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return EMPTY_ID
	return _cells[y * width + x]


## Поставить материал и активировать окрестность, чтобы со следующего тика
## симуляция обработала и ячейку, и соседей (которым теперь есть куда двигаться).
func set_cell(x: int, y: int, id: int) -> void:
	if not in_bounds(x, y):
		return
	var i := y * width + x
	_cells[i] = id
	_aux[i] = 0
	_mark_dirty(x, y)


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
		tick += 1
		return

	var x0 := 0
	var y0 := 0
	var x1 := width - 1
	var y1 := height - 1
	if not force_full_scan:
		# Расширяем скан на 1 клетку за грязный прямоугольник: за проход снизу
		# вверх ячейка прямо НАД активной областью может каскадно упасть в неё в
		# ТОТ ЖЕ тик (нижняя ушла — верхняя падает следом). Без этого запаса
		# такой каскад отстаёт на тик от полного прохода. Спокойные ячейки в
		# запасе — no-op, "покой = ноль работы" цел (осевшее поле не активно).
		x0 = maxi(_dmin_x - 1, 0)
		y0 = maxi(_dmin_y - 1, 0)
		x1 = mini(_dmax_x + 1, width - 1)
		y1 = mini(_dmax_y + 1, height - 1)
	_reset_dirty()

	# Снизу вверх: упавшая ячейка попадает в уже пройденный ряд и повторно за
	# тик не обрабатывается. Направление по X чередуем по чётности тика — иначе
	# сыпучее/жидкость систематически сползают в одну сторону (детерминировано).
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
	var i := y * width + x
	var id := _cells[i]
	if id == EMPTY_ID:
		return
	if _moved_at[i] == tick:
		return  # уже сдвинут/создан в этот тик — не трогаем повторно
	match _kind_of[id]:
		KIND_POWDER:
			_step_powder(x, y, id)
		KIND_LIQUID:
			_step_liquid(x, y, id)
		KIND_FIRE:
			_step_fire(x, y, i, id)
		# SOLID / EMPTY / GAS — неподвижны (дерево горит через _step_fire соседа)


## Порошок: вниз; тонет в жидкости под собой, если плотнее её; иначе по диагонали
## вниз (сторона — детерминированный хеш). Даёт угол откоса ~45°.
func _step_powder(x: int, y: int, id: int) -> void:
	var below := y + 1
	if below >= height:
		return  # дно карты = стена

	if _is_empty(x, below):
		_move_to_empty(x, y, x, below, id)
		return
	if _is_lighter_liquid(x, below, id):
		_swap_cells(x, y, x, below)  # песок тонет, жидкость всплывает
		return

	var first_dx := -1 if (_hash3(x, y, tick) & 1) == 0 else 1
	if _is_empty(x + first_dx, below):
		_move_to_empty(x, y, x + first_dx, below, id)
		return
	if _is_empty(x - first_dx, below):
		_move_to_empty(x, y, x - first_dx, below, id)


## Жидкость: вниз; по диагонали вниз; иначе растекается вбок ТОЛЬКО «под
## давлением» — если прямо над ней есть вода. Так вода разравнивается в плоскую
## лужу, стекает через край и в дыры, но одиночный поверхностный слой не дёргается
## вбок без конца — это и даёт ГАРАНТИЮ ОСЕДАНИЯ (важно для "покой = ноль работы").
##
## Почему оседает: каждое растекание освобождает клетку, в которую в следующий
## тик падает вода сверху (та самая, что создавала давление) — то есть уводит
## воду вниз по энергии. Пока есть стопка воды — она расползается и оседает; когда
## остаётся один слой (давления нет) — движение прекращается. Проверено тестом.
func _step_liquid(x: int, y: int, id: int) -> void:
	var below := y + 1
	if below < height:
		if _is_empty(x, below):
			_move_to_empty(x, y, x, below, id)
			return
		var d := -1 if (_hash3(x, y, tick) & 1) == 0 else 1
		if _is_empty(x + d, below):
			_move_to_empty(x, y, x + d, below, id)
			return
		if _is_empty(x - d, below):
			_move_to_empty(x, y, x - d, below, id)
			return

	# растекание — только если сверху давит вода (иначе стоим, осели)
	if _cell_kind(x, y - 1) != KIND_LIQUID:
		return
	var dir := -1 if (_hash3(x, y, tick) & 1) == 0 else 1
	if _is_empty(x + dir, y):
		_move_to_empty(x, y, x + dir, y, id)
		return
	if _is_empty(x - dir, y):
		_move_to_empty(x, y, x - dir, y, id)


## Огонь: тушится соседней водой; поджигает горючих 4-соседей (детерминированным
## шансом — мерцает, а не вспыхивает идеальным квадратом); выгорает за счётчик
## жизни в _aux, после чего исчезает. Пока горит — сам себя держит активным.
func _step_fire(x: int, y: int, i: int, id: int) -> void:
	if _has_neighbor_kind(x, y, KIND_LIQUID):
		_cells[i] = EMPTY_ID
		_aux[i] = 0
		_mark_dirty(x, y)
		return

	if _fire_id >= 0:
		_ignite(x + 1, y)
		_ignite(x - 1, y)
		_ignite(x, y + 1)
		_ignite(x, y - 1)

	var life := _aux[i]
	if life == 0:
		life = _burnlife_of[id]  # свежий огонь (кистью) — взять базовую жизнь
	life -= 1
	if life <= 0:
		_cells[i] = EMPTY_ID
		_aux[i] = 0
	else:
		_aux[i] = life
	_mark_dirty(x, y)  # огонь активен, пока не выгорел (само-пометка)


## Поджечь клетку, если она горючая (детерминированный шанс за тик).
func _ignite(x: int, y: int) -> void:
	if not in_bounds(x, y):
		return
	var j := y * width + x
	var nid := _cells[j]
	if nid == EMPTY_ID or _flammable_of[nid] == 0:
		return
	if (_hash3(x, y, tick) & 1) != 0:
		return  # в этот тик не занялось — займётся в следующий
	_cells[j] = _fire_id
	_aux[j] = _burnlife_of[nid]  # горит столько, сколько задано горючему материалу
	_moved_at[j] = tick          # только что создан — не обрабатывать в этот тик
	_mark_dirty(x, y)


## Пустая ли ячейка (за границей по X — стена, не пусто).
func _is_empty(x: int, y: int) -> bool:
	if x < 0 or x >= width:
		return false
	return _cells[y * width + x] == EMPTY_ID


## Клетка (x,y) — жидкость легче, чем порошок powder_id? (порошок в неё тонет)
func _is_lighter_liquid(x: int, y: int, powder_id: int) -> bool:
	if x < 0 or x >= width or y < 0 or y >= height:
		return false
	var oid := _cells[y * width + x]
	if oid == EMPTY_ID or _kind_of[oid] != KIND_LIQUID:
		return false
	return _density_of[powder_id] > _density_of[oid]


func _has_neighbor_kind(x: int, y: int, kind: int) -> bool:
	return _cell_kind(x + 1, y) == kind or _cell_kind(x - 1, y) == kind \
		or _cell_kind(x, y + 1) == kind or _cell_kind(x, y - 1) == kind


func _cell_kind(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return -1
	return _kind_of[_cells[y * width + x]]


## Переместить материал в ПУСТУЮ клетку.
func _move_to_empty(fx: int, fy: int, tx: int, ty: int, id: int) -> void:
	var to_i := ty * width + tx
	_cells[to_i] = id
	_cells[fy * width + fx] = EMPTY_ID
	_moved_at[to_i] = tick
	_mark_dirty(fx, fy)
	_mark_dirty(tx, ty)


## Поменять местами две ЗАНЯТЫЕ клетки (порошок тонет в жидкость).
func _swap_cells(fx: int, fy: int, tx: int, ty: int) -> void:
	var from_i := fy * width + fx
	var to_i := ty * width + tx
	var a := _cells[from_i]
	_cells[from_i] = _cells[to_i]
	_cells[to_i] = a
	_moved_at[from_i] = tick
	_moved_at[to_i] = tick
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


## Целочисленный хеш-финализатор (в духе xxHash): младший бит хорошо распределён
## (простое (x^y^t)&1 давало бы шахматную систематику). Маска 0xFFFFFFFF держит
## значение неотрицательным 32-битным, одинаково на любой машине.
func _hash3(x: int, y: int, t: int) -> int:
	var h := (x * 374761393 + y * 668265263 + t * 2147483647) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return h


## ── Диагностика/тесты ────────────────────────────────────────────────────

func count_material(id: int) -> int:
	var n := 0
	for b in _cells:
		if b == id:
			n += 1
	return n


## FNV-1a 32-бит по всему полю — детерминированная подпись состояния для теста
## воспроизводимости (одинаковый старт + тики -> равный хеш).
func grid_hash() -> int:
	var h := 0x811C9DC5
	for b in _cells:
		h = (h ^ b) & 0xFFFFFFFF
		h = (h * 0x01000193) & 0xFFFFFFFF
	return h


## RGBA8-байты всего поля для отрисовки (Image.create_from_data).
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
