## Ввод с клавиатуры через InputMap: экшены p{N}_thrust / _left / _right / _fire / _fire2.
##
## Хотсит на одной клавиатуре — это штатный InputMap оригинала (8 наборов клавиш из
## KEYS.DAT = 8 игроков × 5 действий). Никакого своего опроса клавиш: только чтение
## экшенов. См. notes/architecture.md §2.3.
class_name LocalInput
extends ShipInput

var player: int
var _a_thrust: StringName
var _a_left: StringName
var _a_right: StringName
var _a_fire: StringName
var _a_fire2: StringName


func _init(player_index: int) -> void:
	player = player_index
	var p := "p%d_" % player_index
	_a_thrust = StringName(p + "thrust")
	_a_left = StringName(p + "left")
	_a_right = StringName(p + "right")
	_a_fire = StringName(p + "fire")
	_a_fire2 = StringName(p + "fire2")


func poll(_delta: float) -> void:
	thrust = Input.is_action_pressed(_a_thrust)
	turn = Input.get_axis(_a_left, _a_right)
	fire_primary = Input.is_action_pressed(_a_fire)
	fire_secondary = Input.is_action_pressed(_a_fire2)
