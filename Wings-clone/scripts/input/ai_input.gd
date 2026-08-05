## Бот: третий источник интентов рядом с LocalInput (клавиатура) и RemoteInput
## (сеть). Шов был заложен с самого начала — Ship не знает, кто им управляет
## (ship.gd:56, architecture.md §2.3), поэтому боту не нужно ни строчки внутри
## корабля.
##
## ЗАЧЕМ он появился: заказчик попросил ботов, чтобы «тестировать, как проходит
## сражение». Это в первую очередь измерительный прибор, и требования к нему
## жёстче, чем к игровому противнику:
##   - детерминированный: тот же seed даёт тот же бой (иначе как регрессия он
##     бесполезен). Отсюда собственный RandomNumberGenerator, а не глобальный
##     randf(), и решения по накопленному фиксированному delta физ-кадра;
##   - живёт headless: ни одного обращения к синглтону Input, к экрану и к узлам
##     сцены сверх переданных ему явно.
##
## ПОЧЕМУ НЕ дерево поведения (LimboAI/Beehave) и не навигация Godot — разобрано
## в devlog §53. Коротко: тяжёлое здесь не «какую ветку выбрать», а управление —
## тяга и прицел в этой игре ЖЁСТКО связаны одним углом (ship.gd:193-197), нос
## нельзя направить на врага и одновременно держаться в воздухе. Дерево село бы
## поверх слоя управления, который всё равно писать самому.
class_name AIInput
extends ShipInput

const DEFAULT_SETTINGS := preload("res://data/ai/default.tres")

## Числа поведения (data/ai/*.tres). Разные файлы = разные уровни сложности при
## одном и том же коде.
var settings: AISettings = DEFAULT_SETTINGS

var _ship: Ship
var _enemies: Array[Ship] = []
var _terrain: Terrain
var _rng := RandomNumberGenerator.new()

## Гравитация снаряда берётся из тех же ProjectSettings, что и физика тел — если
## дизайнер поменяет её в проекте, упреждение бота поедет вместе с баллистикой,
## а не начнёт врать (жёсткая константа здесь была бы тихим рассинхроном).
var _world_gravity := 0.0

var _since_decision := 0.0
## Режим «набираю высоту». Поле, а не локальная переменная: у него ГИСТЕРЕЗИС
## (включается ниже danger_altitude, выключается только выше safe_altitude),
## иначе бот дребезжал бы тягой на самой границе.
var _climbing := false
## Куда сейчас доворачиваем нос. Пересчитывается раз в decision_interval, между
## пересчётами бот доворачивает на уже выбранный угол — это и «время реакции»,
## и защита от дёрганого носа.
var _desired_angle := 0.0
var _want_primary := false
var _want_secondary := false
var _want_thrust := false


## rng_seed — из seed матча (Level берёт GameRules.level_seed_used), чтобы бой
## воспроизводился целиком вместе с уровнем.
func _init(rng_seed: int = 0) -> void:
	_rng.seed = rng_seed
	_world_gravity = float(ProjectSettings.get_setting("physics/2d/default_gravity", 400.0))


## Кого ведём, против кого и по какому рельефу. Отдельно от _init, потому что
## список кораблей известен только после того, как заспавнены ВСЕ (см. Level).
func setup(ship: Ship, all_ships: Array[Ship], terrain: Terrain,
		ai_settings: AISettings = null) -> void:
	_ship = ship
	_terrain = terrain
	if ai_settings != null:
		settings = ai_settings
	_enemies.clear()
	for s in all_ships:
		if s != ship:
			_enemies.append(s)


func poll(delta: float) -> void:
	if _ship == null or not _ship.is_alive():
		thrust = false
		turn = 0.0
		fire_primary = false
		fire_secondary = false
		return

	_since_decision += delta
	if _since_decision >= settings.decision_interval:
		_since_decision = 0.0
		_decide()

	# Доворот идёт КАЖДЫЙ кадр, а решение — раз в интервал: иначе нос двигался
	# бы рывками по 80 мс и бот не мог бы поймать цель в узкий конус огня.
	turn = _turn_toward(_desired_angle, delta)
	thrust = _want_thrust
	fire_primary = _want_primary
	fire_secondary = _want_secondary


# ------------------------------------------------------------------- решение

func _decide() -> void:
	var pos := _ship.global_position
	var ground := _ground_distance(pos)

	# Земля в игре с гравитацией убивает чаще противника, поэтому высота
	# проверяется ПЕРВОЙ и перебивает любые боевые намерения.
	var falling := _ship.linear_velocity.y > 1.0
	var time_to_ground := ground / _ship.linear_velocity.y if falling else INF
	if ground < settings.danger_altitude or time_to_ground < settings.impact_lookahead:
		_climbing = true
	elif ground > settings.safe_altitude:
		_climbing = false

	var target := _pick_target()
	if target == null:
		# Без цели бот не выключается, а держит высоту: иначе одинокий корабль
		# (соло-матч, все противники мертвы) просто упал бы камнем.
		_desired_angle = 0.0
		_want_primary = false
		_want_secondary = false
		_want_thrust = _climbing
		return

	if _climbing:
		# Нос строго вверх: тяга направлена туда же, куда смотрит нос.
		_desired_angle = 0.0
		_want_thrust = true
		_want_primary = false
		_want_secondary = false
		return

	var to_target := target.global_position - pos
	var dist := to_target.length()
	var has_los := _has_line_of_sight(pos, target.global_position)

	# Стрелять не в кого, пока противник за холмом или вне дальности — надо
	# СБЛИЖАТЬСЯ. Без этого режима два бота просто висели каждый на своей
	# половине карты и за 45 секунд не делали ни выстрела (замер до правки:
	# tools/diag_arena.gd, 3 боя из 5 вообще без стрельбы, devlog §53).
	if dist > settings.fire_range or not has_los:
		_approach(target, ground)
		return

	var aim_dir := _solve_aim(target, _ship.primary_weapon)
	if aim_dir == Vector2.ZERO:
		_approach(target, ground)
		return

	_desired_angle = _angle_of(aim_dir) + _rng.randf_range(
		-settings.aim_jitter, settings.aim_jitter)

	var err: float = absf(wrapf(_desired_angle - _ship.aim_angle, -PI, PI))
	var in_cone := err < settings.fire_cone

	_want_primary = in_cone
	# Бомба падает — пускать её во врага ВЫШЕ себя бессмысленно (y растёт вниз).
	_want_secondary = in_cone and to_target.y > settings.bomb_min_height_gain

	# Тяга в бою — только когда нос и так задран вверх: иначе она разгоняла бы
	# бота в землю ровно в тот момент, когда он целится по горизонтали.
	var nose_up := Vector2.UP.rotated(_ship.aim_angle).dot(Vector2.UP) > 0.3
	_want_thrust = ground < settings.safe_altitude and nose_up


## Лететь к противнику. Тяга и нос — один вектор (ship.gd:197), поэтому
## «двигаться вбок» здесь means наклониться и жечь: ровно так же играет человек.
func _approach(target: Ship, ground: float) -> void:
	var dx := target.global_position.x - _ship.global_position.x
	var lean: float = settings.approach_lean * signf(dx)

	# Уже разогнались в нужную сторону — выпрямляем нос. Тяга при этом никуда
	# не девается, просто уходит в высоту, а не в дальнейший разгон: иначе бот
	# проскакивает мимо цели и потом долго тормозит обратно.
	var vx := _ship.linear_velocity.x
	if absf(vx) > settings.approach_speed and signf(vx) == signf(dx):
		lean = 0.0
	# Низко — не до манёвров вбок, сначала высота (наклон крадёт подъёмную силу).
	if ground < settings.danger_altitude * 1.5:
		lean *= 0.35

	_desired_angle = lean
	_want_thrust = true
	_want_primary = false
	_want_secondary = false


func _pick_target() -> Ship:
	var best: Ship = null
	var best_d := INF
	for e in _enemies:
		if not is_instance_valid(e) or not e.is_alive():
			continue
		var d := _ship.global_position.distance_squared_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best


# ------------------------------------------------------------------ стрельба

## Куда направить нос, чтобы снаряд встретился с целью. Одна формула на оба
## оружия: у пулемёта gravity_scale = 0, и баллистическая часть просто
## обнуляется, превращая решение в обычное упреждение по прямой.
##
## Метод — последовательное уточнение времени полёта: точное решение с
## гравитацией и подвижной целью это уравнение 4-й степени, а здесь хватает
## нескольких итераций (settings.lead_iterations) — цель всё равно маневрирует,
## и лишняя точность уходит в шум.
func _solve_aim(target: Ship, weapon: WeaponData) -> Vector2:
	if weapon == null or weapon.muzzle_speed <= 0.0:
		return Vector2.ZERO

	var from := _ship.global_position
	# Снаряд наследует часть скорости корабля (WeaponData.velocity_inherit) —
	# без этого бот, стреляя на ходу, систематически мажет в сторону движения.
	var inherit := _ship.linear_velocity * weapon.velocity_inherit
	var g := Vector2(0.0, _world_gravity * weapon.gravity_scale)

	var t := maxf(from.distance_to(target.global_position) / weapon.muzzle_speed, 0.001)
	var v_muzzle := Vector2.ZERO
	for _i in settings.lead_iterations:
		var predicted := target.global_position + target.linear_velocity * t
		# Скорость, с которой снаряд обязан стартовать, чтобы за t попасть в
		# predicted с учётом падения.
		v_muzzle = (predicted - from) / t - 0.5 * g * t - inherit
		var speed := v_muzzle.length()
		if speed < 0.001:
			return Vector2.ZERO
		# Дуло выдаёт ФИКСИРОВАННУЮ muzzle_speed, поэтому подгоняем не скорость,
		# а время полёта: нужно быстрее, чем можем — значит лететь дольше.
		t *= speed / weapon.muzzle_speed
		if t > weapon.lifetime:
			return Vector2.ZERO  # не долетит и самоуничтожится
	return v_muzzle.normalized()


## Не тратить снаряды в стену. Пулемёт летит по прямой и рельеф не роет
## (dumbfire.tres: terrain_power = 0), так что выстрел в холм — чистая потеря.
func _has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	if _terrain == null:
		return true
	var delta := to - from
	var dist := delta.length()
	if dist < 1.0:
		return true
	var step: float = maxf(settings.ground_probe_step, 1.0)
	var steps := int(dist / step)
	var dir := delta / dist
	# Первую клетку пропускаем: дуло стоит вплотную к собственному кораблю.
	for i in range(1, steps):
		var p := from + dir * (i * step)
		if _terrain.is_solid_at(Vector2i(int(p.x), int(p.y))):
			return false
	return true


# ------------------------------------------------------------------ выживание

## Сколько пикселей свободного пространства под кораблём. Замер по карте классов
## рельефа, а не физическим лучом: карта — чистые данные, одинаковые на хосте и
## клиенте и доступные без шага физики (важно для headless-тестов), тогда как
## intersect_ray зависит от состояния физического мира в этот конкретный кадр.
func _ground_distance(from: Vector2) -> float:
	if _terrain == null:
		return settings.ground_probe_depth
	var step: float = maxf(settings.ground_probe_step, 1.0)
	var steps := int(settings.ground_probe_depth / step)
	var x := int(from.x)
	for i in range(1, steps + 1):
		var y := int(from.y + i * step)
		if y >= _terrain.size.y:
			# Дно уровня — такая же смерть, как рельеф.
			return float(y) - from.y
		if _terrain.is_solid_at(Vector2i(x, y)):
			return float(y) - from.y
	return settings.ground_probe_depth


# -------------------------------------------------------------------- поворот

## Угол aim_angle, при котором нос смотрит в сторону dir. Обратное к
## Vector2.UP.rotated(aim_angle), которым пользуется сам корабль.
static func _angle_of(dir: Vector2) -> float:
	return atan2(dir.x, -dir.y)


## Пропорциональный доворот: берём ровно столько, сколько успеем провернуть за
## кадр. Полный руль до упора давал бы перелёт мимо цели и раскачку.
func _turn_toward(desired: float, delta: float) -> float:
	# Кратчайший знаковый доворот. wrapf, а не angle_difference — та же
	# величина, но этой функцией проект уже пользуется (ship.gd:193).
	var err := wrapf(desired - _ship.aim_angle, -PI, PI)
	if absf(err) < settings.turn_deadzone:
		return 0.0
	var per_frame := _ship.data.turn_rate * delta
	if per_frame <= 0.0:
		return 0.0
	return clampf(err / per_frame, -1.0, 1.0)
