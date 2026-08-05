## Экран загрузки уровня: затемнение, полоса, подпись фазы.
##
## Заводится кодом, а не отдельной .tscn — ровно по тому же доводу, что и общий
## HUD (scripts/level/hud_label.gd): узел собирается из трёх стандартных
## контролов, и сцена-файл добавила бы к нему только лишний повод разойтись с
## кодом. Стиль — чистый вектор без пиксельной стилизации (CLAUDE.md).
##
## Сам оверлей НИЧЕГО не считает и не знает, что грузится: ему сообщают долю и
## подпись, он рисует. Кто крутит сборку — дело вызывающего (level.gd).
class_name LoadingOverlay
extends CanvasLayer

## Выше HUD-слоя (CanvasLayer по умолчанию 1) — на время загрузки оверлей
## обязан быть поверх всего, что успело появиться на сцене.
const LAYER := 100

## Полоса ползёт к цели, а не прыгает на неё: доля прогресса меняется рывками
## (фаза перебора seed'ов заканчивается скачком с ~8% до 25%), и без сглаживания
## это читается как «дёрнулось и снова встало».
const SMOOTHING := 9.0

## Период анимации многоточия, секунд на полный цикл из 4 состояний. Живёт
## отдельно от прогресса нарочно: пока идёт неделимая порция работы, доля стоит
## на месте, и точки — единственное, что показывает «процесс жив, не повис».
const DOTS_PERIOD := 1.2

var _bar: ProgressBar
var _phase_label: Label
var _percent_label: Label
var _phase_text := ""
var _target := 0.0
var _shown := 0.0
var _time := 0.0


func _ready() -> void:
	# Слой ставим здесь, а не у вызывающего: «поверх всего» — свойство самого
	# экрана загрузки, знать о нём снаружи незачем.
	layer = LAYER

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.04, 0.05, 0.09)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	# CenterContainer сам держит колонку по центру экрана при любом разрешении —
	# важно, потому что целевой Steam Deck и окно разработки разного размера.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	center.add_child(column)

	var title := Label.new()
	title.text = "Загрузка уровня"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	column.add_child(title)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(440, 12)
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 0.0
	# Свой процент рисуем ниже вместе с подписью фазы — встроенный текст
	# ProgressBar рисуется внутри полосы и на 12 px высоты не помещается.
	_bar.show_percentage = false
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.10)
	track.set_corner_radius_all(6)
	_bar.add_theme_stylebox_override("background", track)
	var fill := StyleBoxFlat.new()
	# Тот же холодный акцент, что у свечения двигателя — экран загрузки не
	# должен выглядеть деталью из другой игры.
	fill.bg_color = Color(0.42, 0.83, 1.0)
	fill.set_corner_radius_all(6)
	_bar.add_theme_stylebox_override("fill", fill)
	column.add_child(_bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	column.add_child(row)

	_phase_label = Label.new()
	_phase_label.add_theme_font_size_override("font_size", 16)
	_phase_label.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	_phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_phase_label)

	_percent_label = Label.new()
	_percent_label.add_theme_font_size_override("font_size", 16)
	_percent_label.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	_percent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_percent_label)


## value — доля 0..1, phase — что сейчас происходит (показывается под полосой).
func set_progress(value: float, phase: String) -> void:
	_target = clampf(value, 0.0, 1.0)
	_phase_text = phase


func _process(delta: float) -> void:
	_time += delta
	# exp-сглаживание, а не линейный шаг: не зависит от частоты кадров, поэтому
	# полоса ведёт себя одинаково и на 60 Гц, и на просадке до 20.
	_shown = lerpf(_shown, _target, 1.0 - exp(-SMOOTHING * delta))
	if _bar != null:
		_bar.value = _shown
	if _percent_label != null:
		_percent_label.text = "%d%%" % int(round(_shown * 100.0))
	if _phase_label != null:
		var dots := int(_time / DOTS_PERIOD * 4.0) % 4
		_phase_label.text = _phase_text + ".".repeat(dots)
