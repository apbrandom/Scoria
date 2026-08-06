## Регрессия devlog §55 ("самолётики появляются в текстурах, бой не
## состоялся"): find_clear_spawn мог легально выбрать точку без открытого
## неба над ней — статичной пещере это раньше было безразлично, но живая
## физика (live_sand.gd слушает Terrain.carved) роняет несвязанную породу
## обратно в свежую воронку за секунду-две, и корабль замуровывается в
## коллизию. Воспроизводилось в ~половине случайных заходов (tools/
## diag_spawn_bug.gd, разовый прогон, найденный баг задокументирован там же).
##
## Этот набор гоняет РЕАЛЬНЫЙ level.tscn (не синтетическую картинку — сама
## интеграция MatchManager+LiveSand+Terrain и есть то, что сломалось) на
## нескольких seed'ах и проверяет: сразу после спавна точка пуста, и она
## ОСТАЁТСЯ пустой спустя секунду живой физики.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_spawn_safety.tscn
extends Node

const LEVEL_SCENE := "res://scenes/level/level.tscn"
const TRIALS := 8
## 60 тиков = 1 сек на 60 фпс — по замеру devlog §49 обвал крупной воронки
## оседает за ~12 тиков, запас с большим избытком.
const SETTLE_TICKS := 60

var _pass := 0
var _fail := 0
var _trial := 0


func _ready() -> void:
	print("=== Проверка безопасности спавна (%s) ===" % DisplayServer.get_name())
	GameRules.reset()
	GameRules.player_count = 2
	GameRules.bot_count = 2  # боты держат позицию сами, без клавиатуры некому
	_run_trial()


func _check(title: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %s   %s" % ["OK" if ok else "ПРОВАЛ", title, detail])


func _run_trial() -> void:
	if _trial >= TRIALS:
		print("\n=== ИТОГ: %d пройдено, %d провалено ===" % [_pass, _fail])
		get_tree().quit(1 if _fail > 0 else 0)
		return
	GameRules.level_seed = 0  # новый случайный seed каждый раз — не один и тот же счастливый билет
	var level: Node = load(LEVEL_SCENE).instantiate()
	add_child(level)
	if not level.is_world_ready():
		await level.world_ready
	_check_trial(level)


func _check_trial(level: Node) -> void:
	var terrain = level.get("_terrain")
	var ships: Array = level.get("_ships")
	var empty := TerrainPalette.Cls.EMPTY

	for i in ships.size():
		var p := Vector2i(ships[i].global_position)
		_check("seed=%d корабль %d: точка спавна пуста сразу после появления" % [GameRules.level_seed_used, i],
			terrain.class_at(p) == empty, "класс=%d" % terrain.class_at(p))

	for _t in SETTLE_TICKS:
		await get_tree().physics_frame

	for i in ships.size():
		var p := Vector2i(ships[i].global_position)
		var cls: int = terrain.class_at(p)
		_check("seed=%d корабль %d: не замурован спустя %d тиков" % [GameRules.level_seed_used, i, SETTLE_TICKS],
			cls == empty, "класс=%d, pos=%s" % [cls, p])

	level.queue_free()
	await get_tree().process_frame
	_trial += 1
	_run_trial()
