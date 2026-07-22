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
@onready var _visual: Polygon2D = $Visual
@onready var _collision: CollisionShape2D = $CollisionShape2D

## Скорость на МОМЕНТ входа в столкновение, а не в момент детонации: к вызову
## body_entered физдвижок уже разрешил контакт и погасил linear_velocity почти
## до нуля (та же особенность, что и в Ship._integrate_forces — см. её комментарий
## "ни state.linear_velocity, ни self.linear_velocity в этом колбэке не годятся").
## Проверено диагностикой: linear_velocity в _detonate() у пули, летевшей 900 px/с,
## оказывается (0, 0). Кэшируем каждый физ-кадр ДО разрешения столкновений.
var _last_velocity := Vector2.ZERO


func _ready() -> void:
	if weapon == null:
		push_error("Projectile без WeaponData")
		queue_free()
		return
	gravity_scale = weapon.gravity_scale
	# Масштабируем ТОЛЬКО визуал, не коллайдер (регрессия, заказчик 2026-07-21:
	# уменьшенный коллайдер у пулемётной пули — радиус 2px×0.45=0.9px — почти
	# перестал попадать по рельефу: рельеф собран как ConcavePolygonShape2D из
	# ГОЛЫХ ОТРЕЗКОВ без толщины (см. terrain_chunk.gd), у быстрой (900 px/с) и
	# тонкой пули почти нет шанса зацепить нулевую по толщине линию между физ-
	# кадрами. Замерено tools/diag_bullet_tunnel.gd: с масштабом коллайдера —
	# 40 из 40 пуль прошли насквозь (0 взрывов); без — коллизия снова надёжна.
	# self.scale тоже не годится — RigidBody2D каждый физ-шаг перезаписывает
	# global_transform результатом симуляции (позиция+поворот, БЕЗ масштаба),
	# сброс на 1.0 уже на следующем кадре (проверено диагностикой отдельно).
	_visual.scale = Vector2.ONE * weapon.projectile_scale
	add_to_group("projectiles")
	_lifetime.wait_time = weapon.lifetime
	_lifetime.one_shot = true
	_lifetime.timeout.connect(queue_free)
	_lifetime.start()
	body_entered.connect(_on_body_entered)
	_last_velocity = linear_velocity  # на случай столкновения в тот же кадр, что спавн


func _physics_process(_delta: float) -> void:
	_last_velocity = linear_velocity


func _on_body_entered(body: Node) -> void:
	if body == shooter:
		return
	_detonate()


func _detonate() -> void:
	var exp: Explosion = EXPLOSION_SCENE.instantiate()
	exp.global_position = global_position + _impact_offset()
	exp.blast_radius = weapon.blast_radius
	exp.terrain_power = weapon.terrain_power
	exp.damage = weapon.damage
	exp.shooter = shooter
	get_parent().add_child(exp)
	queue_free()


## Тело снаряда физически тормозит СВОИМ радиусом раньше настоящей поверхности
## (центр CircleShape2D не может дойти до точки контакта вплотную — стандартное
## поведение физики). При carve-радиусе, сравнимом с радиусом снаряда, это съедает
## почти весь запас: взрыв вокруг ЦЕНТРА тела едва задевает породу. Замерено
## (заказчик, "разрежения земли нет", tools/diag_bullet_erosion.gd): попадание
## пулемёта регистрировалось на cell x=298 при границе стены x=300 — carve на
## номинальный радиус 2 (после материала — 2.6) доставал внутрь породы всего на
## ~0.6 px, реальный съём ~3 px за выстрел ВНЕ ЗАВИСИМОСТИ от того, сколько раз
## стрелять в одну точку (тело каждый раз тормозит на той же дистанции от НОВОЙ
## границы). Сдвигаем точку взрыва вперёд по направлению полёта на радиус
## снаряда — туда, где он РЕАЛЬНО коснулся поверхности, а не туда, где
## остановился его центр; тогда каждое попадание выедает полный номинальный
## радиус, и очередь по одной точке реально протачивает проход вглубь.
func _impact_offset() -> Vector2:
	var shape := _collision.shape
	if not (shape is CircleShape2D) or _last_velocity.is_zero_approx():
		return Vector2.ZERO
	return _last_velocity.normalized() * (shape as CircleShape2D).radius
