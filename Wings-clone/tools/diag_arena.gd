## Арена: боты дерутся сами, а мы СМОТРИМ ЦИФРЫ. Ровно то, ради чего заказчик
## просил ботов — «тестировать, как проходит сражение».
##
## Это не тест (здесь нечему быть «пройдено/провалено» — баланс не бывает
## правильным или неправильным), а измерительный прибор: прогоняет несколько
## боёв на РАЗНЫХ процедурных уровнях и печатает, сколько бой длится, сколько
## снарядов на попадание уходит и от чего вообще гибнут — от оружия или об землю.
##
## Числа отсюда — материал для разговора о балансе: «долго ли живёт корабль»,
## «не слишком ли смертелен рельеф», «попадают ли вообще». Меняешь .tres
## (ship/weapon/ai) — гоняешь снова и сравниваешь.
##
## Запуск: godot --headless --path Wings-clone res://tools/diag_arena.tscn
extends Node2D

const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const DUMBFIRE := preload("res://data/weapons/dumbfire.tres")
const BOMB := preload("res://data/weapons/bomb.tres")
const PALETTE := preload("res://data/terrain/wings_classes.tres")
const AI_INPUT := preload("res://scripts/input/ai_input.gd")
const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")

## Уровень меньше боевого 2700x1350: боёв несколько, и на полном размере прибор
## считал бы минуты. Рельеф при этом настоящий, от генератора — с холмами и
## укрытиями, а не плоская доска (иначе бой мерился бы в несуществующих условиях).
const ARENA_SIZE := Vector2i(1500, 750)
const MATCHES := 5
const FIRST_SEED := 4242
const SEED_STEP := 7919
## Потолок одного боя. Ничья по времени — тоже результат, и важный: значит
## боты не могут друг друга добить.
const MAX_SECONDS := 45.0
const PHYS_HZ := 60.0

var _terrain: Terrain
var _seen_shots := {}
var _deaths: Array = []


func _ready() -> void:
	print("=== Арена: бой ботов, %d матчей ===" % MATCHES)
	print("    уровень %dx%d, потолок боя %.0f с\n" % [
		ARENA_SIZE.x, ARENA_SIZE.y, MAX_SECONDS])

	var rows: Array = []
	for i in MATCHES:
		rows.append(await _run_match(FIRST_SEED + i * SEED_STEP))
	_report(rows)
	get_tree().quit(0)


func _run_match(rng_seed: int) -> Dictionary:
	GameRules.reset()
	GameRules.level_seed = rng_seed
	await _build_level(rng_seed)

	_seen_shots.clear()
	_deaths.clear()

	var spawns := _pick_spawns()
	var a := _make_bot(spawns[0], rng_seed + 1)
	var b := _make_bot(spawns[1], rng_seed + 2)
	var bots := [a, b] as Array[Ship]
	for s in bots:
		s.input.setup(s, bots, _terrain)
		s.destroyed.connect(_on_destroyed.bind(s))

	var hull0: float = a.hull
	var frames := 0
	var limit := int(MAX_SECONDS * PHYS_HZ)
	while frames < limit and a.is_alive() and b.is_alive():
		await get_tree().physics_frame
		frames += 1
		_track_shots()

	var row := {
		"seed": rng_seed,
		"sec": frames / PHYS_HZ,
		# Немой бой надо уметь ОБЪЯСНИТЬ: сошлись ли боты вообще. Без этого
		# «0 выстрелов» одинаково выглядит и когда бот туп, и когда он застрял.
		"gap0": spawns[0].distance_to(spawns[1]),
		"gap1": a.global_position.distance_to(b.global_position),
		"shots": _seen_shots.size(),
		"hull_a": a.hull,
		"hull_b": b.hull,
		"hull0": hull0,
		"decided": not (a.is_alive() and b.is_alive()),
		"deaths": _deaths.duplicate(),
	}
	for s in bots:
		s.queue_free()
	for c in get_children():
		if c is Projectile or c is Explosion:
			c.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	return row


func _build_level(rng_seed: int) -> void:
	if _terrain != null:
		_terrain.queue_free()
		await get_tree().physics_frame
	var lvl := SAND_LEVEL_GEN.generate(ARENA_SIZE, rng_seed, PALETTE)
	_terrain = Terrain.new()
	_terrain.palette = PALETTE
	_terrain.immediate_rebuild = false
	add_child(_terrain)
	_terrain.load_level(lvl["visual"], lvl["mask"])
	_terrain.add_to_group("terrain")
	_build_bounds()
	await get_tree().physics_frame


## Невидимые стены по краям — такие же, как заводит настоящий уровень
## (Level._build_world_bounds). Без них первый замер был недействителен: боты
## наклонялись, жгли тягу и УЛЕТАЛИ с карты (итоговая дистанция 20760 px на
## карте шириной 1500), а отчёт показывал это как «ничья, ни одного выстрела» —
## то есть прибор мерил не игру. Отдельное следствие: собственного понятия
## «край карты» у бота нет, его держат стены (см. roadmap).
func _build_bounds() -> void:
	var t := 300.0
	var w := float(ARENA_SIZE.x)
	var h := float(ARENA_SIZE.y)
	var walls := StaticBody2D.new()
	walls.name = "ArenaBounds"
	_terrain.add_child(walls)
	var rects := [
		[Vector2(-t / 2.0, h / 2.0), Vector2(t, h + t * 2.0)],
		[Vector2(w + t / 2.0, h / 2.0), Vector2(t, h + t * 2.0)],
		[Vector2(w / 2.0, -t / 2.0), Vector2(w + t * 2.0, t)],
		[Vector2(w / 2.0, h + t / 2.0), Vector2(w + t * 2.0, t)],
	]
	for r in rects:
		var shape := CollisionShape2D.new()
		var box := RectangleShape2D.new()
		box.size = r[1]
		shape.shape = box
		shape.position = r[0]
		walls.add_child(shape)


## Точки старта — по одной на половину карты, как это делает настоящий матч
## (MatchManager.pick_spawns разносит корабли, чтобы они не родились в упор).
func _pick_spawns() -> Array[Vector2]:
	var left := _terrain.find_clear_spawn(40, 60)
	var best := left
	var best_gap := 0.0
	# Просто ПЕРЕБИРАЕМ свободные места, пока не найдётся достаточно далёкое.
	# Зеркалить точку по X (первая версия этого инструмента) нельзя: y остаётся
	# от другой половины карты, и корабль рождался замурованным в холме — бой
	# получался немым не потому, что боты плохи, а потому что мерили ерунду.
	for _i in 30:
		var cand := _terrain.find_clear_spawn(40, 60)
		var gap := absf(float(cand.x - left.x))
		if gap > best_gap:
			best_gap = gap
			best = cand
		if gap > ARENA_SIZE.x * 0.45:
			break
	return [Vector2(left), Vector2(best)] as Array[Vector2]


func _make_bot(at: Vector2, rng_seed: int) -> Ship:
	var s: Ship = SHIP_SCENE.instantiate()
	s.data = SHIP_DATA
	s.primary_weapon = DUMBFIRE
	s.secondary_weapon = BOMB
	s.position = at
	s.input = AI_INPUT.new(rng_seed)
	add_child(s)
	return s


## Снаряды считаем по УНИКАЛЬНЫМ объектам: они живут доли секунды, и простой
## подсчёт детей в кадре дал бы «сколько в воздухе», а не «сколько выпущено».
func _track_shots() -> void:
	for c in get_children():
		if c is Projectile:
			_seen_shots[c.get_instance_id()] = true


## killer == null означает «убился сам»: об рельеф или собственным взрывом.
## Это ровно та цифра, из-за которой стоит смотреть на баланс — если корабли
## гибнут в основном о землю, дело не в оружии.
func _on_destroyed(killer: Node, victim: Ship) -> void:
	_deaths.append("от оружия" if killer != null and killer != victim else "сам (рельеф/свой взрыв)")


func _report(rows: Array) -> void:
	print("  %-10s %7s %7s %10s  %s" % ["seed", "сек", "выстр.", "прочн. A/B", "исход"])
	var total_sec := 0.0
	var total_shots := 0
	var decided := 0
	var by_weapon := 0
	var by_self := 0
	for r in rows:
		var outcome: String = "ничья по времени"
		if r["decided"]:
			decided += 1
			outcome = ", ".join(r["deaths"])
		for d in r["deaths"]:
			if d == "от оружия":
				by_weapon += 1
			else:
				by_self += 1
		total_sec += r["sec"]
		total_shots += r["shots"]
		if r["shots"] == 0:
			outcome += "  [дистанция %.0f -> %.0f px]" % [r["gap0"], r["gap1"]]
		print("  %-10d %7.1f %7d %10s  %s" % [
			r["seed"], r["sec"], r["shots"],
			"%.0f/%.0f" % [r["hull_a"], r["hull_b"]], outcome])

	var n := float(rows.size())
	print("\n  --- итого по %d матчам ---" % rows.size())
	print("  средняя длительность боя: %.1f с" % (total_sec / n))
	print("  выстрелов за матч: %.0f" % (total_shots / n))
	print("  боёв с исходом: %d из %d (остальные — ничья по потолку времени)" % [
		decided, rows.size()])
	print("  смертей: от оружия %d, сам (рельеф/свой взрыв) %d" % [by_weapon, by_self])
	print("\n  Это не «правильно/неправильно», а точка отсчёта: поменяй числа в")
	print("  data/ships, data/weapons или data/ai — и сравни с этим прогоном.")
