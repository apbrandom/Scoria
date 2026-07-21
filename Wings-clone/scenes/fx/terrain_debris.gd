## Обломок рельефа — мелкий RigidBody2D, разлетающийся от точки разрушения.
##
## Чисто ДЕКОРАТИВНЫЙ слой ПОВЕРХ основной попиксельной системы (Terrain.carve_circle
## по-прежнему единственный источник истины для формы рельефа и его коллизии,
## см. terrain.gd) — обломок ничего не роет и сам не считается столкновением.
## Строится целиком в коде (как TerrainChunk, см. terrain_chunk.gd) — рантаймовый
## объект без авторского содержимого, отдельная .tscn дала бы только лишний файл.
##
## Физика — штатный паттерн Godot "разлетающиеся обломки": RigidBody2D +
## apply_central_impulse() в момент спавна (см. документацию RigidBody2D, пример
## со взрывающимся кораблём/астероидами). Своей коллизии с миром НЕТ
## (collision_mask=0, свой collision_layer=Terrain.DEBRIS_LAYER только чтобы у
## слоя было явное значение — см. Terrain.spawn_weapon_debris/spawn_crash_debris):
## обломок падает под гравитацией и гаснет по таймеру раньше, чем успел бы долететь
## до другой поверхности. Не сталкивать его физически с рельефом/кораблями
## специально — на масштабе времени жизни (≤ пары секунд) разница незаметна, а
## сложность (столкновение с формой рельефа, которая сама постоянно
## пересобирается) не оправдана для чисто визуального эффекта.
class_name TerrainDebris
extends RigidBody2D

## Доля времени жизни в конце, за которую обломок гаснет (альфа -> 0), а не
## исчезает хлопком.
const FADE_FRACTION := 0.35

var _visual: Polygon2D
var _lifetime := 1.0
var _ttl := 1.0


## color — цвет материала (см. Terrain._spawn_debris: palette.get_mask_color(cls)).
## lifetime — время жизни, с.
func setup(color: Color, lifetime: float) -> void:
	gravity_scale = 1.0
	# 0.3 -> 1.2: на исходном значении обломок почти не гасил скорость за время
	# жизни и улетал на 100+ px от точки попадания (см. правку скоростей в
	# Terrain, devlog §19) — выглядело как "обломки где-то отдельно", а не
	# осколки ИМЕННО этого попадания. Выше — быстрее теряет скорость, гаснет
	# рядом с местом, где появился.
	linear_damp = 1.2
	angular_damp = 0.6
	# mass=1 намеренно: apply_central_impulse(direction * speed) в Terrain._spawn_debris
	# тогда читается прямо как "скорость вылета, px/с" (impulse = mass*Δv, при mass=1
	# impulse=Δv) — без лишнего пересчёта на вызывающей стороне.
	mass = 1.0
	collision_layer = Terrain.DEBRIS_LAYER
	collision_mask = 0  # намеренно ни с чем не сталкивается, см. шапку файла

	var shape := CircleShape2D.new()
	shape.radius = randf_range(1.2, 2.6)
	var shape_node := CollisionShape2D.new()
	shape_node.shape = shape
	add_child(shape_node)

	_visual = Polygon2D.new()
	_visual.polygon = _random_chip_polygon(shape.radius * 1.6)
	_visual.color = color.darkened(randf_range(0.0, 0.25))
	add_child(_visual)

	angular_velocity = randf_range(-10.0, 10.0)
	_lifetime = maxf(lifetime, 0.05)
	_ttl = _lifetime


## Время жизни отсчитывается в _physics_process, а не Tween/Timer (которые по
## умолчанию идут по idle-времени) — так жизненный цикл обломка идёт в ТОМ ЖЕ
## такте, что и его собственная физика (гравитация/импульс), и детерминирован
## в headless-тестах, которые шагают именно физ-кадрами (см. tools/test_ship.gd,
## проверка "обломок сам исчезает по истечении времени жизни").
func _physics_process(delta: float) -> void:
	_ttl -= delta
	if _ttl <= 0.0:
		queue_free()
		return
	var fade_start := _lifetime * (1.0 - FADE_FRACTION)
	var age := _lifetime - _ttl
	if age > fade_start:
		_visual.modulate.a = clampf((_lifetime - age) / (_lifetime - fade_start), 0.0, 1.0)


## Неправильный многоугольник 5-6 вершин вокруг центра — силуэт осколка, а не
## идеальный круг/квадрат. Чисто визуально, коллизии не касается (форма физики —
## отдельный CircleShape2D в setup(), проще и дешевле, тот же приём, что у Ship:
## круглый коллайдер + отдельный многоугольник-визуал).
static func _random_chip_polygon(base_radius: float) -> PackedVector2Array:
	var n := randi_range(5, 6)
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var a := (TAU / n) * i + randf_range(-0.3, 0.3)
		var r := base_radius * randf_range(0.55, 1.0)
		pts[i] = Vector2.RIGHT.rotated(a) * r
	return pts
