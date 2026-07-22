## Общий текстовый HUD (CanvasLayer + Label, белый текст с чёрной обводкой) —
## level.gd/net_playground.gd/terrain_playground.gd заводили идентичный узел
## по отдельности (даже с мелким разночтением Color.WHITE/Color(1,1,1) — те же
## значения, разный стиль, след копипаста, см. notes/audit.md §3.1). Три сцены
## показывают разное СОДЕРЖИМОЕ (текст HUD у каждой свой), сам узел — общий.
class_name HudLabel
extends RefCounted


## parent — куда повесить CanvasLayer (обычно корень сцены). Возвращает Label,
## текст которого вызывающий обновляет сам (_update_hud()/_set_status() и т.п.).
static func build(parent: Node) -> Label:
	var layer := CanvasLayer.new()
	parent.add_child(layer)

	var label := Label.new()
	label.position = Vector2(12, 8)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 5)
	layer.add_child(label)
	return label
