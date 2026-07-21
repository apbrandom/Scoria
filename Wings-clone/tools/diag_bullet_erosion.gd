## Диагностика "контакт хороший, но разрежения земли не видно" (заказчик,
## по факту игры 2026-07-21). Стреляем очередью пулемёта из НАСТОЯЩЕГО Ship
## (Ship._fire -> Projectile -> body_entered -> Explosion), как в игре, а не
## голым Explosion — чтобы поймать разницу между "carve технически произошёл"
## и "дыра видна снаружи стены".
##
## Находка: тело снаряда физически тормозит СВОИМ радиусом (2px) РАНЬШЕ
## настоящей поверхности — стандартное поведение физики, центр CircleShape2D не
## может дойти до точки контакта вплотную. При carve-радиусе (после материала —
## 2.6px), сравнимом с радиусом снаряда, воронка вокруг ЦЕНТРА тела едва
## задевала породу: замерено — попадание регистрировалось на cell x=298 при
## границе стены x=300, реальный съём ~3px за выстрел, ВНЕ ЗАВИСИМОСТИ от
## числа попаданий в одну точку (тело каждый раз тормозит на той же дистанции
## от НОВОЙ границы — тоннель физически не может начать копать глубже). Плюс
## linear_velocity в _detonate()/body_entered уже погашена физдвижком в (0,0) —
## та же особенность, что в Ship._integrate_forces (см. её комментарий);
## Projectile теперь кэширует скорость в _physics_process ДО разрешения
## столкновения (_last_velocity) и сдвигает точку взрыва вперёд по ней на
## радиус снаряда — воронка ложится на РЕАЛЬНУЮ точку контакта.
##
## Запуск: godot --headless --path Wings-clone res://tools/diag_bullet_erosion.tscn
extends Node2D

const DUMBFIRE_DATA := preload("res://data/weapons/dumbfire.tres")
const PALETTE := preload("res://data/terrain/wings_classes.tres")
const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const PROJECTILE_SCENE := preload("res://scenes/projectiles/projectile.tscn")

const WALL_LEFT := 300


func _ready() -> void:
	print("=== Диагностика глубины попадания и профиля эрозии ===")
	await _single_shot_depth()
	await _burst_profile()
	get_tree().quit()


## Один выстрел прямо в стену — на какой глубине (px от WALL_LEFT) реально
## сработал Explosion._carve_terrain()?
func _single_shot_depth() -> void:
	var terrain := Terrain.new()
	terrain.palette = PALETTE
	add_child(terrain)
	var vis := Image.create(600, 200, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0, 0, 0, 0))
	vis.fill_rect(Rect2i(WALL_LEFT, 0, 600 - WALL_LEFT, 200), Color(0.5, 0.3, 0.1, 1.0))
	terrain.load_level(vis)
	terrain.add_to_group("terrain")
	await get_tree().physics_frame

	var p: Projectile = PROJECTILE_SCENE.instantiate()
	p.weapon = DUMBFIRE_DATA
	p.global_position = terrain.position + Vector2(100, 100)
	p.linear_velocity = Vector2(DUMBFIRE_DATA.muzzle_speed, 0)
	add_child(p)
	for _i in 30:
		await get_tree().physics_frame
	for _i in 5:
		await get_tree().process_frame

	var hit := -1
	for x in range(WALL_LEFT, 600):
		if not terrain.is_solid_at(Vector2i(x, 100)):
			hit = x
			break
	print("  один выстрел в упор: поверхность стены x=%d, первый вырезанный пиксель x=%s (глубина=%s)" % [
		WALL_LEFT, str(hit), (str(hit - WALL_LEFT) if hit >= 0 else "н/д — ничего не задето")])
	terrain.remove_from_group("terrain")
	terrain.queue_free()
	await get_tree().process_frame


## Очередь настоящим Ship (как реальная игра: reload_time, muzzle у носа) по
## стене в упор, корабль без гравитации (держим точно на одной высоте — снос
## гравитацией размазывает очередь по разным y, отдельный от carve эффект) —
## сколько пикселей исчезло и виден ли сплошной канал от поверхности вглубь.
func _burst_profile() -> void:
	var terrain := Terrain.new()
	terrain.palette = PALETTE
	add_child(terrain)
	var vis := Image.create(600, 200, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0, 0, 0, 0))
	vis.fill_rect(Rect2i(WALL_LEFT, 0, 600 - WALL_LEFT, 200), Color(0.5, 0.3, 0.1, 1.0))
	terrain.load_level(vis)
	terrain.add_to_group("terrain")
	await get_tree().physics_frame

	var ship: Ship = SHIP_SCENE.instantiate()
	ship.data = SHIP_DATA
	ship.input = ShipInput.new()
	add_child(ship)
	ship.global_position = terrain.position + Vector2(100, 100)
	ship.equip_primary(DUMBFIRE_DATA)
	ship.aim_angle = PI / 2.0  # нос смотрит вправо (+X) — в стену
	ship.gravity_scale = 0.0
	await get_tree().physics_frame

	var solid0 := terrain.count_solid()
	ship.input.fire_primary = true
	for _i in 180:  # 3 с при 60 Гц — при reload_time=0.15 это ~20 выстрелов
		await get_tree().physics_frame
		await get_tree().process_frame
	ship.input.fire_primary = false
	for _i in 10:
		await get_tree().process_frame

	var removed := solid0 - terrain.count_solid()
	var first_gap := -1
	var last_gap := -1
	for x in range(WALL_LEFT, 600):
		if not terrain.is_solid_at(Vector2i(x, 100)):
			if first_gap < 0:
				first_gap = x
			last_gap = x
	print("  очередь по стене (~3с, reload=%.2fс -> ~%d выстрелов): выбито=%d px" % [
		DUMBFIRE_DATA.reload_time, int(3.0 / DUMBFIRE_DATA.reload_time), removed])
	if first_gap >= 0:
		print("  профиль по центральной линии: от x=%d до x=%d (глубина канала=%d px)" % [
			first_gap, last_gap, last_gap - WALL_LEFT])
	else:
		print("  профиль по центральной линии: ПУСТО — на центральной линии ничего не тронуто")

	for n in get_tree().get_nodes_in_group("projectiles"):
		(n as Node).queue_free()
	terrain.remove_from_group("terrain")
	terrain.queue_free()
	ship.queue_free()
	await get_tree().process_frame
