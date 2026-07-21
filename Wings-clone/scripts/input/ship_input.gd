## Интенты управления кораблём, отвязанные от источника ввода.
##
## Корабль читает поля после poll(); конкретный источник (клавиатура/ИИ/сеть) —
## в наследнике. Это шов под сетевой мультиплеер: Ship не знает, откуда взялись
## интенты. См. notes/architecture.md §2.3.
class_name ShipInput
extends RefCounted

var thrust := false
var turn := 0.0            # -1 влево, +1 вправо
var fire_primary := false
var fire_secondary := false


## Обновить интенты за кадр. Переопределяется наследником.
func poll(_delta: float) -> void:
	pass
