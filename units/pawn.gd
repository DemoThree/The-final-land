extends CharacterBody2D

enum tool { HAND, HAMMER, AXE, PICKAXE, KNIFE }
enum state { IDLE, MOVING, GATHERING, BUILDING, ATTACKING, DEAD }

const ANIM_BY_TOOL := {
	tool.HAND: "idle",
	tool.HAMMER: "idle_Hammer",
	tool.AXE: "idel_axe",
	tool.PICKAXE: "run_pickaxe",
	tool.KNIFE: "idel_knife",
}

@export var move_speed: float = 200.0

@export var max_hp: int = 100

@export var attack_damage: int = 10
@export var attack_range: float = 32.0
@export var attack_speed: float = 1.0

@export var gather_amount: int = 1
@export var gather_speed: float = 1.0

var current_tool: tool = tool.HAND
var current_state: state = state.IDLE
var hp: int

signal state_changed(new_state: state)
signal tool_changed(new_tool: tool)
signal hp_changed(current_hp: int, max_value: int)
signal died

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var tool_buttons: Dictionary = {
	tool.HAND: $Control2/hand,
	tool.HAMMER: $Control2/hand2,
	tool.AXE: $Control2/hand3,
	tool.PICKAXE: $Control2/hand4,
	tool.KNIFE: $Control2/hand5,
}

func _ready() -> void:
	hp = max_hp
	for t in tool_buttons:
		var btn: Button = tool_buttons[t]
		btn.visible = true
		btn.pressed.connect(_on_tool_pressed.bind(t))
	_refresh_animation()

func _physics_process(_delta: float) -> void:
	if current_state == state.DEAD:
		return
	if current_state != state.IDLE and current_state != state.MOVING:
		velocity = Vector2.ZERO
		return
	var input_dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	)
	velocity = input_dir.normalized() * move_speed
	move_and_slide()
	_update_state_and_facing(input_dir)

func _update_state_and_facing(input_dir: Vector2) -> void:
	if input_dir.length() > 0.0:
		if current_state == state.IDLE:
			change_state(state.MOVING)
		if input_dir.x > 0.0:
			animated_sprite.flip_h = false
		elif input_dir.x < 0.0:
			animated_sprite.flip_h = true
	elif current_state == state.MOVING:
		change_state(state.IDLE)

func change_state(new_state: state) -> void:
	if new_state == current_state:
		return
	current_state = new_state
	state_changed.emit(new_state)

func _on_tool_pressed(t: tool) -> void:
	if current_state == state.DEAD:
		return
	current_tool = t
	tool_changed.emit(t)
	_refresh_animation()

func _refresh_animation() -> void:
	animated_sprite.play(ANIM_BY_TOOL[current_tool])

func take_damage(amount: int) -> void:
	if current_state == state.DEAD:
		return
	hp = max(0, hp - amount)
	hp_changed.emit(hp, max_hp)
	if hp == 0:
		change_state(state.DEAD)
		died.emit()
