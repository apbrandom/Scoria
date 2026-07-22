## Headless-проверка слоя подключения (scripts/net/network_manager.gd): реальный
## коннект по ENet между хостом и клиентом, поднятыми в ОДНОМ процессе.
##
## Как это возможно без двух процессов: сервер и клиент живут в двух поддеревьях
## (ServerRoot / ClientRoot), каждому назначен свой MultiplayerAPI через
## SceneTree.set_multiplayer(). NetworkManager работает через node.multiplayer
## (path-scoped), поэтому под ServerRoot он видит серверный API, под ClientRoot —
## клиентский, и они соединяются по 127.0.0.1 как две отдельные машины.
##
## Авто-поллинг дерева выключен (multiplayer_poll=false) — оба API поллим вручную
## в цикле шага, чтобы коннект был детерминирован и не зависел от того, в какой
## фазе кадра дерево опрашивает сеть.
##
## Камеру/HUD/"ощущение" сети это не проверяет — только факт установки соединения
## и что дружелюбные сигналы NetworkManager срабатывают. Игру вдвоём по-настоящему
## смотреть двумя инстансами в окне (та же конвенция "красоту глазами", что и в
## test_match.gd).
##
## Запуск: godot --headless --path Wings-clone res://tools/test_net.tscn
extends Node

const NET_MANAGER_SCRIPT := preload("res://scripts/net/network_manager.gd")
const PORT := 24545
## Потолок ожидания коннекта в физ-кадрах. Localhost-хендшейк ENet укладывается
## в единицы кадров; большой запас — только чтобы не флейкнуть на нагруженной
## машине. При успехе выходим из цикла сразу, не ждём потолок.
const CONNECT_TIMEOUT_FRAMES := 600

var _pass := 0
var _fail := 0

var _server_mp: MultiplayerAPI
var _client_mp: MultiplayerAPI
var _server_nm: NetworkManager
var _client_nm: NetworkManager

# Флаги, которые выставляют обработчики сигналов NetworkManager (именованные, не
# лямбды — как в match_manager.gd, без неоднозначностей захвата).
var _server_saw_join := -1
var _server_saw_leave := -1
var _client_saw_join := -1
var _client_connected := false
var _client_failed := false


func _ready() -> void:
	print("=== Проверка NetworkManager / ENet-коннект (%s) ===" % DisplayServer.get_name())

	# Два поддерева под отдельные MultiplayerAPI.
	var server_root := Node.new()
	server_root.name = "ServerRoot"
	add_child(server_root)
	var client_root := Node.new()
	client_root.name = "ClientRoot"
	add_child(client_root)

	_server_mp = MultiplayerAPI.create_default_interface()
	_client_mp = MultiplayerAPI.create_default_interface()
	# Пути должны существовать в дереве до set_multiplayer — потому root'ы уже added.
	get_tree().set_multiplayer(_server_mp, server_root.get_path())
	get_tree().set_multiplayer(_client_mp, client_root.get_path())
	# Ручной поллинг обоих API (см. шапку).
	get_tree().multiplayer_poll = false

	# NetworkManager добавляем ПОСЛЕ set_multiplayer, чтобы их _ready подписался
	# на нужный (scoped) API.
	_server_nm = NET_MANAGER_SCRIPT.new()
	server_root.add_child(_server_nm)
	_client_nm = NET_MANAGER_SCRIPT.new()
	client_root.add_child(_client_nm)

	_server_nm.peer_joined.connect(_on_server_join)
	_server_nm.peer_left.connect(_on_server_leave)
	_client_nm.peer_joined.connect(_on_client_join)
	_client_nm.connected_to_host.connect(_on_client_connected)
	_client_nm.connection_failed.connect(_on_client_failed)

	await _run()

	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


## Поллит оба API и ждёт кадр. Именно здесь двигается ENet-хендшейк.
func _poll_step() -> void:
	_server_mp.poll()
	_client_mp.poll()
	await get_tree().physics_frame


func _run() -> void:
	var host_err := _server_nm.host(PORT)
	_check("host() поднял сервер (OK)", host_err == OK, "err=%s" % error_string(host_err))
	if host_err != OK:
		return   # порт занят/недоступен — дальше проверять нечего, не висим

	var join_err := _client_nm.join("127.0.0.1", PORT)
	_check("join() отправил запрос (OK)", join_err == OK, "err=%s" % error_string(join_err))
	if join_err != OK:
		return

	# Ждём коннект (или таймаут / провал).
	var frames := 0
	while frames < CONNECT_TIMEOUT_FRAMES:
		await _poll_step()
		frames += 1
		if _client_failed:
			break
		if _client_connected and _server_saw_join >= 0:
			break

	_check("клиент подключился к хосту (connected_to_host)", _client_connected,
		"кадров ждали: %d" % frames)
	_check("соединение НЕ провалилось (connection_failed не пришёл)", not _client_failed)
	_check("хост увидел подключение клиента (peer_joined)", _server_saw_join >= 0,
		"id=%d" % _server_saw_join)
	_check("клиент увидел хост как пир id=1", _client_saw_join == 1,
		"id=%d" % _client_saw_join)

	# Идентичность пиров.
	_check("хост имеет unique_id == 1", _server_nm.unique_id() == 1,
		"id=%d" % _server_nm.unique_id())
	_check("клиент имеет unique_id != 1 и != 0", _client_nm.unique_id() > 1,
		"id=%d" % _client_nm.unique_id())
	_check("id клиента на хосте совпал с его unique_id",
		_server_saw_join == _client_nm.unique_id(),
		"host видел %d, у клиента %d" % [_server_saw_join, _client_nm.unique_id()])

	# Роли.
	_check("is_host(): сервер = true", _server_nm.is_host())
	_check("is_host(): клиент = false", not _client_nm.is_host())
	_check("is_networked(): оба в сети", _server_nm.is_networked() and _client_nm.is_networked())

	# Разрыв: клиент уходит, хост должен это увидеть.
	var expected_leave := _client_nm.unique_id()
	_client_nm.disconnect_net()
	var left_frames := 0
	while left_frames < CONNECT_TIMEOUT_FRAMES and _server_saw_leave < 0:
		await _poll_step()
		left_frames += 1
	_check("хост увидел отключение клиента (peer_left)", _server_saw_leave == expected_leave,
		"ждали id=%d, видели id=%d" % [expected_leave, _server_saw_leave])
	_check("клиент после disconnect_net() снова оффлайн", not _client_nm.is_networked())
	_check("оффлайн-клиент ведёт себя как хост (is_host()=true)", _client_nm.is_host())

	_server_nm.disconnect_net()


func _on_server_join(id: int) -> void:
	_server_saw_join = id


func _on_server_leave(id: int) -> void:
	_server_saw_leave = id


func _on_client_join(id: int) -> void:
	_client_saw_join = id


func _on_client_connected() -> void:
	_client_connected = true


func _on_client_failed() -> void:
	_client_failed = true
