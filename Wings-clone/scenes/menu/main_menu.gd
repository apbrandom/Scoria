## Главное меню — точка входа проекта (project.godot run/main_scene).
##
## Это простой переключатель сцен (get_tree().change_scene_to_file), а НЕ тот
## архитектурный Main из architecture.md §2.1 (Main/MatchManager/LevelHost —
## персистентный корень для смены уровней ВНУТРИ одного матча). Тот пока не
## нужен: level.tscn по-прежнему сам себе хозяин (спавнит свой MatchManager
## ребёнком), это меню лишь решает, КАКУЮ сцену открыть, и выставляет
## GameRules.player_count перед этим — тот же паттерн, что kills_per_level и
## прочие поля GameRules, уже читаемые Level/MatchManager.
##
## Режим "По сети" ведёт в отдельный подэкран «Создать игру (хост)» /
## «Присоединиться» — заказчик явно попросил ВИДЕТЬ и ВЫБИРАТЬ роль руками, а
## не полагаться на автогонку за bind порта (та осталась в net_playground.gd
## как фолбэк для запуска в обход меню, см. его шапку). Выбор кладётся в
## GameRules.net_forced_role ДО смены сцены — тот же паттерн, что
## player_count для level.tscn. «Присоединиться» всегда бьёт в 127.0.0.1:
## расчёт на два окна ОДНОГО компьютера (Debug → Customize Run Instances →
## Enable Multiple Instances) — для другого адреса по-прежнему нужен CLI-флаг
## `-- --join=<ip>`, меню его не заменяет.
##
## Раздел «Разработка» (ниже) — служебные прогоны для заказчика/разработки,
## В РЕЛИЗ НЕ ИДЁТ: кнопка скрыта в export-сборке release-шаблоном и видна
## только в editor/debug-сборке (OS.has_feature("debug") — штатный тег Godot,
## "Running on a debug build (including the editor)", истинен и в редакторе, и
## в debug-экспорте, ложен только в release-шаблоне для настоящего релиза).
extends Control

const LEVEL_SCENE := "res://scenes/level/level.tscn"
const NET_PLAYGROUND_SCENE := "res://scenes/level/net_playground.tscn"
const SAND_PLAYGROUND_SCENE := "res://tools/sand_playground.tscn"

@onready var _main_buttons: Control = %MainButtons
@onready var _mode_buttons: Control = %ModeButtons
@onready var _net_buttons: Control = %NetButtons
@onready var _dev_button: Control = %DevButton
@onready var _dev_buttons: Control = %DevButtons


func _ready() -> void:
	# Не visible=false в самой .tscn — тогда кнопка была бы скрыта и в
	# editor/debug тоже, где её как раз и нужно видеть.
	_dev_button.visible = OS.has_feature("debug")
	_show_main()


func _on_play_pressed() -> void:
	_show_modes()


func _on_back_pressed() -> void:
	_show_main()


func _on_single_pressed() -> void:
	_set_single_player()
	get_tree().change_scene_to_file(LEVEL_SCENE)


func _on_local_two_pressed() -> void:
	_set_local_two_player()
	get_tree().change_scene_to_file(LEVEL_SCENE)


func _on_network_pressed() -> void:
	_show_net()


func _on_net_back_pressed() -> void:
	_show_modes()


func _on_host_pressed() -> void:
	_set_host_role()
	get_tree().change_scene_to_file(NET_PLAYGROUND_SCENE)


func _on_join_pressed() -> void:
	_set_join_role()
	get_tree().change_scene_to_file(NET_PLAYGROUND_SCENE)


## Запись в GameRules вынесена из _on_*_pressed отдельными методами — не ради
## самого по себе разделения, а чтобы tools/test_menu.gd мог проверить ЧТО
## записывается, не вызывая следом реальный change_scene_to_file(): тот
## запускает по-настоящему net_playground.tscn (реальный ENet-хост на порту)
## или level.tscn, и вызванный несколько раз подряд в одном headless-прогоне
## (все четыре обработчика в одном тесте) роняет движок ("Parent node is busy
## adding/removing children") — обнаружено эмпирически при попытке написать
## тест "в лоб" через сами _on_*_pressed.
func _set_single_player() -> void:
	GameRules.player_count = 1


func _set_local_two_player() -> void:
	GameRules.player_count = 2


func _set_host_role() -> void:
	GameRules.net_forced_role = "host"


func _set_join_role() -> void:
	GameRules.net_forced_role = "join"


func _on_exit_pressed() -> void:
	get_tree().quit()


func _on_dev_pressed() -> void:
	_show_dev()


func _on_dev_back_pressed() -> void:
	_show_main()


## Смотреть бой ботов — это НЕ отдельная сцена, а тот же боевой level.tscn с
## обоими кораблями под ИИ: путь уже собран и проверен (GameRules.bot_count,
## scripts/input/ai_input.gd, devlog §53), здесь только настройка перед
## change_scene_to_file — тот же паттерн, что у остальных пунктов меню.
func _on_bot_sim_pressed() -> void:
	_set_bot_simulation()
	get_tree().change_scene_to_file(LEVEL_SCENE)


func _on_physics_sim_pressed() -> void:
	get_tree().change_scene_to_file(SAND_PLAYGROUND_SCENE)


func _set_bot_simulation() -> void:
	GameRules.player_count = 2
	GameRules.bot_count = 2


func _show_main() -> void:
	_main_buttons.visible = true
	_mode_buttons.visible = false
	_net_buttons.visible = false
	_dev_buttons.visible = false


func _show_modes() -> void:
	_main_buttons.visible = false
	_mode_buttons.visible = true
	_net_buttons.visible = false
	_dev_buttons.visible = false


func _show_net() -> void:
	_main_buttons.visible = false
	_mode_buttons.visible = false
	_net_buttons.visible = true
	_dev_buttons.visible = false


func _show_dev() -> void:
	_main_buttons.visible = false
	_mode_buttons.visible = false
	_net_buttons.visible = false
	_dev_buttons.visible = true
