# Wings-clone — архитектура Godot 4.7

Основано на `notes/mechanics.md`. Границы v0.1 (что входит, что отложено) —
в `notes/scope.md`; этот документ описывает КАК, а не ЧТО. На момент
первоначального проектирования `scope.md` был пуст, рамки ниже были уточнены
у заказчика напрямую и позже перенесены в `scope.md` как источник истины:

| Решение | Выбор |
|---|---|
| Мультиплеер | Локальный хотсит в v0.1, архитектура со швом под сетевой позже |
| Уровни | Свои PNG в палитре оригинала (импортёр `.LEV` — не сейчас) |
| Рендер | Свободное разрешение, рельеф крупнее оригинала (`TERRAIN_SCALE`, ориентир x3) |

**Принцип:** нативный узел/система Godot по умолчанию. Кастом — только там, где
встроенное объективно не решает задачу; каждый такой случай ниже помечен
**[КАСТОМ]** с обоснованием.

---

## 1. Структура проекта

```
res://
├── autoload/
│   └── game_rules.gd              # autoload "GameRules" (§5)
├── resources/                     # определения Resource-классов (код)
│   ├── ship_data.gd
│   ├── weapon_data.gd
│   └── terrain_palette.gd
├── data/                          # инстансы данных (.tres, без кода)
│   ├── ships/         normal.tres, arrow.tres, dart.tres, ...
│   ├── weapons/       dumbfire.tres, bomb.tres, digger.tres, ...
│   └── terrain/       wings_palette.tres
├── scenes/
│   ├── main.tscn                  # корень: меню -> матч
│   ├── level/
│   │   ├── level.tscn
│   │   ├── terrain.tscn
│   │   └── terrain_chunk.tscn
│   ├── ship/
│   │   └── ship.tscn
│   ├── projectiles/
│   │   ├── projectile.tscn        # база
│   │   ├── bomb.tscn, bouncer.tscn, digger.tscn, mine.tscn
│   ├── fx/
│   │   └── explosion.tscn
│   └── ui/
│       └── hud.tscn
├── scripts/
│   ├── input/  ship_input.gd, local_input.gd, ai_input.gd
│   └── match/  match_manager.gd, spawn_service.gd
└── levels/                        # ассеты уровней
    └── arena/  visual.png (+ background.png)
```

Разделение `resources/` (классы) и `data/` (`.tres`-инстансы) — чтобы дизайнер
добавлял корабль/оружие файлом, не трогая код.

---

## 2. Сцены и узлы

### 2.1 `main.tscn`
```
Main (Node)
├── MatchManager (Node)          # правила матча, счёт, смена уровней
├── LevelHost (Node2D)           # сюда инстанцируется level.tscn
└── HUD (CanvasLayer)
```
`MatchManager` — обычный узел, **не** autoload: его жизнь равна жизни матча,
глобальным он быть не должен.

### 2.2 `level.tscn`
```
Level (Node2D)
├── ParallaxBackground            # встроенный узел — фон 1:1 из механики оригинала
│   └── ParallaxLayer/Sprite2D
├── Terrain (Node2D)              # см. §3
├── Ships (Node2D)                # контейнер спавна кораблей
├── Projectiles (Node2D)          # контейнер снарядов
├── Bases (Node2D)                # Area2D-базы (ремонт/смена оружия/победа)
├── Camera2D                      # limit_* по границам уровня
└── SpawnPoints (Node2D)          # Marker2D
```
- Параллакс-фон оригинала — ровно то, для чего существует `ParallaxBackground`.
- Базы: `Area2D` + `CollisionPolygon2D`. Позиции берутся из палитровых индексов
  32–47 при загрузке уровня (сегментируем связные области нужных индексов), но сами
  зоны — штатные `Area2D`, а не ручные проверки.

### 2.3 `ship.tscn` — **`RigidBody2D`**
```
Ship (RigidBody2D)
├── CollisionShape2D (CircleShape2D)
├── Sprite2D                      # rotation = aim_angle
├── Muzzle (Marker2D)
├── Thrust (GPUParticles2D)
├── EngineSfx (AudioStreamPlayer2D)
└── PickupArea (Area2D)           # десантники в одиночной игре
```

**Почему `RigidBody2D`, а не `CharacterBody2D`:** параметры оригинала ложатся на его
свойства один в один, без единой строки собственной физики:

| Оригинал (Options/Rules) | Свойство Godot |
|---|---|
| Gravity | `gravity_scale` (× `ProjectSettings.physics/2d/default_gravity`) |
| Air resistance | `linear_damp` |
| Масса корабля (стат `.SHP`) | `mass` |
| Тяга | `apply_central_force()` |
| Удар о рельеф | `contact_monitor` + `max_contacts_reported`, `body_entered` |

Единственная тонкость: в Wings корабль поворачивается **с фиксированной скоростью
по кнопке**, а не крутящим моментом. Решение без борьбы с солвером —
`lock_rotation = true` и собственная переменная `aim_angle`. Коллайдер круглый
(корабль 15×15 → круг), поэтому поворот тела на физику вообще не влияет:
```gdscript
aim_angle += input.turn * data.turn_rate * delta
$Sprite2D.rotation = aim_angle
if input.thrust:
    apply_central_force(Vector2.UP.rotated(aim_angle) * data.thrust)
```

**Шов под сеть.** Ввод отделён от симуляции: корабль не читает `Input` напрямую,
а получает `ShipInput` (`thrust: bool`, `turn: float`, `fire_primary`, `fire_secondary`)
от провайдера:
- `LocalInput` — читает `InputMap`-экшены `p{N}_thrust` / `p{N}_left` / … (8 игроков × 5
  действий = 40 экшенов, ровно как 8 наборов клавиш в `KEYS.DAT` оригинала).
  Хотсит на одной клавиатуре — это штатный `InputMap`, ничего своего.
- `AIInput` — позже (в оригинале есть Computer-игроки).
- `RemoteInput` — позже; тогда на корабль вешается `MultiplayerSynchronizer`,
  а сервер получает интенты по RPC. Переписывать `Ship` не придётся.

### 2.4 Снаряды — `projectile.tscn` (`RigidBody2D`)
```
Projectile (RigidBody2D)
├── CollisionShape2D
├── Sprite2D
└── Lifetime (Timer)              # встроенный таймер вместо ручного счётчика
```
- Гравитация бомб/гранат — `gravity_scale`, бесплатно.
- **Bouncer** (рикошетящий снаряд) — `PhysicsMaterial.bounce`, встроенное свойство.
- **Mine** — `freeze = true` после приземления + `Area2D`-триггер.
- Быстрые пули — `continuous_cd = CCD_MODE_CAST_RAY`, встроенное решение проблемы
  туннелирования; писать свой raycast-марш не нужно.
- Взрыв: `explosion.tscn` (`GPUParticles2D` + `AudioStreamPlayer2D` + вызов
  `Terrain.carve()`), самоудаление по `finished`.

Поведение живёт в скрипте сцены снаряда, числа — в `WeaponData` (§4).

---

## 3. Разрушаемый рельеф — сравнение и выбор

Требование из механики: **попиксельное** разрушение произвольно нарисованного
битмапа + классы материалов по диапазонам палитры (пустота / вода / огонь / мягкое /
неразрушаемое / взрывчатое).

### Вариант B — `TileMapLayer` со слоями урона → **отклонён**
`TileMapLayer` спроектирован под сетку авторских тайлов. Здесь он не подходит по сути
задачи, а не по производительности:
- источник — свободно нарисованный PNG, а не тайлсет; чтобы положить его в тайлы,
  пришлось бы изобретать автотайл-схему поверх пиксельного арта;
- разрушение стало бы поблочным. Даже тайл 4×4 px убивает силуэт кратера, ради
  которого весь жанр и существует; тайл 1×1 px — это 1200×1200 = 1.44 млн тайлов,
  что абсурдно и медленнее любого битмапа.

### Вариант C — чистая попиксельная физика без физдвижка → **отклонён как основа**
Так делал оригинал (DOS, без физдвижка). В Godot это означало бы отказ от
`RigidBody2D`, `Area2D`, слоёв коллизий, нормалей контакта — то есть ручную
реализацию того, что движок уже даёт. Нормали нужны для Bouncer и для порога
«Ship strength», ими не хочется жертвовать.

### Вариант A — `Image` + `BitMap.opaque_to_polygons()` + чанки → **выбран**

Полностью на встроенных классах: `Image`, `BitMap`, `CollisionPolygon2D`,
`StaticBody2D`, `ImageTexture`, `Sprite2D`.

**Две картинки как источник истины** (обе — `Image`, живут в памяти):
1. `visual_image` (RGBA8) — то, что видно;
2. `class_image` (R8) — класс материала на пиксель, строится один раз при загрузке
   из `visual_image` через `TerrainPalette` (§4.3).

**Чанки.** Рельеф режется на сетку `terrain_chunk.tscn` (ориентир 128×128 px,
параметр). Уровень 1200×1200 → ~100 чанков.
```
Terrain (Node2D)
└── TerrainChunk (StaticBody2D) × N
    ├── Sprite2D (ImageTexture)         # рендер чанка
    └── CollisionPolygon2D × M          # генерируются заново при изменении
```

> ⚠️ **Три поправки, найденные при реализации** (детали и замеры — §8):
> 1. `opaque_to_polygons()` **теряет дырки** — возвращает только внешние контуры.
>    Приходится трассировать ещё и инвертированную маску.
> 2. Контур обязан **замкнуться по краю чанка**, из-за чего у маски пустоты
>    появляются фантомные стены поперёк открытого воздуха. Такие рёбра отбрасываются.
> 3. Из-за (1) и (2) вместо `CollisionPolygon2D` используется
>    `ConcavePolygonShape2D` с явным списком отрезков.

**Цикл разрушения:**
```
carve(center, radius, power)
  └─ для пикселей в радиусе: класс из class_image
       INDESTRUCTIBLE -> пропустить
       SOFT           -> радиус × коэффициент
       EXPLOSIVE      -> в очередь цепной детонации
       иначе          -> class_image = EMPTY, visual_image = прозрачный
  └─ пометить задетые чанки dirty (обычно 1–4)
  └─ в конце кадра для каждого dirty-чанка:
       ImageTexture.update(sub_image)                      # рендер
       BitMap.create_from_image_alpha(solid_mask_sub)      # маска твёрдого
       BitMap.opaque_to_polygons(rect, epsilon)            # C++, встроенное
       пересобрать CollisionPolygon2D чанка
```
Перегенерация ограничена задетыми чанками, а не всем уровнем, и делается один раз за
кадр (батч через `set_deferred` / очередь dirty), а не на каждый пиксель.

**Настройки производительности:**
- `epsilon` в `opaque_to_polygons` — упрощение контура; убирает пилу пиксельных краёв.
- Маска коллизий строится в 1/2 разрешения рельефа: полигонов вдвое меньше, разница
  визуально незаметна (мы и так рисуем рельеф крупнее оригинала).
- Если dirty-чанков за кадр много (Nuke), обработка размазывается по кадрам очередью.

**[КАСТОМ] Попиксельный запрос материала для нетвёрдых зон.**
Вода, течения, огонь, снег, пузыри — не коллизия, а свойство точки пространства,
причём вода в оригинале ещё и течёт. Строить на них `Area2D`-полигоны и
перегенерировать их каждый кадр — дороже и хуже, чем `class_image.get_pixelv(pos)`,
то есть O(1) обращение встроенным методом `Image`. Отдельного узла под «карту
материалов» в Godot нет, так что это не замена встроенной системы, а её штатное
использование. Твёрдость при этом остаётся на физдвижке.

---

## 4. Данные: Resource-классы

Числа — в `.tres`, поведение — в сценах. Добавление корабля/оружия = новый файл.

### 4.1 `ShipData`
```gdscript
class_name ShipData extends Resource

@export var display_name: String
@export var sprite: Texture2D
@export_group("Physics")
@export var mass: float = 1.0                 # .SHP стат 75–170 -> нормировать
@export var thrust: float = 800.0
@export var turn_rate: float = 3.0            # рад/с (в оригинале 0.04–0.08 рад/кадр)
@export var linear_damp: float = 0.5
@export var collision_radius: float = 7.0
@export_group("Combat")
@export var max_hull: float = 100.0
@export var max_fuel: float = 2000.0
@export var gun_count: int = 1                # 1 или 2 в оригинале
@export var crash_tolerance: float = 200.0    # порог импульса удара
@export var default_weapon: WeaponData
```
Восемь `.tres` заполняются прямо из таблицы `mechanics.md` §3.2 — данные уже извлечены.

### 4.2 `WeaponData`
```gdscript
class_name WeaponData extends Resource

@export var display_name: String
@export var icon: Texture2D
@export var projectile_scene: PackedScene     # поведение
@export var ammo: int = -1                    # -1 = бесконечно
@export var reload_time: float = 0.5
@export var muzzle_speed: float = 400.0
@export var damage: float = 20.0
@export var blast_radius: float = 12.0
@export var terrain_power: float = 1.0        # 0 = не роет рельеф
@export var selectable: bool = true           # флаг из W_SELECT.DAT
```
31 оружие оригинала слишком разнородно (Teleport, Shield, Harpoon, Bats), чтобы быть
чистыми данными. Поэтому `WeaponData` = числа + ссылка на `PackedScene` со скриптом
поведения. Это штатная композиция Godot: ресурс для параметров, сцена для логики.
В v0.1 достаточно 2 файлов (`dumbfire.tres`, `bomb.tres`), остальные 29 добавляются
без изменения кода стрельбы.

### 4.3 `TerrainPalette`
```gdscript
class_name TerrainPalette extends Resource

enum Class { EMPTY, BACKGROUND, WATER, WATER_FLOW_D, WATER_FLOW_L, WATER_FLOW_R,
             BUBBLES, SNOW, FIRE, EXPLOSIVE, INDESTRUCTIBLE, SOFT, BURNING,
             NORMAL, BASE, BASE_TEAM }

@export var colors: PackedColorArray          # 256 записей (из COLORS.PCX)
@export var ranges: Array[Dictionary]         # {from, to, class} по COLORS.TXT
```
Семантика `COLORS.TXT` становится **данными, а не кодом**. Один `.tres` генерируется
из `COLORS.PCX`, и правила материалов можно менять без перекомпиляции.
Загрузка уровня: RGB пикселя → индекс палитры → класс → `class_image`.

> Запасной вариант, если рисовать строго в 256-цветной палитре окажется неудобно:
> уровень как две PNG — `visual.png` (любой арт) + `mask.png` (цвет = класс).
> Загрузчик уровня абстрагирован, так что второй источник подключается без правок
> `Terrain`.

---

## 5. Autoload

**Один autoload: `GameRules`** (`autoload/game_rules.gd`).

Хранит настраиваемые правила матча — те самые пункты меню Options оригинала,
которым в движке нет места и которые нужны глобально и в рантайме. Физические
поля — МНОЖИТЕЛИ с нейтральным умолчанием 1.0 (без настроек — как будто autoload
нет). **Реализовано**, точная раскладка «какое поле где применяется» — в
`notes/devlog.md` §17; здесь — суть:
```gdscript
extends Node
# Физика: множители поверх ShipData/ProjectSettings, 1.0 = «как задано»
var gravity_scale: float = 1.0         # -> RigidBody2D.gravity_scale (× default_gravity)
var air_resistance_scale: float = 1.0  # -> × ShipData.linear_damp
var ship_strength: float = 1.0         # -> делитель ВСЕГО входящего урона (Ship.take_damage)
var reload_time_scale: float = 1.0     # -> × WeaponData.reload_time (кулдаун)
# Матч (задел под MatchManager, шаг 6)
var kills_per_level: int = 10
# Детали визуала (флаги на будущее)
var parallax_enabled: bool = true
```
> Изменения против первоначального наброска: `air_resistance` стал множителем
> `air_resistance_scale` (а не абсолютным linear_damp); `ship_strength` теперь
> делит урон, а не множит `crash_tolerance` (то поле удалено — урон от
> столкновения переехал на пороги по скорости в `TerrainPalette`, devlog §14);
> `load_time_scale`→`reload_time_scale`. Поля `starting_weapon`, `water_flow_speed`,
> `snow_enabled` отложены до соответствующих механик.

**Что НЕ кладём в autoload** (для этого есть штатные места):
- Базовая гравитация и демпфирование — `ProjectSettings`:
  `physics/2d/default_gravity`, `physics/2d/default_linear_damp`.
  `GameRules` держит только игровой множитель поверх них.
- Слои коллизий — именованные слои в `ProjectSettings`, а не константы в синглтоне.
- Статы кораблей/оружия — `.tres` (§4), не глобальные словари.
- Состояние матча — узел `MatchManager`, у него жизненный цикл матча.
- Глобальная шина сигналов — **не заводим**. Доступ к рельефу из снаряда — через
  группу: `get_tree().get_first_node_in_group("terrain")`, кэшируется в `_ready()`.
  Группы — встроенный механизм, отдельный синглтон тут лишний.

---

## 6. План v0.1

1. `TerrainPalette` + генератор `.tres` из `COLORS.PCX`; тестовый `visual.png`.
   **Готово** — см. §8, включая три поправки, найденные при реализации.
2. `Terrain` + `TerrainChunk`: загрузка, рендер, коллизии, `carve()`. Ключевой риск —
   сюда идёт основное время. **Готово** — замеры и проверки в §8.
3. `ShipData` — данные готовятся на все 8 кораблей (структура одна, дёшево), но
   в геймплей v0.1 подключается **один** (scope.md: выбор корабля отложен) +
   `ship.tscn` на `RigidBody2D` + `LocalInput` на `InputMap`.
   **Готово** — см. §10, включая проверку физики (7 утверждений) и риск-проверку ②.
4. `WeaponData` (2 оружия: Dumbfire, Bomb — см. scope.md) + база `Projectile` +
   `Explosion` с вызовом `carve()`. **Готово** — см. devlog §11.
5. `Level` + `Camera2D` + спавн + `GameRules`. **Готово (база)** — Level (новая
   главная сцена), камера, случайный спавн и autoload GameRules реализованы,
   см. devlog §16, §17. Осталось на потом: контейнеры Ships/Projectiles/Bases,
   `ParallaxBackground` и границы камеры по уровню — при нескольких кораблях (шаг 6).
6. `MatchManager`: «последний выживший летит на базу», рестарт. **← следующий шаг.**

**Проверки-риски:** ①  время `opaque_to_polygons` на dirty-чанке при взрыве Nuke
(проверено, devlog §8.2); ②  корректность порога урона по столкновению — модель
сменилась с импульса на скорость по материалу (devlog §14–§15), проверено тестом;
③  стоимость сборки `class_image` при загрузке 1200×1200 (проверено, devlog §8.2).

---

## 7. Сводка: встроенное vs своё

| Задача | Решение | Тип |
|---|---|---|
| Физика корабля | `RigidBody2D` (`gravity_scale`, `linear_damp`, `mass`) | встроенное |
| Поворот по кнопке | `lock_rotation` + своя `aim_angle`, круглый коллайдер | встроенное свойство |
| Хотсит-ввод 8 игроков | `InputMap`, 40 экшенов | встроенное |
| Коллизия рельефа | `BitMap.opaque_to_polygons` → `CollisionPolygon2D` | встроенное |
| Рендер рельефа | `ImageTexture.update` на чанк | встроенное |
| Материалы (вода/огонь) | `Image.get_pixelv` по `class_image` | **[КАСТОМ]**, обосновано §3 |
| Рикошет | `PhysicsMaterial.bounce` | встроенное |
| Быстрые пули | `continuous_cd` | встроенное |
| Параллакс-фон | `ParallaxBackground` | встроенное |
| Базы | `Area2D` | встроенное |
| Данные кораблей/оружия | `Resource` + `.tres` | встроенное |
| Правила матча | 1 autoload `GameRules` | встроенное |
| Доступ к рельефу | группы узлов | встроенное |
| Космический фон | `ParallaxBackground` + `CanvasItem`-шейдер | встроенное |
| Свечение (двигатель/взрыв/выстрел) | `WorldEnvironment.Glow`, Background Mode = Canvas | встроенное |
| Сцена-wide динамический 2D-свет | **не используем в v0.1** — риск для Steam Deck, см. §9 | отклонено |

Единственное кастомное место — попиксельная карта материалов, и она дополняет
физдвижок, а не заменяет его.

---

## Журнал реализации — в notes/devlog.md

Разделы §8–§17 (результаты реализации, замеры, найденные особенности Godot 4.7 и
как их обошли) вынесены в `notes/devlog.md`, чтобы этот документ остался
описанием СТАБИЛЬНОГО дизайна (КАК и ПОЧЕМУ), не смешивая его с посессионным
журналом. Быстрая карта журнала:

- §8 — рельеф (Terrain): поправки к плану, замеры производительности, параметры.
- §9 — рендер и графический стиль (Steam Deck, свет, свечение).
- §10 — корабль (RigidBody2D, шов ввода).
- §11 — стрельба (WeaponData, Projectile, Explosion).
- §12 — материал «Земля» + находка про CCD и контактный импульс.
- §13 — хвост двигателя (GPUParticles2D).
- §14 — урон от столкновения: порог по скорости + находка про скорость в колбэке.
- §15 — урон: порог + пропорциональный рост; о «весе корабля».
- §16 — спавн: случайное место вместо фиксированной точки.
- §17 — база матча: autoload GameRules + сцена Level + guard immediate_rebuild.

Ссылки вида «§8»…«§17» в тексте выше (в §1–§7) указывают на эти разделы
`devlog.md`. Реализованное на текущий момент: §8–§17 (шаги 1–5 плана §6);
следующий шаг — MatchManager (§6, шаг 6).
