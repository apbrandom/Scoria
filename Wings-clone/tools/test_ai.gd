## Проверка бота (AIInput) — он же измерительный прибор для боя, поэтому
## проверяется не «умный ли он», а свойства, без которых им нельзя мерить:
## воспроизводимость, живучесть, что бой реально происходит.
##
## Уровень здесь выкладывается РУКАМИ (плоская земля внизу, небо сверху), а не
## берётся у генератора: проверяемая ситуация должна быть одной и той же в
## каждом прогоне, а не выпасть случайным seed'ом. Тот же приём, что в
## test_live_sand.gd.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_ai.tscn
extends Node2D

const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
const DUMBFIRE := preload("res://data/weapons/dumbfire.tres")
const BOMB := preload("res://data/weapons/bomb.tres")
const PALETTE := preload("res://data/terrain/wings_classes.tres")
const AI_INPUT := preload("res://scripts/input/ai_input.gd")

const W := 1200
const H := 700
## Земля занимает нижнюю четверть — боту есть куда падать и обо что убиться.
const GROUND_Y := 520

var _pass := 0
var _fail := 0
var _terrain: Terrain


func _ready() -> void:
	print("=== Проверка бота AIInput (%s) ===" % DisplayServer.get_name())
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


func _build_terrain() -> void:
	if _terrain != null:
		_terrain.queue_free()
		await get_tree().physics_frame
	_terrain = Terrain.new()
	_terrain.palette = PALETTE
	_terrain.immediate_rebuild = false
	add_child(_terrain)
	var vis := Image.create(W, H, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0, 0, 0, 0))
	vis.fill_rect(Rect2i(0, GROUND_Y, W, H - GROUND_Y), Color(0.5, 0.3, 0.1, 1.0))
	_terrain.load_level(vis)
	_terrain.add_to_group("terrain")
	await get_tree().physics_frame


func _make_bot(at: Vector2, rng_seed: int) -> Ship:
	var s: Ship = SHIP_SCENE.instantiate()
	s.data = SHIP_DATA
	s.primary_weapon = DUMBFIRE
	s.secondary_weapon = BOMB
	s.position = at
	s.input = AI_INPUT.new(rng_seed)
	add_child(s)
	return s


func _wire(bots: Array[Ship]) -> void:
	for b in bots:
		b.input.setup(b, bots, _terrain)


func _projectile_count() -> int:
	var n := 0
	for c in get_children():
		if c is Projectile:
			n += 1
	return n


## Убрать корабли и всё, что они успели напустить. Снаряды освобождаются ВМЕСТЕ
## с кораблями, а не после: снаряд, переживший своего стрелка, — отдельный
## сценарий (он вскрыл настоящую хрупкость в projectile.gd, см. devlog §53), и
## тащить его во все подтесты значит зашумлять их чужой проблемой.
func _clear_scene(ships: Array[Ship]) -> void:
	for s in ships:
		s.queue_free()
	for c in get_children():
		if c is Projectile or c is Explosion:
			c.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame


func _run() -> void:
	GameRules.reset()
	await _test_survives()
	await _test_fights()
	await _test_deterministic()
	await _test_no_target()
	await _test_aim_math()
	await _test_fov()
	await _test_memory()
	GameRules.reset()


## Главное свойство для «потестировать бой»: бот не должен убиться о землю за
## первые же секунды, иначе мерить нечего.
func _test_survives() -> void:
	print("\n-- бот держится в воздухе --")
	await _build_terrain()
	# Нарочно низко и уже падая — положение, из которого без реакции он разобьётся.
	var bot := _make_bot(Vector2(300, GROUND_Y - 90), 1)
	bot.linear_velocity = Vector2(0, 120)
	_wire([bot] as Array[Ship])

	await _step(60 * 8)  # 8 секунд

	_check("жив через 8 секунд над землёй", bot.is_alive(),
		"прочность %.0f, y=%.0f (земля на %d)" % [bot.hull, bot.global_position.y, GROUND_Y])
	_check("не провалился под рельеф", bot.global_position.y < GROUND_Y,
		"y=%.0f" % bot.global_position.y)
	await _clear_scene([bot] as Array[Ship])


## Два бота друг против друга: стрельба должна начаться сама, а урон — дойти.
func _test_fights() -> void:
	print("\n-- два бота реально дерутся --")
	await _build_terrain()
	var a := _make_bot(Vector2(250, GROUND_Y - 260), 11)
	var b := _make_bot(Vector2(950, GROUND_Y - 260), 22)
	var bots := [a, b] as Array[Ship]
	_wire(bots)
	# Носом друг на друга с самого начала: оба на одной высоте, обзор ±45°
	# (devlog §55) от носа по умолчанию (aim_angle=0, "вверх") иначе не
	# гарантирует мгновенное обнаружение — тест про сам БОЙ, а не про то,
	# сколько секунд уйдёт на первичное обнаружение с произвольного старта.
	a.aim_angle = AI_INPUT._angle_of((b.global_position - a.global_position).normalized())
	b.aim_angle = AI_INPUT._angle_of((a.global_position - b.global_position).normalized())

	var hull_a0 := a.hull
	var hull_b0 := b.hull
	var shots := 0
	var frames := 0
	while frames < 60 * 20 and a.is_alive() and b.is_alive():
		await get_tree().physics_frame
		frames += 1
		shots = maxi(shots, _projectile_count())

	_check("боты стреляют (снаряды появились)", shots > 0, "одновременно в воздухе: %d" % shots)
	var damaged: bool = a.hull < hull_a0 or b.hull < hull_b0 or not a.is_alive() or not b.is_alive()
	_check("урон реально доходит до противника", damaged,
		"прочность %.0f/%.0f из %.0f, кадров %d" % [a.hull, b.hull, hull_a0, frames])
	# Не «оба обязаны выжить» и не «обязан быть убитый»: и то и другое — про
	# баланс, который здесь не проверяется. Проверяем, что бой ИДЁТ.
	_check("бой не выродился в падение обоих на землю",
		a.global_position.y < GROUND_Y and b.global_position.y < GROUND_Y,
		"y: %.0f и %.0f" % [a.global_position.y, b.global_position.y])

	await _clear_scene([a, b] as Array[Ship])


## Без этого бот бесполезен как регрессия: одинаковый бой обязан повторяться.
func _test_deterministic() -> void:
	print("\n-- тот же seed даёт тот же бой --")
	var runs := []
	for _r in 2:
		await _build_terrain()
		var a := _make_bot(Vector2(300, GROUND_Y - 240), 7)
		var b := _make_bot(Vector2(900, GROUND_Y - 240), 8)
		_wire([a, b] as Array[Ship])
		await _step(60 * 5)
		runs.append({
			"a": a.global_position, "b": b.global_position,
			"aa": a.aim_angle, "ba": b.aim_angle,
			"ah": a.hull, "bh": b.hull,
		})
		await _clear_scene([a, b] as Array[Ship])

	var r0: Dictionary = runs[0]
	var r1: Dictionary = runs[1]

	# ИСХОД боя обязан совпасть ТОЧНО. Урон дискретен (попал/не попал), и если бы
	# бот принимал разные решения, прочность разошлась бы сразу и заметно —
	# это самая сильная проверка воспроизводимости, какая здесь возможна.
	_check("исход боя совпал точно (прочность обоих)",
		r0["ah"] == r1["ah"] and r0["bh"] == r1["bh"],
		"%.1f/%.1f против %.1f/%.1f" % [r0["ah"], r0["bh"], r1["ah"], r1["bh"]])

	# Непрерывные величины — с допуском, и это не послабление ради зелёного
	# теста, а измеренный факт (devlog §53): сама физика Godot в одном процессе
	# даёт одно из ДВУХ значений, различающихся на ~0.004 px, в зависимости от
	# того, что происходило на сцене ДО прогона. Бот детерминирован как функция
	# (seeded RNG + фиксированный delta), но его ВХОД — позиции от физики — уже
	# не бит-в-бит, и дрожь просачивается в прицел, который считается от позиции.
	# Допуски нарочно крошечные: случайный бот разошёлся бы на метры и радианы,
	# а не на сотые пикселя, и проверка это поймает.
	const POS_TOLERANCE := 0.05
	const ANGLE_TOLERANCE := 0.001
	_check("позиции совпали в пределах %.2f px" % POS_TOLERANCE,
		r0["a"].distance_to(r1["a"]) < POS_TOLERANCE
			and r0["b"].distance_to(r1["b"]) < POS_TOLERANCE,
		"расхождение %.4f px и %.4f px" % [
			r0["a"].distance_to(r1["a"]), r0["b"].distance_to(r1["b"])])
	_check("углы прицела совпали в пределах %.4f рад" % ANGLE_TOLERANCE,
		absf(r0["aa"] - r1["aa"]) < ANGLE_TOLERANCE
			and absf(r0["ba"] - r1["ba"]) < ANGLE_TOLERANCE,
		"расхождение %.8f и %.8f рад" % [
			absf(r0["aa"] - r1["aa"]), absf(r0["ba"] - r1["ba"])])


## Соло-матч и «все противники мертвы» — бот без цели не должен ни падать
## камнем, ни палить в пустоту, а по прямой просьбе заказчика (devlog §55) —
## реально патрулировать: облетать карту, а не висеть статуей.
func _test_no_target() -> void:
	print("\n-- бот без противника --")
	await _build_terrain()
	var lone := _make_bot(Vector2(600, GROUND_Y - 200), 3)
	_wire([lone] as Array[Ship])
	var x0 := lone.global_position.x

	await _step(60 * 6)

	_check("одинокий бот жив", lone.is_alive(), "y=%.0f" % lone.global_position.y)
	_check("не стреляет в пустоту", _projectile_count() == 0,
		"снарядов: %d" % _projectile_count())
	# Патрулирование, а не глушняк на месте: за 6 секунд без цели бот обязан
	# заметно сместиться по X (не микро-дрожь от физики, а целенаправленный полёт).
	_check("патрулирует — сместился по X, а не стоит истуканом",
		absf(lone.global_position.x - x0) > 100.0,
		"было x=%.0f, стало x=%.0f" % [x0, lone.global_position.x])
	await _clear_scene([lone] as Array[Ship])


## Обзор ~90° (devlog §55, по прямой просьбе заказчика): цель точно ЗА спиной
## (вне конуса), хоть и вплотную по расстоянию и без препятствий, не должна
## быть видна — бот не имеет права "знать" её магически.
func _test_fov() -> void:
	print("\n-- обзор: не видит цель за спиной --")
	await _build_terrain()
	var watcher := _make_bot(Vector2(600, 200), 41)
	var behind := _make_bot(Vector2(600, 260), 42)  # строго ПОД watcher
	_wire([watcher, behind] as Array[Ship])
	watcher.aim_angle = 0.0  # нос строго вверх — цель снизу-сзади, вне конуса
	await get_tree().physics_frame

	_check("цель за спиной вне конуса обзора (_can_see -> false)",
		not watcher.input._can_see(behind))

	# Цель ПЕРЕД носом, тот же угол от вертикали — обязана быть видна.
	var ahead := _make_bot(Vector2(600, 140), 43)  # строго НАД watcher
	_wire([watcher, ahead] as Array[Ship])
	await get_tree().physics_frame
	_check("цель перед носом видна (_can_see -> true)",
		watcher.input._can_see(ahead))

	await _clear_scene([watcher, behind, ahead] as Array[Ship])


## Память (devlog §55): цель была видна, потом пропала из конуса — бот ещё
## какое-то время "помнит"/предполагает её позицию (не бросает цель мгновенно
## при первом же кадре без прямой видимости), но после settings.memory_time
## признаёт её потерянной.
func _test_memory() -> void:
	print("\n-- память о цели: не бросает мгновенно, но и не помнит вечно --")
	await _build_terrain()
	var bot := _make_bot(Vector2(600, 200), 51)
	var enemy := _make_bot(Vector2(800, 200), 52)
	_wire([bot, enemy] as Array[Ship])
	bot.aim_angle = AI_INPUT._angle_of((enemy.global_position - bot.global_position).normalized())
	enemy.freeze = true
	await get_tree().physics_frame

	var ai := bot.input as AIInput
	ai._update_memory(0.0)
	_check("цель видна и запомнена (age=0)",
		ai._memory.has(enemy) and ai._memory[enemy]["age"] == 0.0)

	# Разворачиваем нос ровно на 180° — цель гарантированно выходит из
	# конуса ±45°, но должна остаться в памяти, пока age <= memory_time.
	bot.aim_angle = wrapf(bot.aim_angle + PI, -PI, PI)
	var half_memory := ai.settings.memory_time * 0.5
	ai._update_memory(half_memory)
	_check("цель вне конуса, но ещё в пределах memory_time — не забыта",
		ai._memory.has(enemy) and ai._memory[enemy]["age"] == half_memory,
		"age=%.2f" % ai._memory.get(enemy, {}).get("age", -1.0))

	ai._update_memory(ai.settings.memory_time)  # суммарно заметно больше memory_time
	var mem: Dictionary = ai._memory.get(enemy, {})
	var expired: bool = mem.is_empty() or float(mem["age"]) > ai.settings.memory_time
	_check("а вот теперь — по прошествии memory_time — цель признана потерянной",
		expired, "age=%.2f, memory_time=%.2f" % [
			float(mem.get("age", -1.0)), ai.settings.memory_time])

	await _clear_scene([bot, enemy] as Array[Ship])


## Прицельная математика отдельно от полёта: неподвижная цель прямо по
## горизонтали, оружие без гравитации — правильный ответ известен заранее.
func _test_aim_math() -> void:
	print("\n-- упреждение считается верно --")
	await _build_terrain()
	var shooter := _make_bot(Vector2(300, 200), 5)
	var target := _make_bot(Vector2(800, 200), 6)
	var bots := [shooter, target] as Array[Ship]
	_wire(bots)
	# Цель замораживаем: проверяем формулу, а не её поведение.
	target.freeze = true
	await get_tree().physics_frame

	var dir: Vector2 = shooter.input._solve_aim(target, DUMBFIRE)
	_check("решение для неподвижной цели найдено", dir != Vector2.ZERO)
	# Цель строго справа и неподвижна, пулемёт без гравитации, стрелок ещё не
	# успел разогнаться — нос обязан смотреть вправо (aim_angle = +PI/2).
	_check("для цели справа нос смотрит вправо", dir.x > 0.9,
		"направление %s" % dir)
	_check("угол переводится в aim_angle корабля правильно",
		is_equal_approx(Vector2.UP.rotated(AI_INPUT._angle_of(dir)).angle(), dir.angle()),
		"_angle_of дал %.3f" % AI_INPUT._angle_of(dir))

	# У бомбы гравитация не ноль — прицел обязан уйти ВЫШЕ прямой линии,
	# иначе она упадёт по дороге.
	var dir_bomb: Vector2 = shooter.input._solve_aim(target, BOMB)
	_check("бомба целится выше прямой линии на цель", dir_bomb.y < dir.y - 0.01,
		"пулемёт y=%.3f, бомба y=%.3f (y растёт вниз)" % [dir.y, dir_bomb.y])

	await _clear_scene([shooter, target] as Array[Ship])
