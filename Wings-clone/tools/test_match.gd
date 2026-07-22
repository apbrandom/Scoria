## Headless-проверка MatchManager: атрибуция килла, самоубийство, счёт, условие
## победы, остановка авто-респавна после конца матча, рестарт, разнесение спавнов.
## Камера/HUD (Level) не тестируются здесь — это "красота", смотреть в окне
## (та же конвенция, что и в test_ship.gd) — тут только логика.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_match.tscn
extends Node2D

const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const EXPLOSION_SCENE := preload("res://scenes/fx/explosion.tscn")
const PALETTE := preload("res://data/terrain/wings_classes.tres")
const MATCH_MANAGER_SCRIPT := preload("res://scripts/match/match_manager.gd")

var _pass := 0
var _fail := 0
var _terrain: Terrain


func _ready() -> void:
	print("=== Проверка MatchManager (%s) ===" % DisplayServer.get_name())
	_terrain = Terrain.new()
	_terrain.palette = PALETTE
	_terrain.immediate_rebuild = false
	add_child(_terrain)
	var vis := Image.create(400, 400, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	_terrain.load_level(vis)
	_terrain.add_to_group("terrain")
	await get_tree().physics_frame

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


func _make_ship() -> Ship:
	var s: Ship = SHIP_SCENE.instantiate()
	s.data = SHIP_DATA
	s.input = ShipInput.new()
	add_child(s)
	return s


func _make_match(ships: Array[Ship]) -> MatchManager:
	var m: MatchManager = MATCH_MANAGER_SCRIPT.new()
	m.terrain = _terrain
	m.respawn_delay = 0.05   # маленький, чтобы не ждать реальную секунду в тесте
	add_child(m)
	m.setup(ships)
	return m


func _run() -> void:
	# 1. Атрибуция килла: явный выстрел засчитывает +1 стрелку, не жертве.
	var a := _make_ship()
	var b := _make_ship()
	a.respawn(Vector2(100, 100))
	b.respawn(Vector2(300, 100))   # достаточно далеко от a — во взрыв около b не попадает
	await _step(1)
	var m := _make_match([a, b])

	var exp: Explosion = EXPLOSION_SCENE.instantiate()
	exp.global_position = b.global_position
	exp.blast_radius = 60.0   # 60 < 200 (дистанция до a) — задевает только b
	exp.terrain_power = 0.0   # рельеф не трогаем — не важно для этого теста
	exp.damage = 9999.0
	exp.shooter = a
	add_child(exp)
	await _step(1)

	_check("килл засчитан стрелку (+1)", m.get_score(a) == 1, "счёт a=%d" % m.get_score(a))
	_check("жертве килл не засчитан", m.get_score(b) == 0, "счёт b=%d" % m.get_score(b))
	_check("жертва мертва сразу после взрыва", not b.is_alive())

	# 2. Самоубийство: attacker == victim.
	await _step(10)   # дать респавн-таймеру (0.05с) сработать
	_check("b воскрес после первого килла", b.is_alive())
	b.take_damage(9999.0, b)
	_check("самоубийство даёт -1", m.get_score(b) == -1, "счёт b=%d" % m.get_score(b))
	_check("самоубийство не даёт килл никому другому", m.get_score(a) == 1)

	# 3. Крэш о рельеф (attacker=null) — тоже самоубийство. Тестируем именно
	#    КОНТРАКТ MatchManager ("Ship.destroyed(null) = самоубийство"), не сам
	#    крэш-детект физики — тот уже покрыт test_ship.gd отдельно.
	await _step(10)
	b.take_damage(9999.0)   # без attacker
	_check("крэш без атакующего тоже -1 (не крашится MatchManager)",
		m.get_score(b) == -2, "счёт b=%d" % m.get_score(b))

	# 4. Условие победы срабатывает РОВНО на пороге, не раньше.
	await _step(10)
	GameRules.kills_per_level = 3
	b.take_damage(9999.0, a)   # счёт a: 1 -> 2
	await _step(1)
	_check("матч не окончен на 2 из 3", not m.is_match_over())
	await _step(10)
	b.take_damage(9999.0, a)   # счёт a: 2 -> 3
	await _step(1)
	_check("матч окончен ровно на пороге kills_per_level", m.is_match_over())
	_check("победитель определён верно", m.winner() == a)

	# 5. После конца матча авто-респавн не срабатывает.
	await _step(20)   # дольше respawn_delay
	_check("проигравший НЕ воскрешён после конца матча", not b.is_alive())

	# 6. Рестарт матча: счёт в ноль, оба живы и целы, GameRules не тронуты.
	GameRules.gravity_scale = 2.5   # "домашнее правило" — должно пережить рестарт
	m.restart_match()
	await _step(1)
	_check("рестарт: матч снова идёт", not m.is_match_over())
	_check("рестарт: победитель сброшен", m.winner() == null)
	_check("рестарт: счёт a в нуле", m.get_score(a) == 0)
	_check("рестарт: счёт b в нуле", m.get_score(b) == 0)
	_check("рестарт: a жив и цел", a.is_alive() and is_equal_approx(a.hull, a.data.max_hull))
	_check("рестарт: b жив и цел", b.is_alive() and is_equal_approx(b.hull, b.data.max_hull))
	_check("рестарт НЕ трогает GameRules (домашние правила не слетают)",
		is_equal_approx(GameRules.gravity_scale, 2.5))
	GameRules.reset()   # гигиена — не протекать в другие headless-прогоны

	# 7. Разнесение спавнов: pick_spawns() не сажает корабли друг на друга.
	var spawns := m.pick_spawns(2)
	_check("pick_spawns даёт 2 разные точки",
		spawns[0].distance_to(spawns[1]) > 1.0,
		"spawn0=%s spawn1=%s" % [spawns[0], spawns[1]])
