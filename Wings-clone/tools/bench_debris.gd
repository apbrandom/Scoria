## Бенчмарк декоративного слоя обломков (scenes/fx/terrain_debris.gd,
## Terrain.spawn_weapon_debris/spawn_crash_debris) — стресс-сценарий "много
## одновременных попаданий на хотсите 8 игроков", чтобы понять стоимость на
## физ-кадр при max_debris обломков одновременно на сцене.
##
## Headless (точные usec на физ-шаг, без GPU/рендера):
##   godot --headless --path Wings-clone res://tools/bench_debris.tscn
## В окне (реальный FPS, GPU/рендер — как в architecture.md §8.5/devlog §8.5):
##   Godot...console.exe --path Wings-clone res://tools/bench_debris.tscn --quit-after 900
extends Node2D

const LEVEL_SIZE := Vector2i(1200, 1200)
const RNG_SEED := 1337
const EXPLOSION_SCENE := preload("res://scenes/fx/explosion.tscn")
const STEADY_FRAMES := 300  # 5 с при 60 Гц

var _terrain: Terrain
var _headless: bool


## Случайная точка ГАРАНТИРОВАННО в твёрдой земле — генератор пещеры даёт немало
## открытого пространства (тоннели), поэтому чисто случайная точка часто попадает
## в пустоту (carve ничего не выбивает, обломков нет) и стресс-тест мерил бы не то,
## что заявлено. Несколько попыток вместо честного поиска — для бенчмарка
## достаточно, реальная гарантия (Terrain.find_clear_spawn) тут не нужна.
func _random_solid_point() -> Vector2:
	for _i in 30:
		var p := Vector2i(randi_range(100, 1100), randi_range(100, 1100))
		if _terrain.is_solid_at(p):
			return Vector2(p)
	return Vector2(600, 600)  # geometric центр — почти наверняка порода


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	print("=== Бенчмарк обломков (%s), Godot %s ===" % [
		"headless" if _headless else "окно", Engine.get_version_info().string])

	var palette := load("res://data/terrain/wings_classes.tres") as TerrainPalette
	var lvl := TestLevelGen.generate(LEVEL_SIZE, RNG_SEED, palette)

	_terrain = Terrain.new()
	_terrain.palette = palette
	_terrain.immediate_rebuild = false
	add_child(_terrain)
	_terrain.load_level(lvl["visual"], lvl["mask"])
	_terrain.add_to_group("terrain")
	await get_tree().physics_frame

	print("max_debris (кап) = %d" % _terrain.max_debris)

	await _bench_burst()
	await _bench_steady_state()

	if not _headless:
		_run_windowed_stress()
	else:
		get_tree().quit()


## Худший разовый случай: N взрывов ОДНОВРЕМЕННО за один кадр (залп всей комнаты
## из 8 игроков разом). Меряем время самого залпа (инстанцирование Explosion +
## carve, БЕЗ спавна обломков — тот теперь идёт через _process, см. §17.4/§18) и
## сколько обломков реально осело после дренажа (должно упереться в max_debris).
func _bench_burst() -> void:
	print("\n--- Залп: 16 взрывов за один кадр ---")
	var t0 := Time.get_ticks_usec()
	for _i in 16:
		var exp: Explosion = EXPLOSION_SCENE.instantiate()
		exp.global_position = _terrain.position + _random_solid_point()
		exp.blast_radius = 30.0
		exp.terrain_power = 1.0
		exp.damage = 0.0
		add_child(exp)
	var dt := Time.get_ticks_usec() - t0
	print("  16x Explosion._ready (carve + постановка обломков в очередь): %.2f мс" % (dt / 1000.0))
	# Ждём дренажа _pending_debris опросом, а не фиксированным числом кадров:
	# на тяжёлом уровне (1200x1200) один физ-шаг сам по себе стоит ~16 мс (см.
	# baseline ниже), сравнимо с целевым тактом idle-обработки (_process) — сколько
	# именно физ-кадров пройдёт до следующего вызова _process, здесь не гарантия
	# в 1-2, в отличие от лёгких сцен tools/test_ship.gd. Дренаж проверялся и
	# работает — важно дать ему достаточно кадров, а не считать конкретное число.
	var drain_frames := 0
	while not _terrain._pending_debris.is_empty() and drain_frames < 60:
		await get_tree().physics_frame
		drain_frames += 1
	print("  дренаж очереди занял %d физ-кадров" % drain_frames)
	print("  обломков на сцене после залпа: %d (кап=%d)" % [_terrain._debris.size(), _terrain.max_debris])


## Устойчивый режим: держим _debris на потолке max_debris несколько секунд подряд
## (каждые 10 физ-кадров подливаем новый взрыв), меряем стоимость ОДНОГО физ-шага
## и сравниваем с шагом на том же уровне вовсе без обломков (baseline) — так видно
## именно МАРЖИНАЛЬНУЮ стоимость слоя обломков, а не шум от рельефа/чанков.
func _bench_steady_state() -> void:
	print("\n--- Устойчивый режим: %d физ-кадров (%.0f с), обломки держатся у потолка ---" % [
		STEADY_FRAMES, STEADY_FRAMES / 60.0])

	var base_terrain := Terrain.new()
	base_terrain.palette = _terrain.palette
	add_child(base_terrain)
	var lvl := TestLevelGen.generate(LEVEL_SIZE, RNG_SEED, _terrain.palette)
	base_terrain.load_level(lvl["visual"], lvl["mask"])
	await get_tree().physics_frame
	var base_sum := 0
	var base_max := 0
	for _i in STEADY_FRAMES:
		var t0 := Time.get_ticks_usec()
		await get_tree().physics_frame
		var d := Time.get_ticks_usec() - t0
		base_sum += d
		base_max = maxi(base_max, d)
	print("  baseline (тот же рельеф, БЕЗ обломков)   : %.3f мс/кадр средн., %.3f мс худший" % [
		base_sum / float(STEADY_FRAMES) / 1000.0, base_max / 1000.0])
	base_terrain.queue_free()

	var sum := 0
	var maxv := 0
	for i in STEADY_FRAMES:
		if i % 10 == 0:
			var exp: Explosion = EXPLOSION_SCENE.instantiate()
			exp.global_position = _terrain.position + _random_solid_point()
			exp.blast_radius = 30.0
			exp.terrain_power = 1.0
			exp.damage = 0.0
			add_child(exp)
		var t0 := Time.get_ticks_usec()
		await get_tree().physics_frame
		var d := Time.get_ticks_usec() - t0
		sum += d
		maxv = maxi(maxv, d)
	print("  с обломками (взрыв каждые 10 кадров, кап=%d): %.3f мс/кадр средн., %.3f мс худший" % [
		_terrain.max_debris, sum / float(STEADY_FRAMES) / 1000.0, maxv / 1000.0])
	print("  обломков на сцене под конец: %d" % _terrain._debris.size())
	print("  маржинальная стоимость слоя обломков (средн.): %.3f мс/кадр" % (
		(sum - base_sum) / float(STEADY_FRAMES) / 1000.0))


## Оконный прогон — реальный FPS с GPU/рендером (Sprite2D чанков + Polygon2D
## обломков), тот же вопрос, что уже закрывался для рельефа в architecture.md §8.5:
## headless-цифры точны для физики/логики, но не видят стоимость отрисовки.
func _run_windowed_stress() -> void:
	print("\n--- Оконный прогон: непрерывные взрывы, реальный FPS ---")
	var timer := 0
	while true:
		timer += 1
		if timer % 10 == 0:
			var exp: Explosion = EXPLOSION_SCENE.instantiate()
			exp.global_position = _terrain.position + _random_solid_point()
			exp.blast_radius = 30.0
			exp.terrain_power = 1.0
			exp.damage = 0.0
			add_child(exp)
		if timer % 60 == 0:
			print("  кадр %d   FPS %d   обломков %d" % [
				timer, Engine.get_frames_per_second(), _terrain._debris.size()])
		await get_tree().physics_frame
