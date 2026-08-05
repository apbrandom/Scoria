## Снимки экрана загрузки в notes/img/ — то, что тест поймать не может
## (вёрстка, читаемость, цвета). Математику проверяет headless-тест, красоту
## смотрит человек (CLAUDE.md).
##
## Запуск БЕЗ --headless (нужен настоящий кадр, а не заглушка рендера):
##   /Applications/Godot.app/Contents/MacOS/Godot --path Wings-clone \
##     res://tools/shot_loading.tscn
extends Node

const LOADING_OVERLAY := preload("res://scripts/level/loading_overlay.gd")
const OUT_DIR := "res://../notes/img"

## Что снимаем: доля прогресса и подпись — по одному кадру на каждую фазу,
## которую реально видит игрок (см. LevelBuildJob.phase_text и Level).
const SHOTS := [
	{"file": "loading_01_sim.png", "value": 0.08, "phase": "Генерация рельефа (попытка 2)"},
	{"file": "loading_02_bake.png", "value": 0.47, "phase": "Отрисовка материалов"},
	{"file": "loading_03_world.png", "value": 0.82, "phase": "Сборка рельефа и коллизии"},
]


func _ready() -> void:
	print("=== Снимки экрана загрузки ===")
	var overlay: CanvasLayer = LOADING_OVERLAY.new()
	add_child(overlay)

	for shot in SHOTS:
		overlay.set_progress(shot["value"], shot["phase"])
		# Полоса подъезжает к цели плавно (LoadingOverlay.SMOOTHING) — снимать
		# сразу нельзя, поймаем незаполненную. Даём ей доехать.
		for _i in 40:
			await get_tree().process_frame
		# Кадр должен быть уже НАРИСОВАН, иначе снимем предыдущий.
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path: String = "%s/%s" % [OUT_DIR, shot["file"]]
		var err := img.save_png(path)
		print("  %s  %s  (%dx%d)" % [
			"OK" if err == OK else "ОШИБКА %d" % err,
			shot["file"], img.get_width(), img.get_height()])

	get_tree().quit(0)
