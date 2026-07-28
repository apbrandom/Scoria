## Сетевая репликация carve рельефа: хост шлёт клиентам (center, radius) события
## Terrain.carved по reliable @rpc, клиент детерминированно повторяет тот же
## carve_circle() у себя — получает БИТ-В-БИТ идентичный результат, не сам
## Image/BitMap (architecture.md «Сеть: модель синхронизации» → «Carve рельефа:
## событие»).
##
## Почему не MultiplayerSynchronizer: подтверждено докой 4.7 — не поддерживает
## Object/Resource, рельеф 1200×1200 через него не прогнать (devlog §23.1).
## Почему не полный diff (список изменившихся пикселей): рельеф детерминирован
## (тот же center/radius по тому же состоянию = тот же результат — фиксированный
## seed edge-шума, см. Terrain._get_edge_noise), значит достаточно передать
## НАМЕРЕНИЕ (что вырезать), а не РЕЗУЛЬТАТ (какие пиксели изменились).
##
## Как и ShipInputSync (scripts/net/ship_input_sync.gd) — для маршрутизации RPC
## узел обязан иметь ОДИНАКОВЫЙ путь относительно multiplayer-корня на хосте и у
## клиента: добавлять ребёнком к Terrain под тем же именем ("NetSync") в обоих
## деревьях (см. net_playground.gd).
##
## Хост — единственный источник carve в реальной игре (host-authoritative: только
## хост по-настоящему симулирует столкновения/попадания — clients держат чужие и
## свои корабли замороженными, см. ship_input_sync.gd). "authority" в @rpc ниже
## достаточен без ручного set_multiplayer_authority: authority узла по умолчанию —
## 1 (хост), см. офиц. доку 4.7 High-Level Multiplayer.
class_name TerrainNetSync
extends Node

## Рельеф, чьи carve рассылаются/на котором реплеятся — выставляется снаружи,
## см. net_playground.gd и tools/test_net_terrain.gd.
var terrain: Terrain = null:
	set(value):
		if terrain != null and terrain.carved.is_connected(_on_carved):
			terrain.carved.disconnect(_on_carved)
		terrain = value
		if terrain != null:
			terrain.carved.connect(_on_carved)


## Нет сети — рассылать некому, carve уже применён локальным вызовом carve_circle.
## Есть сеть, но мы не хост — это чужой carve, реплей придёт RPC-ом; свой
## carve_circle() (которого в host-authoritative режиме у клиента и не должно
## быть) этот узел на клиенте не рассылает.
func _on_carved(center: Vector2i, radius: int, _area: Rect2i) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if not multiplayer.is_server():
		return
	_replay_carve.rpc(center, radius)


## Исполняется НА КЛИЕНТАХ: повторить тот же carve_circle(), что хост уже применил
## у себя. "authority" — вызвать может только хост (id=1 по умолчанию); "call_remote" —
## хосту самому это не нужно, он уже вырезал прямым вызовом carve_circle() (см.
## _on_carved); "reliable" — порядок наложения пересекающихся carve обязан
## совпасть 1-в-1 с хостом (architecture.md, «Authority vs Transmission»).
@rpc("authority", "call_remote", "reliable")
func _replay_carve(center: Vector2i, radius: int) -> void:
	terrain.carve_circle(center, radius)
