## База — зона ремонта и смены оружия (notes/mechanics.md §4: "ремонт корабля +
## смена оружия кнопками поворота, стоя на базе").
##
## БЕЗ .tscn, узел собирается кодом — как Terrain, MatchManager и
## GlowEnvironment. Причина конкретная: размер зоны живёт в BaseData.zone_size,
## а сцена хранила бы свой размер RectangleShape2D. Получилось бы два источника
## правды на одно число, и правка .tres молча не отражалась бы на коллизии —
## ровно та болезнь, которую заказчик отдельно просил не разводить (roadmap.md,
## "Единый источник физических констант").
##
## Вся логика базы — здесь. Корабль про базы не знает: у него только флаг
## _docked_at, который ставит и снимает отсюда set_docked(). Это позволяет
## добавить командные/неразрушаемые базы (бэклог) без единой правки ship.gd.
class_name BaseZone
extends Area2D

@export var data: BaseData

## Отфильтрованный по selectable арсенал — считается один раз: BaseData общий
## .tres и по ходу матча не меняется.
var _selectable: Array[WeaponData] = []
## Ship -> bool: была ли ось поворота в НЕЙТРАЛИ в прошлом кадре. Нужен фронт, а
## не уровень: ось ShipInput.turn непрерывная и держится нажатой десятки кадров
## подряд, а "следующее оружие" — дискретное событие. Без фронта одно нажатие
## пролистывало бы весь арсенал по кругу за долю секунды.
##
## Словарь на базе, а не поле на корабле: корабль одновременно стоит только на
## одной базе (см. Ship.set_docked), гонки за это состояние нет, зато вся
## механика выбора оружия остаётся в одном файле.
var _turn_neutral: Dictionary = {}


func _ready() -> void:
	if data == null:
		push_error("BaseZone без BaseData — нечего настраивать")
		set_physics_process(false)
		return

	for w in data.weapons:
		if w != null and w.selectable:
			_selectable.append(w)

	var rect := RectangleShape2D.new()
	rect.size = data.zone_size
	var shape := CollisionShape2D.new()
	shape.shape = rect
	add_child(shape)

	add_child(_build_visual())

	# Именно сигналом, а не вычитанием множеств по кадрам: улетевшего корабля в
	# get_overlapping_bodies() уже нет, снять с него флаг больше некому.
	body_exited.connect(_on_body_exited)


## Плейсхолдер-визуал: рамка посадочной площадки. Настоящая графика базы — вместе
## со спрайтом корабля (roadmap.md, "Визуал и звук"), сейчас треугольник-корабль
## и эта рамка одного уровня условности.
func _build_visual() -> Polygon2D:
	var half := data.zone_size / 2.0
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(half.x, half.y), Vector2(-half.x, half.y),
	])
	poly.color = Color(0.35, 0.75, 0.9, 0.25)
	return poly


## Опрос раз в физ-кадр, а не по body_entered: стыковка — это НЕПРЕРЫВНОЕ
## условие ("стоит достаточно медленно"), а не разовое событие входа. Корабль
## может влететь в зону на полной скорости и затормозить внутри — по одному
## лишь body_entered этот момент не поймать.
##
## get_overlapping_bodies() обновляется ровно раз за физ-шаг (доки Area2D 4.7),
## то есть здесь он и читается в свежем виде.
func _physics_process(delta: float) -> void:
	for body in get_overlapping_bodies():
		var ship := body as Ship
		if ship == null:
			continue
		# Труп на базе не чинится и не выбирает оружие: воскрешение — дело
		# MatchManager.respawn(), а не ремонта.
		if not ship.is_alive():
			ship.set_docked(self, false)
			continue

		var docked := ship.linear_velocity.length() <= data.dock_speed_threshold
		ship.set_docked(self, docked)
		if not docked:
			# Пролетающий сквозь зону не должен копить состояние фронта: иначе
			# он "нажал" на пролёте, а сработало бы это при следующей посадке.
			_turn_neutral[ship] = true
			continue

		ship.repair(data.repair_rate * delta)
		_handle_weapon_select(ship)


func _on_body_exited(body: Node2D) -> void:
	var ship := body as Ship
	if ship == null:
		return
	ship.set_docked(self, false)
	_turn_neutral.erase(ship)


## Кнопки поворота на базе листают ВТОРОЙ слот: пулемёт в оригинале постоянный,
## выбирается спецоружие (mechanics.md §4).
func _handle_weapon_select(ship: Ship) -> void:
	var turn := ship.input.turn if ship.input != null else 0.0
	var pressed: bool = absf(turn) >= data.turn_press_threshold
	if pressed and _turn_neutral.get(ship, true):
		_cycle_weapon(ship, 1 if turn > 0.0 else -1)
	_turn_neutral[ship] = not pressed


func _cycle_weapon(ship: Ship, dir: int) -> void:
	if _selectable.is_empty():
		return
	var idx := _selectable.find(ship.secondary_weapon)
	# idx < 0 — на корабле оружие, которого в арсенале ЭТОЙ базы нет: начинаем
	# с начала списка, а не отсчитываем "следующее после несуществующего".
	var next := 0 if idx < 0 else wrapi(idx + dir, 0, _selectable.size())
	# Через equip_secondary, а не присваиванием secondary_weapon: он сбрасывает
	# боезапас и кулдаун нового ствола (ship.gd:126 прямо про этот случай).
	ship.equip_secondary(_selectable[next])
