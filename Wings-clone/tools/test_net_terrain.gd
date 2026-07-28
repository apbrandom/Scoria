## Headless-проверка сетевой репликации carve рельефа (scripts/net/terrain_net_sync.gd):
## хост режет рельеф несколькими carve_circle(), клиент обязан прийти к БИТ-В-БИТ
## идентичному результату через reliable @rpc-реплей, а не пересчитать что-то своё.
##
## Схема как в test_net_ship_sync.gd (сервер+клиент в одном процессе, два поддерева
## с отдельными MultiplayerAPI, ручной поллинг). Рельеф — простая сплошная порода
## без маски (тот же приём, что test_ship.gd: vis.fill(...), без mask.png = вся
## площадь default_solid_class) — детерминированно и гарантированно carvable, в
## отличие от процедурного TestLevelGen, где попадание carve именно в породу, а не
## в воздух/INDESTRUCTIBLE-кайму, зависело бы от шума.
##
## Что проверяется: несколько carve (включая пересекающиеся, где порядок наложения
## важен) на хосте -> тот же класс КАЖДОГО пикселя на клиенте (не только агрегатный
## count_solid — он не ловит "то же количество, но не там"); коллизия
## (total_segments()) тоже сходится после flush_dirty() на обеих сторонах; на
## холостых кадрах без новых carve рельеф не расходится сам по себе.
##
## Что НЕ проверяется: полный ресинк для позже подключившегося клиента (здесь оба
## грузят один и тот же Image локально с самого старта — контрольная сумма/ресинк
## при расхождении, roadmap.md, отдельный будущий шаг), сама доставка через
## настоящий межпроцессный ENet (проверено на уровне подключения в test_net.gd) —
## здесь фокус на корректности replay, не транспорта.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_net_terrain.tscn
extends Node

const NET_MANAGER_SCRIPT := preload("res://scripts/net/network_manager.gd")
const TERRAIN_NET_SYNC_SCRIPT := preload("res://scripts/net/terrain_net_sync.gd")
const PALETTE := preload("res://data/terrain/wings_classes.tres")
const PORT := 24548
const CONNECT_TIMEOUT_FRAMES := 600
## Кадров ожидания после carve на хосте, чтобы reliable RPC успел доехать и
## клиент применил реплей — локальный loopback ENet в одном процессе доставляет
## за считанные кадры, запас здесь только против флейка на медленной машине.
const RELAY_FRAMES := 10
## Кадров простоя СРАЗУ после того, как клиент подключился, ПЕРЕД первым RPC.
## Не перестраховка "на всякий случай" — без этого зазора первый же _replay_carve
## после коннекта ТЕРЯЕТСЯ надёжно и стабильно (проверено многократными прогонами:
## 1 кадр — 100% провал, 2+ — устойчиво ОК), причём именно ПЕРВЫЙ RPC на новом
## соединении, все последующие идут нормально даже без задержки между ними. Это
## известная особенность Godot 4 SceneMultiplayer: `peer_connected`/
## `connected_to_server` сигналят по низкоуровневому ENet-рукопожатию РАНЬШЕ, чем
## сам SceneMultiplayer успевает завершить свою внутреннюю настройку пира — RPC,
## отправленный в этом окне, молча пропадает без ошибки на любой стороне (см.
## godotengine/godot#68750 "RPCs do not work during MultiplayerPeer signals",
## рекомендованный воркэраунд — не дёргать RPC сразу в обработчике сигнала, а
## дать пройти хотя бы одному кадру). Здесь это не гипотетический edge-case
## реальной игры (там между коннектом и первым carve всегда проходят секунды
## геймплея), а именно свойство ЭТОГО двух-MultiplayerAPI-в-одном-процессе
## тестового стенда — но обходить всё равно нужно, иначе тест флейкует.
const CONNECT_SETTLE_FRAMES := 5
const LEVEL_SIZE := Vector2i(200, 200)

var _pass := 0
var _fail := 0

var _server_mp: MultiplayerAPI
var _client_mp: MultiplayerAPI
var _server_root: Node
var _client_root: Node
var _server_nm: NetworkManager
var _client_nm: NetworkManager
var _client_connected := false


func _ready() -> void:
	print("=== Проверка репликации carve рельефа (TerrainNetSync, %s) ===" % DisplayServer.get_name())

	_server_root = Node.new()
	_server_root.name = "ServerRoot"
	add_child(_server_root)
	_client_root = Node.new()
	_client_root.name = "ClientRoot"
	add_child(_client_root)

	_server_mp = MultiplayerAPI.create_default_interface()
	_client_mp = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(_server_mp, _server_root.get_path())
	get_tree().set_multiplayer(_client_mp, _client_root.get_path())
	get_tree().multiplayer_poll = false

	_server_nm = NET_MANAGER_SCRIPT.new()
	_server_root.add_child(_server_nm)
	_client_nm = NET_MANAGER_SCRIPT.new()
	_client_root.add_child(_client_nm)
	_client_nm.connected_to_host.connect(func() -> void: _client_connected = true)

	await _run()

	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


func _poll_step() -> void:
	_server_mp.poll()
	_client_mp.poll()
	await get_tree().physics_frame


## Пара одноимённых Terrain (под сервером и под клиентом), с TerrainNetSync-ребёнком
## под тем же именем "NetSync" на каждом — RPC матчит по пути, оба обязаны совпасть
## (тот же приём, что ShipInputSync/NetSync в ship.tscn, см. terrain_net_sync.gd).
func _make_terrain_pair(node_name: String) -> Array:
	var vis := Image.create(LEVEL_SIZE.x, LEVEL_SIZE.y, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0.5, 0.3, 0.1, 1.0))  # сплошная порода, без маски = default_solid_class

	var host_terrain := Terrain.new()
	host_terrain.name = node_name
	host_terrain.palette = PALETTE
	host_terrain.immediate_rebuild = true
	_server_root.add_child(host_terrain)
	host_terrain.load_level(vis)
	var host_sync := TERRAIN_NET_SYNC_SCRIPT.new()
	host_sync.name = "NetSync"
	host_terrain.add_child(host_sync)
	host_sync.terrain = host_terrain

	var client_terrain := Terrain.new()
	client_terrain.name = node_name
	client_terrain.palette = PALETTE
	client_terrain.immediate_rebuild = true
	_client_root.add_child(client_terrain)
	client_terrain.load_level(vis)
	var client_sync := TERRAIN_NET_SYNC_SCRIPT.new()
	client_sync.name = "NetSync"
	client_terrain.add_child(client_sync)
	client_sync.terrain = client_terrain

	return [host_terrain, client_terrain]


## Сравнение класса КАЖДОГО пикселя — сильнее агрегатного count_solid(): ловит
## случай "то же количество твёрдых клеток, но не в тех местах".
func _terrains_match(a: Terrain, b: Terrain) -> bool:
	if a.size != b.size:
		return false
	for y in a.size.y:
		for x in a.size.x:
			var p := Vector2i(x, y)
			if a.class_at(p) != b.class_at(p):
				return false
	return true


func _run() -> void:
	# --- соединение ---
	var host_err := _server_nm.host(PORT)
	_check("host() поднял сервер", host_err == OK, "err=%s" % error_string(host_err))
	if host_err != OK:
		return
	var join_err := _client_nm.join("127.0.0.1", PORT)
	_check("join() отправил запрос", join_err == OK, "err=%s" % error_string(join_err))
	if join_err != OK:
		return
	var frames := 0
	while frames < CONNECT_TIMEOUT_FRAMES and not _client_connected:
		await _poll_step()
		frames += 1
	_check("клиент подключился", _client_connected, "кадров: %d" % frames)
	if not _client_connected:
		return

	var pair := _make_terrain_pair("Terrain")
	var host_t: Terrain = pair[0]
	var client_t: Terrain = pair[1]
	for _i in CONNECT_SETTLE_FRAMES:
		await _poll_step()

	# --- 0. Стартовое состояние совпадает (тот же Image загружен локально с обеих сторон) ---
	_check("рельеф хоста и клиента совпадает ДО всякого carve", _terrains_match(host_t, client_t))

	# --- 1. Один carve на хосте доезжает до клиента ---
	var solid_before := host_t.count_solid()
	host_t.carve_circle(Vector2i(60, 60), 15)
	var changed := solid_before - host_t.count_solid()
	_check("carve реально что-то вырезал на хосте", changed > 0, "changed=%d" % changed)
	for _i in RELAY_FRAMES:
		await _poll_step()
	_check("одиночный carve реплицировался клиенту бит-в-бит", _terrains_match(host_t, client_t))

	# --- 2. Несколько carve подряд, включая пересекающиеся — порядок наложения важен ---
	host_t.carve_circle(Vector2i(100, 100), 20)
	host_t.carve_circle(Vector2i(108, 100), 20)   # пересекается с предыдущим
	host_t.carve_circle(Vector2i(30, 150), 12)
	for _i in RELAY_FRAMES:
		await _poll_step()
	_check("серия пересекающихся carve реплицировалась в том же порядке (reliable)",
		_terrains_match(host_t, client_t))

	# --- 3. Коллизия (не только видимый класс) тоже пересобралась одинаково ---
	host_t.flush_dirty()
	client_t.flush_dirty()
	_check("число сегментов коллизии совпадает после пересборки",
		host_t.total_segments() == client_t.total_segments(),
		"host=%d client=%d" % [host_t.total_segments(), client_t.total_segments()])

	# --- 4. Без новых carve рельеф не расходится сам по себе на холостых кадрах ---
	for _i in RELAY_FRAMES:
		await _poll_step()
	_check("рельеф хоста и клиента остаются идентичны без новых carve (нет самопроизвольного дрейфа)",
		_terrains_match(host_t, client_t))

	_client_nm.disconnect_net()
	_server_nm.disconnect_net()
