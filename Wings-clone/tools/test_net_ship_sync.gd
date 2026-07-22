## Headless-проверка сетевой синхронизации состояния корабля (scenes/ship/ship.tscn:
## узел NetSync — MultiplayerSynchronizer, поля global_position/aim_angle).
##
## Схема как в test_net_input.gd (сервер+клиент в одном процессе, два поддерева с
## отдельными MultiplayerAPI, ручной поллинг, корабль под каждым поддеревом —
## ОДНОГО имени, иначе синхронизатор, как и RPC, не найдёт пару по пути).
##
## Что проверяется: хостовый корабль летит под тягой (host-authoritative — только
## он симулирует физику), клиентская копия того же корабля НЕ считает физику сама
## (заморожена, см. ship.gd Ship._ready()/_is_authority()), а подтягивает
## global_position/aim_angle от хоста через NetSync. Чужой (не свой) корабль на
## клиенте — тоже витрина: серверная копия свободно летает, клиентская молча копирует.
##
## Сходимость проверяется НЕ "клиент == хост в этот же кадр" — при постоянном
## разгоне (thrust+gravity) это в принципе неверно: синхронизатор шлёт снапшот раз
## в физ-тик, поэтому клиент структурно на 1 тик позади (см. _poll_step). Тест
## ведёт точную историю состояний хоста и ищет среди последних MAX_LAG_TICKS
## записей точное совпадение с клиентом (см. _matches_recent_host_state) — не
## "ровно на 1 тик раньше": headless крутит физ-кадры быстрее реального времени
## игры, отчего синхронизатор изредка пропускает такт отправки (не потеря данных,
## а таймер-джиттер синтетического теста — см. константу), и жёсткая проверка "on
## ровно N тиков" флейковала на этом примерно раз в 10-15 прогонов.
##
## Что НЕ проверяется: ввод (test_net_input.gd), спавн с владением
## (MultiplayerSpawner — будущий шаг), carve рельефа по сети (будущий шаг).
##
## Запуск: godot --headless --path Wings-clone res://tools/test_net_ship_sync.tscn
extends Node

const NET_MANAGER_SCRIPT := preload("res://scripts/net/network_manager.gd")
const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const PORT := 24547
const CONNECT_TIMEOUT_FRAMES := 600
## Кадров на прокачку синхронизатора и заметное смещение хоста под тягой.
const RELAY_FRAMES := 30
## Точное сравнение (см. шапку) — допуск только на float-джиттер, не на скорость.
const POS_EPSILON := 0.05
const ANGLE_EPSILON := 0.005
## Сколько последних тактов истории хоста проверяем на совпадение с клиентом —
## см. _matches_recent_host_state.
const MAX_LAG_TICKS := 3

var _pass := 0
var _fail := 0

var _server_mp: MultiplayerAPI
var _client_mp: MultiplayerAPI
var _server_root: Node
var _client_root: Node
var _server_nm: NetworkManager
var _client_nm: NetworkManager
var _client_connected := false

## История состояний host_ship, одна запись за каждый _poll_step_recording().
## history[-1] — состояние ПОСЛЕ последнего физ-шага (то, что видит сам хост);
## history[-2] — состояние на 1 тик раньше (то, что к этому моменту должен видеть
## клиент — см. пояснение порядка поллинга в _poll_step).
var _history: Array[Dictionary] = []


func _ready() -> void:
	print("=== Проверка синхронизации корабля (NetSync/MultiplayerSynchronizer, %s) ===" % DisplayServer.get_name())

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
	# Хост раньше клиента (в отличие от test_net_input.gd, где поток обратный):
	# здесь authority — хост, его NetSync отправляет состояние ПЕРВЫМ, чтобы
	# клиент получил его этим же шагом, а не на следующем кадре.
	_server_mp.poll()
	_client_mp.poll()
	await get_tree().physics_frame


## _poll_step() + запись состояния хоста в _history сразу после физ-шага —
## используется вместо голого _poll_step() везде, где потом сверяем клиента
## с историей (см. шапку файла).
func _poll_step_recording(host_ship: Ship) -> void:
	await _poll_step()
	_history.append({"pos": host_ship.global_position, "angle": host_ship.aim_angle})


## true, если client_pos/client_angle совпадают (в пределах эпсилон) хоть с одной
## из последних MAX_LAG_TICKS записей истории хоста — см. константу выше.
func _matches_recent_host_state(client_pos: Vector2, client_angle: float) -> bool:
	var n := _history.size()
	for back in range(2, mini(MAX_LAG_TICKS, n - 1) + 1):
		var entry: Dictionary = _history[n - back]
		if (entry.pos as Vector2).distance_to(client_pos) <= POS_EPSILON \
				and absf((entry.angle as float) - client_angle) <= ANGLE_EPSILON:
			return true
	return false


## Пара одноимённых кораблей (под сервером и под клиентом) — NetSync находит
## партнёра по пути относительно multiplayer-корня, поэтому имена обязаны совпадать
## (тот же приём, что и с ShipInputSync в test_net_input.gd).
func _make_ship_pair(node_name: String) -> Array:
	var host_ship: Ship = SHIP_SCENE.instantiate()
	host_ship.name = node_name
	host_ship.data = SHIP_DATA
	host_ship.input = ShipInput.new()
	_server_root.add_child(host_ship)

	var client_ship: Ship = SHIP_SCENE.instantiate()
	client_ship.name = node_name
	client_ship.data = SHIP_DATA
	client_ship.input = ShipInput.new()
	_client_root.add_child(client_ship)
	return [host_ship, client_ship]


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

	var pair := _make_ship_pair("Ship")
	var host_ship: Ship = pair[0]
	var client_ship: Ship = pair[1]
	await _poll_step()  # дать отработать _ready() (freeze на клиенте) до проверок
	_history.append({"pos": host_ship.global_position, "angle": host_ship.aim_angle})

	# --- 1. Authority расставлена верно дефолтом, без ручного set_multiplayer_authority ---
	_check("хостовый корабль — authority (симулирует сам)", host_ship.is_multiplayer_authority())
	_check("клиентская копия — НЕ authority", not client_ship.is_multiplayer_authority())
	_check("клиентская копия заморожена (не считает физику сама)", client_ship.freeze)
	_check("хостовый корабль НЕ заморожен", not host_ship.freeze)

	# --- 2. Хост летит под тягой и поворачивается; клиент подтягивает состояние ---
	host_ship.input.thrust = true
	host_ship.input.turn = 1.0
	for _i in RELAY_FRAMES:
		await _poll_step_recording(host_ship)

	var moved := host_ship.global_position.distance_to(Vector2.ZERO) > 5.0
	_check("хост реально сдвинулся под тягой", moved,
		"pos=%s" % host_ship.global_position)
	_check("aim_angle хоста изменился от turn", not is_equal_approx(host_ship.aim_angle, 0.0),
		"aim_angle=%.3f" % host_ship.aim_angle)

	_check("позиция и aim_angle клиента совпадают с одним из последних состояний хоста",
		_matches_recent_host_state(client_ship.global_position, client_ship.aim_angle),
		"client=%s/%.4f, последние состояния хоста: %s" %
			[client_ship.global_position, client_ship.aim_angle, _history.slice(-3)])

	# --- 3. Поток обновляется: хост продолжает лететь — клиент не застревает на первом значении ---
	var client_pos_before := client_ship.global_position
	for _i in RELAY_FRAMES:
		await _poll_step_recording(host_ship)
	_check("хост продолжил двигаться", not host_ship.global_position.is_equal_approx(client_pos_before))
	_check("клиент обновился вслед за хостом (не залип)",
		not client_ship.global_position.is_equal_approx(client_pos_before),
		"было=%s стало=%s" % [client_pos_before, client_ship.global_position])
	_check("позиция клиента по-прежнему совпадает с одним из последних состояний хоста",
		_matches_recent_host_state(client_ship.global_position, client_ship.aim_angle),
		"client=%s/%.4f, последние состояния хоста: %s" %
			[client_ship.global_position, client_ship.aim_angle, _history.slice(-3)])

	# --- 4. Клиент не двигает корабль сам: заданный ему input.thrust ни на что не влияет ---
	client_ship.input.thrust = true
	client_ship.input.turn = -1.0
	for _i in 10:
		await _poll_step_recording(host_ship)
	_check("client_ship.input игнорируется (не authority) — клиент всё ещё точно следует за хостом",
		_matches_recent_host_state(client_ship.global_position, client_ship.aim_angle),
		"client=%s/%.4f, последние состояния хоста: %s" %
			[client_ship.global_position, client_ship.aim_angle, _history.slice(-3)])

	_client_nm.disconnect_net()
	_server_nm.disconnect_net()
