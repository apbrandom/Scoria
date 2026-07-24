## Level — канонический игровой контейнер локальной игры (одиночной и хотсит-вдвоём).
## Открывается из scenes/menu/main_menu.gd, которое перед этим выставляет
## GameRules.player_count (1 или 2) — сетевой режим здесь не живёт, для него
## отдельная сцена net_playground.tscn (свой спавн, свой NetworkManager).
##
## Пришёл на смену scenes/ship/ship_playground: та песочница делала ровно это же, но
## жила в scenes/ship/ и не знала про правила матча. Level собирает рельеф + 1-2
## корабля с локальным вводом, следит общей камерой, показывает
## HUD и владеет MatchManager (счёт, респавн, условие победы дезматча — см.
## scripts/match/match_manager.gd, notes/architecture.md §2.1, §6 шаг 6). Режим
## "последний выживший летит на базу" и смена уровней — не здесь, требует системы
## Bases, которой ещё нет (notes/roadmap.md).
##
## Управление: P1 ← → поворот · ↑ тяга · Space пулемёт · Ctrl ракетница ·
## P2 (если player_count=2) A D поворот · W тяга · Q пулемёт · E ракетница ·
## R — рестарт матча (после победы) · F1 коллизия рельефа · колесо мыши зум ·
## ESC — назад в главное меню.
##
## Структура по architecture.md §2.2 упрощена: контейнеры Ships/Projectiles/Bases
## не заведены — MatchManager и HUD уже имеют прямой доступ к обоим кораблям через
## _ships: Array[Ship], а снаряды как рождались прямыми потомками Level
## (Ship._fire добавляет их в get_parent()), так и рождаются — заводить контейнер
## сейчас без Bases был бы половинчатый шаг без пользы. Рельеф ищется через
## группу "terrain" независимо от места в дереве. Правила матча
## (гравитация/прочность/...) корабль берёт сам из autoload GameRules в
## Ship.apply_rules(); условие победы (kills_per_level) читает оттуда же MatchManager.
extends Node2D

const PALETTE_PATH := "res://data/terrain/wings_classes.tres"
const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const DUMBFIRE_DATA := preload("res://data/weapons/dumbfire.tres")
const BOMB_DATA := preload("res://data/weapons/bomb.tres")
## preload по пути, не голый MatchManager.new() — свежий class_name может не
## резолвиться по идентификатору в headless-запуске, пока не обновится
## .godot/global_script_class_cache.cfg (та же грабля уже ловилась в этой
## сессии на TerrainDebris, см. terrain.gd::TerrainDebrisScript).
const MATCH_MANAGER_SCRIPT := preload("res://scripts/match/match_manager.gd")
## preload по пути — та же причина, что у MATCH_MANAGER_SCRIPT выше (свежий
## class_name может не резолвиться headless-запуском до пересканирования кэша).
const GLOW_ENV_SCRIPT := preload("res://scripts/level/glow_environment.gd")
const HUD_LABEL_SCRIPT := preload("res://scripts/level/hud_label.gd")
## preload по пути — та же причина, что у остальных SCRIPT-констант выше
## (свежий class_name может не резолвиться headless-запуском до пересборки кэша).
const SAND_LEVEL_GEN_SCRIPT := preload("res://scripts/level/sand_level_gen.gd")
## Фиксированный seed — детерминизм важен для будущего сетевого запуска
## с общим уровнем у хоста и клиента (roadmap.md, "сетевой детерминированный
## replay").
const LEVEL_SEED := 1337
## Широкий и плоский, не квадрат — "много открытого пространства" ложится
## лучше на широкий экран.
const SAND_LEVEL_SIZE := Vector2i(1800, 900)
const MENU_SCENE := "res://scenes/menu/main_menu.tscn"

## Камера кадрирует ОБА корабля: зажимаем зум сверху/снизу и оставляем запас
## по краям области, в которую должны поместиться оба (не впритык к краю экрана).
const CAM_MIN_ZOOM := 0.6
const CAM_MAX_ZOOM := 1.5
const CAM_PADDING := 220.0
## Колесо мыши крутит МНОЖИТЕЛЬ поверх автозума (не абсолютный зум напрямую,
## как было при одном корабле) — тот же диапазон ручного управления, что и
## раньше, только поверх динамической рамки на двоих.
const ZOOM_WHEEL_STEP := 1.1
const ZOOM_MULT_MIN := 0.5
const ZOOM_MULT_MAX := 2.0

var _palette: TerrainPalette
var _terrain: Terrain
var _match: MatchManager
var _ships: Array[Ship] = []
var _last_alive_pos: Dictionary = {}   # Ship -> Vector2, для камеры пока корабль мёртв
var _cam: Camera2D
var _zoom_mult := 1.0
var _hud: Label
var _debug: TerrainDebugDraw


func _ready() -> void:
	_palette = load(PALETTE_PATH) as TerrainPalette
	if _palette == null:
		push_error("Не загрузилась палитра " + PALETTE_PATH)
		return

	# Рельеф уровня — не нарисован вручную и не сгенерирован шумом
	# (устаревший путь через LevelImageLoader/TestLevelGen, использовался до
	# 2026-07-24), а осел ОДИН РАЗ через настоящую SandSim при заходе в
	# уровень (статичный старт, не живая симуляция в кадре полёта —
	# notes/terrain_research.md). Старый путь через levels/test/*.png остался
	# только у tools/terrain_playground.gd (там он и нужен как неизменный
	# референс для ручного теста carve) — реальная игра его больше не видит.
	var lvl := SAND_LEVEL_GEN_SCRIPT.generate(SAND_LEVEL_SIZE, LEVEL_SEED, _palette)
	var vis: Image = lvl["visual"]
	var msk: Image = lvl["mask"]

	_terrain = Terrain.new()
	_terrain.palette = _palette
	_terrain.immediate_rebuild = false
	add_child(_terrain)
	_terrain.load_level(vis, msk)
	_terrain.add_to_group("terrain")

	_debug = TerrainDebugDraw.new()
	_debug.terrain = _terrain
	_debug.visible = false
	add_child(_debug)

	_match = MATCH_MANAGER_SCRIPT.new()
	_match.terrain = _terrain
	add_child(_match)

	# Сколько кораблей поднимать — решает меню ДО change_scene_to_file (см.
	# GameRules.player_count): 1 — сольный полёт, 2 — хотсит. clamp на случай,
	# если сцену открыли напрямую из редактора мимо меню (значение по умолчанию — 2).
	var player_count := clampi(GameRules.player_count, 1, 2)

	# Позиция выставляется ДО add_child, как и раньше у одного корабля — спавны
	# теперь считает MatchManager (с разнесением, чтобы не родиться друг на друге).
	var spawns := _match.pick_spawns(player_count)
	for i in player_count:
		var ship: Ship = SHIP_SCENE.instantiate()
		ship.data = SHIP_DATA
		ship.primary_weapon = DUMBFIRE_DATA
		ship.secondary_weapon = BOMB_DATA
		ship.input = LocalInput.new(i + 1)
		ship.position = spawns[i]
		add_child(ship)
		_ships.append(ship)
	_match.setup(_ships)

	add_child(GLOW_ENV_SCRIPT.build())

	_cam = Camera2D.new()
	_cam.position_smoothing_enabled = true
	_cam.limit_left = 0
	_cam.limit_top = 0
	_cam.limit_right = _terrain.size.x
	_cam.limit_bottom = _terrain.size.y
	add_child(_cam)
	_cam.make_current()

	_hud = HUD_LABEL_SCRIPT.build(self)


func _process(_delta: float) -> void:
	_update_camera()
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				if _match.is_match_over():
					_match.restart_match()
			KEY_F1:
				_debug.visible = not _debug.visible
				if _debug.visible:
					_debug.refresh()
			KEY_ESCAPE:
				get_tree().change_scene_to_file(MENU_SCENE)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom_mult = clampf(_zoom_mult * ZOOM_WHEEL_STEP, ZOOM_MULT_MIN, ZOOM_MULT_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_mult = clampf(_zoom_mult / ZOOM_WHEEL_STEP, ZOOM_MULT_MIN, ZOOM_MULT_MAX)


## Общая камера на двоих: центр — середина между кораблями, зум — по расстоянию
## между ними (дальше друг от друга — шире план). Мёртвый корабль не дёргает
## рамку на место своей гибели — держим последнюю известную ЖИВУЮ позицию, пока
## он не воскреснет.
func _update_camera() -> void:
	if _cam == null or _ships.is_empty():
		return
	var pts: Array[Vector2] = []
	for ship in _ships:
		if not is_instance_valid(ship):
			continue
		if ship.is_alive():
			_last_alive_pos[ship] = ship.global_position
		pts.append(_last_alive_pos.get(ship, ship.global_position))
	if pts.is_empty():
		return

	var min_p := pts[0]
	var max_p := pts[0]
	for p in pts:
		min_p = Vector2(minf(min_p.x, p.x), minf(min_p.y, p.y))
		max_p = Vector2(maxf(max_p.x, p.x), maxf(max_p.y, p.y))
	_cam.position = (min_p + max_p) / 2.0

	var span := max_p - min_p
	var needed := Vector2(maxf(span.x + CAM_PADDING * 2.0, 1.0), maxf(span.y + CAM_PADDING * 2.0, 1.0))
	var vp := get_viewport_rect().size
	var auto_zoom := minf(vp.x / needed.x, vp.y / needed.y)
	_cam.zoom = Vector2.ONE * clampf(auto_zoom * _zoom_mult, CAM_MIN_ZOOM, CAM_MAX_ZOOM)


func _update_hud() -> void:
	if _ships.is_empty():
		return
	var lines: Array[String] = []
	lines.append("FPS %d      уровень %dx%d" % [
		Engine.get_frames_per_second(), _terrain.size.x, _terrain.size.y])
	for i in _ships.size():
		var ship := _ships[i]
		var status := "" if ship.is_alive() else " — уничтожен"
		lines.append("P%d %s: прочность %d/%d   счёт %d%s" % [
			i + 1, ship.data.display_name, ship.hull, ship.data.max_hull,
			_match.get_score(ship), status])
	var rules := _rules_line()
	if rules != "":
		lines.append(rules)
	lines.append("")
	lines.append("P1: ← → поворот · ↑ тяга · Space пулемёт · Ctrl ракетница")
	if _ships.size() > 1:
		lines.append("P2: A D поворот · W тяга · Q пулемёт · E ракетница")
	lines.append("F1 коллизия · колесо зум · ESC меню")
	if _match.is_match_over():
		lines.append(">>> P%d ПОБЕДИЛ (%d килов) — R для рестарта матча <<<" % [
			_ships.find(_match.winner()) + 1, _match.get_score(_match.winner())])
	_hud.text = "\n".join(lines)


## Показывает активные правила матча, только если они отличаются от нейтральных.
func _rules_line() -> String:
	var parts: Array[String] = []
	if not is_equal_approx(GameRules.gravity_scale, 1.0):
		parts.append("гравитация ×%.2f" % GameRules.gravity_scale)
	if not is_equal_approx(GameRules.air_resistance_scale, 1.0):
		parts.append("сопр.воздуха ×%.2f" % GameRules.air_resistance_scale)
	if not is_equal_approx(GameRules.ship_strength, 1.0):
		parts.append("прочность ×%.2f" % GameRules.ship_strength)
	if not is_equal_approx(GameRules.reload_time_scale, 1.0):
		parts.append("перезарядка ×%.2f" % GameRules.reload_time_scale)
	return "правила матча: " + " · ".join(parts) if not parts.is_empty() else ""
