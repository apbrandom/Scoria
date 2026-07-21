## Эффект попадания: роет рельеф и наносит урон кораблям в радиусе, затем исчезает.
##
## Отдельный узел от Projectile — попадание может прийти не только от снаряда
## (позже: цепная детонация EXPLOSIVE-породы, см. architecture.md §8.6), а сам
## эффект не обязан знать, кто его вызвал. Самоудаляется по Tween; настоящие
## GPUParticles2D/звук — позже (architecture.md §9, notes/roadmap.md), место уже
## заложено (эта сцена — единственная точка, где взрыв касается мира).
class_name Explosion
extends Node2D

@export var blast_radius: float = 12.0
## Множитель радиуса разрушения рельефа. 0 — рельеф не трогаем.
@export var terrain_power: float = 1.0
@export var damage: float = 20.0

@onready var _flash: Polygon2D = $Flash


func _ready() -> void:
	_carve_terrain()
	_damage_ships()
	_flash.scale = Vector2.ONE * maxf(blast_radius / 8.0, 0.3)
	var tw := create_tween()
	tw.tween_property(_flash, "modulate:a", 0.0, 0.25)
	tw.tween_callback(queue_free)


func _carve_terrain() -> void:
	if terrain_power <= 0.0:
		return
	var terrain := get_tree().get_first_node_in_group("terrain") as Node2D
	if terrain == null or not terrain.has_method("carve_circle"):
		return
	# Terrain не обязан стоять в (0,0) сцены (например, в будущей level.tscn) —
	# переводим глобальные координаты взрыва в его локальные пиксели явно,
	# а не полагаемся на совпадение global_position с координатами рельефа.
	var local_pos := terrain.to_local(global_position)
	var cell := Vector2i(local_pos.round())
	var cls: int = terrain.class_at(cell) if terrain.has_method("class_at") else TerrainPalette.Cls.NORMAL
	var changed: int = terrain.carve_circle(cell, roundi(blast_radius * terrain_power))
	# Обломки декоративного слоя (см. scenes/fx/terrain_debris.gd) — только если
	# carve реально что-то выбил: попадание в неразрушаемый Камень (CARVABLE=0) не
	# должно давать "оторвавшиеся куски породы", раз порода не оторвалась. Класс
	# читаем ДО carve (после — там уже EMPTY), только для цвета обломков.
	if changed > 0 and terrain.has_method("spawn_weapon_debris"):
		terrain.spawn_weapon_debris(global_position, cls)


func _damage_ships() -> void:
	if damage <= 0.0:
		return
	var space := get_world_2d().direct_space_state
	var query := PhysicsShapeQueryParameters2D.new()
	var shape := CircleShape2D.new()
	shape.radius = blast_radius
	query.shape = shape
	query.transform = Transform2D(0.0, global_position)
	query.collide_with_bodies = true
	for hit in space.intersect_shape(query, 8):
		var body = hit["collider"]
		if body is Ship:
			body.take_damage(damage)
