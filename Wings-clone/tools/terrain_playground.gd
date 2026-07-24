## Интерактивная песочница рельефа: нажать Play и покопать.
##
## ЛКМ (можно зажать) — копать,  ПКМ — большой взрыв (x2.5)
## 1..5 — радиус 8/16/32/64/100
## СКМ или пробел+мышь — панорама,  колесо — зум
## F1 — показать реальные отрезки коллизии и сетку чанков
## F2 — перезагрузить уровень,  ESC — выход
##
## process_priority = 10, чтобы _process песочницы шёл ПОСЛЕ Terrain._process
## и телеметрия за кадр читалась уже собранной.
extends Node2D

const PALETTE_PATH := "res://data/terrain/wings_classes.tres"
const VISUAL_PATH := "res://levels/test/visual.png"
const MASK_PATH := "res://levels/test/mask.png"
const RADII: Array[int] = [8, 16, 32, 64, 100]
const FALLBACK_SIZE := Vector2i(1200, 1200)
const FALLBACK_SEED := 1337
const HUD_LABEL_SCRIPT := preload("res://scripts/level/hud_label.gd")

var _palette: TerrainPalette
var _terrain: Terrain
var _cam: Camera2D
var _hud: Label
var _debug: TerrainDebugDraw

var _radius_idx := 2
var _source := ""
var _last_carve_ms := 0.0
var _last_carve_px := 0
var _frame_rebuild_ms := 0.0
var _frame_rebuilt := 0
var _panning := false

# --- автотест: godot --path Wings-clone -- --autocarve ---
# Нужен, чтобы померить ImageTexture.update с настоящим GPU: headless-прогон
# использует dummy-драйвер и стоимость загрузки текстуры там всегда ~0.
var _auto := false
var _auto_left := 0
var _auto_tex_usec := 0
var _auto_rebuilds := 0
var _auto_frame_ms: Array[float] = []
var _auto_done := false
## Куда автотест кладёт скриншоты. Пусто — не сохранять.
var _auto_shot_dir := ""


func _ready() -> void:
	process_priority = 10
	_palette = load(PALETTE_PATH) as TerrainPalette
	if _palette == null:
		push_error("Не загрузилась палитра " + PALETTE_PATH)
		return

	var vis := LevelImageLoader.load_image(VISUAL_PATH)
	var msk := LevelImageLoader.load_image(MASK_PATH)
	if vis == null:
		var lvl := TestLevelGen.generate(FALLBACK_SIZE, FALLBACK_SEED, _palette)
		vis = lvl["visual"]
		msk = lvl["mask"]
		_source = "процедурный (PNG не найден)"
	else:
		_source = "PNG" + ("" if msk != null else " без маски")

	_terrain = Terrain.new()
	_terrain.palette = _palette
	_terrain.immediate_rebuild = false
	add_child(_terrain)
	_terrain.load_level(vis, msk)

	_debug = TerrainDebugDraw.new()
	_debug.terrain = _terrain
	_debug.visible = false
	add_child(_debug)

	_cam = Camera2D.new()
	_cam.position = Vector2(_terrain.size) * 0.5
	_cam.zoom = Vector2.ONE * 0.5
	add_child(_cam)
	_cam.make_current()

	_hud = HUD_LABEL_SCRIPT.build(self)

	var args := OS.get_cmdline_user_args()
	if "--autocarve" in args:
		_auto = true
		_auto_left = 60
		_cam.zoom = Vector2.ONE * 0.5
		for a in args:
			if a.begins_with("--shots="):
				_auto_shot_dir = a.substr(8)
		print("=== АВТОТЕСТ: %d взрывов, драйвер %s ===" % [
			_auto_left, DisplayServer.get_name()])


func _process(delta: float) -> void:
	if _terrain == null:
		return

	if _auto:
		_auto_step(delta)
	elif Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_carve(RADII[_radius_idx])

	# телеметрия за прошедший кадр
	_frame_rebuild_ms = (_terrain.stat_solid_image_usec + _terrain.stat_bitmap_usec \
		+ _terrain.stat_polygons_usec + _terrain.stat_apply_usec \
		+ _terrain.stat_texture_usec) / 1000.0
	_frame_rebuilt = _terrain.stat_rebuilds
	if _frame_rebuilt > 0 and _debug.visible:
		_debug.refresh()
	_terrain.stats_reset()

	_update_hud()


func _auto_step(delta: float) -> void:
	_auto_frame_ms.append(delta * 1000.0)
	_auto_tex_usec += _terrain.stat_texture_usec
	_auto_rebuilds += _terrain.stat_rebuilds
	if _auto_left <= 0:
		if _terrain.dirty_count() > 0 or _auto_done:
			return
		_auto_done = true
		_auto_finish()
		return
	# детерминированный проход по уровню взрывами разного радиуса
	# (индексы ниже)
	var i := 60 - _auto_left
	var p := Vector2i(
		200 + (i * 137) % 800,
		200 + (i * 241) % 800)
	var t0 := Time.get_ticks_usec()
	_last_carve_px = _terrain.carve_circle(p, RADII[i % RADII.size()])
	_last_carve_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_auto_left -= 1


func _auto_finish() -> void:
	# первые кадры — создание окна и компиляция шейдеров, к рельефу отношения
	# не имеют, поэтому в статистику установившегося режима не идут
	const WARMUP := 5
	var sum := 0.0
	var worst := 0.0
	var startup := 0.0
	for i in _auto_frame_ms.size():
		var v: float = _auto_frame_ms[i]
		if i < WARMUP:
			startup = maxf(startup, v)
			continue
		sum += v
		worst = maxf(worst, v)
	var n := maxi(_auto_frame_ms.size() - WARMUP, 1)
	print("  кадров: %d" % _auto_frame_ms.size())
	print("  установившийся режим: средний %.2f мс, худший %.2f мс" % [sum / n, worst])
	print("  худший из первых %d кадров (старт): %.2f мс" % [WARMUP, startup])
	print("  пересобрано чанков: %d" % _auto_rebuilds)
	print("  ImageTexture.update: %.4f мс на чанк (суммарно %.2f мс)" % [
		(_auto_tex_usec / 1000.0) / maxi(_auto_rebuilds, 1), _auto_tex_usec / 1000.0])
	print("  отрезков коллизии: %d" % _terrain.total_segments())

	if _auto_shot_dir != "":
		_debug.visible = false
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_auto_shot_dir + "/view.png")
		_debug.visible = true
		_debug.refresh()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_auto_shot_dir + "/view_collision.png")
		print("  скриншоты сохранены в %s" % _auto_shot_dir)
	get_tree().quit()


func _carve(radius: int) -> void:
	var p := Vector2i(get_global_mouse_position().round())
	var t0 := Time.get_ticks_usec()
	var px := _terrain.carve_circle(p, radius)
	_last_carve_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_last_carve_px = px


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_RIGHT:
					_carve(int(RADII[_radius_idx] * 2.5))
				MOUSE_BUTTON_WHEEL_UP:
					_zoom_at(1.15)
				MOUSE_BUTTON_WHEEL_DOWN:
					_zoom_at(1.0 / 1.15)
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed

	elif event is InputEventMouseMotion and _panning:
		_cam.position -= (event as InputEventMouseMotion).relative / _cam.zoom

	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
				_radius_idx = (event as InputEventKey).keycode - KEY_1
			KEY_F1:
				_debug.visible = not _debug.visible
				if _debug.visible:
					_debug.refresh()
			KEY_F2:
				_reload()
			KEY_ESCAPE:
				get_tree().quit()


func _zoom_at(factor: float) -> void:
	_cam.zoom = (_cam.zoom * factor).clampf(0.1, 8.0)


func _reload() -> void:
	var vis := LevelImageLoader.load_image(VISUAL_PATH)
	var msk := LevelImageLoader.load_image(MASK_PATH)
	if vis == null:
		var lvl := TestLevelGen.generate(FALLBACK_SIZE, FALLBACK_SEED, _palette)
		vis = lvl["visual"]
		msk = lvl["mask"]
	_terrain.load_level(vis, msk)
	if _debug.visible:
		_debug.refresh()


func _update_hud() -> void:
	var m := Vector2i(get_global_mouse_position().round())
	var cls := _terrain.class_at(m)
	_hud.text = "\n".join([
		"FPS %d      уровень %dx%d (%s)" % [
			Engine.get_frames_per_second(), _terrain.size.x, _terrain.size.y, _source],
		"радиус %d   (1..5)      зум %.2f" % [RADII[_radius_idx], _cam.zoom.x],
		"",
		"carve      %6.2f мс  (%d пикс.)" % [_last_carve_ms, _last_carve_px],
		"пересборка %6.2f мс  чанков за кадр: %d,  в очереди: %d" % [
			_frame_rebuild_ms, _frame_rebuilt, _terrain.dirty_count()],
		"отрезков коллизии: %d   чанков: %d" % [_terrain.total_segments(), _terrain.chunk_count],
		"",
		"под курсором: %s  %s" % [str(m), TerrainPalette.class_title(cls)],
		"",
		"ЛКМ копать · ПКМ большой взрыв · СКМ панорама · колесо зум",
		"F1 отрезки коллизии · F2 перезагрузить · ESC выход",
	])
