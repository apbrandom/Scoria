## Общий WorldEnvironment для игровых сцен (level.tscn/net_playground.tscn) —
## решение принято в architecture.md §7 ("Свечение (двигатель/взрыв/выстрел)"),
## узел не был заведён ни в одной сцене. Один источник истины вместо двух копий
## настроек, как и LevelImageLoader/_load_image до дедупа.
##
## background_mode = BG_CANVAS обязателен: сцена рисует 2D-контент сама
## (Terrain/Ship/фон), WorldEnvironment здесь только ради пост-процесса Glow,
## не ради неба/цвета фона — без BG_CANVAS Environment попытался бы нарисовать
## СВОЙ фон (чёрный/clear color) НАД уже отрисованной 2D-сценой.
class_name GlowEnvironment
extends RefCounted


## glow_hdr_threshold занижен с дефолта 1.0: цвета Thrust (scenes/ship/ship.tscn,
## Gradient_thrust_color) авторские, в обычном 0..1 диапазоне (не HDR overbright),
## самый яркий кадр — (1, 1, 0.8) — у порога ровно в дефолтном threshold почти
## не светится (проверено на глаз через реальный запуск, не только по числам).
## 0.75 — достаточно ниже, чтобы яркая часть пламени уверенно попадала в bloom,
## не настолько низко, чтобы засветился весь HUD/интерфейс поверх (тот в
## отдельном CanvasLayer, Glow всё равно на него не действует — CanvasLayer
## рисуется поверх результата 3D/2D-рендера с Environment, а не входит в него;
## неочевидно и стоит проверять реальным скриншотом при следующей правке HUD).
const GLOW_HDR_THRESHOLD := 0.75
const GLOW_INTENSITY := 0.6
const GLOW_STRENGTH := 1.0
const GLOW_BLOOM := 0.05


static func build() -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.glow_enabled = true
	env.glow_hdr_threshold = GLOW_HDR_THRESHOLD
	env.glow_intensity = GLOW_INTENSITY
	env.glow_strength = GLOW_STRENGTH
	env.glow_bloom = GLOW_BLOOM

	var we := WorldEnvironment.new()
	we.environment = env
	return we
