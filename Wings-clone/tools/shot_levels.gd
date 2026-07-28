## Снимает уровни в PNG — чтобы вариативность генератора и работу живой физики
## можно было ОЦЕНИТЬ ГЛАЗАМИ, а не по числам в тесте. Правило проекта: физику и
## математику проверяет headless-тест, красоту смотрит человек (CLAUDE.md).
##
## Делает два набора:
##  1. notes/img/level_seed_*.png — несколько уровней от разных seed'ов подряд,
##     чтобы увидеть, НАСКОЛЬКО они отличаются (профиль, озёра, дюны).
##  2. notes/img/live_before.png / live_after.png — один и тот же уровень до и
##     после взрыва, прожитого живой симуляцией: видно, что земля именно съехала
##     вниз и заполнила воронку, а не просто исчезла кругом, как раньше.
##
## Запуск: godot --headless --path Wings-clone res://tools/shot_levels.tscn
extends Node

const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const LIVE_SAND := preload("res://scripts/level/live_sand.gd")
const RULES := preload("res://data/level/default_gen.tres")
const SETTINGS := preload("res://data/sand/live_sand.tres")
const PALETTE := preload("res://data/terrain/wings_classes.tres")

## Тот же размер, в который реально играют (level.gd::SAND_LEVEL_SIZE).
const LEVEL_SIZE := Vector2i(2700, 1350)
## Во сколько раз ужать снимок при сохранении. Полноразмерный PNG уровня — это
## мегабайты на картинку; для оценки формы уровня половины разрешения хватает.
const SHOT_DOWNSCALE := 2
const OUT_DIR := "res://../notes/img"

const SHOT_SEEDS := [101, 202, 303, 404]
## Куда бить в демонстрации живой физики. Радиус примерно как у ракетницы
## (data/weapons/bomb.tres). Точек две, потому что они показывают РАЗНОЕ:
##  · "lake" — попадание у самой поверхности рядом с озером: видно, как вода
##    стекает в свежую воронку, а берега оседают;
##  · "deep" — попадание в толщу склона заметно ниже поверхности: видно чистый
##    обвал земли (свод осыпается, дно воронки заполняется), без участия воды —
##    именно то, что нельзя было получить раньше на статичном рельефе.
const DEMO_BLAST_RADIUS := 46
const DEMO_HITS := [
	{"name": "lake", "x_frac": 0.5, "depth_mult": 0.5},
	{"name": "deep", "x_frac": 0.25, "depth_mult": 2.5},
]
const DEMO_SETTLE_FRAMES := 240
## Размер крупного плана вокруг воронки, в пикселях рельефа (полное разрешение).
const CLOSEUP := Vector2i(520, 400)


func _ready() -> void:
	print("=== Снимки уровней (%s) ===" % DisplayServer.get_name())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_shoot_variety()
	await _shoot_live_collapse()
	print("\nГотово. Картинки в notes/img/")
	get_tree().quit(0)


## Набор 1: разные seed'ы — насколько уровни отличаются друг от друга.
func _shoot_variety() -> void:
	print("\n-- вариативность --")
	for s in SHOT_SEEDS:
		var lvl := SAND_LEVEL_GEN.generate(LEVEL_SIZE, s, PALETTE, RULES)
		var report: Dictionary = lvl["report"]
		var stats: Dictionary = report["stats"]
		var path := "%s/level_seed_%d.png" % [OUT_DIR, lvl["seed_used"]]
		_save(lvl["visual"], path)
		print("  seed %d -> %s  (небо %.2f, вода %.3f, попыток %d)" % [
			lvl["seed_used"], path.get_file(), stats["open_frac"], stats["water_frac"],
			lvl["attempts"]])


## Набор 2: один уровень до и после взрыва, прожитого живой симуляцией.
func _shoot_live_collapse() -> void:
	print("\n-- живой обвал --")
	var lvl := SAND_LEVEL_GEN.generate(LEVEL_SIZE, SHOT_SEEDS[0], PALETTE, RULES)

	var terrain := Terrain.new()
	terrain.palette = PALETTE
	terrain.immediate_rebuild = false
	add_child(terrain)
	terrain.load_level(lvl["visual"], lvl["mask"])

	var live = LIVE_SAND.new()
	add_child(live)
	live.setup(terrain, lvl["sim"], lvl["grid"], RULES.cell_px, lvl["seed_used"], SETTINGS)

	var before := _compose(terrain)
	_save(before, "%s/live_before.png" % OUT_DIR)

	# Бьём поочерёдно в каждую демо-точку. Порядок важен только тем, что второй
	# взрыв бьёт по уже пожившему рельефу — то есть снимок "после" честно
	# показывает НАКОПЛЕННОЕ состояние, а не стерильную сцену.
	var crops: Array = []
	for hit in DEMO_HITS:
		var hit_x := int(LEVEL_SIZE.x * float(hit["x_frac"]))
		var hit_y := _surface_px(terrain, hit_x)
		if hit_y < 0:
			print("  в колонке %d нет рельефа — точка '%s' пропущена" % [hit_x, hit["name"]])
			continue
		var center := Vector2i(hit_x, hit_y + int(DEMO_BLAST_RADIUS * float(hit["depth_mult"])))
		var repainted_before: int = live.stat_cells_repainted
		var carved := terrain.carve_circle(center, DEMO_BLAST_RADIUS)
		for _i in DEMO_SETTLE_FRAMES:
			await get_tree().physics_frame
		terrain.flush_dirty()
		print("  '%s': взрыв в (%d,%d) r=%d — выбито %d px, осыпалось %d клеток" % [
			hit["name"], center.x, center.y, DEMO_BLAST_RADIUS, carved,
			live.stat_cells_repainted - repainted_before])
		crops.append({"name": hit["name"], "center": center})

	print("  всего тиков симуляции: %d, в покое: %s" % [
		live.stat_ticks, not lvl["sim"].is_active()])
	var after := _compose(terrain)
	_save(after, "%s/live_after.png" % OUT_DIR)

	# Крупный план в ПОЛНОМ разрешении: на снимке всего уровня воронка радиусом
	# 46 px занимает несколько пикселей — по нему нельзя оценить ни форму осыпи,
	# ни то, совпал ли цвет свежей земли с нетронутой.
	for c in crops:
		var center: Vector2i = c["center"]
		var crop := Rect2i(center.x - CLOSEUP.x / 2, center.y - CLOSEUP.y / 2,
			CLOSEUP.x, CLOSEUP.y)
		_save_crop(before, crop, "%s/live_%s_before.png" % [OUT_DIR, c["name"]])
		_save_crop(after, crop, "%s/live_%s_after.png" % [OUT_DIR, c["name"]])
		print("  крупный план '%s': live_%s_before.png / live_%s_after.png" % [
			c["name"], c["name"], c["name"]])


## Верхний непустой пиксель колонки.
func _surface_px(terrain: Terrain, x: int) -> int:
	for y in terrain.size.y:
		if terrain.class_at(Vector2i(x, y)) != TerrainPalette.Cls.EMPTY:
			return y
	return -1


## Собирает текущую картинку рельефа обратно из чанков. Источник истины для
## отрисовки живёт по чанкам (TerrainChunk.vis_bytes), единой картинки уровня
## после загрузки уже не существует — а снимок нужен именно ТЕКУЩИЙ, с учётом
## всего, что натворили carve и живая симуляция.
func _compose(terrain: Terrain) -> Image:
	var out := Image.create_empty(terrain.size.x, terrain.size.y, false, Image.FORMAT_RGBA8)
	for chunk in terrain.get_chunks():
		var sub := Image.create_from_data(chunk.cw, chunk.ch, false, Image.FORMAT_RGBA8,
			chunk.vis_bytes)
		out.blit_rect(sub, Rect2i(0, 0, chunk.cw, chunk.ch), Vector2i(chunk.position))
	return out


## Сохраняет ужатую копию — полноразмерный PNG уровня весит слишком много для
## того, чтобы просто посмотреть на форму.
func _save(img: Image, path: String) -> void:
	# Явный тип: Resource.duplicate() объявлен как Resource, и без аннотации
	# компилятор не знает, что дальше можно звать Image.save_png.
	var copy: Image = img.duplicate()
	copy.resize(img.get_width() / SHOT_DOWNSCALE, img.get_height() / SHOT_DOWNSCALE,
		Image.INTERPOLATE_BILINEAR)
	var err := copy.save_png(path)
	if err != OK:
		push_error("не сохранился %s: %s" % [path, error_string(err)])


## Кусок картинки БЕЗ уменьшения — для разглядывания деталей.
func _save_crop(img: Image, rect: Rect2i, path: String) -> void:
	var r := rect.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if r.size.x <= 0 or r.size.y <= 0:
		return
	var out := Image.create_empty(r.size.x, r.size.y, false, Image.FORMAT_RGBA8)
	out.blit_rect(img, r, Vector2i.ZERO)
	var err := out.save_png(path)
	if err != OK:
		push_error("не сохранился %s: %s" % [path, error_string(err)])
