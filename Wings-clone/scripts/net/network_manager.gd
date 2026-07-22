## Точка входа в сетевой режим: поднять listen-server (хост) или подключиться к
## нему по ENet. Тонкая обёртка над High-Level API Godot — никакого своего
## транспорта (решение и обоснование — notes/architecture.md «Сеть: модель
## синхронизации»). Топология — listen-server (хост = один из игроков), authority
## по миру на хосте; здесь пока только СЛОЙ ПОДКЛЮЧЕНИЯ, он одинаков при любой
## модели authority, поэтому им и начинаем.
##
## Работает через node.multiplayer (path-scoped MultiplayerAPI), НЕ через
## get_tree().get_multiplayer(): так один и тот же класс годится и в реальной игре
## (дефолтный multiplayer), и в headless-тесте, где сервер и клиент подняты в ОДНОМ
## процессе как два поддерева с РАЗНЫМИ MultiplayerAPI (SceneTree.set_multiplayer) —
## node.multiplayer резолвит нужный по месту узла в дереве.
##
## Steam: ENet здесь — прототипный пир (localhost/LAN, ноль зависимостей). Позже
## SteamMultiplayerPeer (аддон GodotSteam) встаёт за тем же интерфейсом
## MultiplayerPeer — этот код и RPC игры не меняются.
class_name NetworkManager
extends Node

## Порт по умолчанию для listen-server. Произвольный высокий, вне типичных диапазонов.
const DEFAULT_PORT := 24545
## 2 игрока = хост + 1 клиент. Хост в max_clients ENet не входит.
const MAX_CLIENTS := 1

## Кто-то подключился: на хосте — id клиента; на клиенте — id хоста (всегда 1).
signal peer_joined(id: int)
## Кто-то отключился (тот же смысл id, что и в peer_joined).
signal peer_left(id: int)
## Клиент успешно подключился к хосту (у клиента; на хосте не эмитится).
signal connected_to_host
## Клиент не смог подключиться (у клиента).
signal connection_failed
## Клиент потерял хост / хост закрылся (у клиента).
signal host_left

var _peer: ENetMultiplayerPeer = null


func _ready() -> void:
	# Подписка на СВОЙ MultiplayerAPI (см. шапку) — один раз, оба режима
	# (host/join) слушают одни и те же сигналы пира.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


## Поднять listen-server. Возвращает OK или код ошибки ENet (например, порт занят).
func host(port := DEFAULT_PORT) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		push_warning("NetworkManager.host: create_server(%d) -> %s" % [port, error_string(err)])
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	return OK


## Подключиться к хосту. OK означает лишь, что запрос отправлен — фактический
## успех/провал придёт сигналом connected_to_host / connection_failed.
func join(address := "127.0.0.1", port := DEFAULT_PORT) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		push_warning("NetworkManager.join: create_client(%s:%d) -> %s" % [address, port, error_string(err)])
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	return OK


## Разорвать соединение и вернуться в оффлайн.
func disconnect_net() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null


## Есть активный сетевой пир (хост или клиент).
func is_networked() -> bool:
	return multiplayer.multiplayer_peer != null


## true — этот процесс authoritative. Оффлайн (пира нет) тоже считаем хостом:
## одиночная игра ведёт себя как listen-server без клиентов, поэтому
## authority-проверки в геймплее не нужно ветвить на "а есть ли вообще сеть".
func is_host() -> bool:
	return not is_networked() or multiplayer.is_server()


## Сетевой id этого пира (хост = 1). Оффлайн — тоже 1 (ведём себя как хост).
func unique_id() -> int:
	return multiplayer.get_unique_id() if is_networked() else 1


func _on_peer_connected(id: int) -> void:
	peer_joined.emit(id)


func _on_peer_disconnected(id: int) -> void:
	peer_left.emit(id)


func _on_connected_to_server() -> void:
	connected_to_host.emit()


func _on_connection_failed() -> void:
	_peer = null
	multiplayer.multiplayer_peer = null
	connection_failed.emit()


func _on_server_disconnected() -> void:
	_peer = null
	multiplayer.multiplayer_peer = null
	host_left.emit()
