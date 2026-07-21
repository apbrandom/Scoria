## Диагностика боевого пути в РЕАЛЬНЫХ условиях: снаряд рождает взрыв из
## body_entered (физический колбэк), а взрыв внутри дёргает carve рельефа,
## space-запрос по кораблям И спавн декоративных обломков (Terrain.
## spawn_weapon_debris, scenes/fx/terrain_debris.gd). Тест_ship №7/№12 создают
## взрыв ВНЕ колбэка (напрямую через add_child(Explosion)) и потому НЕ ловят
## "Can't change state while flushing queries" — ровно так уже ловился баг с
## обломками (add_child нового RigidBody2D внутри body_entered падал с этой
## ошибкой, пока не завёл call_deferred в Terrain._spawn_debris). Здесь — как
## в игре, единственный тест, что реально проходит через body_entered.
## Запуск: godot --headless --path Wings-clone res://tools/diag_combat.tscn
extends Node2D

const PROJECTILE_SCENE := preload("res://scenes/projectiles/projectile.tscn")
const BOMB_DATA := preload("res://data/weapons/bomb.tres")
const PALETTE := preload("res://data/terrain/wings_classes.tres")


func _ready() -> void:
	print("=== Диагностика боевого пути (взрыв из body_entered) ===")
	var terrain := Terrain.new()
	terrain.palette = PALETTE
	terrain.immediate_rebuild = false  # как в игре (Level)
	add_child(terrain)
	var vis := Image.create(400, 400, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	terrain.load_level(vis)
	terrain.add_to_group("terrain")
	await get_tree().physics_frame

	var solid_before := terrain.count_solid()

	# снаряд с гравитацией, летит вниз в сплошную породу — попадёт через пару кадров
	var p: Projectile = PROJECTILE_SCENE.instantiate()
	p.weapon = BOMB_DATA
	p.global_position = terrain.position + Vector2(200, 20)
	p.linear_velocity = Vector2(0, 500)
	add_child(p)
	print("  снаряд запущен, ждём попадания...")

	for _i in 60:
		await get_tree().physics_frame

	# дать отложенной пересборке коллизии (immediate_rebuild=false) отработать
	for _i in 5:
		await get_tree().process_frame

	var solid_after := terrain.count_solid()
	print("  твёрдых пикселей: было %d, стало %d (взрыв %s)" % [
		solid_before, solid_after,
		"сработал" if solid_after < solid_before else "НЕ сработал"])
	print("  снарядов осталось в дереве: %d" % get_tree().get_nodes_in_group("projectiles").size())
	print("  обломков заспавнено (через очередь _pending_debris/_process): %d (ожидалось 3..8)" % terrain._debris.size())
	print("=== диагностика завершена (ищи ERROR выше по логу) ===")
	get_tree().quit()
