## Диагностика: что именно возвращает BitMap.opaque_to_polygons().
## Отвечает на два вопроса, от которых зависит корректность рельефа:
##   A. Возвращаются ли контуры ДЫРОК, и как их отличить от внешних контуров?
##      (если дырка приедет как обычный полигон в BUILD_SOLIDS — воронка внутри
##       массива породы останется твёрдой)
##   B. Бывают ли контуры самопересекающимися? (из-за них "Convex decomposing failed")
extends Node2D


func _ready() -> void:
	_part_a()
	_part_b()
	_part_c()
	await get_tree().process_frame
	get_tree().quit()


## Замыкается ли контур ПУСТОЙ области по краю чанка? Если да — в открытом
## пространстве на границе чанков появляется невидимая стена.
func _part_c() -> void:
	print("")
	print("=== C. ЗАМЫКАНИЕ КОНТУРА ПУСТОТЫ ПО КРАЮ ЧАНКА ========================")
	# чанк 64x64: слева камень (x<32), справа пустота (x>=32), пустота упирается
	# в правый/верхний/нижний край
	var empty_img := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	empty_img.fill(Color(0, 0, 0, 0))
	empty_img.fill_rect(Rect2i(32, 0, 32, 64), Color(1, 1, 1, 1)) # пустое = непрозрачное

	var bm := BitMap.new()
	bm.create_from_image_alpha(empty_img, 0.5)
	var polys := bm.opaque_to_polygons(Rect2i(0, 0, 64, 64), 0.0)
	print("  контуров пустоты: %d" % polys.size())
	for p in polys:
		print("    вершин=%d  bbox=%s" % [p.size(), str(_bbox(p))])
		var on_border := 0
		for i in p.size():
			var a := p[i]
			var b := p[(i + 1) % p.size()]
			if (is_equal_approx(a.x, b.x) and (is_zero_approx(a.x) or is_equal_approx(a.x, 64.0))) \
			or (is_equal_approx(a.y, b.y) and (is_zero_approx(a.y) or is_equal_approx(a.y, 64.0))):
				on_border += 1
		print("    рёбер, лежащих ровно на краю чанка: %d  <-- это фантомные стены" % on_border)
	print("  Настоящая поверхность здесь только одна — вертикаль x=32.")


func _part_a() -> void:
	print("")
	print("=== A. КВАДРАТ С ДЫРКОЙ ===============================================")
	# 64x64: твёрдый квадрат 8..56, внутри пустая дырка 24..40
	var img := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(8, 8, 48, 48), Color(1, 1, 1, 1))
	img.fill_rect(Rect2i(24, 24, 16, 16), Color(0, 0, 0, 0))

	var bm := BitMap.new()
	bm.create_from_image_alpha(img, 0.5)
	print("  твёрдых битов: %d (ожидание 48*48-16*16 = %d)" % [
		bm.get_true_bit_count(), 48 * 48 - 16 * 16])

	for eps in [0.0, 2.0]:
		var polys := bm.opaque_to_polygons(Rect2i(0, 0, 64, 64), eps)
		print("  epsilon=%.1f -> контуров: %d" % [eps, polys.size()])
		for i in polys.size():
			var p: PackedVector2Array = polys[i]
			print("    [%d] вершин=%d  площадь=%.1f  по часовой=%s  bbox=%s" % [
				i, p.size(), _area(p), str(Geometry2D.is_polygon_clockwise(p)), str(_bbox(p))])
	print("  ВЫВОД: если контур дырки вернулся отдельным полигоном, в BUILD_SOLIDS")
	print("         он станет твёрдым — это надо обрабатывать явно.")


func _part_b() -> void:
	print("")
	print("=== B. САМОПЕРЕСЕЧЕНИЯ НА РЕАЛЬНОМ РЕЛЬЕФЕ =============================")
	var palette := load("res://data/terrain/wings_classes.tres") as TerrainPalette
	var lvl := TestLevelGen.generate(Vector2i(512, 512), 1337, palette)
	var vis: Image = lvl["visual"]

	# маска твёрдости из альфы
	var bm := BitMap.new()
	bm.create_from_image_alpha(vis, 0.5)

	for cfg in [[64, 2.0], [64, 6.0], [32, 2.0], [32, 6.0]]:
		var chunk: int = cfg[0]
		var eps: float = cfg[1]
		var total := 0
		var selfint := 0
		var repaired_ok := 0
		for cy in range(0, 512 / chunk):
			for cx in range(0, 512 / chunk):
				var sub := Image.create_empty(chunk, chunk, false, Image.FORMAT_RGBA8)
				sub.blit_rect(vis, Rect2i(cx * chunk, cy * chunk, chunk, chunk), Vector2i.ZERO)
				var b2 := BitMap.new()
				b2.create_from_image_alpha(sub, 0.5)
				var polys := b2.opaque_to_polygons(Rect2i(0, 0, chunk, chunk), eps)
				for p in polys:
					total += 1
					if _self_intersects(p):
						selfint += 1
						var fixed := Geometry2D.merge_polygons(p, p)
						var all_simple := fixed.size() > 0
						for f in fixed:
							if _self_intersects(f):
								all_simple = false
						if all_simple:
							repaired_ok += 1
		print("  chunk=%3d eps=%.1f : контуров %4d, самопересекающихся %3d, из них чинится merge_polygons: %d" % [
			chunk, eps, total, selfint, repaired_ok])


static func _area(p: PackedVector2Array) -> float:
	var n := p.size()
	if n < 3:
		return 0.0
	var s := 0.0
	var prev := p[n - 1]
	for i in n:
		var cur := p[i]
		s += prev.x * cur.y - cur.x * prev.y
		prev = cur
	return absf(s) * 0.5


static func _bbox(p: PackedVector2Array) -> Rect2:
	if p.is_empty():
		return Rect2()
	var r := Rect2(p[0], Vector2.ZERO)
	for v in p:
		r = r.expand(v)
	return r


static func _self_intersects(p: PackedVector2Array) -> bool:
	var n := p.size()
	if n < 4:
		return false
	for i in n:
		var a1 := p[i]
		var a2 := p[(i + 1) % n]
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue # смежные рёбра
			var b1 := p[j]
			var b2 := p[(j + 1) % n]
			if Geometry2D.segment_intersects_segment(a1, a2, b1, b2) != null:
				return true
	return false
