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

## Что бот ПОМНИТ о каждом противнике: Ship -> {"pos", "vel", "age"}. pos/vel —
## снимок на момент последнего кадра, когда цель реально видели (в конусе
## обзора, в пределах vision_range, без препятствия); age — сколько секунд
## прошло с тех пор (0.0 = видим ПРЯМО СЕЙЧАС, это ровно и только что
## присвоенный литерал, а не накопленная сумма — сравнение age == 0.0 поэтому
## безопасно). Без этой памяти "не вижу" мгновенно превращалось бы в "забыл",
## и бот терял бы цель, стоило ей на кадр скрыться за бугром рельефа.
var _memory: Dictionary = {}
## Точка патруля (только X — высотой ведает гистерезис climbing выше, как и
## раньше; см. _patrol). _patrol_point_set отдельным флагом, потому что
## Vector2 не бывает null.
var _patrol_point_x := 0.0
var _patrol_point_set := false
var _since_patrol_point := 0.0
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
		var elapsed := _since_decision
		_since_decision = 0.0
		_decide(elapsed)

	# Доворот идёт КАЖДЫЙ кадр, а решение — раз в интервал: иначе нос двигался
	# бы рывками по 80 мс и бот не мог бы поймать цель в узкий конус огня.
	turn = _turn_toward(_desired_angle, delta)
	thrust = _want_thrust
	fire_primary = _want_primary
	fire_secondary = _want_secondary


# ------------------------------------------------------------------- решение

func _decide(elapsed: float) -> void:
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

	_update_memory(elapsed)
	var target := _pick_target()

	if target == null:
		if _climbing:
			_desired_angle = 0.0
			_want_thrust = true
			_want_primary = false
			_want_secondary = false
		else:
			# Ни видимой, ни ещё не забытой цели — не висеть истуканом, а
			# облетать карту и искать (devlog §55, по прямой просьбе заказчика).
			_patrol(pos, ground, elapsed)
		return

	if _climbing:
		# Нос строго вверх: тяга направлена туда же, куда смотрит нос.
		_desired_angle = 0.0
		_want_thrust = true
		_want_primary = false
		_want_secondary = false
		return

	var mem: Dictionary = _memory[target]
	# age == 0.0 — точный литерал, присвоенный в _update_memory этим же кадром
	# принятия решения, не накопленная сумма, поэтому сравнение на равенство
	# безопасно (см. комментарий у объявления _memory).
	var seen_now: bool = mem["age"] == 0.0
	var known_pos: Vector2 = mem["pos"] + mem["vel"] * mem["age"]
	var to_target := known_pos - pos
	var dist := to_target.length()

	# Стрелять не в кого, пока противник не виден ПРЯМО СЕЙЧАС (за холмом, вне
	# конуса обзора, потерян из памяти) или вне дальности — надо СБЛИЖАТЬСЯ с
	# последним известным/предполагаемым местом. Без этого режима два бота
	# просто висели каждый на своей половине карты и за 45 секунд не делали ни
	# выстрела (замер до правки: tools/diag_arena.gd, 3 боя из 5 вообще без
	# стрельбы, devlog §53).
	if not seen_now or dist > settings.fire_range:
		_approach(known_pos, ground)
		return

	var aim_dir := _solve_aim(target, _ship.primary_weapon)
	if aim_dir == Vector2.ZERO:
		_approach(known_pos, ground)
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


## Лететь к точке (последнее известное/предполагаемое место цели, а не её
## живая позиция — см. _decide). Тяга и нос — один вектор (ship.gd:197),
## поэтому «двигаться вбок» здесь means наклониться и жечь: ровно так же
## играет человек.
func _approach(target_pos: Vector2, ground: float) -> void:
	var dx := target_pos.x - _ship.global_position.x
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


## Ни видимой, ни ещё не забытой цели нет — методично облетать карту точками
## по X (высота по-прежнему только под гистерезисом climbing выше, отдельная
## забота), периодически выбирая новую, будто высматривая противника, а не
## паря на месте статуей.
func _patrol(pos: Vector2, ground: float, elapsed: float) -> void:
	_since_patrol_point += elapsed
	if not _patrol_point_set or absf(pos.x - _patrol_point_x) < settings.patrol_arrive_radius \
			or _since_patrol_point >= settings.patrol_change_interval:
		_pick_patrol_point(pos)

	var dx := _patrol_point_x - pos.x
	var lean: float = settings.approach_lean * signf(dx)
	if ground < settings.danger_altitude * 1.5:
		lean *= 0.35

	_desired_angle = lean
	# Та же граница, что отпускает climbing (safe_altitude) — не "всегда тяга":
	# нос при патруле почти вертикален (approach_lean — это наклон ОТ
	# вертикали, не полный разворот вбок), поэтому непрерывная тяга почти
	# целиком уходит вверх и без гейта бот улетел бы за пределы уровня, а не
	# летал по нему кругами. С гейтом получается та же гистерезисная
	# "подскакивает — падает", что раньше держала высоту без цели вообще, но
	# теперь ещё и со сносом в сторону точки патруля при каждом всплытии.
	_want_thrust = ground < settings.safe_altitude
	_want_primary = false
	_want_secondary = false


func _pick_patrol_point(pos: Vector2) -> void:
	var margin := 80.0
	# _terrain почти всегда есть (Level его передаёт в setup); запасной вариант
	# на случай синтетического теста без него — не уезжать в бесконечность.
	var w := float(_terrain.size.x) if _terrain != null else pos.x + margin
	_patrol_point_x = _rng.randf_range(margin, maxf(w - margin, margin))
	_patrol_point_set = true
	_since_patrol_point = 0.0


## Обновляет "память" о каждом противнике: кого видно ПРЯМО СЕЙЧАС — снимок
## его позиции/скорости и age=0; кого не видно, но ещё помним — просто стареет.
## Мёртвых/освобождённых — забываем совсем, а не оставляем стухший снимок.
func _update_memory(elapsed: float) -> void:
	for e in _enemies:
		if not is_instance_valid(e) or not e.is_alive():
			_memory.erase(e)
			continue
		if _can_see(e):
			_memory[e] = {"pos": e.global_position, "vel": e.linear_velocity, "age": 0.0}
		elif _memory.has(e):
			_memory[e]["age"] += elapsed


## Видит ли бот ПРЯМО СЕЙЧАС этого противника: в пределах vision_range, внутри
## конуса обзора fov_deg вокруг текущего носа (aim_angle — это и есть "куда
## смотрит" в этой игре, тяга и прицел жёстко связаны одним углом,
## ship.gd:193-197) и без препятствия между.
func _can_see(target: Ship) -> bool:
	var pos := _ship.global_position
	var to_target := target.global_position - pos
	var dist := to_target.length()
	if dist < 0.001:
		return true
	if dist > settings.vision_range:
		return false
	var nose := Vector2.UP.rotated(_ship.aim_angle)
	var half_fov := deg_to_rad(settings.fov_deg) * 0.5
	if nose.dot(to_target / dist) < cos(half_fov):
		return false
	return _has_line_of_sight(pos, target.global_position)


## Ближайшая цель среди тех, кого видно ПРЯМО СЕЙЧАС или ещё не забыли
## (age <= memory_time) — по последней известной/предполагаемой позиции, не по
## живой (её бот вслепую знать не может, см. _decide). Порядок — _enemies
## (Array, детерминированный), а не ключи _memory: устойчивость к возможной
## смене порядка обхода Dictionary важнее для воспроизводимости боя.
func _pick_target() -> Ship:
	var best: Ship = null
	var best_d := INF
	for e in _enemies:
		var mem: Dictionary = _memory.get(e, {})
		if mem.is_empty() or float(mem["age"]) > settings.memory_time:
			continue
		var known_pos: Vector2 = mem["pos"] + mem["vel"] * float(mem["age"])
		var d := _ship.global_position.distance_squared_to(known_pos)
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
