## Сетевая доставка интентов управления ОДНОГО корабля от его владельца к хосту.
##
## Host-authoritative (architecture.md «Сеть: модель синхронизации»): клиент шлёт
## хосту ТОЛЬКО свой ввод, а состояние корабля (позицию/поворот) считает хост и
## синхронизирует обратно отдельным механизмом (MultiplayerSynchronizer — следующий
## шаг). Здесь — только ввод.
##
## Роли по кадрам:
## - владелец-клиент: читает локальный источник (LocalInput) и шлёт упакованные
##   интенты хосту (unreliable_ordered — важна лишь свежая версия, потерять один
##   пакет не страшно, следующий кадр перекроет);
## - владелец-хост: применяет свои интенты в `remote` сразу, без сети;
## - хост для чужого корабля: получает интенты по RPC в `remote`;
## - не-владелец-клиент: ничего не делает (чужой корабль он не симулирует — его
##   состояние придёт синхронизатором).
##
## НЕ знает про спавн/расстановку: `owner_peer` и `source` ему ЗАДАют снаружи
## (Level при спавне), поэтому узел переиспользуем и не связан с логикой владения.
## Для маршрутизации RPC узел обязан иметь ОДИНАКОВЫЙ путь (имя) относительно
## multiplayer-корня на хосте и у клиента (devlog §24).
class_name ShipInputSync
extends Node

## Кто правит этим кораблём (его unique_id). 1 = хост.
var owner_peer := 1
## Локальный источник интентов у владельца (LocalInput). На не-владельце не нужен.
var source: ShipInput = null
## Итоговые интенты для Ship. На хосте это истина (свои — из source, чужие — из
## RPC). Ship читает это как обычный ShipInput.
var remote := RemoteInput.new()


func _physics_process(delta: float) -> void:
	# Нет сети — этот узел не при делах (одиночную игру ведёт LocalInput напрямую).
	if multiplayer.multiplayer_peer == null:
		return
	# Шлёт/применяет ввод только владелец корабля.
	if multiplayer.get_unique_id() != owner_peer or source == null:
		return
	source.poll(delta)
	var packed := RemoteInput.pack(source)
	if owner_peer == 1:
		# Владелец — сам хост: применяем без сети.
		remote.apply_packed(packed)
	else:
		# Владелец — клиент: отдаём хосту, там применится в его remote.
		_receive_intents.rpc_id(1, packed)


## Исполняется НА ХОСТЕ: сохранить интенты владельца-клиента.
## any_peer — инициатор клиент (не authority узла); unreliable_ordered — поток
## ввода, где важна лишь последняя версия.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_intents(packed: Array) -> void:
	remote.apply_packed(packed)
