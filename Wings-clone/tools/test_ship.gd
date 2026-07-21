## Headless-проверка физики корабля и оружия (без окна и клавиатуры).
##
## Запуск: godot --headless --path Wings-clone res://tools/test_ship.tscn
## Ввод подаётся напрямую (ShipInput с публичными полями, poll() базового класса —
## no-op, поэтому выставленные интенты не перетираются).
extends Node2D

const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const DUMBFIRE_DATA := preload("res://data/weapons/dumbfire.tres")
const BOMB_DATA := preload("res://data/weapons/bomb.tres")
const EXPLOSION_SCENE := preload("res://scenes/fx/explosion.tscn")
const PALETTE := preload("res://data/terrain/wings_classes.tres")

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка корабля и оружия (%s) ===" % DisplayServer.get_name())
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


func _run() -> void:
	var s := _make_ship()
	await _step(1)  # дать отработать _ready

	# 1. Визуал не вылезает за пределы коллизии — регрессия на баг "корабль торчит
	#    из текстур" (нос Polygon2D уходил на 11px при коллайдере радиусом 7).
	var visual_extent: float = s._visual.scale.x * Ship.VISUAL_MAX_VERTEX_DIST
	_check("визуал вписан в коллизию", visual_extent <= s.data.collision_radius,
		"визуал=%.2f px, коллизия=%.2f px" % [visual_extent, s.data.collision_radius])

	# 2. Гравитация тянет вниз (тяга выключена).
	s.respawn(Vector2.ZERO)
	s.input.thrust = false
	var y0 := s.global_position.y
	await _step(30)
	_check("гравитация тянет вниз", s.global_position.y > y0 + 5.0,
		"Δy=%.1f" % (s.global_position.y - y0))

	# 3. Тяга вверх пересиливает гравитацию (thrust 800 > вес 400) — скорость вверх.
	s.respawn(Vector2.ZERO)
	s.input.thrust = true
	await _step(30)
	_check("тяга поднимает (v.y < 0)", s.linear_velocity.y < 0.0,
		"v.y=%.1f" % s.linear_velocity.y)
	s.input.thrust = false

	# 4. Поворот меняет угол прицела.
	s.respawn(Vector2.ZERO)
	s.input.turn = 1.0
	await _step(30)
	_check("поворот меняет угол", absf(s.aim_angle) > 1.0,
		"угол=%.2f рад" % s.aim_angle)
	s.input.turn = 0.0

	# 4b. Дуло и хвост двигателя поворачиваются вместе с корпусом. Регрессия:
	#     раньше Muzzle позиционировался один раз в _ready() и не обновлялся —
	#     скорость снаряда считалась верно из aim_angle отдельно, а точка появления
	#     всегда оставалась "над центром" независимо от поворота. Тест на скорость
	#     снаряда (ниже) этого не ловил, потому что проверял только направление
	#     полёта, не точку старта.
	var expected_muzzle_dir := Vector2.UP.rotated(s.aim_angle)
	var muzzle_dir: Vector2 = (s._muzzle.global_position - s.global_position).normalized()
	_check("дуло поворачивается вместе с корпусом", muzzle_dir.dot(expected_muzzle_dir) > 0.99,
		"угол=%.2f muzzle_dir=%s expected=%s" % [s.aim_angle, muzzle_dir, expected_muzzle_dir])

	var expected_thrust_dir := Vector2.DOWN.rotated(s.aim_angle)
	var thrust_dir: Vector2 = (s._thrust.global_position - s.global_position).normalized()
	_check("хвост двигателя смотрит в сторону, противоположную дулу",
		thrust_dir.dot(expected_thrust_dir) > 0.99,
		"thrust_dir=%s expected=%s" % [thrust_dir, expected_thrust_dir])
	_check("Thrust.rotation синхронизирован с aim_angle",
		is_equal_approx(s._thrust.rotation, s.aim_angle), "")

	s.input.thrust = false
	await _step(1)
	_check("хвост не эмиттит без тяги", s._thrust.emitting == false, "")
	s.input.thrust = true
	await _step(1)
	_check("хвост эмиттит при тяге", s._thrust.emitting == true, "")
	s.input.thrust = false

	# 5. Выстрел пулемётом рождает снаряд у дула со скоростью
	#    "прицел × muzzle_speed + скорость корабля × velocity_inherit" —
	#    проверка сложения скоростей, а не просто "снаряд появился".
	s.equip_primary(DUMBFIRE_DATA)
	s.equip_secondary(BOMB_DATA)
	s.respawn(Vector2.ZERO)
	s.linear_velocity = Vector2(40, 0)
	s.input.fire_primary = true
	await _step(1)
	s.input.fire_primary = false
	var shots := get_tree().get_nodes_in_group("projectiles")
	_check("выстрел порождает снаряд", shots.size() == 1, "снарядов=%d" % shots.size())
	if shots.size() > 0:
		var expected_v: Vector2 = Vector2.UP.rotated(s.aim_angle) * DUMBFIRE_DATA.muzzle_speed \
			+ Vector2(40, 0) * DUMBFIRE_DATA.velocity_inherit
		var got_v: Vector2 = shots[0].linear_velocity
		# допуск на один шаг демпфирования физдвижка между spawn и проверкой,
		# не на ошибку в математике (см. ship.gd _fire)
		_check("скорость снаряда = прицел + скорость корабля", got_v.distance_to(expected_v) < 5.0,
			"получено=%s ожидалось=%s" % [got_v, expected_v])
		(shots[0] as Node).queue_free()
	await _step(1)

	# 6. Повторный выстрел раньше reload_time не проходит — кулдаун реально работает.
	s.input.fire_primary = true
	await _step(1)
	s.input.fire_primary = false
	_check("кулдаун не даёт стрелять чаще reload_time",
		get_tree().get_nodes_in_group("projectiles").is_empty(), "")
	for n in get_tree().get_nodes_in_group("projectiles"):
		(n as Node).queue_free()
	await _step(1)

	# 7. Explosion: роет рельеф (с переводом глобальных координат в локальные —
	#    Terrain намеренно не в (0,0), проверяем to_local(), а не просто carve_circle)
	#    и наносит урон кораблю в радиусе, но не за его пределами.
	var terrain := Terrain.new()
	terrain.palette = PALETTE
	terrain.position = Vector2(5000, 5000)
	add_child(terrain)
	var vis := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0.5, 0.3, 0.1, 1.0))  # сплошная порода, без маски = default_solid_class
	terrain.load_level(vis)
	terrain.add_to_group("terrain")
	await _step(1)

	var center := terrain.position + Vector2(terrain.size) * 0.5
	var solid_before := terrain.count_solid()

	var near_pos := center + Vector2(15, 0)
	var far_pos := center + Vector2(500, 0)  # заведомо вне blast_radius=40
	terrain.carve_circle(Vector2i(terrain.to_local(near_pos)), 20)
	terrain.carve_circle(Vector2i(terrain.to_local(far_pos)), 20)
	terrain.flush_dirty()

	var near_ship := _make_ship()
	var far_ship := _make_ship()
	await _step(1)
	near_ship.respawn(near_pos)
	far_ship.respawn(far_pos)
	await _step(1)

	var exp: Explosion = EXPLOSION_SCENE.instantiate()
	exp.global_position = center
	exp.blast_radius = 40.0
	exp.terrain_power = 1.0
	exp.damage = 30.0
	add_child(exp)
	await _step(1)

	_check("Explosion роет рельеф (координаты переведены верно)",
		terrain.count_solid() < solid_before,
		"было=%d стало=%d" % [solid_before, terrain.count_solid()])
	_check("Explosion наносит урон кораблю в радиусе",
		absf((near_ship.data.max_hull - near_ship.hull) - exp.damage) < 1.0,
		"прочность=%.1f/%.1f (ожидался урон %.1f)" % [
			near_ship.hull, near_ship.data.max_hull, exp.damage])
	_check("Explosion не трогает корабль за пределами радиуса",
		far_ship.hull == far_ship.data.max_hull,
		"прочность=%.1f/%.1f" % [far_ship.hull, far_ship.data.max_hull])

	# 8. "Земля": столкновение с рыхлым рельефом даёт урон = база НА пороге
	#    (1 hp при 250 px/с, dirt_crash_damage/dirt_crash_speed) плюс линейный
	#    рост от превышения (dirt_crash_rate) — не жёстко фиксированное число,
	#    заказчик явно попросил пропорциональный рост "в том же порядке"
	#    (notes/terrain_materials.md, architecture.md §15). Открываем вертикальную
	#    шахту и роняем корабль с нулевой начальной скоростью — набирает скорость
	#    под гравитацией естественно. Специально НЕ выставляем скорость скачком:
	#    резкий телепорт + моментальная большая скорость гасится через
	#    CCD-предохранитель от прошивания стен, а не через обычный контактный
	#    импульс (проверено отладкой отдельно).
	var shaft_center := terrain.position + Vector2(250, 90)
	terrain.carve_circle(Vector2i(terrain.to_local(shaft_center)), 100)
	terrain.flush_dirty()
	var solid_before_crash := terrain.count_solid()

	var crasher := _make_ship()
	await _step(1)
	crasher.respawn(shaft_center + Vector2(0, -70))  # у верхнего края шахты
	var crash_speed := [0.0]
	crasher.crashed.connect(func(v: float): crash_speed[0] = v)
	await _step(120)

	_check("столкновение с землёй роет рельеф",
		terrain.count_solid() < solid_before_crash,
		"было=%d стало=%d" % [solid_before_crash, terrain.count_solid()])
	_check("столкновение с землёй сработало выше порога 250 px/с",
		crash_speed[0] >= PALETTE.dirt_crash_speed,
		"скорость удара=%.0f px/с (порог %.0f)" % [crash_speed[0], PALETTE.dirt_crash_speed])
	var expected_dirt_damage: float = PALETTE.dirt_crash_damage \
		+ (crash_speed[0] - PALETTE.dirt_crash_speed) * PALETTE.dirt_crash_rate
	_check("урон от земли = база + рост от превышения скорости",
		is_equal_approx(crasher.hull, crasher.data.max_hull - expected_dirt_damage),
		"прочность=%.2f/%.1f (ожидалось урона %.2f при скорости %.0f)" % [
			crasher.hull, crasher.data.max_hull, expected_dirt_damage, crash_speed[0]])

	# 9. "Камень": свой (более низкий) порог скорости и свой (больший) урон —
	#    отдельный терраин с маской "почти весь камень, шахта — пустота" (у камня
	#    CARVABLE=0, carve_circle открыть проход не может, дырку рисуем в маске
	#    заранее). Прежний terrain снят с группы "terrain" — group-поиск должен
	#    однозначно цеплять только актуальный уровень для теста.
	terrain.remove_from_group("terrain")
	var stone_terrain := Terrain.new()
	stone_terrain.palette = PALETTE
	stone_terrain.position = Vector2(20000, 20000)
	add_child(stone_terrain)
	var stone_vis := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	stone_vis.fill(Color(0.5, 0.5, 0.5, 1.0))
	var stone_mask := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	stone_mask.fill(PALETTE.get_mask_color(TerrainPalette.Cls.INDESTRUCTIBLE))
	stone_mask.fill_rect(Rect2i(80, 0, 40, 180), PALETTE.get_mask_color(TerrainPalette.Cls.EMPTY))
	stone_terrain.load_level(stone_vis, stone_mask)
	stone_terrain.add_to_group("terrain")
	await _step(1)
	var stone_solid_before := stone_terrain.count_solid()

	var stone_crasher := _make_ship()
	await _step(1)
	stone_crasher.respawn(stone_terrain.position + Vector2(100, 10))
	var stone_crash_speed := [0.0]
	stone_crasher.crashed.connect(func(v: float): stone_crash_speed[0] = v)
	await _step(120)

	_check("столкновение с камнем сработало выше порога 100 px/с",
		stone_crash_speed[0] >= PALETTE.stone_crash_speed,
		"скорость удара=%.0f px/с (порог %.0f)" % [stone_crash_speed[0], PALETTE.stone_crash_speed])
	var expected_stone_damage: float = PALETTE.stone_crash_damage \
		+ (stone_crash_speed[0] - PALETTE.stone_crash_speed) * PALETTE.stone_crash_rate
	_check("урон от камня = база + рост от превышения скорости, круче земли",
		is_equal_approx(stone_crasher.hull, stone_crasher.data.max_hull - expected_stone_damage),
		"прочность=%.2f/%.1f (ожидалось урона %.2f при скорости %.0f)" % [
			stone_crasher.hull, stone_crasher.data.max_hull, expected_stone_damage, stone_crash_speed[0]])
	_check("камень не роется столкновением (CARVABLE=0)",
		stone_terrain.count_solid() == stone_solid_before,
		"было=%d стало=%d" % [stone_solid_before, stone_terrain.count_solid()])

	# 10. Спавн: Terrain.find_clear_spawn() не должен заспавнить корабль в Камне —
	#     регрессия на баг "появляюсь в скале" (фиксированная точка + carve_circle
	#     молча ничего не делает на CARVABLE=0-материале). Терраин наполовину
	#     камень (верх), наполовину земля (низ) — поиск обязан уйти в земляную
	#     половину, а не застрять наверху.
	var spawn_terrain := Terrain.new()
	spawn_terrain.palette = PALETTE
	spawn_terrain.position = Vector2(30000, 30000)
	add_child(spawn_terrain)
	var spawn_vis := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	spawn_vis.fill(Color(0.5, 0.5, 0.5, 1.0))
	var spawn_mask := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	spawn_mask.fill(PALETTE.get_mask_color(TerrainPalette.Cls.INDESTRUCTIBLE))  # верх — камень
	spawn_mask.fill_rect(Rect2i(0, 150, 300, 150), PALETTE.get_mask_color(TerrainPalette.Cls.NORMAL))  # низ — земля
	spawn_terrain.load_level(spawn_vis, spawn_mask)
	await _step(1)

	var found := spawn_terrain.find_clear_spawn(20, 10)
	_check("find_clear_spawn нашёл место", found != Vector2i(-1, -1), "found=%s" % found)
	if found != Vector2i(-1, -1):
		_check("найденное место не в Камне (y >= 150)", found.y >= 150, "found=%s" % found)
		var clear := true
		for offset in [Vector2i.ZERO, Vector2i(19, 0), Vector2i(-19, 0), Vector2i(0, 19), Vector2i(0, -19)]:
			if spawn_terrain.is_solid_at(found + offset):
				clear = false
		_check("вокруг найденного места нет твёрдого", clear, "found=%s" % found)

	# 11. GameRules — autoload правил матча реально влияет на корабль (шов меню Options,
	#     architecture §5, devlog §17). Что дефолт нейтрален, уже доказано тем, что
	#     тесты 1–10 прошли при GameRules по умолчанию. Здесь проверяем обратное: что
	#     КРУЧЕНИЕ множителя доходит до физики. Проверяем свойства напрямую, а не через
	#     тайминг падения — так тест не флакует. В конце GameRules.reset(), чтобы
	#     настройки не «протекли» из этого прогона.
	var rs := _make_ship()
	await _step(1)

	GameRules.gravity_scale = 2.5
	rs.apply_rules()
	_check("GameRules.gravity_scale доходит до RigidBody2D.gravity_scale",
		is_equal_approx(rs.gravity_scale, 2.5), "gravity_scale=%.2f" % rs.gravity_scale)

	GameRules.air_resistance_scale = 3.0
	rs.apply_rules()
	_check("GameRules.air_resistance_scale множит linear_damp",
		is_equal_approx(rs.linear_damp, rs.data.linear_damp * 3.0),
		"linear_damp=%.3f ожидалось=%.3f" % [rs.linear_damp, rs.data.linear_damp * 3.0])

	GameRules.ship_strength = 2.0
	rs.respawn(Vector2(-9999, -9999))  # вдали от любого рельефа, чтобы не крэшнуться
	var hull0 := rs.hull
	rs.take_damage(10.0)
	_check("GameRules.ship_strength делит весь входящий урон",
		is_equal_approx(rs.hull, hull0 - 5.0),
		"снято=%.2f hp (ожидалось 5.0 при strength=2)" % (hull0 - rs.hull))

	GameRules.reload_time_scale = 2.0
	rs.equip_primary(DUMBFIRE_DATA)
	rs.input.fire_primary = true
	await _step(1)
	rs.input.fire_primary = false
	_check("GameRules.reload_time_scale множит кулдаун перезарядки",
		is_equal_approx(rs._primary_cd, DUMBFIRE_DATA.reload_time * 2.0),
		"cd=%.3f ожидалось=%.3f" % [rs._primary_cd, DUMBFIRE_DATA.reload_time * 2.0])
	for n in get_tree().get_nodes_in_group("projectiles"):
		(n as Node).queue_free()

	GameRules.reset()
	_check("GameRules.reset() возвращает нейтральные значения (1.0)",
		is_equal_approx(GameRules.gravity_scale, 1.0)
			and is_equal_approx(GameRules.air_resistance_scale, 1.0)
			and is_equal_approx(GameRules.ship_strength, 1.0)
			and is_equal_approx(GameRules.reload_time_scale, 1.0), "")
