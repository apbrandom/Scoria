## Разовый «пшик» пыли в точке разрушения рельефа — чисто декоративный слой,
## дополняющий (не заменяющий) TerrainDebris (см. terrain_debris.gd): тот —
## отлетающие твёрдые осколки породы, этот — облачко мелкой взвеси, оседающей
## почти на месте. Вместе они и есть числовое воплощение "сыпучести" земли из
## notes/terrain_materials.md ("осталось открытым: частицы осыпающихся
## обломков при разрушении").
##
## Строится целиком в коде, как TerrainChunk/TerrainDebris — рантаймовый
## одноразовый эффект без авторского содержимого, отдельная .tscn дала бы
## только лишний файл. Параметры частиц (текстура/материал) — тот же паттерн,
## что у Ship.tscn::Thrust (GradientTexture2D + ParticleProcessMaterial), но
## всенаправленный (spread=180) взрыв облачка, а не направленная струя.
##
## Жизненный цикл: one_shot=true + emitting=true — GPUParticles2D сам
## останавливает эмиссию после одного цикла (проверено по офиц. доке 4.7,
## class_gpuparticles2d.html) и шлёт finished() ТОЛЬКО когда отрисованы уже
## ВСЕ частицы (не когда кончилась эмиссия) — безопасный момент для
## queue_free(), раньше — обрезало бы видимые частицы.
class_name TerrainDust
extends GPUParticles2D

const AMOUNT := 12
const LIFETIME := 0.5


## color — цвет материала (Terrain.palette.get_mask_color(cls), см.
## Terrain._spawn_dust) — тот же источник цвета, что и у TerrainDebris,
## чтобы пыль и осколки одного попадания читались как один и тот же материал.
func setup(color: Color) -> void:
	one_shot = true
	amount = AMOUNT
	lifetime = LIFETIME
	explosiveness = 1.0  # весь пшик разом, не струйкой — это взрыв, не дым из трубы
	local_coords = false  # облако не должно ехать вместе с узлом, если тот сдвинут

	var grad := Gradient.new()
	# Полупрозрачная взвесь, гаснущая к концу жизни — не твёрдый осколок
	# (тем и отличается от TerrainDebris визуально).
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([
		Color(color.r, color.g, color.b, 0.55),
		Color(color.r, color.g, color.b, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 12
	tex.height = 12
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	texture = tex

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, -1, 0)
	mat.spread = 180.0  # во все стороны — облачко, не струя
	mat.initial_velocity_min = 15.0
	mat.initial_velocity_max = 45.0
	mat.gravity = Vector3(0, 30, 0)  # пыль оседает, но медленнее твёрдых осколков
	mat.damping_min = 30.0
	mat.damping_max = 60.0
	mat.scale_min = 0.5
	mat.scale_max = 1.1
	process_material = mat

	finished.connect(queue_free)
	emitting = true
