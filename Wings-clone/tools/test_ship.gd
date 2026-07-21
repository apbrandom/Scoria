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
	# Terrain._ready() сам добавляет себя в группу "terrain" (см. terrain.gd) —
	# spawn_terrain никогда явно add_to_group() не звал (find_clear_spawn() группу
	# не использует), но авто-вступление всё равно случилось. Не уходим —
	# get_first_node_in_group("terrain") в секции 12 подхватил бы ЭТОТ террейн
	# (он старше всех фикстур той секции), а не актуальный.
	spawn_terrain.remove_from_group("terrain")

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

	# 12. Обломки: декоративный RigidBody2D-слой поверх попиксельной системы (см.
	#     terrain_debris.gd, Terrain.spawn_weapon_debris/spawn_crash_debris). Свежие
	#     terrain-фикстуры на новых мировых координатах — не переиспользуем terrain/
	#     stone_terrain из секций 7-9, у тех уже есть накопленные обломки от
	#     собственных столкновений; проверяем ДЕЛЬТАМИ, а не абсолютными числами.
	# stone_terrain из секции 9 группу "terrain" не покидал (там это было не
	# нужно) — уходим сами, иначе get_first_node_in_group("terrain") ниже мог бы
	# зацепить его вместо актуальной фикстуры этой секции.
	stone_terrain.remove_from_group("terrain")

	# 12a. Взрыв в разрушаемую породу — 3..8 обломков.
	var debris_terrain := Terrain.new()
	debris_terrain.palette = PALETTE
	debris_terrain.position = Vector2(40000, 40000)
	add_child(debris_terrain)
	var debris_vis := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	debris_vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	debris_terrain.load_level(debris_vis)
	debris_terrain.add_to_group("terrain")
	await _step(1)

	var before_weapon := debris_terrain._debris.size()
	var exp2: Explosion = EXPLOSION_SCENE.instantiate()
	exp2.global_position = debris_terrain.position + Vector2(150, 150)
	exp2.blast_radius = 20.0
	exp2.terrain_power = 1.0
	exp2.damage = 0.0
	add_child(exp2)
	await _step(1)
	var weapon_spawned := debris_terrain._debris.size() - before_weapon
	_check("взрыв в разрушаемую породу даёт 3..8 обломков",
		weapon_spawned >= 3 and weapon_spawned <= 8, "заспавнено=%d" % weapon_spawned)

	# 12b. Взрыв в неразрушаемый Камень (changed=0) — обломков нет вовсе.
	debris_terrain.remove_from_group("terrain")
	var stone_debris_terrain := Terrain.new()
	stone_debris_terrain.palette = PALETTE
	stone_debris_terrain.position = Vector2(50000, 50000)
	add_child(stone_debris_terrain)
	var stone_debris_vis := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	stone_debris_vis.fill(Color(0.5, 0.5, 0.5, 1.0))
	var stone_debris_mask := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	stone_debris_mask.fill(PALETTE.get_mask_color(TerrainPalette.Cls.INDESTRUCTIBLE))
	stone_debris_mask.fill_rect(Rect2i(80, 0, 40, 180), PALETTE.get_mask_color(TerrainPalette.Cls.EMPTY))
	stone_debris_terrain.load_level(stone_debris_vis, stone_debris_mask)
	stone_debris_terrain.add_to_group("terrain")
	await _step(1)

	var before_stone := stone_debris_terrain._debris.size()
	var exp3: Explosion = EXPLOSION_SCENE.instantiate()
	exp3.global_position = stone_debris_terrain.position + Vector2(200, 100)  # вне шахты, сплошной камень
	exp3.blast_radius = 20.0
	exp3.terrain_power = 1.0
	exp3.damage = 0.0
	add_child(exp3)
	await _step(1)
	_check("взрыв в неразрушаемый Камень не даёт обломков (changed=0)",
		stone_debris_terrain._debris.size() == before_stone,
		"было=%d стало=%d" % [before_stone, stone_debris_terrain._debris.size()])

	# 12c. Столкновение корабля с Землёй на скорости — 1..3 обломка (пыль),
	#      заметно меньше взрыва. СВОЙ terrain, а не переиспользуем debris_terrain
	#      из 12a: тот уже несёт 8 обломков со случайным временем жизни 0.8-1.6 с, и
	#      за 120 физ-кадров (2 с) ожидания крэша часть из них успела бы истечь —
	#      "до/после" на общем terrain дало бы отрицательную/зашумлённую дельту.
	stone_debris_terrain.remove_from_group("terrain")
	var crash_land_terrain := Terrain.new()
	crash_land_terrain.palette = PALETTE
	crash_land_terrain.position = Vector2(80000, 80000)
	add_child(crash_land_terrain)
	var crash_land_vis := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	crash_land_vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	crash_land_terrain.load_level(crash_land_vis)
	await _step(1)
	var shaft2 := crash_land_terrain.position + Vector2(250, 90)
	crash_land_terrain.carve_circle(Vector2i(crash_land_terrain.to_local(shaft2)), 100)
	crash_land_terrain.flush_dirty()

	var before_crash := crash_land_terrain._debris.size()
	var crasher2 := _make_ship()
	await _step(1)
	crasher2.respawn(shaft2 + Vector2(0, -70))
	var crash2_speed := [-1.0]
	crasher2.crashed.connect(func(v: float): crash2_speed[0] = v)
	# Ждём удара покадрово и останавливаемся СРАЗУ по факту (а не фиксированные
	# 120 кадров вслепую): время жизни обломка случайное 0.8-1.6 с (48-96 кадров,
	# см. debris_lifetime_min/max) — если бы удар пришёлся рано, а мы всё равно
	# досиживали фиксированное окно, обломок успевал бы истечь ДО проверки, и
	# "заспавнено=0" означало бы "уже не там", а не "не появился" (ровно так и
	# ловилось нестабильно, пока тест был на фиксированном большом ожидании).
	for _i in 150:
		await get_tree().physics_frame
		if crash2_speed[0] >= 0.0:
			break
	await _step(3)  # дать _process() продренажить _pending_debris следом за ударом
	var crash_spawned := crash_land_terrain._debris.size() - before_crash
	_check("корабль реально врезался в Землю за 150 кадров",
		crash2_speed[0] >= 0.0, "скорость удара=%.0f (−1 = не врезался)" % crash2_speed[0])
	_check("столкновение с землёй даёт 1..3 обломка (пыль)",
		crash_spawned >= 1 and crash_spawned <= 3, "заспавнено=%d" % crash_spawned)
	crash_land_terrain.remove_from_group("terrain")

	# 12d. Столкновение с Камнем ТОЖЕ поднимает пыль, хотя камень не крошится —
	#      удар корпусом сам по себе источник пыли, не только выбитая порода.
	#      Свой terrain по той же причине, что и 12c (не stone_debris_terrain из 12b).
	var crash_stone_terrain := Terrain.new()
	crash_stone_terrain.palette = PALETTE
	crash_stone_terrain.position = Vector2(90000, 90000)
	add_child(crash_stone_terrain)
	var crash_stone_vis := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	crash_stone_vis.fill(Color(0.5, 0.5, 0.5, 1.0))
	var crash_stone_mask := Image.create(300, 300, false, Image.FORMAT_RGBA8)
	crash_stone_mask.fill(PALETTE.get_mask_color(TerrainPalette.Cls.INDESTRUCTIBLE))
	crash_stone_mask.fill_rect(Rect2i(80, 0, 40, 180), PALETTE.get_mask_color(TerrainPalette.Cls.EMPTY))
	crash_stone_terrain.load_level(crash_stone_vis, crash_stone_mask)
	crash_stone_terrain.add_to_group("terrain")
	await _step(1)

	var before_stone_crash := crash_stone_terrain._debris.size()
	var stone_crasher2 := _make_ship()
	await _step(1)
	stone_crasher2.respawn(crash_stone_terrain.position + Vector2(100, 10))
	var stone_crash2_speed := [-1.0]
	stone_crasher2.crashed.connect(func(v: float): stone_crash2_speed[0] = v)
	# Останавливаемся сразу по факту удара, не досиживаем фиксированное окно —
	# та же причина, что и в 12c: время жизни обломка случайное (0.8-1.6 с), и
	# ранний удар + слепое долгое ожидание давали ложные "заспавнено=0" (обломок
	# уже истёк к моменту проверки, хотя реально появлялся) — воспроизводилось
	# нестабильно, пока тест не начал проверять сразу после самого удара.
	for _i in 150:
		await get_tree().physics_frame
		if stone_crash2_speed[0] >= 0.0:
			break
	await _step(3)  # дать _process() продренажить _pending_debris следом за ударом
	var stone_crash_spawned := crash_stone_terrain._debris.size() - before_stone_crash
	# Проверяем и сам факт столкновения (сигнал crashed), и обломки отдельно — если
	# заспавнено=0 из-за того, что удар вообще не засчитался (а не баг обломков),
	# эта проверка укажет на причину точно, а не спишет всё на debris-логику.
	_check("корабль реально врезался в Камень за 150 кадров",
		stone_crash2_speed[0] >= 0.0, "скорость удара=%.0f (−1 = не врезался)" % stone_crash2_speed[0])
	_check("столкновение с камнем тоже даёт пыль, хоть камень не крошится",
		stone_crash_spawned >= 1 and stone_crash_spawned <= 3, "заспавнено=%d" % stone_crash_spawned)
	crash_stone_terrain.remove_from_group("terrain")

	# 12e. Жёсткий кап: max_debris держит потолок, старые вытесняются (FIFO).
	var cap_terrain := Terrain.new()
	cap_terrain.palette = PALETTE
	cap_terrain.position = Vector2(60000, 60000)
	cap_terrain.max_debris = 5
	add_child(cap_terrain)
	var cap_vis := Image.create(200, 200, false, Image.FORMAT_RGBA8)
	cap_vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	cap_terrain.load_level(cap_vis)
	await _step(1)

	for _i in 4:
		cap_terrain.spawn_weapon_debris(cap_terrain.position + Vector2(100, 100), TerrainPalette.Cls.NORMAL)
	await _step(1)  # спавн реально происходит в _process() (см. terrain.gd) — дать кадр
	_check("жёсткий кап держит max_debris обломков одновременно",
		cap_terrain._debris.size() == 5, "обломков=%d (кап=5)" % cap_terrain._debris.size())

	# 12f. Слой/маска: обломок не должен физически сталкиваться ни с кораблём,
	#      ни с рельефом (декоративный слой, см. terrain_debris.gd). Достаточно
	#      RigidBody2D — collision_layer/mask объявлены в CollisionObject2D, а
	#      не в TerrainDebris, кастовать к самому классу не нужно.
	var probe := cap_terrain._debris.back() as RigidBody2D
	_check("обломок на отдельном физическом слое",
		probe.collision_layer == Terrain.DEBRIS_LAYER, "layer=%d" % probe.collision_layer)
	_check("обломок ни с чем не сталкивается (mask=0)",
		probe.collision_mask == 0, "mask=%d" % probe.collision_mask)

	# 12g. Обломки не наносят урон и не толкают корабль — декоративный слой
	#      поверх физики, а не участник её. Спавним прямо в корпус и смотрим,
	#      что прочность не падает.
	var bystander := _make_ship()
	await _step(1)
	bystander.respawn(cap_terrain.position + Vector2(100, 100))
	await _step(1)
	for _i in 8:
		cap_terrain.spawn_weapon_debris(bystander.global_position, TerrainPalette.Cls.NORMAL)
	await _step(30)
	_check("обломки не наносят урон кораблю рядом",
		bystander.hull == bystander.data.max_hull,
		"прочность=%.1f/%.1f" % [bystander.hull, bystander.data.max_hull])

	# 12h. Время жизни ограничено — обломок сам исчезает через несколько секунд,
	#      не копится вечно (свой terrain, чтобы не путать с кап-тестом выше).
	var ttl_terrain := Terrain.new()
	ttl_terrain.palette = PALETTE
	ttl_terrain.position = Vector2(70000, 70000)
	ttl_terrain.debris_lifetime_min = 0.2
	ttl_terrain.debris_lifetime_max = 0.2
	add_child(ttl_terrain)
	var ttl_vis := Image.create(100, 100, false, Image.FORMAT_RGBA8)
	ttl_vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	ttl_terrain.load_level(ttl_vis)
	await _step(1)

	ttl_terrain.spawn_weapon_debris(ttl_terrain.position + Vector2(50, 50), TerrainPalette.Cls.NORMAL)
	await _step(1)  # спавн реально происходит в _process() (см. terrain.gd) — дать кадр
	_check("обломки появились на сцене", ttl_terrain._debris.size() > 0,
		"обломков=%d" % ttl_terrain._debris.size())
	await _step(90)  # 1.5 с при 60 Гц — заведомо больше lifetime=0.2 с
	_check("обломки сами исчезают по истечении времени жизни (не копятся)",
		ttl_terrain._debris.size() == 0, "обломков осталось=%d" % ttl_terrain._debris.size())
	# cap_terrain (12e) и ttl_terrain (12h) сами группу никогда не запрашивали
	# (spawn_weapon_debris звался напрямую на ссылку), но Terrain._ready() всё
	# равно кладёт их в "terrain" (см. devlog §18, находка D) — уходим явно,
	# иначе секция 13 ниже резолвит группу на них, а не на актуальный terrain.
	cap_terrain.remove_from_group("terrain")
	ttl_terrain.remove_from_group("terrain")

	# 13. Регрессия на "разрушаемости от пуль нет" (заказчик, по факту игры
	#     2026-07-21): при terrain_power=0.3 очередь из 20 пулемётных попаданий в
	#     одну область выбивала считаные пиксели — визуально неотличимо от "пули
	#     ничего не делают". Порог terrain_power поднят до 0.6 (devlog §19); тест
	#     фиксирует нижнюю границу видимости через РЕАЛЬНЫЙ Explosion (не сырой
	#     carve_circle) — чтобы будущая правка weapon-данных не тихо откатила
	#     эффект обратно к незаметному.
	var dumbfire_terrain := Terrain.new()
	dumbfire_terrain.palette = PALETTE
	dumbfire_terrain.position = Vector2(100000, 100000)
	add_child(dumbfire_terrain)
	var dumbfire_vis := Image.create(200, 200, false, Image.FORMAT_RGBA8)
	dumbfire_vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	dumbfire_terrain.load_level(dumbfire_vis)
	dumbfire_terrain.add_to_group("terrain")
	await _step(1)

	var dumbfire_solid0 := dumbfire_terrain.count_solid()
	var burst_center := dumbfire_terrain.position + Vector2(100, 100)
	var jitter_rng := RandomNumberGenerator.new()
	jitter_rng.seed = 1
	for _i in 20:
		var exp4: Explosion = EXPLOSION_SCENE.instantiate()
		exp4.global_position = burst_center + Vector2(
			jitter_rng.randi_range(-3, 3), jitter_rng.randi_range(-3, 3))
		exp4.blast_radius = DUMBFIRE_DATA.blast_radius
		exp4.terrain_power = DUMBFIRE_DATA.terrain_power
		exp4.damage = 0.0
		add_child(exp4)
		await _step(1)
	var dumbfire_removed := dumbfire_solid0 - dumbfire_terrain.count_solid()
	_check("очередь из 20 пулемётных попаданий заметно выедает Землю (не считаные пиксели)",
		dumbfire_removed >= 60,
		"выбито=%d px (было 5 px при старом terrain_power=0.3, порог регрессии — 60)" % dumbfire_removed)
	dumbfire_terrain.remove_from_group("terrain")
