## Общая загрузка visual.png/mask.png уровня — раньше три копии одного и того
## же кода жили в level.gd/net_playground.gd/terrain_playground.gd и уже успели
## разойтись (net_playground.gd потерял предупреждение про испорченный импорт) —
## один источник истины вместо трёх.
class_name LevelImageLoader
extends RefCounted


## null, если файла нет (вызывающий тогда берёт процедурный TestLevelGen).
## Если PNG импортирован как Texture2D, а не Image (importer="image" не
## выставлен в .import) — process/fix_alpha_border меняет RGB у прозрачных
## пикселей, для разбора маски классов это фатально (devlog §8.5) —
## предупреждаем, но не роняем загрузку: для visual.png без маски порча
## прозрачных пикселей не критична.
static func load_image(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var res := load(path)
	if res is Image:
		return res
	if res is Texture2D:
		push_warning("%s импортирован как Texture2D, а не Image — цвета могут быть искажены" % path)
		return (res as Texture2D).get_image()
	return null
