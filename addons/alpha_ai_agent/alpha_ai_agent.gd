@tool
extends EditorPlugin

var agent_workspace: Control
var main_placeholder: Control
var bottom_placeholder: Control

var main_screen_wrapper: Control
var bottom_panel_wrapper: Control
var bottom_panel_button: Button

var current_location: String = "main_screen" # "main_screen" or "bottom_panel"

func _enable_plugin() -> void:
	print_rich("[color=cyan]⚡ Alpha AI Agent plugin enabled successfully![/color]")

func _enter_tree() -> void:
	var dock_scene := load("res://addons/alpha_ai_agent/ai_dock.tscn") as PackedScene
	if not dock_scene:
		push_error("Alpha AI Agent: Failed to load ai_dock.tscn scene.")
		return

	# 1. Create single shared workspace instance
	agent_workspace = dock_scene.instantiate() as Control
	agent_workspace.set("editor_interface", get_editor_interface())
	agent_workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	agent_workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agent_workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if agent_workspace.has_signal("switch_location_requested"):
		agent_workspace.connect("switch_location_requested", _on_switch_location_requested)

	# 2. Create wrappers
	main_screen_wrapper = MarginContainer.new()
	main_screen_wrapper.name = "AlphaAIMainScreenWrapper"
	main_screen_wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_screen_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_screen_wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL

	bottom_panel_wrapper = MarginContainer.new()
	bottom_panel_wrapper.name = "AlphaAIBottomPanelWrapper"
	bottom_panel_wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bottom_panel_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_panel_wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# 3. Create placeholders
	main_placeholder = _create_placeholder("The AI Agent workspace is open in the Bottom Panel.", "💬 Move Workspace to Main Screen")
	if main_placeholder and main_placeholder.has_user_signal("request_move_here"):
		main_placeholder.connect("request_move_here", func(): move_workspace_to("main_screen"))

	bottom_placeholder = _create_placeholder("The AI Agent workspace is open in the Main Screen.", "💬 Move Workspace to Bottom Panel")
	if bottom_placeholder and bottom_placeholder.has_user_signal("request_move_here"):
		bottom_placeholder.connect("request_move_here", func(): move_workspace_to("bottom_panel"))

	# 4. Register wrappers
	get_editor_interface().get_editor_main_screen().add_child(main_screen_wrapper)
	_make_visible(false)

	bottom_panel_button = add_control_to_bottom_panel(bottom_panel_wrapper, "⚡ Alpha AI Agent")

	# 5. Default location: Main Screen
	move_workspace_to("main_screen")

func move_workspace_to(target_location: String) -> void:
	if not main_screen_wrapper or not bottom_panel_wrapper:
		return

	# Clear children of wrappers
	for child in main_screen_wrapper.get_children():
		main_screen_wrapper.remove_child(child)
	for child in bottom_panel_wrapper.get_children():
		bottom_panel_wrapper.remove_child(child)

	current_location = target_location

	if target_location == "main_screen":
		if agent_workspace:
			main_screen_wrapper.add_child(agent_workspace)
		if bottom_placeholder:
			bottom_panel_wrapper.add_child(bottom_placeholder)
	else:
		if main_placeholder:
			main_screen_wrapper.add_child(main_placeholder)
		if agent_workspace:
			bottom_panel_wrapper.add_child(agent_workspace)
		make_bottom_panel_item_visible(bottom_panel_wrapper)

func _on_switch_location_requested() -> void:
	if current_location == "main_screen":
		move_workspace_to("bottom_panel")
	else:
		move_workspace_to("main_screen")

func _exit_tree() -> void:
	if bottom_panel_button and bottom_panel_wrapper:
		remove_control_from_bottom_panel(bottom_panel_wrapper)
		bottom_panel_button = null

	if main_screen_wrapper and main_screen_wrapper.get_parent():
		main_screen_wrapper.get_parent().remove_child(main_screen_wrapper)

	if agent_workspace:
		agent_workspace.queue_free()
		agent_workspace = null
	if main_placeholder:
		main_placeholder.queue_free()
		main_placeholder = null
	if bottom_placeholder:
		bottom_placeholder.queue_free()
		bottom_placeholder = null
	if main_screen_wrapper:
		main_screen_wrapper.queue_free()
		main_screen_wrapper = null
	if bottom_panel_wrapper:
		bottom_panel_wrapper.queue_free()
		bottom_panel_wrapper = null

func _has_main_screen() -> bool:
	return true

func _make_visible(visible: bool) -> void:
	if main_screen_wrapper:
		main_screen_wrapper.visible = visible

func _get_plugin_name() -> String:
	return "Alpha AI"

func _get_plugin_icon() -> Texture2D:
	if get_editor_interface():
		return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")
	return null

func _create_placeholder(p_info: String, p_btn_text: String) -> Control:
	var container := MarginContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_user_signal("request_move_here")

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "⚡ Alpha AI Agent"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var info := Label.new()
	info.text = p_info
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(info)

	var btn := Button.new()
	btn.text = p_btn_text
	btn.custom_minimum_size = Vector2(240, 36)
	btn.pressed.connect(func(): container.emit_signal("request_move_here"))
	vbox.add_child(btn)

	return container
