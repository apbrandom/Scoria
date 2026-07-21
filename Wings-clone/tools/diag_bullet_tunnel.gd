## Диагностика "пули проходят сквозь текстуры" (заказчик, по факту игры 2026-07-21).
## Стреляем N снарядов под разными углами в сплошную стену земли на боевой
## скорости пулемёта — снаряд, который прошёл насквозь и не взорвался, всё ещё
## жив в группе "projectiles" (у Dumbfire gravity_scale=0, летит прямо дальше).
## Снаряд, который столкнулся — self.queue_free() в Projectile._detonate(),
## группу покидает сам.
##
## Находка: continuous_cd=2 (CCD_MODE_CAST_SHAPE, было в projectile.tscn) против
## рельефа (ConcavePolygonShape2D из безтолщинных отрезков, см. terrain_chunk.gd)
## ненадёжен — на боевой скорости пулемёта (900 px/с) давал 19/20 промахов по
## прямому попаданию. continuous_cd=1 (CCD_MODE_CAST_RAY, текущее значение) — 0/20
## на любой скорости вплоть до 1400 px/с при близком к перпендикулярному угле.
## Остаточный эффект: на очень пологих углах (скольжение вдоль поверхности,
## <60° к нормали) промахи всё ещё растут (см. вывод ниже) — реже задевает
## тонкий отрезок на большом протяжении полёта параллельно ему. В реальной игре
## это стрельба почти вдоль стены, не в упор — редкий и менее критичный случай,
## оставлен как открытый пункт (roadmap.md), не блокирует основной сценарий.
##
## Запуск: godot --headless --path Wings-clone res://tools/diag_bullet_tunnel.tscn
extends Node2D

const PROJECTILE_SCENE := preload("res://scenes/projectiles/projectile.tscn")
const DUMBFIRE_DATA := preload("res://data/weapons/dumbfire.tres")
const PALETTE := preload("res://data/terrain/wings_classes.tres")

const N := 30
const WALL_LEFT := 200
const START_X := 100


func _ready() -> void:
	print("=== Диагностика туннелирования пуль по углу атаки (стена в x=%d, скорость=%.0f) ===" % [
		WALL_LEFT, DUMBFIRE_DATA.muzzle_speed])
	# от почти параллельного стене (5°) до почти прямого попадания (85°)
	for angle_deg in [5.0, 15.0, 30.0, 45.0, 60.0, 75.0, 85.0]:
		await _run_batch(angle_deg)
	print("=== диагностика завершена ===")
	get_tree().quit()


func _run_batch(angle_deg: float) -> void:
	var terrain := Terrain.new()
	terrain.palette = PALETTE
	add_child(terrain)
	var vis := Image.create(500, 500, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0, 0, 0, 0))
	vis.fill_rect(Rect2i(WALL_LEFT, 0, 500 - WALL_LEFT, 500), Color(0.5, 0.3, 0.1, 1.0))
	terrain.load_level(vis)
	terrain.add_to_group("terrain")
	await get_tree().physics_frame

	var angle := deg_to_rad(angle_deg)
	var dir := Vector2(cos(angle), sin(angle))
	for i in N:
		var p: Projectile = PROJECTILE_SCENE.instantiate()
		p.weapon = DUMBFIRE_DATA
		var y := 20 + i * (460.0 / N)
		p.global_position = terrain.position + Vector2(START_X, y)
		p.linear_velocity = dir * DUMBFIRE_DATA.muzzle_speed
		add_child(p)

	# время до стены зависит от угла (при пологом угле x-составляющая скорости
	# маленькая) — раньше ждали фиксированные 60 кадров и на 75-85° часть пуль
	# просто ещё не долетела до стены к моменту проверки (ложный "survivor",
	# не туннелирование); считаем честно от геометрии.
	var vx := DUMBFIRE_DATA.muzzle_speed * dir.x
	var dist_to_clear := (WALL_LEFT - START_X) + 100.0  # долёт + запас на "насквозь"
	var frames_needed := int(dist_to_clear / vx * 60.0) + 10
	for _i in frames_needed:
		await get_tree().physics_frame
	for _i in 5:
		await get_tree().process_frame

	var survivors := get_tree().get_nodes_in_group("projectiles").size()
	print("  угол=%4.0f° (кадров ожидания=%d): прошло насквозь %d/%d" % [angle_deg, frames_needed, survivors, N])

	for s in get_tree().get_nodes_in_group("projectiles"):
		(s as Node).queue_free()
	terrain.remove_from_group("terrain")
	terrain.queue_free()
	await get_tree().process_frame
