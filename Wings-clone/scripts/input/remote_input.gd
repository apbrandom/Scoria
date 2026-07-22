## Источник интентов управления кораблём, приходящих ПО СЕТИ (не с клавиатуры).
## Третий провайдер шва ShipInput (architecture.md §2.3, рядом с LocalInput/AIInput).
## На host-authoritative хосте им правят ЧУЖИЕ корабли: клиент шлёт свои интенты,
## хост складывает их сюда, Ship читает это как обычный ShipInput и не знает, что
## ввод пришёл из сети.
##
## poll() пустой (наследуется от базового): поля выставляются извне —
## apply_packed() из сетевого кода (scripts/net/ship_input_sync.gd), а не читаются
## из устройства.
class_name RemoteInput
extends ShipInput

## Индексы упакованного вида (см. pack/apply_packed). Держим компактным ради
## трафика: массив из 4 значений вместо словаря с ключами-строками.
const I_THRUST := 0
const I_TURN := 1
const I_FIRE1 := 2
const I_FIRE2 := 3


## Упаковать интенты любого ShipInput в компактный вид для RPC.
## Оптимизация на будущее: thrust/fire1/fire2 — биты, можно свернуть в один int
## вместе с квантованным turn; для прототипа массив читаемее и достаточно дёшев.
static func pack(src: ShipInput) -> Array:
	return [src.thrust, src.turn, src.fire_primary, src.fire_secondary]


## Заполнить свои поля из упакованного вида (пришедшего по сети).
func apply_packed(data: Array) -> void:
	if data.size() != 4:
		push_warning("RemoteInput.apply_packed: ждали 4 значения, пришло %d" % data.size())
		return
	thrust = data[I_THRUST]
	turn = data[I_TURN]
	fire_primary = data[I_FIRE1]
	fire_secondary = data[I_FIRE2]
