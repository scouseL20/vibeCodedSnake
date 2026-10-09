extends Node2D

## Core snake loop: grid movement on a fixed tick, buffered input, food, growth, collision.
## The snake is pure data (an array of grid cells); all rendering happens in draw callbacks.
## Visuals interpolate between the previous and current tick so movement glides,
## while the simulation itself stays strictly grid-based.
## Two modes: Classic (walls kill) and Zen (walls wrap around). Food and snake are drawn
## on Playfield inside the clipping Board control, so wrapped segments are cut at the edge.
## Plays with keyboard, gamepad or touch (swipe to steer, tap to start/resume), and adapts
## to landscape or portrait: the grid's long side follows the screen's long side.

enum State { READY, PLAYING, PAUSED, GAME_OVER }

const SAVE_PATH := "user://save.cfg"

# The grid is picked from the screen orientation at the start of each round.
const GRID_LANDSCAPE := Vector2i(24, 16)
const GRID_PORTRAIT := Vector2i(16, 24)
# Stretch base resolutions. Portrait uses a smaller short side so text and buttons
# come out larger on a phone held upright.
const BASE_LANDSCAPE := Vector2i(1152, 648)
const BASE_PORTRAIT := Vector2i(540, 960)
# Room kept around the board (base pixels); the top margin holds the HUD.
const BOARD_MARGIN_TOP := 64.0
const BOARD_MARGIN_SIDE := 16.0
const BOARD_MARGIN_BOTTOM := 16.0

const START_LENGTH := 3
const TICK_SECONDS := 0.12
const MIN_TICK_SECONDS := 0.06 # Speed cap, reached at score 20.
const TICK_STEP_PER_FOOD := 0.003
const MAX_BUFFERED_INPUTS := 2

# Touch.
const SWIPE_THRESHOLD := 28.0 # Drag distance (base pixels) before a swipe registers.
const TAP_SLOP := 16.0 # A touch that moves less than this counts as a tap.
const VIBRATE_EAT_MS := 15
const VIBRATE_DEATH_MS := 120
# Ignore restart input briefly after dying, so a held finger or a mashed key
# doesn't skip straight past the game-over screen.
const RESTART_LOCKOUT_SECONDS := 0.5

# Palette.
const BOARD_COLOR := Color("12151c")
const BOARD_ALT_COLOR := Color("151922")
const BOARD_BORDER_COLOR := Color("232a38")
const ZEN_BORDER_COLOR := Color("2a8f86") # Teal border signals the walls are open.
const HEAD_COLOR := Color("7cf29a")
const TAIL_COLOR := Color("1f8f5f")
const FOOD_COLOR := Color("ff5c7a")
const EYE_COLOR := Color("f4f7fb")
const PUPIL_COLOR := Color("0b0d12")

# Feel.
const BOARD_PADDING := 8.0
const BODY_RADIUS_RATIO := 0.42 # Head radius as a fraction of a cell.
const TAIL_TAPER := 0.7 # Tail radius as a fraction of the head's.
const SHAKE_PIXELS := 8.0

@onready var move_timer: Timer = $MoveTimer
@onready var board: Control = $Board
@onready var playfield: Node2D = $Board/Playfield
@onready var score_label: Label = $CanvasLayer/ScoreLabel
@onready var message_label: Label = $CanvasLayer/MessageLabel
@onready var pause_button: Button = $CanvasLayer/PauseButton
@onready var mode_button: Button = $CanvasLayer/ModeButton

var state: State = State.READY
var wrap_walls := false # Zen mode.
var snake: Array[Vector2i] = [] # Head first.
var prev_snake: Array[Vector2i] = [] # Snake as of the previous tick, for interpolation.
var direction := Vector2i.RIGHT
var input_queue: Array[Vector2i] = []
var food := Vector2i.ZERO
var score := 0
var high_score := 0

# Layout.
var grid_size := GRID_LANDSCAPE
var cell_size := 32.0
var board_origin := Vector2.ZERO
var portrait := false

# Last input came from a touchscreen; drives on-screen hints and haptics.
var using_touch := false

# Animation state, driven by tweens and read in the draw callbacks.
var time := 0.0
var eat_pulse := 0.0
var eat_ring := 1.0
var eat_ring_cell := Vector2i.ZERO
var shake := 0.0
var death_flash := 0.0

var _board_style := StyleBoxFlat.new()
var _sfx: Dictionary[StringName, AudioStreamPlayer] = {}
var _last_won := false
var _last_new_best := false
var _game_over_time := 0.0

# Swipe tracking for the first finger down.
var _touch_index := -1
var _touch_start := Vector2.ZERO
var _touch_anchor := Vector2.ZERO
var _touch_swiped := false


func _ready() -> void:
	_board_style.bg_color = BOARD_COLOR
	_board_style.set_border_width_all(2)
	_board_style.set_corner_radius_all(12)
	_build_sfx()

	move_timer.timeout.connect(_on_move_timer_timeout)
	playfield.draw.connect(_draw_playfield)
	pause_button.pressed.connect(_on_pause_button_pressed)
	mode_button.pressed.connect(_toggle_mode)
	get_viewport().size_changed.connect(_update_layout)
	_load_save()
	_update_layout()
	_reset()


func _process(delta: float) -> void:
	time += delta
	# Shake the whole node; the HUD lives on a CanvasLayer so it stays put.
	position = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * SHAKE_PIXELS * shake
	# Only the playfield animates; the board itself redraws on layout changes.
	playfield.queue_redraw()


func _notification(what: int) -> void:
	# Never let the player die while alt-tabbed, switching browser tabs or backgrounded.
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		_touch_index = -1 # A finger held while focus is lost may never report its release.
		if state == State.PLAYING:
			_set_paused(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_handle_touch(event)
		return
	if event is InputEventKey or event is InputEventJoypadButton:
		_set_using_touch(false)

	if _is_pause_event(event) and state in [State.PLAYING, State.PAUSED]:
		_set_paused(state == State.PLAYING)
		return

	if event.is_action_pressed("ui_accept"):
		_accept()
		return

	if _is_key(event, KEY_M) and state in [State.READY, State.GAME_OVER]:
		_toggle_mode()
		return

	var dir := _direction_from_event(event)
	if dir != Vector2i.ZERO:
		if state == State.READY:
			_start() # A direction on the title screen starts the game, same as a swipe.
		_queue_direction(dir)


## Space / Enter / tap: start, resume or restart depending on state.
func _accept() -> void:
	match state:
		State.READY:
			_start()
		State.PAUSED:
			_set_paused(false)
		State.GAME_OVER:
			if _restart_locked():
				return
			_reset()
			_start()


func _restart_locked() -> bool:
	return state == State.GAME_OVER and time - _game_over_time < RESTART_LOCKOUT_SECONDS


func _direction_from_event(event: InputEvent) -> Vector2i:
	if event.is_action_pressed("ui_up"):
		return Vector2i.UP
	if event.is_action_pressed("ui_down"):
		return Vector2i.DOWN
	if event.is_action_pressed("ui_left"):
		return Vector2i.LEFT
	if event.is_action_pressed("ui_right"):
		return Vector2i.RIGHT

	# WASD alongside the built-in arrow/gamepad ui_* actions.
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_W:
				return Vector2i.UP
			KEY_S:
				return Vector2i.DOWN
			KEY_A:
				return Vector2i.LEFT
			KEY_D:
				return Vector2i.RIGHT
	return Vector2i.ZERO


func _is_pause_event(event: InputEvent) -> bool:
	return event.is_action_pressed("ui_cancel") or _is_key(event, KEY_P)


## Mnemonic shortcuts (M for mode, P for pause) follow the printed key label,
## unlike WASD which is matched by physical position.
func _is_key(event: InputEvent, keycode: Key) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == keycode


## Swipes steer as soon as the drag passes the threshold, without lifting the finger,
## and re-anchor so one continuous drag can chain several turns. A short touch is a tap.
func _handle_touch(event: InputEvent) -> void:
	_set_using_touch(true)

	if event is InputEventScreenTouch:
		if event.pressed:
			# Only the first finger steers, and touches on HUD buttons belong to them.
			# A new press on the tracked index means its release was lost: take it over.
			if (_touch_index != -1 and event.index != _touch_index) \
					or _is_over_button(event.position):
				return
			_touch_index = event.index
			_touch_start = event.position
			_touch_anchor = event.position
			_touch_swiped = false
		elif event.index == _touch_index:
			_touch_index = -1
			var is_tap: bool = not _touch_swiped \
					and event.position.distance_to(_touch_start) < TAP_SLOP
			if is_tap and state != State.PLAYING:
				_accept()

	elif event is InputEventScreenDrag and event.index == _touch_index:
		var delta: Vector2 = event.position - _touch_anchor
		if delta.length() < SWIPE_THRESHOLD:
			return
		_touch_anchor = event.position
		_touch_swiped = true
		if state == State.READY:
			_start() # Swiping on the title screen starts straight away in that direction.
		_queue_direction(_dominant_direction(delta))


func _dominant_direction(delta: Vector2) -> Vector2i:
	if absf(delta.x) > absf(delta.y):
		return Vector2i.RIGHT if delta.x > 0.0 else Vector2i.LEFT
	return Vector2i.DOWN if delta.y > 0.0 else Vector2i.UP


func _is_over_button(pos: Vector2) -> bool:
	for button: Button in [pause_button, mode_button]:
		if button.is_visible_in_tree() and button.get_global_rect().has_point(pos):
			return true
	return false


func _set_using_touch(value: bool) -> void:
	if using_touch == value:
		return
	using_touch = value
	if message_label.visible:
		message_label.text = _message_text() # Swap key hints for touch hints in place.


func _on_pause_button_pressed() -> void:
	if state == State.PLAYING:
		_set_paused(true)


## Queue turns so two quick presses within one tick both register,
## and validate against the last queued turn so the snake can never reverse into itself.
func _queue_direction(dir: Vector2i) -> void:
	if state != State.PLAYING:
		return
	var last: Vector2i = input_queue.back() if not input_queue.is_empty() else direction
	if dir == last or dir == -last:
		return
	if input_queue.size() < MAX_BUFFERED_INPUTS:
		input_queue.append(dir)


func _on_move_timer_timeout() -> void:
	prev_snake = snake.duplicate()
	if not input_queue.is_empty():
		direction = input_queue.pop_front()

	var new_head := snake[0] + direction
	if wrap_walls:
		new_head = _wrap(new_head)
	var grows := new_head == food

	# The tail vacates its cell this tick unless we're growing, so the head may follow it.
	var blocking: Array[Vector2i] = snake if grows else snake.slice(0, snake.size() - 1)
	if not _in_bounds(new_head) or new_head in blocking:
		_game_over(false)
		return

	snake.push_front(new_head)
	if grows:
		score += 1
		_update_score()
		_update_speed()
		_play_eat_feedback(new_head)
		# Rising pitch as the score climbs makes a streak feel like it's building.
		_play_sfx(&"eat", 1.0 + minf(score, 20) * 0.02)
		_vibrate(VIBRATE_EAT_MS)
		_spawn_food()
	else:
		snake.pop_back()


func _reset() -> void:
	# A fresh round adopts the current orientation; mid-round rotation keeps the grid.
	grid_size = GRID_PORTRAIT if portrait else GRID_LANDSCAPE
	_layout_board()

	var start_cell := grid_size / Vector2i(4, 2)
	snake.clear()
	for i in START_LENGTH:
		snake.append(start_cell - Vector2i(i, 0))
	prev_snake = snake.duplicate()
	direction = Vector2i.RIGHT
	input_queue.clear()
	score = 0
	high_score = _load_value("scores", _high_score_key(), 0)
	move_timer.wait_time = TICK_SECONDS
	_update_score()
	_spawn_food()
	state = State.READY
	_board_style.border_color = ZEN_BORDER_COLOR if wrap_walls else BOARD_BORDER_COLOR
	queue_redraw()
	_show_message()


func _toggle_mode() -> void:
	if _restart_locked():
		return
	wrap_walls = not wrap_walls
	_save_value("settings", "wrap_walls", wrap_walls)
	_play_sfx(&"pause", 1.25)
	_reset()


func _start() -> void:
	state = State.PLAYING
	_hide_message()
	move_timer.paused = false
	move_timer.start()
	_play_sfx(&"start")


func _set_paused(paused: bool) -> void:
	state = State.PAUSED if paused else State.PLAYING
	move_timer.paused = paused
	_play_sfx(&"pause", 1.0 if paused else 1.25)
	if paused:
		_show_message()
	else:
		_hide_message()


func _game_over(won: bool) -> void:
	state = State.GAME_OVER
	move_timer.stop()
	_play_death_feedback()
	_play_sfx(&"win" if won else &"die")
	_vibrate(VIBRATE_DEATH_MS)
	_game_over_time = time

	_last_won = won
	_last_new_best = score > high_score
	if _last_new_best:
		high_score = score
		_save_value("scores", _high_score_key(), high_score)
		_update_score()
	_show_message()


## Overlay text for the current state, worded for touch or keyboard.
func _message_text() -> String:
	match state:
		State.READY:
			if using_touch:
				return "SNAKE\n\nSwipe to steer\nTap II (top right) to pause\n\nTap or swipe to start"
			return "SNAKE\n\nArrows / WASD to move\nEsc / P to pause  ·  M to change mode" \
					+ "\n\nPress Space to start"
		State.PAUSED:
			return "PAUSED\n\n" + ("Tap to resume" if using_touch else "Press Space or Esc to resume")
		State.GAME_OVER:
			var lines: PackedStringArray = [
				"YOU WIN!" if _last_won else "GAME OVER", "", "Score: %d" % score]
			if _last_new_best:
				lines.append("New best!")
			lines.append("")
			lines.append("Tap to restart" if using_touch else "Press Space to restart")
			return "\n".join(lines)
	return ""


func _show_message() -> void:
	message_label.text = _message_text()
	message_label.show()
	message_label.modulate.a = 0.0
	create_tween().tween_property(message_label, "modulate:a", 1.0, 0.2)
	_update_buttons()


func _hide_message() -> void:
	message_label.hide()
	_update_buttons()


func _update_buttons() -> void:
	pause_button.visible = state == State.PLAYING
	mode_button.visible = state in [State.READY, State.GAME_OVER]
	mode_button.text = "Mode: " + ("ZEN  ·  walls wrap" if wrap_walls else "CLASSIC")


## Each food eaten shortens the tick a little, down to MIN_TICK_SECONDS.
func _update_speed() -> void:
	move_timer.wait_time = maxf(MIN_TICK_SECONDS, TICK_SECONDS - score * TICK_STEP_PER_FOOD)
	move_timer.start() # Restart so the very next tick already uses the new speed.


func _build_sfx() -> void:
	var streams: Dictionary[StringName, AudioStream] = {
		&"eat": SfxSynth.sweep(520.0, 1040.0, 0.08),
		&"start": SfxSynth.sweep(330.0, 660.0, 0.14),
		&"pause": SfxSynth.sweep(600.0, 420.0, 0.06, 0.18),
		&"die": SfxSynth.sweep(320.0, 50.0, 0.5, 0.3, 0.35),
		&"win": SfxSynth.sweep(440.0, 1320.0, 0.6),
	}
	for sfx_name in streams:
		var player := AudioStreamPlayer.new()
		player.stream = streams[sfx_name]
		add_child(player)
		_sfx[sfx_name] = player


func _play_sfx(sfx_name: StringName, pitch := 1.0) -> void:
	var player := _sfx[sfx_name]
	player.pitch_scale = pitch
	player.play()


## Haptics only when playing by touch; a no-op on desktop and iOS browsers.
func _vibrate(duration_ms: int) -> void:
	if using_touch:
		Input.vibrate_handheld(duration_ms)


func _play_eat_feedback(cell: Vector2i) -> void:
	eat_ring_cell = cell
	var tween := create_tween().set_parallel()
	tween.tween_property(self, "eat_pulse", 0.0, 0.25).from(1.0)
	tween.tween_property(self, "eat_ring", 1.0, 0.35).from(0.0) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

	score_label.pivot_offset = score_label.size / 2.0
	tween.tween_property(score_label, "scale", Vector2.ONE, 0.25).from(Vector2.ONE * 1.3) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


func _play_death_feedback() -> void:
	var tween := create_tween().set_parallel()
	tween.tween_property(self, "shake", 0.0, 0.35).from(1.0)
	tween.tween_property(self, "death_flash", 0.0, 0.45).from(1.0)


func _load_save() -> void:
	wrap_walls = _load_value("settings", "wrap_walls", false)


## One best score per mode and grid orientation, since the boards differ in shape.
## Classic landscape keeps the original key so existing saves carry over.
func _high_score_key() -> String:
	var key := "high_score_zen" if wrap_walls else "high_score"
	if grid_size == GRID_PORTRAIT:
		key += "_portrait"
	return key


func _load_value(section: String, key: String, default: Variant) -> Variant:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return default
	return config.get_value(section, key, default)


func _save_value(section: String, key: String, value: Variant) -> void:
	var config := ConfigFile.new()
	config.load(SAVE_PATH) # Keep any other saved keys; a missing file is fine.
	config.set_value(section, key, value)
	var err := config.save(SAVE_PATH)
	if err != OK:
		push_warning("Could not save %s/%s: %s" % [section, key, error_string(err)])


func _spawn_food() -> void:
	var free_cells: Array[Vector2i] = []
	for y in grid_size.y:
		for x in grid_size.x:
			var cell := Vector2i(x, y)
			if cell not in snake:
				free_cells.append(cell)
	if free_cells.is_empty():
		_game_over(true)
		return
	food = free_cells.pick_random()


func _update_score() -> void:
	score_label.text = "%s    Score: %d    Best: %d" \
			% ["ZEN" if wrap_walls else "CLASSIC", score, high_score]


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < grid_size.x and cell.y < grid_size.y


func _wrap(cell: Vector2i) -> Vector2i:
	return Vector2i(posmod(cell.x, grid_size.x), posmod(cell.y, grid_size.y))


## Shortest offset between two cell positions; in Zen mode this crosses the board edge.
func _cell_delta(from: Vector2, to: Vector2) -> Vector2:
	var d := to - from
	if wrap_walls:
		d.x -= roundf(d.x / grid_size.x) * grid_size.x
		d.y -= roundf(d.y / grid_size.y) * grid_size.y
	return d


## Swap the stretch base resolution to match the screen orientation, then refit the board.
func _update_layout() -> void:
	var window := get_window()
	if window.size.x <= 0 or window.size.y <= 0:
		return # Minimized: keep the last layout instead of fitting to nothing.
	var now_portrait := window.size.y > window.size.x
	var base := BASE_PORTRAIT if now_portrait else BASE_LANDSCAPE
	if window.content_scale_size != base:
		window.content_scale_size = base

	var rotated := now_portrait != portrait
	portrait = now_portrait
	_layout_board()

	if rotated:
		match state:
			State.READY:
				_reset() # Nothing at stake yet: switch to the grid that fits.
			State.PLAYING:
				_set_paused(true) # Give the player a beat to re-grip the phone.


## Fit the current grid into the viewport with the largest whole-pixel cell size.
func _layout_board() -> void:
	var view := get_viewport_rect().size
	var avail := view - Vector2(BOARD_MARGIN_SIDE * 2.0, BOARD_MARGIN_TOP + BOARD_MARGIN_BOTTOM)
	cell_size = maxf(1.0, floorf(minf(avail.x / grid_size.x, avail.y / grid_size.y)))
	var board_px := Vector2(grid_size) * cell_size
	board_origin = Vector2((view.x - board_px.x) / 2.0,
			BOARD_MARGIN_TOP + (avail.y - board_px.y) / 2.0)
	board.position = board_origin
	board.size = board_px

	# Keep the HUD attached to the board's top edge rather than the screen's,
	# so tall portrait screens don't leave the score floating far above it.
	var hud_bottom := board_origin.y - BOARD_PADDING - 4.0
	score_label.position.y = hud_bottom - score_label.size.y
	pause_button.position = Vector2(board_origin.x + board_px.x + BOARD_PADDING - pause_button.size.x,
			hud_bottom - pause_button.size.y)
	queue_redraw()


## 0..1 progress through the current tick; 1 when the snake isn't moving.
func _move_progress() -> float:
	if move_timer.is_stopped():
		return 1.0
	return clampf(1.0 - move_timer.time_left / move_timer.wait_time, 0.0, 1.0)


func _body_radius() -> float:
	return cell_size * BODY_RADIUS_RATIO


## Playfield-local pixel center of a (fractional) cell position.
func _cell_center(cell: Vector2) -> Vector2:
	return (cell + Vector2(0.5, 0.5)) * cell_size


## Interpolated segment positions in cell units, as one continuous chain:
## across a wrap seam the chain runs off the board edge rather than jumping,
## so connecting lines never span the whole board.
func _segment_cells() -> PackedVector2Array:
	var t := _move_progress()
	var cells := PackedVector2Array()
	for i in snake.size():
		# A freshly grown tail segment has no previous position; it holds still.
		var from_cell: Vector2i = prev_snake[i] if i < prev_snake.size() else snake[i]
		var from := Vector2(from_cell)
		var pos := from + _cell_delta(from, Vector2(snake[i])) * t
		if i > 0:
			pos = cells[i - 1] + _cell_delta(cells[i - 1], pos)
		cells.append(pos)
	return cells


## Board-sized offsets at which the chain must be redrawn so every part that ran off
## one edge shows up on the opposite one. The Board control clips the excess.
func _wrap_offsets(cells: PackedVector2Array) -> PackedVector2Array:
	var offsets := PackedVector2Array([Vector2.ZERO])
	if not wrap_walls:
		return offsets
	var lo := cells[0]
	var hi := cells[0]
	for c in cells:
		lo = lo.min(c)
		hi = hi.max(c)
	offsets.clear()
	var size := Vector2(grid_size)
	for kx in range(floori(-hi.x / size.x), ceili((size.x - lo.x) / size.x) + 1):
		for ky in range(floori(-hi.y / size.y), ceili((size.y - lo.y) / size.y) + 1):
			offsets.append(Vector2(kx, ky) * size)
	return offsets


## Static board: only redrawn on layout or mode changes, not every frame.
func _draw() -> void:
	var board_rect := Rect2(board_origin, Vector2(grid_size) * cell_size)
	draw_style_box(_board_style, board_rect.grow(BOARD_PADDING))
	for y in grid_size.y:
		for x in grid_size.x:
			if (x + y) % 2 == 0:
				var pos := board_origin + Vector2(x, y) * cell_size
				draw_rect(Rect2(pos, Vector2(cell_size, cell_size)), BOARD_ALT_COLOR)


func _draw_playfield() -> void:
	_draw_food()
	_draw_eat_ring()
	var cells := _segment_cells()
	for offset in _wrap_offsets(cells):
		_draw_snake(cells, offset)


func _draw_food() -> void:
	var center := _cell_center(Vector2(food))
	var radius := cell_size * 0.28 * (1.0 + 0.08 * sin(time * 6.0))
	for k in 3:
		var glow := FOOD_COLOR
		glow.a = 0.07
		playfield.draw_circle(center, radius * (1.5 + 0.5 * k), glow)
	playfield.draw_circle(center, radius, FOOD_COLOR)
	playfield.draw_circle(center + Vector2(-0.3, -0.3) * radius, radius * 0.3, Color(1, 1, 1, 0.45))


func _draw_eat_ring() -> void:
	if eat_ring >= 1.0:
		return
	var color := FOOD_COLOR
	color.a = 1.0 - eat_ring
	var radius := cell_size * (0.3 + 0.9 * eat_ring)
	playfield.draw_arc(_cell_center(Vector2(eat_ring_cell)), radius, 0.0, TAU, 32, color, 3.0, true)


func _draw_snake(cells: PackedVector2Array, offset: Vector2) -> void:
	var points := PackedVector2Array()
	for c in cells:
		points.append(_cell_center(c + offset))
	var last := points.size() - 1
	var body_radius := _body_radius()

	# Tail to head so the head is drawn on top.
	for i in range(last, -1, -1):
		var w := float(i) / maxf(last, 1)
		var color := HEAD_COLOR.lerp(TAIL_COLOR, w).lerp(Color.WHITE, death_flash)
		var radius := body_radius * lerpf(1.0, TAIL_TAPER, w)
		if i < last:
			# Bridge to the next (thinner) segment so the body reads as one tube.
			var next_radius := body_radius * lerpf(1.0, TAIL_TAPER, float(i + 1) / last)
			playfield.draw_line(points[i], points[i + 1], color, next_radius * 2.0)
		if i == 0:
			radius *= 1.0 + 0.25 * eat_pulse
		playfield.draw_circle(points[i], radius, color)

	_draw_eyes(points[0], body_radius * (1.0 + 0.25 * eat_pulse))


func _draw_eyes(head: Vector2, radius: float) -> void:
	var forward := Vector2(direction)
	var side := Vector2(-forward.y, forward.x)
	for s: float in [-1.0, 1.0]:
		var eye := head + forward * radius * 0.3 + side * radius * 0.45 * s
		playfield.draw_circle(eye, radius * 0.28, EYE_COLOR)
		playfield.draw_circle(eye + forward * radius * 0.1, radius * 0.14, PUPIL_COLOR)
