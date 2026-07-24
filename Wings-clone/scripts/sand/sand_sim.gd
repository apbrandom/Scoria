## Ядро клеточной симуляции рельефа (falling-sand). Милстоуны 1+3.
## Чистая логика без сцены/рендера — проверяется headless (tools/test_sand.gd):
## детерминизм, сохранение массы, оседание, корректность dirty-rect, поведение
## воды/огня. Отрисовку/ввод берёт tools/sand_playground.gd.
##
## СТАТУС ВОДЫ (2026-07-24, читать перед тем как патчить _step_liquid ещё раз):
## жидкость здесь — БИНАРНАЯ клетка (есть/нет), известный и принятый предел —
## на большом объёме оседает холмом/буграми, не идеальной плоскостью (не баг,
## математическое свойство локального клеточного правила, см. devlog §36-38,
## notes/terrain_research.md). Это ПРИНЯТО как боевой статус-кво, решение НЕ
## менять его сознательно отложено, не забыто. Альтернатива — модель массы
## (переток под давлением, умеет течь вверх) — доказана на прототипе
## (`tools/liquid_mass_sim.gd` + `tools/test_liquid_mass.gd`, 3/4 инварианта
## зелёные), но НЕ интегрирована сюда: решение "заменить или нет" — отдельная
## осознанная сессия, не патч. Не плодить третий параллельный вариант воды —
## если трогаешь жидкость, сначала прочитай оба файла и текущий статус в
## roadmap.md ("Милстоун 3.5").
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

## Предохранитель для падения связных SOLID+falls объектов (дерево): если
## связная область больше этого числа клеток, в этот тик её не трогаем (см.
## _process_falling_solids). Дешёвая защита от неожиданно огромного объекта —
## не тот "point-fix" баг со связностью, что был у обвала рельефа (devlog
## §29.3): там вопрос был ГЛОБАЛЬНЫЙ ("подключено ли к открытому небу" для
## произвольного куска ЛЮБОЙ земли), здесь — ЛОКАЛЬНЫЙ и ограниченный
## ("есть ли опора конкретно под ЭТИМ помеченным falls=true объектом"),
## применяется только к явно помеченным материалам (дерево), не к базовому
## рельефу (камень как был falls=false, навсегда зафиксирован).
const MAX_FALL_GROUP := 4096

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
## Точное число клеток LIQUID в каждой колонке (индекс — x). Поддерживается
## ИНКРЕМЕНТАЛЬНО в _set_cell_raw — единственном месте, где меняется _cells —
## чтобы горизонтальное правило жидкости сравнивало РЕАЛЬНУЮ высоту столба воды
## в соседней колонке за O(1), а не эвристику по 1 соседней клетке (та не
## дотягивала до полного выравнивания на большом объёме — см. devlog §35/§36).
## Безопасно для dirty-rect: сравнение всегда с колонкой x±1 (в пределах уже
## установленной границы скана +1), а само значение обновляется СИНХРОННО с
## _cells в обоих режимах (opt/полный) одним и тем же кодом — в отличие от
## отброшенной идеи "заглянуть на N клеток вверх" (та СЛОМАЛА бы этот же
## инвариант, потому что читала бы состояние, ещё не обновлённое в опт-режиме).
var _liquid_col_count: PackedInt32Array

## Быстрые таблицы id -> свойство (чтобы в цикле не разыменовывать Resource).
var _kind_of: PackedByteArray
var _density_of: PackedFloat32Array
var _flammable_of: PackedByteArray
var _burnlife_of: PackedInt32Array
var _viscosity_of: PackedFloat32Array
var _inertia_of: PackedFloat32Array
var _falls_of: PackedByteArray
var _ignite_chance_of: PackedFloat32Array
var _edge_creep_of: PackedFloat32Array
var _color_of: Array = []
## id материала с kind==FIRE (во что превращается горючее и что ставит кисть
## огня). -1, если в наборе огня нет — тогда логика огня не работает.
var _fire_id := -1
## Есть ли в наборе хоть один материал SOLID+falls (иначе пропускаем весь
## проход _process_falling_solids каждый тик — "нет фичи = ноль работы").
var _has_falling := false

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
	_liquid_col_count = PackedInt32Array()
	_liquid_col_count.resize(w)   # нулями — колонок с жидкостью пока нет

	var max_id := 0
	for m in materials:
		max_id = maxi(max_id, m.id)
	_kind_of = PackedByteArray();       _kind_of.resize(max_id + 1)
	_density_of = PackedFloat32Array(); _density_of.resize(max_id + 1)
	_flammable_of = PackedByteArray();  _flammable_of.resize(max_id + 1)
	_burnlife_of = PackedInt32Array();  _burnlife_of.resize(max_id + 1)
	_viscosity_of = PackedFloat32Array(); _viscosity_of.resize(max_id + 1)
	_inertia_of = PackedFloat32Array();   _inertia_of.resize(max_id + 1)
	_falls_of = PackedByteArray();        _falls_of.resize(max_id + 1)
	_ignite_chance_of = PackedFloat32Array(); _ignite_chance_of.resize(max_id + 1)
	_edge_creep_of = PackedFloat32Array(); _edge_creep_of.resize(max_id + 1)
	_color_of = []; _color_of.resize(max_id + 1)
	for i in _color_of.size():
		_color_of[i] = Color(0, 0, 0, 0)
	_fire_id = -1
	_has_falling = false
	for m in materials:
		_kind_of[m.id] = m.kind
		_density_of[m.id] = m.density
		_flammable_of[m.id] = 1 if m.flammable else 0
		_burnlife_of[m.id] = m.burn_life
		_viscosity_of[m.id] = m.viscosity
		_inertia_of[m.id] = m.inertia
		_falls_of[m.id] = 1 if m.falls else 0
		_ignite_chance_of[m.id] = m.ignite_chance
		_edge_creep_of[m.id] = m.edge_creep_chance
		_color_of[m.id] = m.color
		if m.kind == KIND_FIRE:
			_fire_id = m.id
		if m.kind == KIND_SOLID and m.falls:
			_has_falling = true

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
	_set_cell_raw(i, id)
	_aux[i] = 0
	_mark_dirty(x, y)


## ЕДИНСТВЕННОЕ место, где меняется _cells[i] — держит _liquid_col_count
## синхронно с реальным содержимым поля. Все остальные функции файла обязаны
## менять материал ячейки только через эту функцию (см. комментарий у
## _liquid_col_count выше — почему это должно быть централизовано).
func _set_cell_raw(i: int, new_id: int) -> void:
	var old_id := _cells[i]
	if old_id == new_id:
		return
	if _kind_of[old_id] == KIND_LIQUID:
		_liquid_col_count[i % width] -= 1
	if _kind_of[new_id] == KIND_LIQUID:
		_liquid_col_count[i % width] += 1
	_cells[i] = new_id


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

	# Падение цельных SOLID+falls объектов (дерево) — отдельный проход ПЕРЕД
	# обычным посимвольным сканом: это движение ГРУППОЙ (весь связный кусок
	# разом), а не одной ячейки, логике _step_cell такое не сформулировать.
	if _has_falling:
		_process_falling_solids(x0, y0, x1, y1)

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


## Жидкость: вниз; по диагонали вниз; иначе горизонтально — В СТОРОНУ КОЛОНКИ
## С МЕНЬШИМ ЗАПАСОМ ЖИДКОСТИ (`_liquid_col_count`, точный счётчик, не
## эвристика по соседней клетке). Двигаемся в пустого соседа по ряду, ТОЛЬКО
## если в моей колонке СТРОГО больше жидкости, чем в его — иначе не двигаемся
## вовсе. Это заменяет две прежние (обе наполовину неверные) версии разом:
##
## v1 "течь только к обрыву" (нужна пустая клетка НИЖЕ соседа) — не давало
## растекаться шире исходного пятна на плоском дне (вода вела себя как песок).
## v2 "давление сверху + сосед не так же высок, окно 1 клетка" — чинило v1, но
## сравнение вслепую по 1 клетке слишком локально: большой объём оседал в
## пологий СКЛОН, а не плоскость (заказчик подтвердил на скриншоте — вода
## всё ещё "не растекается до конца"). Пробовал расширить окно до 48 клеток —
## СЛОМАЛО инвариант dirty-rect==полный проход (чтение состояния за пределами
## гарантированно свежей границы скана — та же природа, что каскадный баг).
##
## Точное сравнение через `_liquid_col_count` безопасно для dirty-rect ИМЕННО
## потому, что это не чтение чужой клетки "с запасом", а инкрементально
## поддерживаемый кэш (обновляется в _set_cell_raw синхронно с _cells), и
## сравнение всегда с колонкой ±1 — той же границей, что уже безопасна для
## всех остальных решений в этом файле.
##
## Порог "минимум на 2 больше", НЕ "хоть на сколько-то больше". С порогом в 1
## пара колонок (3,0) сходится к (2,1) и правильно останавливается — но если
## остаток неразрешим поровну (например, (2,1) от нечётной массы на 2 колонки),
## строгое "больше" гоняло бы ход туда-обратно НАВСЕГДА: после хода (2,1)→(1,2)
## правило видит уже НОВУЮ большую колонку и гонит назад — реальный бесконечный
## пинг-понг, пойманный тестом. Порог 2 принимает разницу в 1 как "уже
## выровнено, дальше не долбим" — соседние колонки могут отличаться на 1
## (неизбежно при нечётной массе), это разрешённый финальный покой, не баг.
##
## НАЙДЕНО ПОЗЖЕ (живой тест заказчика, скриншот "три холма не сливаются"):
## порог 2 сам создаёт ДРУГУЮ проблему — край растекающейся лужи истончается
## до 1 клетки, а с ДЕВСТВЕННОЙ (совсем сухой) соседней колонкой разница ровно
## 1 — навсегда ниже порога. Край физически не может сделать последний шаг в
## новую территорию, при том что is_active() честно считает себя осевшим (не
## дребезг, а неправильный, преждевременный покой). Проверено диагностикой
## (100x50, куча песка + вода на склон, 8000 тиков, is_active()==false, воды
## за пределами исходного пятна = 0).
##
## Пробовал вернуть порог 1 целиком — тут же вернулся старый баг ШИРЕ, чем
## ожидалось: не только одиночная капля, а ЛЮБОЕ тело на много колонок с
## нечётным распределением (тест "большой объём... не дребезжит вечно" тоже
## упал). Инерция (добавлена позже раунда 1) сама по себе НЕ спасает — она
## лишь чуть чаще продолжает то же направление, не устраняет двухтактный цикл.
##
## Пробовал ЖЁСТКОЕ правило "разрешить шаг в девственную колонку без вязкости,
## если в источнике остаётся резерв (count>=2 ДО хода)" — математически это
## оказалось ТОЖДЕСТВЕННО обычному порогу >=2 (count[to]==0 и count[from]>=2
## само по себе уже означает diff=count[from]>=2), проверил перебором и
## прогоном — ни на одном тесте ни на диагностике поведение не поменялось ни
## на бит. Пустая ветка, убрал.
##
## Рабочее решение — SandMaterial.edge_creep_chance: разница ровно в 1 клетку
## с ДЕВСТВЕННОЙ (count==0) соседней колонкой разрешена ВЕРОЯТНОСТНО (тот же
## `_chance()`, что и у вязкости/инертности/огня), а не безусловно. Одиночная
## капля (total mass=1, оба соседа пустые) при малом шансе почти всегда стоит
## смирно — просто изредка подрагивает, а не дребезжит каждый тик; настоящий
## фронт с массой позади (много клеток одновременно бросают кубик) статистически
## почти наверняка продвинется в разумное число тиков, потому что кому-то из
## многих кандидатов повезёт. Честная цена: край лужи НИКОГДА не станет
## идеально неподвижным навсегда (пока есть открытая девственная территория
## рядом) — заведомо принятый компромисс, а не порог "diff>=2" (который
## останавливает целую линию колонок, а не одну клетку).
##
## Вязкость/инертность (SandMaterial.viscosity/inertia): вязкость проверяется
## ТОЛЬКО когда ход уже найден (иначе честно осевшая лужа никогда бы не
## уснула — ложная активность каждый тик). Направление вбок хранится в _aux
## ячейки (1=влево,2=вправо,0=нет памяти) и переносится вместе с частицей при
## любом перемещении; инертность предпочитает повторить его, а не выбирать
## заново по хешу, давая цельный поток, а не дрожь.
func _step_liquid(x: int, y: int, id: int) -> void:
	var i := y * width + x
	var prev_dir: int = _aux[i]

	var tx := x
	var ty := y
	var new_dir := prev_dir
	var found := false
	## Бросок edge_creep_chance в этот тик не выпал, но шанс есть — клетку
	## НЕЛЬЗЯ давать заснуть (выпасть из dirty-rect), иначе она больше никогда
	## не попадёт на переоценку и шанс так и останется неиспользованным навсегда.
	var creep_pending := false

	var below := y + 1
	if below < height and _is_empty(x, below):
		tx = x
		ty = below
		found = true
	else:
		var d := _choose_dir(x, y, prev_dir, id)
		if below < height and _is_empty(x + d, below):
			tx = x + d; ty = below; new_dir = _encode_dir(d); found = true
		elif below < height and _is_empty(x - d, below):
			tx = x - d; ty = below; new_dir = _encode_dir(-d); found = true
		else:
			if _is_empty(x + d, y):
				var r := _liquid_horizontal_flow(x, y, id, x, x + d)
				if r == 1:
					tx = x + d; ty = y; new_dir = _encode_dir(d); found = true
				elif r == 2:
					creep_pending = true
			if not found and _is_empty(x - d, y):
				var r2 := _liquid_horizontal_flow(x, y, id, x, x - d)
				if r2 == 1:
					tx = x - d; ty = y; new_dir = _encode_dir(-d); found = true
				elif r2 == 2:
					creep_pending = true

	if not found:
		if creep_pending:
			_mark_dirty(x, y)  # шанс не выпал в этот тик — попробуем на следующем
		return  # действительно некуда течь — покой, не помечаем грязным

	if _viscosity_of[id] > 0.0 and _chance(x, y, tick, 1) < _viscosity_of[id]:
		_mark_dirty(x, y)  # ход есть, но густая жидкость отложила его на следующий тик
		return

	_move_to_empty(x, y, tx, ty, id)
	_aux[ty * width + tx] = new_dir


## Можно ли жидкости шагнуть из колонки from_col в соседнюю to_col (расчёт —
## см. большой комментарий над _step_liquid). Возврат: 1 — да, двигаться
## прямо сейчас; 2 — шанс был, но бросок в этот тик не выпал (звать снова
## позже, не спать); 0 — хода нет вообще (разница <1, или соседняя колонка не
## девственная и не набрала обычный порог 2, или creep не подпёрт телом сзади).
##
## "Подпёрт" (flanked) — с ПРОТИВОПОЛОЖНОЙ от цели стороны источника есть ещё
## жидкость (count>=1). Без этой проверки одинокая капля (масса=1, ОБА соседа
## всегда девственны) подрагивала бы по chance НАВСЕГДА, никогда не оседая —
## поймано диагностикой (сцена "вода тушит огонь", 20 000 тиков — не осела).
## Настоящий край большого тела всегда подпёрт телом с одной стороны — только
## внешняя грань девственна; одиночка не подпёрта НИКОГДА (обе стороны пустые).
func _liquid_horizontal_flow(x: int, y: int, id: int, from_col: int, to_col: int) -> int:
	var diff := _liquid_col_count[from_col] - _liquid_col_count[to_col]
	if diff >= 2:
		return 1
	if diff == 1 and _liquid_col_count[to_col] == 0 and _edge_creep_of[id] > 0.0:
		var opposite_col := 2 * from_col - to_col
		var flanked := opposite_col >= 0 and opposite_col < width and _liquid_col_count[opposite_col] >= 1
		if not flanked:
			return 0
		if _chance(x, y, tick, 3) < _edge_creep_of[id]:
			return 1
		return 2
	return 0


func _choose_dir(x: int, y: int, prev_dir: int, id: int) -> int:
	var w: float = _inertia_of[id]
	if prev_dir != 0 and w > 0.0 and _chance(x, y, tick, 2) < w:
		return -1 if prev_dir == 1 else 1
	return -1 if (_hash3(x, y, tick) & 1) == 0 else 1


func _encode_dir(d: int) -> int:
	return 1 if d < 0 else 2


## Детерминированный псевдослучайный float в [0,1) — то же семейство, что
## _hash3, но с "солью", чтобы вязкость/инертность/базовое направление не
## коррелировали друг с другом на одной и той же ячейке в один тик.
func _chance(x: int, y: int, t: int, salt: int) -> float:
	var h := _hash3(x * 3 + salt, y * 7 + salt * 13, t)
	return float(h % 10000) / 10000.0


## Огонь: тушится соседней водой; поджигает горючих 4-соседей (детерминированным
## шансом — мерцает, а не вспыхивает идеальным квадратом); выгорает за счётчик
## жизни в _aux, после чего исчезает. Пока горит — сам себя держит активным.
func _step_fire(x: int, y: int, i: int, id: int) -> void:
	if _has_neighbor_kind(x, y, KIND_LIQUID):
		_set_cell_raw(i, EMPTY_ID)
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
		_set_cell_raw(i, EMPTY_ID)
		_aux[i] = 0
	else:
		_aux[i] = life
	_mark_dirty(x, y)  # огонь активен, пока не выгорел (само-пометка)


## Поджечь клетку, если она горючая. Шанс за тик — SandMaterial.ignite_chance
## материала FIRE (не горючего!) — управляет СКОРОСТЬЮ распространения по
## связной горючей массе отдельно от burn_life (сколько горит уже занявшаяся
## клетка). Меньше ignite_chance — огонь ползёт по дереву заметно дольше,
## а не занимает всю связную массу почти мгновенно.
func _ignite(x: int, y: int) -> void:
	if not in_bounds(x, y):
		return
	var j := y * width + x
	var nid := _cells[j]
	if nid == EMPTY_ID or _flammable_of[nid] == 0:
		return
	if _chance(x, y, tick, 4) >= _ignite_chance_of[_fire_id]:
		return  # в этот тик не занялось — займётся в следующий
	_set_cell_raw(j, _fire_id)
	_aux[j] = _burnlife_of[nid]  # горит столько, сколько задано горючему материалу
	_moved_at[j] = tick          # только что создан — не обрабатывать в этот тик
	_mark_dirty(x, y)


## Падение цельных SOLID+falls объектов (дерево): найти связные группы в
## отсканированной области и уронить на 1 клетку те, что потеряли опору.
## Каждая группа находится и обрабатывается один раз за тик (visited).
func _process_falling_solids(x0: int, y0: int, x1: int, y1: int) -> void:
	var visited := {}
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i := y * width + x
			var id := _cells[i]
			if id == EMPTY_ID or _kind_of[id] != KIND_SOLID or _falls_of[id] == 0:
				continue
			if visited.has(i):
				continue
			var group := _flood_fill_falls(x, y, id, visited)
			if group.is_empty():
				continue
			if _group_has_support(group):
				continue
			_try_drop_group(group, id)


## Связная (4-соседи) область одного материала id, начиная от (sx,sy). Пустой
## массив — либо материала там нет (не должно случиться, вызывающий уже
## проверил), либо область превысила MAX_FALL_GROUP (см. его комментарий) —
## тогда этот тик её просто не трогаем, безопасный no-op, не баг.
func _flood_fill_falls(sx: int, sy: int, id: int, visited: Dictionary) -> Array:
	var stack: Array = [Vector2i(sx, sy)]
	var group: Array = []
	visited[sy * width + sx] = true
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		group.append(p)
		if group.size() > MAX_FALL_GROUP:
			return []
		var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
		for d in dirs:
			var np: Vector2i = p + d
			if np.x < 0 or np.x >= width or np.y < 0 or np.y >= height:
				continue
			var ni: int = np.y * width + np.x
			if visited.has(ni):
				continue
			if _cells[ni] == id:
				visited[ni] = true
				stack.append(np)
	return group


## Держит ли что-то группу снизу: дно мира ИЛИ непустая ячейка СНАРУЖИ группы
## прямо под какой-либо её клеткой (ячейки самой группы под собой не считаются —
## это не опора, а часть того же тела).
func _group_has_support(group: Array) -> bool:
	var members := {}
	for p in group:
		var pp: Vector2i = p
		members[pp.y * width + pp.x] = true
	for p in group:
		var pp: Vector2i = p
		var by: int = pp.y + 1
		if by >= height:
			return true
		var bi: int = by * width + pp.x
		if members.has(bi):
			continue
		if _cells[bi] != EMPTY_ID:
			return true
	return false


## Опоры нет — уронить ГРУППУ ЦЕЛИКОМ на 1 клетку вниз, атомарно (сначала все
## клетки очищаются, потом все проставляются на новом месте) — иначе порядок
## обработки внутри одной группы мог бы затереть ещё не прочитанные клетки.
## Если путь вниз хоть где-то перекрыт СНАРУЖИ группы — не падаем вовсе в этот
## тик (жёсткое тело не может продавить препятствие частично).
func _try_drop_group(group: Array, id: int) -> void:
	var members := {}
	for p in group:
		var pp: Vector2i = p
		members[pp.y * width + pp.x] = true
	for p in group:
		var pp: Vector2i = p
		var by: int = pp.y + 1
		if by >= height:
			return
		var bi: int = by * width + pp.x
		if members.has(bi):
			continue
		if _cells[bi] != EMPTY_ID:
			return  # снаружи есть препятствие — не падаем в этот тик

	for p in group:
		var pp: Vector2i = p
		var i: int = pp.y * width + pp.x
		_set_cell_raw(i, EMPTY_ID)
		_aux[i] = 0
	for p in group:
		var pp: Vector2i = p
		var ni: int = (pp.y + 1) * width + pp.x
		_set_cell_raw(ni, id)
		_moved_at[ni] = tick
	for p in group:
		var pp: Vector2i = p
		_mark_dirty(pp.x, pp.y)
		_mark_dirty(pp.x, pp.y + 1)


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
	var from_i := fy * width + fx
	_set_cell_raw(to_i, id)
	_set_cell_raw(from_i, EMPTY_ID)
	_moved_at[to_i] = tick
	_mark_dirty(fx, fy)
	_mark_dirty(tx, ty)


## Поменять местами две ЗАНЯТЫЕ клетки (порошок тонет в жидкость).
func _swap_cells(fx: int, fy: int, tx: int, ty: int) -> void:
	var from_i := fy * width + fx
	var to_i := ty * width + tx
	var a := _cells[from_i]
	var b := _cells[to_i]
	_set_cell_raw(from_i, b)
	_set_cell_raw(to_i, a)
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
