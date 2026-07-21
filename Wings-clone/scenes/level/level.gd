## Level — канонический игровой контейнер и главная сцена проекта (Play = играть).
##
## Пришёл на смену scenes/ship/ship_playground: та песочница делала ровно это же, но
## жила в scenes/ship/ и не знала про правила матча. Level собирает рельеф + корабль
## игрока с локальным вводом, следит камерой, показывает HUD и — главное — является
## тем узлом, к которому дальше подключится MatchManager (счёт, «последний выживший
## летит на базу», смена уровней — см. notes/architecture.md §2.1, §6, шаг 6).
##
## Управление: ← → поворот · ↑ тяга · Space пулемёт · Ctrl ракетница ·
## R респавн · F1 коллизия рельефа · колесо мыши зум · ESC выход.
##
## Структура по architecture.md §2.2 упрощена под v0.1 (один корабль): контейнеры
## Ships/Projectiles/Bases и ParallaxBackground появятся, когда появятся несколько
## кораблей и базы (шаг 6). Сейчас корабль — прямой потомок Level, снаряды рождаются
## рядом (Ship._fire добавляет их в get_parent()), рельеф ищется через группу
## "terrain" независимо от места в дереве. Правила матча (гравитация/прочность/…)
## корабль берёт сам из autoload GameRules в Ship.apply_rules().
extends Node2D

const PALETTE_PATH := "res://data/terrain/wings_classes.tres"
const VISUAL_PATH := "res://levels/test/visual.png"
const MASK_PATH := "res://levels/test/mask.png"
const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const DUMBFIRE_DATA := preload("res://data/weapons/dumbfire.tres")
const BOMB_DATA := preload("res://data/weapons/bomb.tres")
const FALLBACK_SIZE := Vector2i(1200, 1200)
const FALLBACK_SEED := 1337
const SPAWN_CLEAR_RADIUS := 48
## Отступ зоны спавна от края уровня, px — не появляться впритык к границе мира.
const SPAWN_MARGIN := 60

var _palette: TerrainPalette
var _terrain: Terrain
var _ship: Ship
var _cam: Camera2D
var _hud: Label
var _debug: TerrainDebugDraw
var _spawn := Vector2.ZERO


func _ready() -> void:
	_palette = load(PALETTE_PATH) as TerrainPalette
	if _palette == null:
		push_error("Не загрузилась палитра " + PALETTE_PATH)
		return

	var vis := _load_image(VISUAL_PATH)
	var msk := _load_image(MASK_PATH)
	if vis == null:
		var lvl := TestLevelGen.generate(FALLBACK_SIZE, FALLBACK_SEED, _palette)
		vis = lvl["visual"]
		msk = lvl["mask"]

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

	_spawn = _pick_spawn()

	_ship = SHIP_SCENE.instantiate()
	_ship.data = SHIP_DATA
	_ship.primary_weapon = DUMBFIRE_DATA
	_ship.secondary_weapon = BOMB_DATA
	_ship.input = LocalInput.new(1)
	_ship.position = _spawn
	_ship.destroyed.connect(_on_ship_destroyed)
	add_child(_ship)

	_cam = Camera2D.new()
	_cam.zoom = Vector2.ONE * 1.3
	_cam.position_smoothing_enabled = true
	add_child(_cam)
	_cam.make_current()

	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 8)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 5)
	layer.add_child(_hud)


func _load_image(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var res := load(path)
	if res is Image:
		return res
	if res is Texture2D:
		push_warning("%s импортирован как Texture2D, а не Image — цвета маски могут быть искажены" % path)
		return (res as Texture2D).get_image()
	return null


func _process(_delta: float) -> void:
	if _ship != null and _cam != null:
		_cam.position = _ship.global_position
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				_respawn()
			KEY_F1:
				_debug.visible = not _debug.visible
				if _debug.visible:
					_debug.refresh()
			KEY_ESCAPE:
				get_tree().quit()
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_cam.zoom = (_cam.zoom * 1.1).clampf(0.3, 4.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				_cam.zoom = (_cam.zoom / 1.1).clampf(0.3, 4.0)


## Случайное чистое место — не фиксированная точка. Terrain.find_clear_spawn() сам
## избегает Камня (его нельзя расчистить, см. terrain.gd §16 devlog) — обычную
## расчистку через carve_circle() он делает внутри. Крайний случай (не нашлось места
## за отведённые попытки) маловероятен при разумной доле камня, но на всякий случай
## не оставляем корабль без места: берём центр и чистим напрямую, что бы там ни было.
func _pick_spawn() -> Vector2:
	var p := _terrain.find_clear_spawn(SPAWN_CLEAR_RADIUS, SPAWN_MARGIN)
	if p == Vector2i(-1, -1):
		push_warning("Не нашлось чистого места для спавна — беру центр уровня")
		p = _terrain.size / 2
		_terrain.carve_circle(p, SPAWN_CLEAR_RADIUS)
		_terrain.flush_dirty()
	return Vector2(p)


func _respawn() -> void:
	_spawn = _pick_spawn()
	_ship.respawn(_spawn)


func _on_ship_destroyed() -> void:
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(_ship) and not _ship.is_alive():
		_respawn()


func _update_hud() -> void:
	if _ship == null:
		return
	var spd := _ship.linear_velocity.length()
	var dead_line := "" if _ship.is_alive() else "  >>> УНИЧТОЖЕН — R для респавна <<<"
	# Строка правил показывает только НЕнейтральные множители — при значениях по
	# умолчанию (всё 1.0) её нет, чтобы не загромождать HUD. Так виден шов GameRules:
	# покрутил правило — увидел его в игре.
	var rules := _rules_line()
	_hud.text = "\n".join([
		"FPS %d      уровень %dx%d" % [
			Engine.get_frames_per_second(), _terrain.size.x, _terrain.size.y],
		"корабль: %s" % _ship.data.display_name,
		"прочность %d/%d" % [_ship.hull, _ship.data.max_hull],
		"скорость %d       угол %d°" % [spd, rad_to_deg(_ship.aim_angle)],
		rules,
		"",
		"← → поворот · ↑ тяга · Space пулемёт · Ctrl ракетница",
		"R респавн · F1 коллизия · колесо зум · ESC выход",
		dead_line,
	])


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
