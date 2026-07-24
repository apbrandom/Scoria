## Headless-проверка: level.tscn реально загружается с GameRules.use_sand_level
## (режим "Открытый ландшафт" из главного меню) — не только сам генератор
## изолированно (см. test_sand_level_gen.gd), а весь путь целиком: Terrain
## принимает картинки от SandLevelGen, MatchManager находит место спавна,
## корабль реально появляется на сцене.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_sand_level_boot.tscn
extends Node

const LEVEL_SCENE := preload("res://scenes/level/level.tscn")

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка загрузки level.tscn с use_sand_level (%s) ===" % DisplayServer.get_name())
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
	# Тот же путь, что и настоящее меню (main_menu.gd::_set_sand_level) —
	# player_count и use_sand_level всегда ставятся ВМЕСТЕ, поэтому и тест
	# должен воспроизводить пару, а не один флаг (иначе проверяет вымышленное
	# состояние, которого в реальной игре никогда не бывает).
	GameRules.player_count = 1
	GameRules.use_sand_level = true

	# Level._ready() выполняется целиком СИНХРОННО внутри add_child (см. тот же
	# довод в test_menu.gd) — рельеф загружен и корабль заспавнен уже здесь.
	var level := LEVEL_SCENE.instantiate()
	add_child(level)

	var terrain: Terrain = level.get_node("Terrain") if level.has_node("Terrain") else _find_terrain(level)
	_check("Terrain реально создан", terrain != null)
	if terrain == null:
		GameRules.reset()
		return

	_check("Размер уровня совпадает с SAND_LEVEL_SIZE (1800x900)",
		terrain.size == Vector2i(1800, 900), "size=%s" % terrain.size)
	_check("В рельефе есть твёрдые пиксели (не пустой уровень)",
		terrain.count_solid() > 0, "count_solid=%d" % terrain.count_solid())

	var ships := level.get_children().filter(func(c): return c is Ship)
	_check("Корабль реально заспавнен (player_count=1 -> 1 корабль)", ships.size() == 1,
		"кораблей на сцене: %d" % ships.size())

	level.queue_free()
	GameRules.reset()


func _find_terrain(root: Node) -> Terrain:
	for c in root.get_children():
		if c is Terrain:
			return c
	return null
