## Headless-проверка: level.tscn (единственный игровой уровень, открывается и
## "Один игрок", и "Два игрока" из главного меню) реально грузится с рельефом
## от SandLevelGen — не только сам генератор изолированно (см.
## test_sand_level_gen.gd), а весь путь целиком: Terrain принимает картинки от
## SandLevelGen, MatchManager находит место спавна, корабль реально
## появляется на сцене.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_sand_level_boot.tscn
extends Node

const LEVEL_SCENE := preload("res://scenes/level/level.tscn")

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка загрузки level.tscn (SandLevelGen, %s) ===" % DisplayServer.get_name())
	await _run()
	print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


func _step(frames: int) -> void:
	for _i in frames:
		await get_tree().physics_frame


func _run() -> void:
	GameRules.reset()
	GameRules.player_count = 1

	# Level._ready() БОЛЬШЕ НЕ делает всю работу синхронно: сборка уровня
	# растянута на кадры, чтобы показывать полосу загрузки (devlog §52).
	# Ждём явного сигнала, а не угаданного числа кадров — иначе тест начнёт
	# то проходить, то падать от скорости машины.
	var level := LEVEL_SCENE.instantiate()
	add_child(level)
	if not level.is_world_ready():
		await level.world_ready
	_check("уровень сообщил о готовности (сигнал world_ready)", level.is_world_ready())

	var terrain: Terrain = level.get_node("Terrain") if level.has_node("Terrain") else _find_terrain(level)
	_check("Terrain реально создан", terrain != null)
	if terrain == null:
		GameRules.reset()
		return

	_check("Размер уровня совпадает с SAND_LEVEL_SIZE (2700x1350)",
		terrain.size == Vector2i(2700, 1350), "size=%s" % terrain.size)
	_check("В рельефе есть твёрдые пиксели (не пустой уровень)",
		terrain.count_solid() > 0, "count_solid=%d" % terrain.count_solid())

	var ships := level.get_children().filter(func(c): return c is Ship)
	_check("Корабль реально заспавнен (player_count=1 -> 1 корабль)", ships.size() == 1,
		"кораблей на сцене: %d" % ships.size())

	if not ships.is_empty():
		await _check_world_bounds(ships[0], terrain.size)

	level.queue_free()
	GameRules.reset()


## Разгоняет корабль на границу уровня (лево/верх/право/низ по очереди) и
## проверяет, что невидимые стены (Level._build_world_bounds) реально не
## дают физически улететь за пределы (0,0)-(size) — не просто "камера не
## показывает дальше", а настоящая коллизия.
func _check_world_bounds(ship: Ship, size: Vector2i) -> void:
	# Скорость разгона (4000 px/с) нарочно намного выше реальных скоростей
	# корабля (тяга даёт ~170 px/с, крэш о рельеф — 250-320 px/с) — стресс-тест
	# на "точно долетит до стены". При такой скорости однокадровое проникновение
	# и коррекция физдвижком дают не идеально нулевой нахлёст (проверено по
	# кадрам scratch-диагностикой: верх тормозит ровно у стены, потом гравитация
	# естественно тащит обратно вниз — не баг стены). MARGIN просторный (стена
	# толщиной WORLD_BOUNDS_THICKNESS=300 px) — цель теста "не улетел за
	# пределы", а не "остановился с точностью до пикселя".
	const MARGIN := 40.0
	var cases := [
		{"name": "левая", "pos": Vector2(60, size.y / 2.0), "vel": Vector2(-4000, 0),
			"check": func(p: Vector2) -> bool: return p.x > -MARGIN},
		{"name": "правая", "pos": Vector2(size.x - 60, size.y / 2.0), "vel": Vector2(4000, 0),
			"check": func(p: Vector2) -> bool: return p.x < size.x + MARGIN},
		{"name": "верхняя", "pos": Vector2(size.x / 2.0, 60), "vel": Vector2(0, -4000),
			"check": func(p: Vector2) -> bool: return p.y > -MARGIN},
		{"name": "нижняя", "pos": Vector2(size.x / 2.0, size.y - 60), "vel": Vector2(0, 4000),
			"check": func(p: Vector2) -> bool: return p.y < size.y + MARGIN},
	]
	for c in cases:
		ship.global_position = c["pos"]
		ship.linear_velocity = c["vel"]
		await _step(30)
		var ok: bool = c["check"].call(ship.global_position)
		_check("граница уровня держит корабль (%s стена)" % c["name"], ok,
			"позиция после разгона: %s" % ship.global_position)


func _find_terrain(root: Node) -> Terrain:
	for c in root.get_children():
		if c is Terrain:
			return c
	return null
