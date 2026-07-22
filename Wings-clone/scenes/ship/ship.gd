## Корабль игрока на RigidBody2D.
##
## Физика оригинала ложится на свойства тела напрямую: mass, gravity_scale,
## linear_damp; тяга — apply_central_force. В Wings корабль поворачивается с
## ФИКСИРОВАННОЙ скоростью по кнопке, а не крутящим моментом, поэтому
## lock_rotation=true и собственный aim_angle; коллайдер круглый, так что поворот
## визуала на физику не влияет. Удар о рельеф — скорость корабля против порога
## конкретного материала (TerrainPalette.crash_speed_threshold), см.
## notes/terrain_materials.md. Глобальные правила матча (гравитация, прочность и
## т.п.) приходят из autoload GameRules через apply_rules(). См.
## notes/architecture.md §2.3, §5 (дизайн) и notes/devlog.md §10, §14, §17 (реализация).
class_name Ship
extends RigidBody2D

signal hull_changed(hull: float, max_hull: float)
signal crashed(speed: float)
## killer — кто нанёс смертельный урон (см. take_damage), null — смерть без
## чужого участия (столкновение с рельефом). MatchManager трактует null или
## killer == self (самострел) как самоубийство.
signal destroyed(killer: Node)

## Защита от многократного срабатывания crash-урона за одно столкновение, сек.
## Не применяется к урону от оружия (Explosion.take_damage) — это разовые события,
## а не непрерывный контакт, дребезг им не грозит.
const CRASH_COOLDOWN := 0.2

## Максимальное расстояние вершины Visual-полигона от центра при scale=1
## (см. ship.tscn: нос на (0,-6.6)). Вместе с VISUAL_FIT_MARGIN гарантирует,
## что визуал никогда не вылезает за пределы коллизии, даже если collision_radius
## поменяют в инспекторе — раньше нос торчал за коллайдер на ~4px и "проваливался"
## в текстуру рельефа.
const VISUAL_MAX_VERTEX_DIST := 6.6
## Насколько визуал не должен доставать до границы коллизии, доля от collision_radius.
const VISUAL_FIT_MARGIN := 0.9
## Насколько дуло выступает за пределы коллизии, чтобы снаряд всегда рождался
## в открытом пространстве, а не внутри собственного корпуса.
const MUZZLE_CLEARANCE := 5.0
## Насколько эмиттер хвоста двигателя отстоит от кормы. Меньше MUZZLE_CLEARANCE —
## частицам не нужно "выходить" за пределы корпуса, как снаряду, только не
## рождаться глубоко внутри геометрии корабля.
const THRUST_CLEARANCE := 3.0
## Предохранитель на радиус кратера от столкновения (data.crash_carve_scale) —
## даже очень сильный удар не должен выесть рельеф сильнее прямого попадания
## ракеты. Без этого предела экстремальная скорость падения дала бы неправдоподобно
## огромную воронку.
const CRASH_CARVE_MAX := 40.0

@export var data: ShipData
## Провайдер ввода (LocalInput/AIInput/RemoteInput). Ставится при спавне.
var input: ShipInput

## Оружие живёт на корабле, а не в ShipData: ShipData — общий .tres на все копии
## этого корабля (см. weapon_data.gd), а оружие меняется у конкретного экземпляра
## (смена на базе, в будущем) — писать это в общий ресурс было бы багом.
@export var primary_weapon: WeaponData      # fire_primary — пулемёт
@export var secondary_weapon: WeaponData    # fire_secondary — ракетница

var aim_angle := 0.0
var hull := 0.0

var _alive := true
var _crash_cd := 0.0
var _primary_cd := 0.0
var _secondary_cd := 0.0
var _primary_ammo := -1
var _secondary_ammo := -1

@onready var _visual: Node2D = $Visual
@onready var _collision: CollisionShape2D = $CollisionShape2D
@onready var _muzzle: Marker2D = $Muzzle
@onready var _thrust: GPUParticles2D = $Thrust


func _ready() -> void:
	if data == null:
		push_error("Ship без ShipData — нечего инициализировать")
		set_physics_process(false)
		return
	mass = data.mass
	apply_rules()
	contact_monitor = true
	max_contacts_reported = maxi(max_contacts_reported, 4)
	var circle := CircleShape2D.new()
	circle.radius = data.collision_radius
	_collision.shape = circle
	_visual.scale = Vector2.ONE * (data.collision_radius * VISUAL_FIT_MARGIN / VISUAL_MAX_VERTEX_DIST)
	_apply_aim_angle()
	hull = data.max_hull
	equip_primary(primary_weapon)
	equip_secondary(secondary_weapon)
	hull_changed.emit(hull, data.max_hull)


## Применяет глобальные правила матча (autoload GameRules) к физике этого корабля.
## Отдельным методом, а не прямо в _ready(), чтобы меню Options / MatchManager могли
## пере-применить правила к уже живым кораблям при смене настроек на ходу.
## gravity_scale — это правило матча, а не свойство корабля (ship_data.gd прямо так
## и оговаривает), поэтому берётся отсюда, а не из ShipData. Множители нейтральны
## по умолчанию (1.0), так что без настроек поведение как раньше.
func apply_rules() -> void:
	gravity_scale = GameRules.gravity_scale
	linear_damp = data.linear_damp * GameRules.air_resistance_scale


## Сменить оружие в первом слоте (и сбросить его боезапас/кулдаун). Всегда ходить
## через это, а не писать primary_weapon напрямую: иначе при смене оружия на ходу
## (например, "выбор оружия на базе" из бэклога) в _primary_ammo останется старое
## число патронов от прошлого оружия — тихий баг, который сложно заметить руками.
func equip_primary(weapon: WeaponData) -> void:
	primary_weapon = weapon
	_primary_ammo = weapon.ammo if weapon != null else 0
	_primary_cd = 0.0


## См. equip_primary — то же самое для второго слота.
func equip_secondary(weapon: WeaponData) -> void:
	secondary_weapon = weapon
	_secondary_ammo = weapon.ammo if weapon != null else 0
	_secondary_cd = 0.0


## Единая точка пересчёта всего, что зависит от направления носа. Раньше Muzzle
## позиционировался один раз в _ready() и больше никогда не обновлялся — корабль
## стрелял в правильном направлении (скорость снаряда считалась из aim_angle
## отдельно), но точка появления снаряда всегда оставалась "над центром", а не
## у носа развёрнутого корабля: незаметный баг, пока не понадобился Thrust,
## которому позиция и поворот критичны для направления выброса частиц.
## Ship (RigidBody2D) не вращается физически (lock_rotation=true) — вращается
## только Visual вручную, поэтому дочерние маркеры сами по себе не следуют
## за aim_angle и их нужно пересчитывать явно.
func _apply_aim_angle() -> void:
	_visual.rotation = aim_angle
	_muzzle.position = Vector2.UP.rotated(aim_angle) * (data.collision_radius + MUZZLE_CLEARANCE)
	_thrust.position = Vector2.DOWN.rotated(aim_angle) * (data.collision_radius + THRUST_CLEARANCE)
	_thrust.rotation = aim_angle


func _physics_process(delta: float) -> void:
	if not _alive or input == null:
		return
	_crash_cd = maxf(_crash_cd - delta, 0.0)
	_primary_cd = maxf(_primary_cd - delta, 0.0)
	_secondary_cd = maxf(_secondary_cd - delta, 0.0)
	input.poll(delta)

	# поворот с фиксированной скоростью
	aim_angle = wrapf(aim_angle + input.turn * data.turn_rate * delta, -PI, PI)
	_apply_aim_angle()

	if input.thrust:
		apply_central_force(Vector2.UP.rotated(aim_angle) * data.thrust)
	_thrust.emitting = input.thrust

	if input.fire_primary and primary_weapon != null and _primary_cd <= 0.0 and _primary_ammo != 0:
		_fire(primary_weapon)
		_primary_cd = primary_weapon.reload_time * GameRules.reload_time_scale
		if _primary_ammo > 0:
			_primary_ammo -= 1
	if input.fire_secondary and secondary_weapon != null and _secondary_cd <= 0.0 and _secondary_ammo != 0:
		_fire(secondary_weapon)
		_secondary_cd = secondary_weapon.reload_time * GameRules.reload_time_scale
		if _secondary_ammo > 0:
			_secondary_ammo -= 1


func _fire(weapon: WeaponData) -> void:
	if weapon.projectile_scene == null:
		return
	var p: Projectile = weapon.projectile_scene.instantiate()
	p.weapon = weapon
	p.shooter = self
	p.global_position = _muzzle.global_position
	p.rotation = aim_angle
	p.linear_velocity = Vector2.UP.rotated(aim_angle) * weapon.muzzle_speed \
		+ linear_velocity * weapon.velocity_inherit
	get_parent().add_child(p)


## Урон от столкновения зависит от СКОРОСТИ корабля и класса материала, в
## который он врезался (см. terrain_materials.md): ниже порога — ровно 0
## (PvP-ощущение "мягкое касание безопасно"), выше — растёт пропорционально
## превышению от опорной точки на пороге (реальная физика удара — больше
## скорость, больше урон — но с настраиваемым PvP-ориентиром, а не пропорция
## от нуля). Пороги/база/скорость роста по материалам — в
## TerrainPalette.crash_speed_threshold()/crash_damage() (Инспектор:
## data/terrain/wings_classes.tres, группа "Столкновение корабля"), не здесь:
## это свойство рельефа, а не корабля.
## Столкновение ещё и роет рельеф той же проверкой — carve_circle() сам уважает
## класс материала (по камню ничего не выроет), отдельной проверки не нужно.
##
## _crash_cd не даёт этому сработать чаще раза в CRASH_COOLDOWN: при затяжном
## скольжении вдоль стены выше порога урон будет тикать раз в 0.2 с, а не 60 раз
## в секунду — накопительный износ от долгого трения, а не мгновенная казнь.
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if not _alive or data == null or _crash_cd > 0.0:
		return
	var impulse := 0.0
	var impact_pos := Vector2.ZERO
	var impact_collider: Object = null
	for i in state.get_contact_count():
		var imp := state.get_contact_impulse(i).length()
		if imp > impulse:
			impulse = imp
			impact_pos = state.get_contact_collider_position(i)
			impact_collider = state.get_contact_collider_object(i)
	if not (impact_collider is StaticBody2D):
		return

	var terrain := get_tree().get_first_node_in_group("terrain") as Terrain
	if terrain == null or terrain.palette == null:
		return
	var local_pos := terrain.to_local(impact_pos)
	var cls := terrain.class_at(Vector2i(local_pos.round()))
	# Скорость столкновения ОЦЕНИВАЕМ через импульс (impulse ≈ mass × Δv для
	# полной остановки о статичное препятствие), а не читаем напрямую:
	# ни state.linear_velocity, ни self.linear_velocity в этом колбэке не годятся —
	# к моменту вызова _integrate_forces столкновение уже разрешено физдвижком,
	# обе показывают скорость ПОСЛЕ удара (обычно ~0 у статичной стены), а не
	# скорость самого удара. Проверено отладкой, не теория. Приближение точное
	# для типичного "влетел и встал", менее точное при скользящем ударе
	# (импульс погасит не всю скорость) — для геймплейного порога достаточно.
	var speed := impulse / maxf(mass, 0.001)
	var threshold := terrain.palette.crash_speed_threshold(cls)
	if speed < threshold:
		return

	_crash_cd = CRASH_COOLDOWN
	crashed.emit(speed)
	take_damage(terrain.palette.crash_damage(cls, speed))
	_carve_crash_site(terrain, impact_pos, speed - threshold)
	# Пыль от удара корпусом — декоративный слой (см. scenes/fx/terrain_debris.gd),
	# срабатывает при ЛЮБОМ засчитанном столкновении, даже по Камню (который не
	# крошится): удар сам по себе источник пыли, не только выбитая порода —
	# в отличие от оружейных обломков (см. Explosion._carve_terrain), которые
	# идут только если carve реально что-то выбил.
	terrain.spawn_crash_debris(impact_pos, cls)


## Небольшой кратер в месте удара о рельеф — только если там вообще есть что
## рыть (карвится только CARVABLE-класс, см. terrain_palette.gd), радиус растёт
## с превышением порога скорости, но не безгранично (CRASH_CARVE_MAX).
func _carve_crash_site(terrain: Terrain, at: Vector2, over_threshold: float) -> void:
	if data.crash_carve_scale <= 0.0:
		return
	var radius := over_threshold * data.crash_carve_scale
	radius = minf(radius, CRASH_CARVE_MAX)
	if radius < 1.0:
		return
	var local_pos := terrain.to_local(at)
	terrain.carve_circle(Vector2i(local_pos.round()), roundi(radius))


## Публичный вход для любого источника урона (взрыв оружия, крэш). Не имеет
## собственного дребезга — вызывающий отвечает за то, чтобы не звать это каждый
## кадр от одной и той же причины (crash — через _crash_cd, взрыв — разовое событие).
## attacker — кто нанёс урон (Explosion.shooter у оружия), null по умолчанию —
## столкновение с рельефом само так и зовёт, вторым аргументом не задаваясь,
## и это верная семантика: смерть без чужого участия = самоубийство (см.
## destroyed(killer) и MatchManager).
func take_damage(amount: float, attacker: Node = null) -> void:
	if not _alive or amount <= 0.0:
		return
	# ship_strength (правило матча, GameRules) делит ВЕСЬ входящий урон — и от
	# столкновений, и от оружия: >1 делает корабли крепче (Options «Ship strength»
	# оригинала). Нейтрально при 1.0. maxf защищает от деления на 0 при кривой настройке.
	hull = maxf(hull - amount / maxf(GameRules.ship_strength, 0.01), 0.0)
	hull_changed.emit(hull, data.max_hull)
	if hull <= 0.0:
		_die(attacker)


func _die(killer: Node = null) -> void:
	_alive = false
	destroyed.emit(killer)
	_thrust.emitting = false
	# взрыв/обломки корабля — позже (notes/roadmap.md); пока просто убираем со сцены
	freeze = true
	visible = false


func respawn(at: Vector2) -> void:
	_alive = true
	freeze = false
	visible = true
	_crash_cd = 0.0
	equip_primary(primary_weapon)
	equip_secondary(secondary_weapon)
	aim_angle = 0.0
	_apply_aim_angle()
	hull = data.max_hull
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	global_position = at
	hull_changed.emit(hull, data.max_hull)


func is_alive() -> bool:
	return _alive
