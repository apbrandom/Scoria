## Headless-проверка главного меню: переходы между экранами и запись в GameRules.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_menu.tscn
extends Node

const MAIN_MENU_SCENE := preload("res://scenes/menu/main_menu.tscn")

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка главного меню (%s) ===" % DisplayServer.get_name())
	_run()
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


func _run() -> void:
	GameRules.reset()

	# PackedScene.instantiate() строит весь узел-поддерево и вызывает _ready()
	# (в т.ч. main_menu.gd::_ready() -> _show_main()) СРАЗУ, до возврата из
	# instantiate() — это происходит независимо от add_child() (см. офиц.
	# поведение SceneTree). add_child() здесь нужен не ради _ready(), а чтобы
	# у menu появился валидный get_tree() — без этого _on_*_pressed() ниже,
	# читающие get_tree().change_scene_to_file(), упали бы на null.
	var menu := MAIN_MENU_SCENE.instantiate()
	add_child(menu)

	var main_buttons: Control = menu.get_node("%MainButtons")
	var mode_buttons: Control = menu.get_node("%ModeButtons")
	var net_buttons: Control = menu.get_node("%NetButtons")
	var dev_button: Control = menu.get_node("%DevButton")
	var dev_buttons: Control = menu.get_node("%DevButtons")

	_check("после _ready() виден MainButtons", main_buttons.visible)
	_check("ModeButtons скрыт изначально", not mode_buttons.visible)
	_check("NetButtons скрыт изначально", not net_buttons.visible)
	_check("DevButtons скрыт изначально", not dev_buttons.visible)
	# headless-запуск здесь — это debug-сборка (запускается движком без экспорта,
	# см. шапку main_menu.gd про OS.has_feature("debug")), поэтому кнопка обязана
	# быть видна — иначе тест не поймает, если условие видимости перевернули.
	_check("кнопка «Разработка» видна в debug-сборке (headless — она же)",
		dev_button.visible)

	menu._on_play_pressed()
	_check("Играть -> показывает ModeButtons", mode_buttons.visible)
	_check("Играть -> скрывает MainButtons", not main_buttons.visible)

	menu._on_network_pressed()
	_check("По сети -> показывает NetButtons", net_buttons.visible)
	_check("По сети -> скрывает ModeButtons", not mode_buttons.visible)

	menu._on_net_back_pressed()
	_check("Назад (из сети) -> возврат к ModeButtons", mode_buttons.visible)
	_check("Назад (из сети) -> скрывает NetButtons", not net_buttons.visible)

	menu._on_back_pressed()
	_check("Назад -> возврат к MainButtons", main_buttons.visible)
	_check("Назад -> скрывает ModeButtons", not mode_buttons.visible)

	menu._on_dev_pressed()
	_check("Разработка -> показывает DevButtons", dev_buttons.visible)
	_check("Разработка -> скрывает MainButtons", not main_buttons.visible)

	menu._on_dev_back_pressed()
	_check("Назад (из разработки) -> возврат к MainButtons", main_buttons.visible)
	_check("Назад (из разработки) -> скрывает DevButtons", not dev_buttons.visible)

	# Запись в GameRules проверяем через _set_*() — НЕ через полные
	# _on_*_pressed(). Первая попытка так и была написана "в лоб" и вскрыла
	# реальную проблему: _on_*_pressed() заканчивается
	# get_tree().change_scene_to_file(...), а он не просто откладывает смену
	# сцены до конца кадра, а фактически срабатывает раньше, чем успевает
	# сработать quit() в конце _ready() — вызванный четыре раза подряд (по
	# разу на каждый обработчик) движок реально валился на "Parent node is
	# busy adding/removing children", а _on_join_pressed() успевал по-настоящему
	# поднять net_playground.tscn (реальный ENet-хост на порту!) прежде, чем
	# процесс завершался. Для лёгкого юнит-теста меню это два лишних, ненужных
	# побочных эффекта — поэтому main_menu.gd вынес запись в GameRules в
	# отдельные _set_*() методы, а полный переход сцены здесь не проверяем
	# вовсе (это штатный, много раз проверенный руками Godot-примитив, не наша
	# логика).
	menu._set_single_player()
	_check("Один игрок -> GameRules.player_count = 1", GameRules.player_count == 1,
		"player_count=%d" % GameRules.player_count)

	menu._set_local_two_player()
	_check("Вдвоём -> GameRules.player_count = 2", GameRules.player_count == 2,
		"player_count=%d" % GameRules.player_count)

	menu._set_host_role()
	_check("Хост -> GameRules.net_forced_role = \"host\"", GameRules.net_forced_role == "host",
		"net_forced_role=%s" % GameRules.net_forced_role)

	menu._set_join_role()
	_check("Присоединиться -> GameRules.net_forced_role = \"join\"", GameRules.net_forced_role == "join",
		"net_forced_role=%s" % GameRules.net_forced_role)

	# Симуляция ботов — это не отдельный игровой режим, а level.tscn с обоими
	# кораблями под ИИ (путь GameRules.bot_count уже проверен tools/test_ai.gd);
	# здесь проверяем только то, что действительно принадлежит меню — запись.
	GameRules.reset()
	menu._set_bot_simulation()
	_check("Симуляция ботов -> player_count=2, bot_count=2",
		GameRules.player_count == 2 and GameRules.bot_count == 2,
		"player_count=%d bot_count=%d" % [GameRules.player_count, GameRules.bot_count])

	GameRules.reset()
