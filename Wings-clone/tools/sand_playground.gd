## Визуальная песочница клеточной симуляции (SandSim). Нажать Play и сыпать песок.
##
## ЛКМ (зажать) — рисовать текущим материалом,  колесо — размер кисти
## 1 — песок,  2 — камень,  3 — ластик (пусто)
## F2 — очистить (пол заново),  ESC — выход
##
## Логика симуляции — в scripts/sand/sand_sim.gd (проверена headless в
## tools/test_sand.gd). Здесь только ввод + отрисовка поля в текстуру. Это
## ПРОТОТИП-витрина, а не часть игры: рендер прямой попиксельный (видно зёрна) —
## сглаживание/векторную отрисовку материала оставляем на отдельный слой позже
## (terrain_research.md), тут задача — увидеть, что физика работает.
##
## Headless-запуск (godot --headless ... res://tools/sand_playground.tscn) делает
## короткий self-smoke: сыпет песок, крутит симуляцию, печатает итог и выходит —
## чтобы CI/проверка ловила поломку сцены без окна (сам рендер в окне не заменяет).
extends Node2D

const SAND_SIM := preload("res://scripts/sand/sand_sim.gd")
const M_EMPTY := preload("res://data/sand/empty.tres")
const M_SAND := preload("res://data/sand/sand.tres")
const M_STONE := preload("res://data/sand/stone.tres")
const HUD_LABEL_SCRIPT := preload("res://scripts/level/hud_label.gd")

const GRID_W := 220
const GRID_H := 140
const SCALE := 5           # экранных пикселей на клетку
const FLOOR_H := 6         # толщина каменного пола снизу
const EMPTY_ID := 0
const SAND_ID := 1
const STONE_ID := 2

var _sim: Object
var _sprite: Sprite2D
var _texture: ImageTexture
var _hud: Label
var _brush_id := SAND_ID
var _brush_r := 4
var _render := true


func _ready() -> void:
	_render = DisplayServer.get_name() != "headless"

	_sim = SAND_SIM.new()
	_sim.setup(GRID_W, GRID_H, [M_EMPTY, M_SAND, M_STONE])
	_reset_floor()

	if _render:
		_sprite = Sprite2D.new()
		_sprite.centered = false
		_sprite.scale = Vector2(SCALE, SCALE)
		# NEAREST — это отладочная витрина, зёрна должны быть чёткими; правило
		# "без пиксель-арта" из CLAUDE.md про финальные ассеты игры, не про
		# диагностический инструмент.
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_sprite)
		_refresh_texture()
		_hud = HUD_LABEL_SCRIPT.build(self)
	else:
		_smoke_test()


## Каменное дно + чистое поле над ним.
func _reset_floor() -> void:
	_sim.setup(GRID_W, GRID_H, [M_EMPTY, M_SAND, M_STONE])
	_sim.fill_rect(0, GRID_H - FLOOR_H, GRID_W, FLOOR_H, STONE_ID)


func _physics_process(_delta: float) -> void:
	if not _render:
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_paint(_cell_under_mouse(), _brush_r, _brush_id)
	_sim.step()


func _process(_delta: float) -> void:
	if not _render:
		return
	_refresh_texture()
	_update_hud()


func _cell_under_mouse() -> Vector2i:
	var p := get_global_mouse_position() / float(SCALE)
	return Vector2i(int(floor(p.x)), int(floor(p.y)))


## Залить круглую кисть материалом. Для песка/ластика — только по пустым/песку,
## чтобы кисть не стирала нарисованный камень случайно? Нет: намеренно рисуем
## поверх всего (это ручной инструмент) — камень отдельной кистью, ластик стирает
## всё. Простота важнее умной логики в отладочной песочнице.
func _paint(center: Vector2i, r: int, id: int) -> void:
	var r2 := r * r
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy <= r2:
				_sim.set_cell(center.x + dx, center.y + dy, id)


func _refresh_texture() -> void:
	var img := Image.create_from_data(GRID_W, GRID_H, false, Image.FORMAT_RGBA8, _sim.to_rgba_bytes())
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
		_sprite.texture = _texture
	else:
		_texture.update(img)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_brush_r = mini(_brush_r + 1, 40)
			MOUSE_BUTTON_WHEEL_DOWN:
				_brush_r = maxi(_brush_r - 1, 1)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_brush_id = SAND_ID
			KEY_2:
				_brush_id = STONE_ID
			KEY_3:
				_brush_id = EMPTY_ID
			KEY_F2:
				_reset_floor()
			KEY_ESCAPE:
				get_tree().quit()


func _brush_title() -> String:
	match _brush_id:
		SAND_ID: return "песок"
		STONE_ID: return "камень"
		_: return "ластик"


func _update_hud() -> void:
	var rect: Rect2i = _sim.get_dirty_rect()
	_hud.text = "\n".join([
		"FPS %d      поле %dx%d,  тик %d" % [
			Engine.get_frames_per_second(), GRID_W, GRID_H, _sim.tick],
		"кисть: %s  (1 песок · 2 камень · 3 ластик),  радиус %d (колесо)" % [
			_brush_title(), _brush_r],
		"песка на поле: %d" % _sim.count_material(SAND_ID),
		"активно (idle=покой): %s   грязный прямоугольник %dx%d" % [
			"да" if _sim.is_active() else "нет (покой)", rect.size.x, rect.size.y],
		"",
		"ЛКМ рисовать · F2 очистить · ESC выход",
	])


## Headless self-smoke: без окна проверяем, что сцена и путь данных живы.
func _smoke_test() -> void:
	print("=== sand_playground self-smoke (%s) ===" % DisplayServer.get_name())
	# насыпать блок песка и уронить
	_paint(Vector2i(GRID_W / 2, 20), 12, SAND_ID)
	var sand0: int = _sim.count_material(SAND_ID)
	for _i in 240:
		_sim.step()
	var bytes: PackedByteArray = _sim.to_rgba_bytes()  # проверяем и путь отрисовки данных
	var ok: bool = _sim.count_material(SAND_ID) == sand0 and bytes.size() == GRID_W * GRID_H * 4
	print("  песка насыпано: %d, после падения: %d, покой: %s, байт кадра: %d" % [
		sand0, _sim.count_material(SAND_ID), "да" if not _sim.is_active() else "нет", bytes.size()])
	print("=== ИТОГ: %s ===" % ("OK" if ok else "ПРОВАЛ"))
	get_tree().quit(0 if ok else 1)
