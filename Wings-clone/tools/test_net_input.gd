## Headless-проверка сетевого шва ВВОДА (scripts/net/ship_input_sync.gd +
## scripts/input/remote_input.gd): интенты владельца доезжают в RemoteInput хоста.
##
## Схема как в test_net.gd (сервер+клиент в одном процессе, два поддерева с
## отдельными MultiplayerAPI, ручной поллинг). Отличие: под каждым поддеревом —
## ShipInputSync с ОДИНАКОВЫМ именем (RPC маршрутизируется по пути относительно
## multiplayer-корня, поэтому имена обязаны совпадать — это и проверяем).
##
## Что НЕ проверяется: синхронизация позиции корабля (следующий шаг,
## MultiplayerSynchronizer) и ощущение управления по сети вживую (на глаз, на
## другой машине). Здесь только: клиент шлёт ввод -> хост его получает.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_net_input.tscn
extends Node

const NET_MANAGER_SCRIPT := preload("res://scripts/net/network_manager.gd")
const SHIP_INPUT_SYNC_SCRIPT := preload("res://scripts/net/ship_input_sync.gd")
const PORT := 24546
const CONNECT_TIMEOUT_FRAMES := 600
## Кадров на прокачку RPC-потока: unreliable_ordered на loopback доезжает за
## единицы кадров, берём с запасом.
const RELAY_FRAMES := 20

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
	print("=== Проверка сетевого ввода (ShipInputSync/RemoteInput, %s) ===" % DisplayServer.get_name())

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
	# Клиент раньше хоста: сначала отправить исходящее, потом принять на хосте.
	_client_mp.poll()
	_server_mp.poll()
	await get_tree().physics_frame


## Создать пару одноимённых ShipInputSync (под сервером и под клиентом).
## Возвращает [host_sync, client_sync].
func _make_sync_pair(node_name: String, owner_peer: int,
		host_source: ShipInput, client_source: ShipInput) -> Array:
	var host_sync: ShipInputSync = SHIP_INPUT_SYNC_SCRIPT.new()
	host_sync.name = node_name
	host_sync.owner_peer = owner_peer
	host_sync.source = host_source
	_server_root.add_child(host_sync)

	var client_sync: ShipInputSync = SHIP_INPUT_SYNC_SCRIPT.new()
	client_sync.name = node_name   # ТО ЖЕ имя — иначе RPC не найдёт цель на хосте
	client_sync.owner_peer = owner_peer
	client_sync.source = client_source
	_client_root.add_child(client_sync)
	return [host_sync, client_sync]


func _make_intents(thrust: bool, turn: float, f1: bool, f2: bool) -> ShipInput:
	# Базовый ShipInput: poll() пустой, поля держатся как выставили.
	var s := ShipInput.new()
	s.thrust = thrust
	s.turn = turn
	s.fire_primary = f1
	s.fire_secondary = f2
	return s


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
	var client_id := _client_nm.unique_id()

	# --- 1. Корабль КЛИЕНТА: его ввод доезжает в remote ХОСТА по RPC ---
	var client_src := _make_intents(true, -1.0, true, false)
	var pair_b := _make_sync_pair("ShipBSync", client_id, null, client_src)
	var host_b: ShipInputSync = pair_b[0]

	for _i in RELAY_FRAMES:
		await _poll_step()

	_check("хост получил thrust клиента", host_b.remote.thrust == true)
	_check("хост получил turn клиента", is_equal_approx(host_b.remote.turn, -1.0),
		"turn=%.2f" % host_b.remote.turn)
	_check("хост получил fire_primary клиента", host_b.remote.fire_primary == true)
	_check("хост получил fire_secondary клиента", host_b.remote.fire_secondary == false)

	# --- 2. Поток обновляется: меняем ввод клиента — хост видит новое ---
	client_src.thrust = false
	client_src.turn = 1.0
	client_src.fire_secondary = true
	for _i in RELAY_FRAMES:
		await _poll_step()

	_check("хост увидел обновление thrust", host_b.remote.thrust == false)
	_check("хост увидел обновление turn", is_equal_approx(host_b.remote.turn, 1.0),
		"turn=%.2f" % host_b.remote.turn)
	_check("хост увидел обновление fire_secondary", host_b.remote.fire_secondary == true)

	# --- 3. Корабль ХОСТА: свой ввод применяется локально, без сети ---
	var host_src := _make_intents(true, 0.5, false, true)
	var pair_a := _make_sync_pair("ShipASync", 1, host_src, null)
	var host_a: ShipInputSync = pair_a[0]
	var client_a: ShipInputSync = pair_a[1]

	for _i in RELAY_FRAMES:
		await _poll_step()

	_check("хост применил свой thrust локально", host_a.remote.thrust == true)
	_check("хост применил свой turn локально", is_equal_approx(host_a.remote.turn, 0.5),
		"turn=%.2f" % host_a.remote.turn)
	_check("хост применил свой fire_secondary локально", host_a.remote.fire_secondary == true)
	# Клиент не владеет кораблём хоста — его remote остаётся пустым (он этот
	# корабль не симулирует, состояние придёт синхронизатором).
	_check("клиент НЕ трогает чужой (хостовый) ввод", client_a.remote.thrust == false)

	_client_nm.disconnect_net()
	_server_nm.disconnect_net()
