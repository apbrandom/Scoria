## Счёт, респавн и условие победы локального хотсит-матча. Два режима из
## оригинала (notes/mechanics.md §4), переключаются GameRules.win_condition:
##   WIN_KILLS        — дезматч: респавн, +1 за килл, −1 за самоубийство,
##                      победа по kills_per_level.
##   WIN_LAST_TO_BASE — раунд: респавна НЕТ, побеждает последний выживший,
##                      севший на базу. Без отключения респавна условие
##                      недостижимо в принципе — живых всегда столько же,
##                      сколько игроков, и "последнего" не существует.
## Смена уровня после N киллов (тоже из оригинала) — отдельная будущая задача.
##
## АРХИТЕКТУРНОЕ УПРОЩЕНИЕ (см. notes/architecture.md §2.1): документ описывает
## MatchManager потомком будущего Main (Main > MatchManager + LevelHost + HUD),
## переживающим смену уровня. Смены уровня в этом шаге нет — городить
## Main/LevelHost сейчас не на чем демонстрировать. MatchManager временно живёт
## ребёнком Level и умирает вместе с ним; поднять на Main, когда понадобится
## реальная смена уровней.
##
## Держит корабли ПРЯМЫМИ ссылками (Array[Ship]), не через группу узлов: в
## отличие от Terrain (один экземпляр, кто угодно должен его найти — группа
## "terrain" оправдана), MatchManager с рождения знает ОБА корабля персонально
## (кто есть кто для счёта) — "первый попавшийся в группе" тут в принципе
## неверный запрос. Заодно не наступает на грабли terrain-группы (devlog.md
## §18.5, "забытый remove_from_group резолвит на протухший экземпляр") — сама
## категория бага невозможна без группы.
class_name MatchManager
extends Node

## Пауза перед авто-респавном погибшего корабля, сек.
@export var respawn_delay: float = 1.0
## Минимальная дистанция между двумя точками спавна одновременно — грубая
## защита от "родились друг на друге". НЕ полноценные ARENA.LEV спавн-точки
## (notes/roadmap.md — отдельная задача), просто прагматичный минимум.
@export var min_spawn_separation: float = 200.0

## Радиус, который должен быть чист при спавне (см. Terrain.find_clear_spawn).
@export var spawn_clear_radius: int = 48
## Отступ от края уровня при поиске точки спавна.
@export var spawn_margin: int = 60
## Сколько раз перебрать точку спавна, пытаясь разнести корабли дальше
## min_spawn_separation, прежде чем смириться с ближайшей найденной.
@export var spawn_separation_attempts: int = 8

## Выставляется вызывающим (Level) до pick_spawns()/setup().
var terrain: Terrain
var ships: Array[Ship] = []

var _scores: Dictionary = {}   # Ship -> int
var _winner: Ship = null
var _match_over := false


## Регистрирует корабли и подписывается на их гибель. terrain должен быть
## выставлен ДО вызова.
func setup(ship_list: Array[Ship]) -> void:
	ships = ship_list
	for ship in ships:
		_scores[ship] = 0
		ship.destroyed.connect(_on_ship_destroyed.bind(ship))
		# В режиме "последний — на базу" победа случается в момент ПОСАДКИ, а не
		# в момент чужой смерти: последний выживший может долго лететь до базы.
		# Без этой подписки _check_win() звался бы только из _apply_score и такую
		# победу просто некому было бы заметить.
		ship.docked_changed.connect(_on_ship_docked_changed)


func get_score(ship: Ship) -> int:
	return _scores.get(ship, 0)


func winner() -> Ship:
	return _winner


func is_match_over() -> bool:
	return _match_over


## count точек спавна, по возможности взаимно разнесённых на
## min_spawn_separation. Публичный — Level вызывает это же и для начальной
## расстановки, и restart_match() использует ту же логику.
func pick_spawns(count: int) -> Array[Vector2]:
	var picked: Array[Vector2] = []
	for i in count:
		picked.append(_pick_spawn_away_from(picked))
	return picked


## Полный рестарт того же матча: счёт в ноль, оба корабля — целые на новом
## месте. НЕ трогает GameRules — GameRules.reset() заодно снёс бы
## пользовательские правки гравитации/сопротивления/прочности/перезарядки,
## а "рестарт матча" не должен откатывать настроенные игроками домашние правила.
func restart_match() -> void:
	_match_over = false
	_winner = null
	for ship in ships:
		_scores[ship] = 0
	var spawns := pick_spawns(ships.size())
	for i in ships.size():
		ships[i].respawn(spawns[i])


func _pick_spawn_away_from(avoid: Array[Vector2]) -> Vector2:
	var best := _pick_spawn_raw()
	var attempts := 0
	while attempts < spawn_separation_attempts and _too_close(best, avoid):
		best = _pick_spawn_raw()
		attempts += 1
	return best


## Terrain.find_clear_spawn() сам ничего не знает про "второй корабль" —
## разнесение целиком забота вызывающего (см. terrain.gd:557 doc-comment).
func _pick_spawn_raw() -> Vector2:
	var p := terrain.find_clear_spawn(spawn_clear_radius, spawn_margin)
	if p == Vector2i(-1, -1):
		# Верх карты, а не геометрический центр: генератор уровня гарантирует
		# открытое небо у верхней кромки как инвариант играбельности
		# (SandLevelGen._evaluate — "рельеф не упирается в потолок"), а центр
		# по вертикали мог оказаться в толще земли — ровно тот же баг "спавн в
		# текстуре" (devlog §55), который find_clear_spawn теперь отбраковывает
		# сам, но этот fallback идёт В ОБХОД него.
		push_warning("Не нашлось чистого места для спавна — беру верх уровня")
		p = Vector2i(terrain.size.x / 2, spawn_margin + spawn_clear_radius)
		terrain.carve_circle(p, spawn_clear_radius)
		terrain.flush_dirty()
	return Vector2(p)


func _too_close(point: Vector2, others: Array[Vector2]) -> bool:
	for o in others:
		if point.distance_to(o) < min_spawn_separation:
			return true
	return false


## killer приходит из сигнала Ship.destroyed(killer); victim привязан через
## .bind(ship) при connect() в setup() — Callable.bind() дописывает аргумент
## ПОСЛЕ тех, что несёт сам сигнал, поэтому порядок параметров здесь
## (killer, victim), а не наоборот.
func _on_ship_destroyed(killer: Node, victim: Ship) -> void:
	_apply_score(killer, victim)
	if _match_over:
		return
	# "Последний выживший — на базу" держится на том, что погибшие остаются
	# погибшими: с респавном живых всегда столько же, сколько игроков, и
	# "последнего" не существует. Раунд заканчивается победой или общей
	# гибелью, дальше — restart_match() по R.
	if GameRules.win_condition == GameRules.WIN_LAST_TO_BASE:
		return
	# process_in_physics=true (3-й позиционный аргумент) — иначе таймер живёт
	# на IDLE-времени (аргумент по умолчанию false) и не гарантированно
	# продвигается в headless-тестах, которые шагают ИСКЛЮЧИТЕЛЬНО
	# physics_frame (та же грабля, что уже задокументирована для Tween —
	# devlog.md §18.3). С этим флагом респавн детерминирован и в игре, и в
	# tools/test_match.gd::_step().
	await get_tree().create_timer(respawn_delay, true, true).timeout
	if _match_over or not is_instance_valid(victim) or victim.is_alive():
		return
	victim.respawn(_pick_spawn_away_from(_alive_positions_excluding(victim)))


## attacker == null (смерть без чужого участия, например столкновение с
## рельефом) ИЛИ attacker == victim (самострел/сам себя взрывом) — самоубийство,
## −1 самому себе, killer никому не засчитывается.
func _apply_score(killer: Node, victim: Ship) -> void:
	if killer == null or killer == victim:
		_scores[victim] = get_score(victim) - 1
	elif _scores.has(killer):
		_scores[killer] = get_score(killer) + 1
	_check_win()


## Сигнал прилетает и на посадку, и на отстыковку — проверку зовём в обоих
## случаях: победа могла бы «отмениться» только тем, что победитель улетел с
## базы, а этого уже не бывает (_match_over не снимается).
func _on_ship_docked_changed(_base: Node, _docked: bool) -> void:
	if not _match_over:
		_check_win()


func _check_win() -> void:
	if GameRules.win_condition == GameRules.WIN_LAST_TO_BASE:
		_check_win_last_to_base()
		return
	_check_win_kills()


func _check_win_kills() -> void:
	for ship in ships:
		if get_score(ship) >= GameRules.kills_per_level:
			_match_over = true
			_winner = ship
			return


## Победа оригинала: остался один и вернулся на базу (notes/mechanics.md §4).
func _check_win_last_to_base() -> void:
	# Соло-режим (player_count=1) иначе выигрывался бы касанием базы на старте:
	# единственный корабль всегда "последний выживший". Пережить в таком матче
	# некого — условие бессмысленно, а не просто неудобно.
	if ships.size() < 2:
		return
	var alive: Array[Ship] = []
	for ship in ships:
		if is_instance_valid(ship) and ship.is_alive():
			alive.append(ship)
	if alive.is_empty():
		# Последний разбился, не долетев — раунд окончен без победителя.
		# Именно окончен, а не "продолжается с нулём живых": иначе матч завис бы
		# навсегда, ведь респавна в этом режиме нет.
		_match_over = true
		_winner = null
		return
	if alive.size() == 1 and alive[0].is_docked():
		_match_over = true
		_winner = alive[0]


func _alive_positions_excluding(exclude: Ship) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	for ship in ships:
		if ship != exclude and is_instance_valid(ship) and ship.is_alive():
			pts.append(ship.global_position)
	return pts
