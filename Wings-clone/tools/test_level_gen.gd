## Процедурный генератор тестового уровня: пещера в духе оригинала.
## Нужен, чтобы бенчмарк был воспроизводимым (фиксированный seed) и не зависел
## от нарисованного вручную PNG.
##
## Шум берётся через FastNoiseLite.get_image() — это одна генерация на стороне C++
## вместо ~6 млн вызовов get_noise_2d() из GDScript.
class_name TestLevelGen
extends RefCounted


static func _noise_bytes(rng_seed: int, freq: float, octaves: int, size: Vector2i) -> PackedByteArray:
	var n := FastNoiseLite.new()
	n.seed = rng_seed
	n.frequency = freq
	n.fractal_octaves = octaves
	# FORMAT_L8, значения нормализованы в 0..255 (128 ~ ноль исходного шума)
	return n.get_image(size.x, size.y, false, false, true).get_data()


## Возвращает {"visual": Image, "mask": Image}.
static func generate(size: Vector2i, rng_seed: int, palette: TerrainPalette) -> Dictionary:
	var w := size.x
	var h := size.y
	var n := w * h

	var shape := _noise_bytes(rng_seed, 0.006, 4, size)
	var soft := _noise_bytes(rng_seed + 1, 0.012, 2, size)
	var hard := _noise_bytes(rng_seed + 2, 0.010, 2, size)
	var detail := _noise_bytes(rng_seed + 3, 0.150, 1, size)

	var vis := PackedByteArray()
	vis.resize(n * 4)
	var msk := PackedByteArray()
	msk.resize(n * 4)

	const BORDER := 24
	const SHAPE_T := 151   # ~0.18 в исходном диапазоне [-1,1]
	const HARD_T := 198    # ~0.55
	const SOFT_T := 185    # ~0.45
	var water_line := int(h * 0.88)

	# цвета маски заранее, как плоские массивы — чтобы в цикле не дёргать методы
	var mr := PackedByteArray()
	var mg := PackedByteArray()
	var mb := PackedByteArray()
	mr.resize(TerrainPalette.CLASS_COUNT)
	mg.resize(TerrainPalette.CLASS_COUNT)
	mb.resize(TerrainPalette.CLASS_COUNT)
	for cls in TerrainPalette.CLASS_COUNT:
		var v: int = palette.mask_rgb[cls]
		mr[cls] = (v >> 16) & 0xFF
		mg[cls] = (v >> 8) & 0xFF
		mb[cls] = v & 0xFF

	for y in h:
		var row := y * w
		# смещение порога у пола и потолка, чтобы уровень был замкнут
		var bias := 0.0
		var dy_top := float(y - BORDER) / 90.0
		var dy_bot := float(h - BORDER - y) / 70.0
		if dy_top < 1.0:
			bias += (1.0 - dy_top) * 115.0
		if dy_bot < 1.0:
			bias += (1.0 - dy_bot) * 140.0
		var thr := SHAPE_T - bias
		var below_water := y >= water_line
		var border_row := y < BORDER or y >= h - BORDER

		for x in w:
			var i := row + x
			var cls := TerrainPalette.Cls.EMPTY

			if border_row or x < BORDER or x >= w - BORDER:
				cls = TerrainPalette.Cls.INDESTRUCTIBLE
			elif shape[i] > thr:
				cls = TerrainPalette.Cls.NORMAL
				if hard[i] > HARD_T:
					cls = TerrainPalette.Cls.INDESTRUCTIBLE
				elif soft[i] > SOFT_T:
					cls = TerrainPalette.Cls.SOFT
			elif below_water:
				cls = TerrainPalette.Cls.WATER

			var o := i * 4
			var d := detail[i] - 128 # -128..127
			var r := 0
			var g := 0
			var b := 0
			var a := 255
			match cls:
				TerrainPalette.Cls.EMPTY:
					a = 0
				TerrainPalette.Cls.WATER:
					r = 24
					g = 60
					b = 190
					a = 190
				TerrainPalette.Cls.INDESTRUCTIBLE:
					var t := 120 + (d >> 3)
					r = t
					g = t
					b = t + 6
				TerrainPalette.Cls.SOFT:
					r = 70 + (d >> 3)
					g = 120 + (d >> 2)
					b = 40 + (d >> 4)
				_:
					r = 122 + (d >> 2)
					g = 74 + (d >> 3)
					b = 38 + (d >> 4)
			vis[o] = clampi(r, 0, 255)
			vis[o + 1] = clampi(g, 0, 255)
			vis[o + 2] = clampi(b, 0, 255)
			vis[o + 3] = a

			msk[o] = mr[cls]
			msk[o + 1] = mg[cls]
			msk[o + 2] = mb[cls]
			msk[o + 3] = 255

	return {
		"visual": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, vis),
		"mask": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, msk),
	}
