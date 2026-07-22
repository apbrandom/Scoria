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
extends Control

const LEVEL_SCENE := "res://scenes/level/level.tscn"
const NET_PLAYGROUND_SCENE := "res://scenes/level/net_playground.tscn"

@onready var _main_buttons: Control = %MainButtons
@onready var _mode_buttons: Control = %ModeButtons
@onready var _net_buttons: Control = %NetButtons


func _ready() -> void:
	_show_main()


func _on_play_pressed() -> void:
	_show_modes()


func _on_back_pressed() -> void:
	_show_main()


func _on_single_pressed() -> void:
	GameRules.player_count = 1
	get_tree().change_scene_to_file(LEVEL_SCENE)


func _on_local_two_pressed() -> void:
	GameRules.player_count = 2
	get_tree().change_scene_to_file(LEVEL_SCENE)


func _on_network_pressed() -> void:
	_show_net()


func _on_net_back_pressed() -> void:
	_show_modes()


func _on_host_pressed() -> void:
	GameRules.net_forced_role = "host"
	get_tree().change_scene_to_file(NET_PLAYGROUND_SCENE)


func _on_join_pressed() -> void:
	GameRules.net_forced_role = "join"
	get_tree().change_scene_to_file(NET_PLAYGROUND_SCENE)


func _on_exit_pressed() -> void:
	get_tree().quit()


func _show_main() -> void:
	_main_buttons.visible = true
	_mode_buttons.visible = false
	_net_buttons.visible = false


func _show_modes() -> void:
	_main_buttons.visible = false
	_mode_buttons.visible = true
	_net_buttons.visible = false


func _show_net() -> void:
	_main_buttons.visible = false
	_mode_buttons.visible = false
	_net_buttons.visible = true
