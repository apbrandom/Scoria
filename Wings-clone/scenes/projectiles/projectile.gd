## Снаряд общего вида: параметры полёта задаёт WeaponData, поведение при попадании
## одно и то же для пулемёта и ракетницы — разница только в цифрах (см. weapon_data.gd).
## Отдельные сцены под конкретное оружие понадобятся, только когда поведение
## качественно другое (Bouncer/Mine/Teleport из бэклога, notes/roadmap.md) —
## пока этого нет, одна сцена на оба оружия проще и ничем не хуже.
class_name Projectile
extends RigidBody2D

## Кто выстрелил — чтобы не подорваться о собственный ствол в первый же кадр.
var shooter: Node = null
var weapon: WeaponData

const EXPLOSION_SCENE := preload("res://scenes/fx/explosion.tscn")

@onready var _lifetime: Timer = $Lifetime


func _ready() -> void:
	if weapon == null:
		push_error("Projectile без WeaponData")
		queue_free()
		return
	gravity_scale = weapon.gravity_scale
	add_to_group("projectiles")
	_lifetime.wait_time = weapon.lifetime
	_lifetime.one_shot = true
	_lifetime.timeout.connect(queue_free)
	_lifetime.start()
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if body == shooter:
		return
	_detonate()


func _detonate() -> void:
	var exp: Explosion = EXPLOSION_SCENE.instantiate()
	exp.global_position = global_position
	exp.blast_radius = weapon.blast_radius
	exp.terrain_power = weapon.terrain_power
	exp.damage = weapon.damage
	get_parent().add_child(exp)
	queue_free()
