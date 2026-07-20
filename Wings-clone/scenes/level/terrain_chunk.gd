## Один чанк рельефа: StaticBody2D с собственным спрайтом и набором
## CollisionPolygon2D, которые пересобираются при разрушении.
##
## Чанки создаются кодом из Terrain, а не инстансом .tscn: это чисто рантаймовый
## объект без авторского содержимого (один Sprite2D + пул полигонов), сцена не дала бы
## ничего кроме лишнего файла.
class_name TerrainChunk
extends StaticBody2D

## RGBA8, размер cw*ch*4. Источник истины для отрисовки чанка.
var vis_bytes: PackedByteArray
## LA8, cw*ch*2. Альфа = «пиксель твёрдый».
var solid_bytes: PackedByteArray
## LA8, cw*ch*2. Альфа = «пиксель пустой». Инверсия solid_bytes.
##
## Второй массив нужен, потому что BitMap.opaque_to_polygons() возвращает только
## ВНЕШНИЕ контуры связных областей и молча теряет дырки внутри них (проверено
## в tools/diag_polygons.gd: квадрат 48x48 с дыркой 16x16 даёт один контур
## площадью 48*48). Контуры дырок получаются трассировкой инвертированной маски:
## дырка в породе — это связная ПУСТАЯ область, её внешний контур трассируется
## штатно. Инверсию дешевле поддерживать инкрементально в carve, чем строить
## заново на каждой пересборке циклом по пикселям.
var empty_bytes: PackedByteArray

var cw: int
var ch: int

var _sprite: Sprite2D
var _texture: ImageTexture
## Одна форма на чанк: набор отрезков границы «камень/пустота».
##
## ConcavePolygonShape2D, а не набор CollisionPolygon2D, по трём причинам:
##  1. Нужен ПРОИЗВОЛЬНЫЙ набор отрезков, а не замкнутые петли: часть рёбер
##     (замыкание контура по краю чанка) приходится выбрасывать — см. Terrain.
##  2. BUILD_SOLIDS в CollisionPolygon2D сделал бы контур дырки твёрдым телом,
##     а BUILD_SOLIDS ещё и падает на самопересекающихся контурах.
##  3. Один узел на чанк вместо пула из десятков.
## Это штатная форма Godot для статичной геометрии уровня.
var _shape_node: CollisionShape2D
var _shape: ConcavePolygonShape2D
## Сколько контуров отброшено как вырожденные при последнем вызове.
var last_rejected := 0


func setup(chunk_w: int, chunk_h: int, origin: Vector2i) -> void:
	cw = chunk_w
	ch = chunk_h
	position = origin
	vis_bytes.resize(cw * ch * 4)
	solid_bytes.resize(cw * ch * 2)
	empty_bytes.resize(cw * ch * 2)
	_sprite = Sprite2D.new()
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)
	_shape = ConcavePolygonShape2D.new()
	_shape_node = CollisionShape2D.new()
	_shape_node.shape = _shape
	add_child(_shape_node)


func refresh_texture() -> void:
	var img := Image.create_from_data(cw, ch, false, Image.FORMAT_RGBA8, vis_bytes)
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
		_sprite.texture = _texture
	else:
		_texture.update(img)


func _mask_image(bytes: PackedByteArray, downscale: int) -> Image:
	var img := Image.create_from_data(cw, ch, false, Image.FORMAT_LA8, bytes)
	if downscale > 1:
		img.resize(maxi(cw / downscale, 1), maxi(ch / downscale, 1), Image.INTERPOLATE_NEAREST)
	return img


func build_solid_image(downscale: int) -> Image:
	return _mask_image(solid_bytes, downscale)


func build_empty_image(downscale: int) -> Image:
	return _mask_image(empty_bytes, downscale)


## Отрезки идут парами: [a1,a2, b1,b2, ...]. Координаты — локальные для чанка.
## Плата за отсутствие «внутренности» у формы: physics point-query не скажет
## «точка внутри камня». Для этого есть Terrain.is_solid_at() по карте классов —
## он и точнее, и быстрее.
func apply_segments(segments: PackedVector2Array) -> void:
	_shape.segments = segments


func segment_count() -> int:
	return _shape.segments.size() / 2


func get_segments() -> PackedVector2Array:
	return _shape.segments
