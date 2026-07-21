## Классы материалов рельефа и их кодирование в маске уровня.
##
## Семантика классов взята из COLORS.TXT оригинала (см. notes/mechanics.md §3.4).
## В оригинале класс определялся ДИАПАЗОНОМ ИНДЕКСА палитры, а не цветом: одно и то
## же RGB встречается под разными индексами (например (0,0,0) — это и индекс 0
## «пустота», и индекс 232 «порода»). PNG в Godot приходит как RGBA без индексов,
## поэтому для авторских уровней класс задаётся отдельной маской в однозначной
## палитре, определённой здесь.
class_name TerrainPalette
extends Resource

enum Cls {
	EMPTY = 0,
	BACKGROUND = 1,
	WATER = 2,
	WATER_FLOW_DOWN = 3,
	WATER_FLOW_LEFT = 4,
	WATER_FLOW_RIGHT = 5,
	BUBBLES = 6,
	SNOW = 7,
	FIRE = 8,
	EXPLOSIVE = 9,
	INDESTRUCTIBLE = 10,
	SOFT = 11,
	BURNING = 12,
	NORMAL = 13,
	BASE = 14,
	BASE_INDESTRUCTIBLE = 15,
	BASE_TEAM = 16,
}

const CLASS_COUNT := 17

## Участвует ли класс в коллизии. Индекс = значение Cls.
## static var, а не const: литерал PackedByteArray не является constant expression
## в GDScript, а обычный Array дороже при индексировании в горячем цикле carve.
static var SOLID := PackedByteArray([
	0, # EMPTY
	0, # BACKGROUND
	0, 0, 0, 0, # WATER, FLOW_DOWN, FLOW_LEFT, FLOW_RIGHT
	0, # BUBBLES
	0, # SNOW
	0, # FIRE
	1, # EXPLOSIVE
	1, # INDESTRUCTIBLE
	1, # SOFT
	1, # BURNING
	1, # NORMAL
	1, # BASE
	1, # BASE_INDESTRUCTIBLE
	1, # BASE_TEAM
])

## Разрушается ли класс попаданием. Индекс = значение Cls.
static var CARVABLE := PackedByteArray([
	0, # EMPTY
	0, # BACKGROUND
	0, 0, 0, 0, # WATER*
	0, # BUBBLES
	0, # SNOW
	0, # FIRE
	1, # EXPLOSIVE — разрушается и детонирует дальше
	0, # INDESTRUCTIBLE
	1, # SOFT — рвётся увеличенным радиусом
	1, # BURNING
	1, # NORMAL
	1, # BASE
	0, # BASE_INDESTRUCTIBLE
	1, # BASE_TEAM
])

## Множитель радиуса воронки по классу.
## NORMAL = "Земля" в текущем 3-материальном концепте (notes/terrain_materials.md):
## основной разрушаемый рельеф, крошится чуть охотнее номинала (1.3, а не 1.0) —
## это и есть "сыпучесть" из концепции. INDESTRUCTIBLE = "Камень" пока абсолютно
## неубиваем; нюанс "ракета немного скалывает поверхность" — открытый вопрос,
## решаем при работе над Камнем, не трогаем сейчас.
static var CARVE_SCALE := PackedFloat32Array([
	0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
	1.0, # EXPLOSIVE
	0.0, # INDESTRUCTIBLE — "Камень"
	1.6, # SOFT
	1.0, # BURNING
	1.3, # NORMAL — "Земля"
	1.0, # BASE
	0.0, # BASE_INDESTRUCTIBLE
	1.0, # BASE_TEAM
])

## Цвета маски как 0xRRGGBB. Целые, а не Color — чтобы сравнение было точным
## и не зависело от округления float при сериализации.
@export var mask_rgb: PackedInt32Array = PackedInt32Array([
	0x000000, # EMPTY
	0x404040, # BACKGROUND
	0x0000FF, # WATER
	0x0040FF, # WATER_FLOW_DOWN
	0x0080FF, # WATER_FLOW_LEFT
	0x00C0FF, # WATER_FLOW_RIGHT
	0x80FFFF, # BUBBLES
	0xFFFFFF, # SNOW
	0xFF8000, # FIRE
	0xFF00FF, # EXPLOSIVE
	0x808080, # INDESTRUCTIBLE
	0x00FF00, # SOFT
	0xFF0000, # BURNING
	0x804000, # NORMAL
	0xFFFF00, # BASE
	0xC0C000, # BASE_INDESTRUCTIBLE
	0x00FF80, # BASE_TEAM
])

## Класс, назначаемый непрозрачным пикселям, когда маска не задана.
@export var default_solid_class: Cls = Cls.NORMAL

## Урон кораблю при столкновении с материалом — по классам, но НЕ static var
## (в отличие от SOLID/CARVABLE/CARVE_SCALE выше): это редкое событие, не
## пиксельный горячий цикл, поэтому Inspector-удобство важнее скорости
## индексирования. Самому менять: FileSystem -> data/terrain/wings_classes.tres
## -> клик -> группа "Столкновение корабля" справа.
##
## Модель — порог + линейный рост сверх него, а не жёстко фиксированное число:
## ниже порога — 0 урона совсем (PvP-ощущение "мягкое касание безопасно"),
## на пороге — *_crash_damage (опорная точка, откалиброванная по ощущениям),
## выше — растёт пропорционально избытку скорости (реальная физика удара, а
## не выдуманное число). Вода отдельного порога не имеет и не нуждается — она
## не твёрдая (SOLID=0 выше), физически столкнуться с ней нельзя.
@export_group("Столкновение корабля")
## "Земля" (Cls.NORMAL) — порог скорости, px/с. Ниже — удар безопасен.
@export_range(0.0, 1000.0, 5.0, "suffix:px/с") var dirt_crash_speed: float = 250.0
## "Земля" — урон РОВНО на пороге, hp. Опорная точка для dirt_crash_rate.
@export_range(0.0, 50.0, 0.5) var dirt_crash_damage: float = 1.0
## "Земля" — рост урона за каждую единицу скорости сверх порога, hp/(px/с).
## По умолчанию dirt_crash_damage/dirt_crash_speed — "в том же порядке", что
## и опорная точка, но можно раскрутить круче или положе отдельно от базы.
@export_range(0.0, 1.0, 0.001) var dirt_crash_rate: float = 0.004
## "Камень" (Cls.INDESTRUCTIBLE) — порог заметно ниже: камень не крошится,
## поэтому весь удар достаётся кораблю, а не рельефу.
@export_range(0.0, 1000.0, 5.0, "suffix:px/с") var stone_crash_speed: float = 100.0
## "Камень" — урон РОВНО на пороге, hp. Заметно выше земли за тот же смысл удара.
@export_range(0.0, 50.0, 0.5) var stone_crash_damage: float = 3.0
## "Камень" — рост урона сверх порога. Круче земли: камень не гасит удар вообще.
@export_range(0.0, 1.0, 0.001) var stone_crash_rate: float = 0.03


## Порог скорости (px/с), с которого столкновение с классом cls вообще
## что-то значит. Отдельно от crash_damage() — нужен и сам по себе, чтобы
## посчитать радиус кратера от превышения (см. Ship._carve_crash_site).
func crash_speed_threshold(cls: int) -> float:
	if cls == Cls.INDESTRUCTIBLE:
		return stone_crash_speed
	return dirt_crash_speed


## Урон при ударе о класс cls на скорости speed. 0 ниже порога, иначе
## база (в точности на пороге) плюс линейный рост от превышения. Классы, для
## которых профиль ещё не решён отдельно (SOFT, BASE, EXPLOSIVE — см.
## terrain_materials.md), используют профиль Земли как безопасный дефолт,
## а не 0 урона: непродуманный материал не должен оказаться неуязвимым
## только потому, что до него не дошли руки.
func crash_damage(cls: int, speed: float) -> float:
	var threshold := crash_speed_threshold(cls)
	if speed < threshold:
		return 0.0
	var base := dirt_crash_damage
	var rate := dirt_crash_rate
	if cls == Cls.INDESTRUCTIBLE:
		base = stone_crash_damage
		rate = stone_crash_rate
	return base + (speed - threshold) * rate


static func class_title(cls: int) -> String:
	var keys := Cls.keys()
	if cls < 0 or cls >= keys.size():
		return "?"
	return keys[cls]


func get_mask_color(cls: int) -> Color:
	var v := mask_rgb[cls]
	return Color8((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)


## LUT «RGB555 -> класс» на 32768 записей. Строится один раз на загрузку уровня,
## чтобы разбор маски был одним индексированием на пиксель вместо поиска по словарю.
## Цвета маски разнесены далеко друг от друга, поэтому квантование до 5 бит на канал
## не создаёт коллизий (проверяется в _validate_lut).
func build_rgb555_lut() -> PackedByteArray:
	var lut := PackedByteArray()
	lut.resize(32768)
	lut.fill(default_solid_class)
	for cls in mini(mask_rgb.size(), CLASS_COUNT):
		var v := mask_rgb[cls]
		var key := (((v >> 19) & 0x1F) << 10) | (((v >> 11) & 0x1F) << 5) | ((v >> 3) & 0x1F)
		lut[key] = cls
	return lut


## Возвращает список конфликтов «два класса схлопнулись в один ключ RGB555».
## Пусто — значит палитра маски корректна.
func validate() -> PackedStringArray:
	var seen := {}
	var problems := PackedStringArray()
	for cls in mini(mask_rgb.size(), CLASS_COUNT):
		var v := mask_rgb[cls]
		var key := (((v >> 19) & 0x1F) << 10) | (((v >> 11) & 0x1F) << 5) | ((v >> 3) & 0x1F)
		if seen.has(key):
			problems.append("Cls %d и Cls %d дают одинаковый ключ RGB555" % [seen[key], cls])
		seen[key] = cls
	return problems
