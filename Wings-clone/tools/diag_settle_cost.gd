## Диагностика: во что упирается ВРЕМЯ ГЕНЕРАЦИИ уровня.
## Бенч живого тика (tools/bench_live_sand.gd) дважды не уложился в 5-10 минут,
## причём тики в нём ограничены сотнями — значит время съедает не тик, а
## оседание при генерации (SandLevelGen.MAX_SETTLE_TICKS = 20000 на попытку,
## помноженное на число попыток seed'а). Здесь меряем это напрямую и по одной
## попытке, чтобы чинить по факту, а не по догадке.
##
## Запуск: godot --headless --path Wings-clone res://tools/diag_settle_cost.tscn
extends Node

const SAND_SIM := preload("res://scripts/sand/sand_sim.gd")
const SAND_LEVEL_GEN := preload("res://scripts/level/sand_level_gen.gd")
const RULES := preload("res://data/level/default_gen.tres")
const M_SAND := preload("res://data/sand/sand.tres")
const M_STONE := preload("res://data/sand/stone.tres")
const M_WATER := preload("res://data/sand/water.tres")
const M_EARTH := preload("res://data/sand/earth.tres")

const LEVEL_SIZE := Vector2i(2700, 1350)
## Жёсткий потолок ЭТОЙ диагностики — независимо от MAX_SETTLE_TICKS генератора.
const PROBE_TICKS := 6000


func _ready() -> void:
	print("=== Во что упирается оседание при генерации (%s) ===" % DisplayServer.get_name())
	var cell_px: int = RULES.cell_px
	var grid_w := maxi(LEVEL_SIZE.x / cell_px, 16)
	var grid_h := maxi(LEVEL_SIZE.y / cell_px, 16)
	print("Сетка %dx%d = %d клеток, потолок диагностики %d тиков\n" % [
		grid_w, grid_h, grid_w * grid_h, PROBE_TICKS])

	for seed_i in [1337, 1337 + 7919, 1337 + 2 * 7919, 424242]:
		_probe(seed_i, grid_w, grid_h)

	get_tree().quit(0)


## Одна попытка генерации: сколько тиков и миллисекунд до покоя (или до потолка),
## и что именно остаётся активным, если покой так и не наступил.
func _probe(rng_seed: int, grid_w: int, grid_h: int) -> void:
	var sim = SAND_SIM.new()
	sim.setup(grid_w, grid_h, [M_SAND, M_STONE, M_WATER, M_EARTH])
	var p = SAND_LEVEL_GEN._roll(RULES, rng_seed, grid_w)
	var surface_row = SAND_LEVEL_GEN._carve_initial_terrain(sim, grid_w, grid_h, rng_seed, RULES, p)
	for lake in p["lakes"]:
		SAND_LEVEL_GEN._carve_lake(sim, surface_row, grid_w, grid_h, RULES,
			int(lake["cx"]), int(lake["half"]), int(lake["depth"]))

	var water0 := sim.count_material(SAND_LEVEL_GEN.WATER_ID)
	var t0 := Time.get_ticks_usec()
	var ticks := 0
	# Отсечки: на каких тиках симуляция ещё была активна — видно, оседает ли
	# рельеф быстро, а вечно шевелится только вода (гипотеза), или тормозит всё.
	var mark_ticks := [100, 300, 1000, 3000]
	var marks: Array = []
	while sim.is_active() and ticks < PROBE_TICKS:
		sim.step()
		ticks += 1
		if ticks in mark_ticks:
			var r: Rect2i = sim.get_dirty_rect()
			marks.append("t=%d площадь=%d" % [ticks, r.size.x * r.size.y])
	var usec := Time.get_ticks_usec() - t0

	print("seed %d: озёр %d, воды %d клеток" % [rng_seed, p["lakes"].size(), water0])
	print("  оседание: %d тиков, %.0f мс (%.3f мс/тик) -> %s" % [
		ticks, usec / 1000.0, usec / 1000.0 / maxi(ticks, 1),
		"осел" if not sim.is_active() else "НЕ ОСЕЛ (упёрся в потолок)"])
	if not marks.is_empty():
		print("  грязная область: %s" % ", ".join(PackedStringArray(marks)))
	if sim.is_active():
		var r: Rect2i = sim.get_dirty_rect()
		print("  остаточная активность: %s (площадь %d клеток из %d)" % [
			r, r.size.x * r.size.y, grid_w * grid_h])
		print("  что в этой области: %s" % _describe(sim, r))
	print("")


## Из чего состоит остаточно-активная область — чтобы понять, вода это шевелится
## (ожидаемо, edge_creep_chance) или сыпучее так и не осело (это было бы плохо).
func _describe(sim, r: Rect2i) -> String:
	var counts := {}
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			var c: int = sim.get_cell(x, y)
			counts[c] = counts.get(c, 0) + 1
	var names := {0: "пусто", 1: "песок", 2: "камень", 3: "вода", 4: "земля"}
	var parts: Array = []
	for k in counts:
		parts.append("%s=%d" % [names.get(k, str(k)), counts[k]])
	return ", ".join(PackedStringArray(parts))
