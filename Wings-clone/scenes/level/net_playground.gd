## Ручная песочница для живой проверки сетевой синхронизации корабля МЕЖДУ ДВУМЯ
## РЕАЛЬНЫМИ ПРОЦЕССАМИ Godot (не in-process тест, как tools/test_net_ship_sync.gd, —
## там сервер и клиент жили в одном процессе на двух MultiplayerAPI; здесь
## проверяется настоящий ENet по loopback между двумя ОС-процессами/окнами).
##
## Роль (хост/клиент) БЕЗ ФЛАГОВ определяется сама: кто первым занял
## DEFAULT_PORT — тот хост, остальные не смогли забиндиться → джойнятся на
## 127.0.0.1 (см. _ready). Бинд UDP-порта атомарен на уровне ОС, гонки без
## однозначного победителя не бывает. Это сделано специально ради Godot'овского
## Debug → Customize Run Instances / Run Multiple Instances: та кнопка запускает
## все копии ОДНОЙ и той же командой (Main Run Args общие на все инстансы, per-
## instance аргументов Godot 4.3+ не даёт — проверено), так что через
## --host/--join разные роли этим способом не назначить. Запуск:
##   Godot editor → Debug → Customize Run Instances → Enable Multiple Instances,
##   2 инстанса → Play — оба окна сами разберутся, кто есть кто.
## Явные флаги остаются для случая, где авто не годится (две РАЗНЫЕ машины —
## порты независимы, гонки за bind нет): `-- --host` форсирует хоста,
## `-- --join=<ip>` — клиента на конкретный адрес. Без Godot editor, из
## терминала (2 отдельных терминала, из каталога Wings-clone):
##   godot --path . res://scenes/level/net_playground.tscn        (оба окна —
##   одна и та же команда, роль определится сама)
##
## Управление в ОБОИХ окнах — экшены p1_* (project.godot): ← → поворот, ↑ тяга.
## Оружие сознательно НЕ выдано (primary/secondary_weapon не заданы) — эта
## песочница проверяет ТОЛЬКО позицию/aim_angle (devlog §25); стрельба и попадания
## по сети ещё не реплицируются, поэтому здесь её и нет, чтобы не создавать
## впечатление сломанной механики там, где механики попросту ещё нет.
## ESC — выход.
##
## Сознательно НЕ MatchManager и НЕ меню (это будущие roadmap-шаги — devlog §25.6,
## «вплетение NetworkManager в реальный поток») — минимум: NetworkManager + два
## Ship (host-корабль/client-корабль), у каждого свой ShipInputSync
## (scripts/net/ship_input_sync.gd), Ship.input указывает на ShipInputSync.remote —
## ровно тот шов, что описан в architecture.md §2.3 и проверен в
## tools/test_net_input.gd, только здесь он впервые подключён к настоящему Ship
## в настоящей игре, а не к голому ShipInput в тесте.
##
## Спавн — на ФИКСИРОВАННЫХ координатах в открытом небе, НЕ через
## Terrain.find_clear_spawn(): та карвит рельеф своим локальным RNG — у хоста и
## клиента вышли бы РАЗНЫЕ вырезы на, казалось бы, одинаковой картинке (carve по
## сети ещё не реализован — roadmap, следующий шаг после этого).
extends Node2D

const PALETTE_PATH := "res://data/terrain/wings_classes.tres"
const VISUAL_PATH := "res://levels/test/visual.png"
const MASK_PATH := "res://levels/test/mask.png"
const FALLBACK_SIZE := Vector2i(1200, 1200)
const FALLBACK_SEED := 1337
const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")

## Открытое небо у верхнего края карты — безопасно и без карва при любом
## содержимом реального/фолбэчного уровня.
const SPAWN_HOST := Vector2(300, 100)
const SPAWN_CLIENT := Vector2(900, 100)

var _net: NetworkManager
var _terrain: Terrain
var _cam: Camera2D
var _hud: Label
var _is_host := false
var _ships: Dictionary = {}   # String (имя узла) -> Ship
var _status := "запуск..."


func _ready() -> void:
	var forced_join_addr := ""
	for arg in OS.get_cmdline_user_args():
		if arg == "--host":
			_is_host = true
		elif arg.begins_with("--join="):
			forced_join_addr = arg.substr("--join=".length())

	var palette := load(PALETTE_PATH) as TerrainPalette
	var vis := _load_image(VISUAL_PATH)
	var msk := _load_image(MASK_PATH)
	if vis == null:
		var lvl := TestLevelGen.generate(FALLBACK_SIZE, FALLBACK_SEED, palette)
		vis = lvl["visual"]
		msk = lvl["mask"]
	_terrain = Terrain.new()
	_terrain.palette = palette
	_terrain.immediate_rebuild = false
	add_child(_terrain)
	_terrain.load_level(vis, msk)
	_terrain.add_to_group("terrain")

	_net = NetworkManager.new()
	add_child(_net)
	_net.peer_joined.connect(_on_peer_joined)
	_net.connected_to_host.connect(_on_connected_to_host)
	_net.connection_failed.connect(func() -> void: _set_status("не удалось подключиться"))
	_net.host_left.connect(func() -> void: _set_status("хост отключился"))

	if forced_join_addr != "":
		# Явно указан --join=<ip> — форсируем клиента (2 разные машины, гонки
		# за bind порта нет и не поможет: см. шапку файла).
		_is_host = false
		var err := _net.join(forced_join_addr)
		_set_status("подключаюсь к %s..." % forced_join_addr if err == OK else "join() не удался: %s" % error_string(err))
	elif _is_host:
		# --host форсирован явно (тоже случай "2 разные машины").
		var err := _net.host()
		_set_status(("хост поднят на порту %d — жду клиента..." % NetworkManager.DEFAULT_PORT) \
			if err == OK else "host() не удался: %s" % error_string(err))
	else:
		# Ни один флаг не задан — автоопределение (см. шапку файла): пробуем
		# занять порт первыми; получилось — мы хост; не получилось (порт уже
		# занят таким же процессом рядом) — значит, кто-то успел раньше, и мы
		# джойнимся к нему на localhost.
		var host_err := _net.host()
		if host_err == OK:
			_is_host = true
			_set_status("хост поднят на порту %d — жду клиента..." % NetworkManager.DEFAULT_PORT)
		else:
			_is_host = false
			var join_err := _net.join("127.0.0.1")
			_set_status("порт занят — подключаюсь как клиент к 127.0.0.1..." \
				if join_err == OK else "join() не удался: %s" % error_string(join_err))

	_cam = Camera2D.new()
	_cam.position_smoothing_enabled = true
	add_child(_cam)
	_cam.make_current()

	# Оба окна называются одинаково ("Wings-clone (DEBUG)") — в Mission Control/
	# переключении окон macOS их не различить. Роль в заголовке решает это малой
	# кровью (по фидбеку с ручного теста — второе окно легко потерять).
	get_window().title = "Wings-clone — %s" % ("ХОСТ" if _is_host else "КЛИЕНТ")

	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 8)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 5)
	layer.add_child(_hud)


## Статус меняется редко (пара раз за сессию: подключение, спавн, обрыв) —
## заодно печатаем в консоль: HUD не виден при headless-прогоне/из терминала,
## а строка в логе — самый дешёвый способ убедиться, что ДВА РЕАЛЬНЫХ процесса
## (не in-process тест) действительно договорились.
func _set_status(text: String) -> void:
	_status = text
	print("[%s] %s" % ["ХОСТ" if _is_host else "КЛИЕНТ", text])


func _load_image(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var res := load(path)
	if res is Image:
		return res
	if res is Texture2D:
		return (res as Texture2D).get_image()
	return null


## На хосте — сигнал приходит, когда клиент реально подключился (id клиента уже
## известен). Спавним обоих кораблей здесь: раньше нельзя (owner_peer второго
## корабля не определён, пока клиент не назвал себя подключением).
func _on_peer_joined(id: int) -> void:
	if _is_host:
		_spawn_ships(id)


## На клиенте — свой unique_id уже валиден только ПОСЛЕ подключения (см.
## NetworkManager.unique_id()), поэтому спавн ждёт именно этот сигнал.
func _on_connected_to_host() -> void:
	_spawn_ships(_net.unique_id())


func _spawn_ships(client_id: int) -> void:
	if _ships.has("ShipHost"):
		return
	_make_ship("ShipHost", 1, SPAWN_HOST)
	_make_ship("ShipClient", client_id, SPAWN_CLIENT)
	_set_status("в игре")


## Один корабль + его ShipInputSync. Ship.input указывает на sync.remote — тот же
## шов, что и в architecture.md §2.3/tools/test_net_input.gd: Ship не знает, что
## ввод (свой или чужой) идёт через сеть. source задаём ТОЛЬКО на процессе,
## которому реально принадлежит корабль (см. ShipInputSync.owner_peer) — иначе
## оба конца слали бы интенты одновременно.
func _make_ship(node_name: String, owner_peer: int, at: Vector2) -> void:
	var ship: Ship = SHIP_SCENE.instantiate()
	ship.name = node_name
	ship.data = SHIP_DATA
	ship.position = at
	add_child(ship)
	_ships[node_name] = ship

	var sync := ShipInputSync.new()
	sync.name = node_name + "Sync"
	sync.owner_peer = owner_peer
	if owner_peer == _net.unique_id():
		sync.source = LocalInput.new(1)
	add_child(sync)
	ship.input = sync.remote


func _process(_delta: float) -> void:
	if _ships.has("ShipHost"):
		var a: Ship = _ships["ShipHost"]
		var mid := a.global_position
		if _ships.has("ShipClient"):
			mid = (a.global_position + (_ships["ShipClient"] as Ship).global_position) / 2.0
		_cam.position = mid
	if _hud == null:
		return
	var lines: Array[String] = []
	lines.append("Роль: %s   Статус: %s" % ["ХОСТ" if _is_host else "КЛИЕНТ", _status])
	lines.append("← → поворот, ↑ тяга (оружие не выдано — тест только позиции/поворота)")
	lines.append("ESC выход")
	_hud.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()
