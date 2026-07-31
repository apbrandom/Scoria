## Headless-проверка баз (BaseZone + BaseData): стыковка по скорости, ремонт,
## выбор оружия кнопками поворота, гейт поворота на базе.
##
## Рельеф здесь не нужен: BaseZone работает по Area2D, а Ship._integrate_forces
## без узла в группе "terrain" сам выходит из обработки удара — столкновений
## в этом тесте нет вовсе.
##
## Гравитацию глушим на время теста (GameRules.gravity_scale = 0): скорость
## корабля здесь — предмет проверки (порог стыковки), и падение добавляло бы к
## ней ~6.7 px/с каждый кадр, делая результат зависимым от числа шагов.
##
## Запуск: godot --headless --path Wings-clone res://tools/test_bases.tscn
extends Node2D

const SHIP_SCENE := preload("res://scenes/ship/ship.tscn")
const SHIP_DATA := preload("res://data/ships/normal.tres")
## preload по пути, не по class_name — свежий class_name может не резолвиться
## в headless-запуске, пока не пересобран global_script_class_cache.cfg
## (та же грабля, что у MATCH_MANAGER_SCRIPT в level.gd).
const BASE_ZONE_SCRIPT := preload("res://scripts/level/base_zone.gd")
const COMMON_BASE := preload("res://data/bases/common.tres")
const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const GEN_RULES := preload("res://data/level/default_gen.tres")
## Размер боевого уровня (level.gd::SAND_LEVEL_SIZE) — размещение баз проверяем
## на том же поле, на котором в него будут играть, а не на удобном маленьком.
const LEVEL_SIZE := Vector2i(2700, 1350)

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== Проверка баз (%s) ===" % DisplayServer.get_name())
	GameRules.reset()
	GameRules.gravity_scale = 0.0
	await get_tree().physics_frame

	await _run()

	GameRules.reset()
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


func _make_ship(at: Vector2) -> Ship:
	var s: Ship = SHIP_SCENE.instantiate()
	s.data = SHIP_DATA
	s.input = ShipInput.new()
	add_child(s)
	s.global_position = at
	s.linear_velocity = Vector2.ZERO
	return s


func _make_base(at: Vector2, data: BaseData) -> BaseZone:
	var b: BaseZone = BASE_ZONE_SCRIPT.new()
	b.data = data
	add_child(b)
	b.global_position = at
	return b


## Свой арсенал вместо common.tres: тест не должен краснеть от того, что
## дизайнер поменял набор оружия на базе — это настройка, а не поведение.
func _make_test_base_data(weapons: Array[WeaponData]) -> BaseData:
	var d := BaseData.new()
	d.zone_size = Vector2(120, 60)
	d.dock_speed_threshold = 40.0
	d.repair_rate = 25.0
	d.turn_press_threshold = 0.5
	d.weapons = weapons
	return d


func _make_weapon(name_: String, selectable: bool) -> WeaponData:
	var w := WeaponData.new()
	w.display_name = name_
	w.selectable = selectable
	return w


func _run() -> void:
	await _test_docking()
	await _test_repair()
	await _test_weapon_select()
	await _test_turn_gate()
	_test_placement()
	await _test_win_condition()


# ------------------------------------------------------------------ стыковка

func _test_docking() -> void:
	print("\n-- стыковка --")
	var base := _make_base(Vector2(500, 500), _make_test_base_data([]))
	var ship := _make_ship(Vector2(500, 500))
	await _step(2)

	_check("медленный корабль в зоне пристыкован", ship.is_docked(),
		"скорость=%.1f" % ship.linear_velocity.length())

	# Быстрее порога (40 px/с), но всё ещё внутри зоны.
	ship.linear_velocity = Vector2(200, 0)
	ship.global_position = Vector2(500, 500)
	await _step(1)
	_check("быстрый корабль в зоне НЕ пристыкован", not ship.is_docked(),
		"скорость=%.1f" % ship.linear_velocity.length())

	# Возврат в покой — стыковка восстанавливается (стыковка это состояние,
	# а не разовое событие входа).
	ship.linear_velocity = Vector2.ZERO
	ship.global_position = Vector2(500, 500)
	await _step(2)
	_check("после остановки внутри зоны стыковка вернулась", ship.is_docked())

	# Улетел далеко за пределы зоны.
	ship.global_position = Vector2(2000, 2000)
	ship.linear_velocity = Vector2.ZERO
	await _step(2)
	_check("вылет из зоны снимает стыковку", not ship.is_docked())

	# Труп на базе не стыкуется.
	ship.global_position = Vector2(500, 500)
	await _step(2)
	_check("живой снова пристыкован (контроль перед проверкой трупа)", ship.is_docked())
	ship.take_damage(99999.0)
	await _step(2)
	_check("мёртвый корабль на базе не пристыкован",
		not ship.is_alive() and not ship.is_docked())

	ship.queue_free()
	base.queue_free()
	await _step(1)


# -------------------------------------------------------------------- ремонт

func _test_repair() -> void:
	print("\n-- ремонт --")
	var ship := _make_ship(Vector2(100, 100))
	await _step(1)

	var emits := [0]
	ship.hull_changed.connect(func(_h, _m): emits[0] += 1)

	ship.repair(10.0)
	_check("repair на полной прочности не меняет hull",
		is_equal_approx(ship.hull, SHIP_DATA.max_hull), "hull=%.1f" % ship.hull)
	_check("repair на полной прочности НЕ шлёт hull_changed", emits[0] == 0,
		"эмитов=%d" % emits[0])

	ship.take_damage(50.0)
	var after_damage := ship.hull
	emits[0] = 0
	ship.repair(20.0)
	_check("repair поднимает прочность",
		is_equal_approx(ship.hull, after_damage + 20.0), "hull=%.1f" % ship.hull)
	_check("repair шлёт hull_changed при реальном изменении", emits[0] == 1,
		"эмитов=%d" % emits[0])

	ship.repair(9999.0)
	_check("repair зажимается max_hull",
		is_equal_approx(ship.hull, SHIP_DATA.max_hull), "hull=%.1f" % ship.hull)

	ship.take_damage(99999.0)
	var dead_hull := ship.hull
	ship.repair(50.0)
	_check("мёртвый корабль не чинится", is_equal_approx(ship.hull, dead_hull),
		"hull=%.1f" % ship.hull)
	ship.queue_free()
	await _step(1)

	# Ремонт на базе идёт по времени со скоростью repair_rate.
	var data := _make_test_base_data([])
	var base := _make_base(Vector2(500, 500), data)
	var s2 := _make_ship(Vector2(500, 500))
	await _step(2)
	s2.take_damage(60.0)
	var start_hull := s2.hull
	var frames := 30
	await _step(frames)
	var grown := s2.hull - start_hull
	var expect := data.repair_rate * frames / Engine.physics_ticks_per_second
	_check("побитый корабль на базе чинится со скоростью repair_rate",
		absf(grown - expect) <= expect * 0.35 + 0.5,
		"выросло на %.1f, ожидалось ~%.1f за %d кадров" % [grown, expect, frames])

	s2.queue_free()
	base.queue_free()
	await _step(1)


# ------------------------------------------------------------ выбор оружия

func _test_weapon_select() -> void:
	print("\n-- выбор оружия --")
	var w1 := _make_weapon("первое", true)
	var w2 := _make_weapon("второе", true)
	var w_hidden := _make_weapon("недоступное", false)
	var data := _make_test_base_data([w1, w_hidden, w2])
	var base := _make_base(Vector2(500, 500), data)
	var ship := _make_ship(Vector2(500, 500))
	ship.equip_secondary(w1)
	await _step(2)
	_check("корабль пристыкован (контроль перед выбором оружия)", ship.is_docked())

	# Нажатие вправо — следующее по списку.
	ship.input.turn = 1.0
	await _step(1)
	_check("нажатие вправо переключает на следующее оружие",
		ship.secondary_weapon == w2, "оружие=%s" % ship.secondary_weapon.display_name)

	# Удержание не листает дальше — нужен именно фронт.
	await _step(10)
	_check("удержание кнопки листает РОВНО один раз",
		ship.secondary_weapon == w2, "оружие=%s" % ship.secondary_weapon.display_name)

	# Отпустили и нажали снова — кольцо возвращает к первому, недоступное
	# оружие пропущено (иначе следующим было бы w_hidden).
	ship.input.turn = 0.0
	await _step(1)
	ship.input.turn = 1.0
	await _step(1)
	_check("selectable=false пропускается, список замкнут в кольцо",
		ship.secondary_weapon == w1, "оружие=%s" % ship.secondary_weapon.display_name)

	# Влево — в обратную сторону.
	ship.input.turn = 0.0
	await _step(1)
	ship.input.turn = -1.0
	await _step(1)
	_check("нажатие влево листает в обратную сторону",
		ship.secondary_weapon == w2, "оружие=%s" % ship.secondary_weapon.display_name)

	# Вне базы кнопки поворота оружие не трогают.
	ship.input.turn = 0.0
	await _step(1)
	ship.global_position = Vector2(2000, 2000)
	await _step(2)
	var before := ship.secondary_weapon
	ship.input.turn = 1.0
	await _step(5)
	_check("вне базы поворот НЕ меняет оружие", ship.secondary_weapon == before,
		"оружие=%s" % ship.secondary_weapon.display_name)

	ship.queue_free()
	base.queue_free()
	await _step(1)

	# Арсенал боевой базы (data/bases/common.tres) не пуст и весь selectable —
	# иначе механика на реальном уровне молча ничего не делает.
	var playable := 0
	for w in COMMON_BASE.weapons:
		if w != null and w.selectable:
			playable += 1
	_check("в common.tres есть хотя бы 2 доступных оружия", playable >= 2,
		"доступных=%d" % playable)


# --------------------------------------------------------------- гейт поворота

func _test_turn_gate() -> void:
	print("\n-- гейт поворота (регрессия физики) --")
	var base := _make_base(Vector2(500, 500), _make_test_base_data([]))
	var ship := _make_ship(Vector2(500, 500))
	await _step(2)
	_check("корабль пристыкован (контроль перед гейтом)", ship.is_docked())

	var angle_before := ship.aim_angle
	ship.input.turn = 1.0
	await _step(10)
	_check("на базе aim_angle НЕ меняется при удержании поворота",
		is_equal_approx(ship.aim_angle, angle_before),
		"было %.3f, стало %.3f" % [angle_before, ship.aim_angle])

	# Тяга на базе работает: взлететь можно в любой момент, и это же само
	# снимает стыковку, когда скорость уйдёт выше порога.
	ship.input.turn = 0.0
	ship.input.thrust = true
	await _step(10)
	_check("тяга на базе работает (взлёт возможен)",
		ship.linear_velocity.length() > 1.0,
		"скорость=%.1f" % ship.linear_velocity.length())
	_check("разгон выше порога сам снимает стыковку", not ship.is_docked(),
		"скорость=%.1f, порог=%.1f" % [ship.linear_velocity.length(), 40.0])

	# Вне базы поворот работает как раньше — главная регрессия на «физику не сломали».
	ship.input.thrust = false
	ship.global_position = Vector2(2000, 2000)
	ship.linear_velocity = Vector2.ZERO
	await _step(2)
	var free_angle := ship.aim_angle
	ship.input.turn = 1.0
	await _step(10)
	_check("вне базы aim_angle меняется как раньше",
		not is_equal_approx(ship.aim_angle, free_angle),
		"было %.3f, стало %.3f" % [free_angle, ship.aim_angle])

	ship.queue_free()
	base.queue_free()
	await _step(1)


# --------------------------------------------------- размещение баз на уровне

func _test_placement() -> void:
	print("\n-- размещение баз на сгенерированном уровне --")
	var palette: TerrainPalette = load("res://data/terrain/wings_classes.tres")
	var cell_px: int = GEN_RULES.cell_px
	var half: int = GEN_RULES.base_half_width_cells
	var depth: int = GEN_RULES.base_platform_depth_cells

	var built := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, 4242, GEN_RULES)
	var bases: Array = built["bases"]
	_check("на уровне нашлись базы", bases.size() == 2, "баз=%d" % bases.size())
	if bases.size() < 2:
		return

	# По базе на половину: иначе игрок, которому до ремонта вдвое дальше,
	# проигрывает по географии, а не по игре.
	var mid := LEVEL_SIZE.x / 2.0
	var left_count := 0
	for b in bases:
		if b.x < mid:
			left_count += 1
	_check("по одной базе в каждой половине карты", left_count == 1,
		"в левой половине=%d из %d" % [left_count, bases.size()])

	# Тот же seed обязан дать те же базы — на этом стоит будущий сетевой матч,
	# где хост и клиент строят уровень независимо (roadmap.md).
	var again := SAND_LEVEL_GEN.build_settled_sim(LEVEL_SIZE, 4242, GEN_RULES)
	_check("тот же seed даёт те же позиции баз", again["bases"] == bases,
		"%s vs %s" % [str(bases), str(again["bases"])])

	# Под базой — камень, над базой — воздух (иначе садиться некуда).
	var sim = built["sim"]
	var spot: Vector2 = bases[0]
	var gx := int(spot.x / cell_px)
	var gy := int(spot.y / cell_px)
	var stone_ok := true
	var sky_ok := true
	for x in range(gx - half, gx + half + 1):
		for y in range(gy, gy + depth):
			if SAND_LEVEL_GEN.cls_of(sim.get_cell(x, y)) != TerrainPalette.Cls.INDESTRUCTIBLE:
				stone_ok = false
		if sim.get_cell(x, gy - 1) != 0:
			sky_ok = false
	_check("под базой сплошной неразрушаемый камень", stone_ok,
		"площадка %d клеток шириной, %d глубиной" % [half * 2 + 1, depth])
	_check("над базой пусто — есть куда сесть", sky_ok)

	# Площадку нельзя выесть оружием: класс INDESTRUCTIBLE carve не берёт,
	# поэтому база остаётся пригодной весь матч. В оригинале база была обычными
	# пикселями уровня и уничтожалась — здесь сознательное расхождение.
	var lvl := SAND_LEVEL_GEN.generate(LEVEL_SIZE, 4242, palette, GEN_RULES)
	var terrain := Terrain.new()
	terrain.palette = palette
	terrain.immediate_rebuild = false
	add_child(terrain)
	terrain.load_level(lvl["visual"], lvl["mask"])
	var base_spot: Vector2 = lvl["bases"][0]
	# На клетку ниже поверхности — заведомо в толще пласта, а не на его кромке.
	var probe := Vector2i(int(base_spot.x), int(base_spot.y) + cell_px)
	var cls_before := terrain.class_at(probe)
	_check("центр площадки — неразрушаемый класс",
		cls_before == TerrainPalette.Cls.INDESTRUCTIBLE, "класс=%d" % cls_before)
	terrain.carve_circle(probe, 60)
	_check("carve радиусом 60 не разрушает площадку базы",
		terrain.class_at(probe) == TerrainPalette.Cls.INDESTRUCTIBLE,
		"класс после carve=%d" % terrain.class_at(probe))
	terrain.queue_free()


# ------------------------------------------------- условие победы «на базу»

## MatchManager нужен минимальный рельеф — он чистит место под спавн через
## Terrain.find_clear_spawn(). Своя маленькая картинка, а не боевой уровень:
## правила победы к форме рельефа отношения не имеют.
func _make_flat_terrain() -> Terrain:
	var t := Terrain.new()
	t.palette = load("res://data/terrain/wings_classes.tres")
	t.immediate_rebuild = false
	add_child(t)
	var vis := Image.create(400, 400, false, Image.FORMAT_RGBA8)
	vis.fill(Color(0.5, 0.3, 0.1, 1.0))
	t.load_level(vis)
	t.add_to_group("terrain")
	return t


func _make_match(terrain: Terrain, ships: Array[Ship]) -> MatchManager:
	var m: MatchManager = preload("res://scripts/match/match_manager.gd").new()
	m.terrain = terrain
	m.respawn_delay = 0.05
	add_child(m)
	m.setup(ships)
	return m


func _test_win_condition() -> void:
	print("\n-- условие победы «последний на базу» --")
	var terrain := _make_flat_terrain()
	await _step(1)

	# Контроль: режим по умолчанию не изменился — респавн работает как раньше.
	GameRules.reset()
	GameRules.gravity_scale = 0.0
	_check("режим по умолчанию — дезматч по фрагам",
		GameRules.win_condition == GameRules.WIN_KILLS,
		"win_condition=%d" % GameRules.win_condition)
	var d1 := _make_ship(Vector2(100, 100))
	var d2 := _make_ship(Vector2(300, 100))
	var dm := _make_match(terrain, [d1, d2])
	d2.take_damage(99999.0)
	await _step(15)
	_check("в режиме фрагов погибший воскресает как раньше", d2.is_alive())
	_check("матч по фрагам не закончился от одной смерти", not dm.is_match_over())
	d1.queue_free()
	d2.queue_free()
	dm.queue_free()
	await _step(1)

	# Режим «последний — на базу».
	GameRules.win_condition = GameRules.WIN_LAST_TO_BASE
	var base := _make_base(Vector2(500, 500), _make_test_base_data([]))
	var a := _make_ship(Vector2(100, 100))
	var b := _make_ship(Vector2(300, 100))
	var m := _make_match(terrain, [a, b])
	await _step(1)

	b.take_damage(99999.0)
	await _step(15)
	_check("погибший НЕ воскресает — иначе «последнего» не бывает",
		not b.is_alive())
	_check("матч не окончен: выживший ещё не на базе", not m.is_match_over())
	_check("победитель пока не определён", m.winner() == null)

	# Долетел до базы — победа.
	a.global_position = Vector2(500, 500)
	a.linear_velocity = Vector2.ZERO
	await _step(3)
	_check("последний выживший сел на базу — матч окончен", m.is_match_over())
	_check("победитель — тот, кто долетел", m.winner() == a,
		"winner=%s" % ("a" if m.winner() == a else str(m.winner())))

	a.queue_free()
	b.queue_free()
	m.queue_free()
	await _step(1)

	# Никто не дожил: раунд обязан закончиться, иначе он завис бы навсегда —
	# респавна в этом режиме нет.
	var c := _make_ship(Vector2(100, 100))
	var d := _make_ship(Vector2(300, 100))
	var m2 := _make_match(terrain, [c, d])
	await _step(1)
	c.take_damage(99999.0)
	d.take_damage(99999.0)
	await _step(3)
	_check("все погибли — раунд окончен", m2.is_match_over())
	_check("победителя нет (ничья)", m2.winner() == null)
	c.queue_free()
	d.queue_free()
	m2.queue_free()
	await _step(1)

	# Соло: один корабль всегда «последний выживший», касанием базы выигрывать
	# нельзя — пережить некого.
	var solo := _make_ship(Vector2(500, 500))
	var m3 := _make_match(terrain, [solo])
	await _step(3)
	_check("соло-матч не выигрывается посадкой на базу", not m3.is_match_over(),
		"пристыкован=%s" % str(solo.is_docked()))
	solo.queue_free()
	m3.queue_free()
	base.queue_free()
	terrain.queue_free()
	await _step(1)

	GameRules.reset()
	_check("GameRules.reset() возвращает режим победы",
		GameRules.win_condition == GameRules.WIN_KILLS,
		"win_condition=%d" % GameRules.win_condition)
