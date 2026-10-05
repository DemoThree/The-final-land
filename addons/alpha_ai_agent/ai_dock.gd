@tool
extends MarginContainer

signal switch_location_requested

var editor_interface: EditorInterface
var config: AIConfig
var network: AINetwork
var execution_engine: ExecutionEngine
var project_context: ProjectContext

# ─── Agent State Machine ─────────────────────────────────────────────────────
# Refactor #2: Strict state enum enforced at dock level.
# Every new user prompt RESETS state to IDLE and clears loop counters.
enum AgentState {
	IDLE,
	PLANNING,       # Round 1: agent receives user goal and creates a plan + first action batch
	EXECUTING,      # Applying file changes to disk
	VERIFYING,      # Running the project and reading logs
	REFLECTING,     # Agent reviewing verification results and deciding next action
	DONE,
	COMPLETED       # Alias for DONE (pipeline compatibility)
}

var _state: AgentState = AgentState.IDLE
var _agent_round: int = 0
var _max_agent_rounds: int = 10          # raised to allow complex multi-step tasks
var _agent_loop_enabled: bool = true
var _is_generating: bool = false
var _missing_json_retry_count: int = 0
var _last_action_signature: String = ""
var _last_runtime_errors: String = ""
var _last_debug_output: String = ""      # most recent ACTUAL captured stdout from verification
var _consecutive_empty_rounds: int = 0   # guard against infinite "nothing to do" loops
var _user_verification_count: int = 0    # how many times we asked user to interact (prevent loops)
var _self_corruption_count: int = 0      # rounds where agent's OWN changes caused new errors
var _last_modified_files: Array[String] = []  # files modified in the most recent round
var _user_goal: String = ""              # original user request, kept for continuity prompts
var _total_actions_executed: int = 0      # track actual file modifications on disk
var _hallucination_count: int = 0         # track hallucination detections to break loops
var _is_read_only_request: bool = false   # true if request only needs to read files, no modifications
var _pipeline: AIPipeline = AIPipeline.new()  # pipeline for state/history management
var _ai_run_duration: int = 0             # seconds AI wants game to run, 0 = use default (5s)
# Archived sub-task context injected into each prompt to prevent re-verification bleed
var _archived_context_prefix: String = ""

var pending_actions: Array[Dictionary] = []
var attached_files: Array[String] = []
var chat_history: Array[Dictionary] = []
var file_dialog: EditorFileDialog
var _is_initializing: bool = true
var git_manager: AIGitManager
const AIDiffWindowScene = preload("res://addons/alpha_ai_agent/ai_diff_window.tscn")
var _diff_window_instance: Window

# ─── Version Checker Constants & Variables ─────────────────────────────────────
const PLUGIN_CURRENT_VERSION: String = "0.57.3"
const VERSION_CHECK_URL: String = "https://mdabunafisniloy.github.io/alpha-ai-plugin-version/"
const UPDATE_REDIRECT_URL: String = "https://nafisniloy.itch.io/alpha-ai-agent"

var _version_http_request: HTTPRequest
var _version_check_timer: Timer
var _update_popup_dialog: AcceptDialog
var _latest_detected_version: String = ""

# ─── Remote Notice System ─────────────────────────────────────────────────────
const DISMISSED_NOTICES_FILE := "user://ai_agent_dismissed_notices.json"
const DISCORD_URL: String = "https://discord.gg/sWM8xUEq9"
const GITHUB_ISSUES_URL: String = "https://github.com/mdabunafisniloy/Alpha-Ai-Plugin/issues"

var _notice_popup_dialog: AcceptDialog
var _pending_notice_data: Variant = null
var support_dev_btn: Button
var discord_btn: Button
var report_bug_btn: Button
var clear_keys_btn: Button

# ─────────────────────────────────────────────────────────────────────────────
# VISUAL CIRCULAR USAGE BADGE (Dynamic Radial Progress Ring)
# ─────────────────────────────────────────────────────────────────────────────
class UsageCircleBadge extends Control:
	var percent_remaining: float = 100.0
	var tooltip_details: String = "Free Mode: 100% usage left today"

	func _init() -> void:
		custom_minimum_size = Vector2(22, 22)
		mouse_filter = MOUSE_FILTER_STOP

	func set_usage(pct: float, details: String) -> void:
		percent_remaining = clamp(pct, 0.0, 100.0)
		tooltip_details = details
		tooltip_text = details
		queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var radius: float = min(size.x, size.y) * 0.42
		var width := 3.0
		
		# Draw dark background track ring
		draw_arc(center, radius, 0, TAU, 32, Color(0.2, 0.25, 0.35, 0.7), width, true)
		
		# Fill progress arc from top 12 o'clock (-PI/2)
		var fill_pct := percent_remaining / 100.0
		var start_angle := -PI * 0.5
		var end_angle := start_angle + (fill_pct * TAU)
		
		var ring_color := Color(0.35, 0.85, 1.0) # cyan
		if percent_remaining < 20.0:
			ring_color = Color(1.0, 0.35, 0.35) # red
		elif percent_remaining < 50.0:
			ring_color = Color(1.0, 0.7, 0.2) # orange
			
		if fill_pct > 0.005:
			draw_arc(center, radius, start_angle, end_angle, 32, ring_color, width, true)

var usage_circle_badge: UsageCircleBadge = null

# ── Header Controls ──────────────────────────────────────────────────────────
@onready var quick_model_option: OptionButton     = %QuickModelOption
@onready var tab_btn_chat: Button                 = %TabBtnChat
@onready var tab_btn_settings: Button             = %TabBtnSettings
@onready var reload_plugin_btn: Button            = %ReloadPluginBtn
@onready var switch_loc_btn: Button               = %SwitchLocBtn
@onready var copy_all_btn: Button                 = %CopyAllBtn
@onready var diff_btn: Button                     = %DiffBtn
@onready var revert_btn: Button                   = %RevertBtn
@onready var agent_loop_toggle: CheckButton       = %AgentLoopToggle

# ── Chat Controls ─────────────────────────────────────────────────────────────
@onready var chat_bubble_list: VBoxContainer      = %ChatBubbleList
@onready var chat_scroll: ScrollContainer         = %ChatScrollContainer
@onready var context_bar_tree: CheckBox           = %TreeCheck
@onready var context_bar_scripts: CheckBox        = %ScriptsCheck
@onready var context_bar_scenes: CheckBox         = %ScenesCheck
@onready var context_bar_assets: CheckBox         = %AssetsCheck
@onready var context_bar_logs: CheckBox           = %LogsCheck
@onready var attach_file_btn: Button              = %AttachFileBtn
@onready var clear_chat_btn: Button               = %ClearChatBtn
@onready var attachments_container: HFlowContainer = %AttachmentsContainer
@onready var prompt_edit: TextEdit                = %PromptEdit
@onready var generate_btn: Button                 = %GenerateBtn
@onready var status_label: Label                  = %StatusLabel
@onready var hint_label: Label                   = %HintLabel

# Autocomplete nodes (found dynamically)
var autocomplete_panel: PanelContainer = null
var autocomplete_list: VBoxContainer = null

# ── Status bar ────────────────────────────────────────────────────────────────
@onready var status_bar: PanelContainer           = %StatusBar
@onready var status_step_label: Label             = %StatusStepLabel
@onready var status_desc_label: Label             = %StatusDescLabel
@onready var spinner_label: Label                 = %SpinnerLabel

# ── Approval panel ────────────────────────────────────────────────────────────
@onready var approval_panel: PanelContainer       = %ApprovalPanel
@onready var changes_list: ItemList               = %ChangesList
@onready var approve_btn: Button                  = %ApproveBtn
@onready var reject_btn: Button                   = %RejectBtn
@onready var approval_round_label: Label          = %ApprovalRoundLabel

# ── Views / Settings ──────────────────────────────────────────────────────────
@onready var chat_view: Control                   = %ChatView
@onready var settings_view: ScrollContainer       = %SettingsView
@onready var welcome_banner: PanelContainer       = %WelcomeBanner
@onready var provider_option: OptionButton        = %ProviderOption
@onready var model_option: OptionButton           = %ModelOption
@onready var refresh_model_btn: Button            = %RefreshModelBtn
@onready var api_key_edit: LineEdit               = %APIKeyEdit
@onready var show_key_btn: Button                 = %ShowKeyBtn
@onready var save_key_btn: Button                 = %SaveKeyBtn
@onready var key_status_label: Label              = %KeyStatusLabel
@onready var free_trial_check: CheckButton         = %FreeTrialCheck
@onready var free_usage_label: Label              = %FreeUsageLabel
@onready var refresh_usage_btn: Button           = %RefreshUsageBtn
@onready var auto_refresh_check: CheckBox        = %AutoRefreshCheck
@onready var auto_refresh_interval: SpinBox      = %AutoRefreshInterval
@onready var last_refresh_label: Label           = %LastRefreshLabel
@onready var temp_slider: HSlider                 = %TempSlider
@onready var temp_label: Label                    = %TempLabel
@onready var use_tokens_check: CheckBox           = %UseTokensCheck
@onready var tokens_spin: SpinBox                 = %TokensSpin
@onready var back_to_chat_btn: Button             = %BackToChatBtn
@onready var console_output: RichTextLabel        = %ConsoleOutput
@onready var clear_console_btn: Button            = %ClearConsoleBtn

# Spinner
var _spinner_chars := ["⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"]
var _spinner_idx := 0
var _spinning := false

var _typing_bubble: Control = null
var _plain_chat_log: String = ""

# Auto-refresh usage timer
var _usage_refresh_timer: Timer = null
var _is_refreshing_usage: bool = false

# Autocomplete state
var _autocomplete_active: bool = false
var _autocomplete_trigger: String = ""  # "/", "@", or "#"
var _autocomplete_start_pos: int = -1
var _autocomplete_suggestions: Array[Dictionary] = []
var _all_project_resources: Array[Dictionary] = []
var _autocomplete_clicking: bool = false

# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	config = AIConfig.new()
	network = AINetwork.new()
	execution_engine = ExecutionEngine.new()
	project_context = ProjectContext.new()
	git_manager = AIGitManager.new("res://")
	add_child(network)
	network.request_started.connect(_on_request_started)
	network.request_completed.connect(_on_request_completed)
	network.request_failed.connect(_on_request_failed)
	network.models_fetched.connect(_on_models_fetched)
	network.models_fetch_failed.connect(_on_models_fetch_failed)
	network.usage_fetched.connect(_on_usage_fetched)
	network.usage_fetch_failed.connect(_on_usage_fetch_failed)

	_setup_ui()
	_update_key_display()
	_populate_model_dropdown()
	_populate_quick_model_option()

	if approval_panel: approval_panel.visible = false
	_clear_status()

	show_view("chat")
	if config.is_using_free_trial_mode():
		_add_bubble("system", "⚡ Alpha AI Agent v" + PLUGIN_CURRENT_VERSION + " ready in Free Trial Mode. Fetching real-time usage...")
		network.fetch_usage(config)
	else:
		_add_bubble("system", "⚡ Alpha AI Agent v" + PLUGIN_CURRENT_VERSION + " ready. Active model: " + config.provider + " › " + config.selected_model)
	
	_setup_version_checker()
	_is_initializing = false

func _process(_delta: float) -> void:
	if _spinning and spinner_label:
		_spinner_idx = (_spinner_idx + 1) % _spinner_chars.size()
		spinner_label.text = _spinner_chars[_spinner_idx]

# ─────────────────────────────────────────────────────────────────────────────
# VIEW SWITCHING
# ─────────────────────────────────────────────────────────────────────────────
func show_view(view_name: String) -> void:
	if chat_view: chat_view.visible = view_name == "chat"
	if settings_view: settings_view.visible = view_name == "settings"
	if tab_btn_chat: tab_btn_chat.button_pressed = view_name == "chat"
	if tab_btn_settings: tab_btn_settings.button_pressed = view_name == "settings"
	if view_name == "settings" and welcome_banner:
		welcome_banner.visible = not config.has_any_api_key()
		_update_key_display()

func _connect_safe(node: Object, signal_name: String, callable: Callable) -> void:
	if node and node.has_signal(signal_name):
		if not node.is_connected(signal_name, callable):
			node.connect(signal_name, callable)

# ─────────────────────────────────────────────────────────────────────────────
# UI SETUP
# ─────────────────────────────────────────────────────────────────────────────
func _setup_ui() -> void:
	if quick_model_option and quick_model_option.get_parent():
		var hb = quick_model_option.get_parent()
		usage_circle_badge = UsageCircleBadge.new()
		hb.add_child(usage_circle_badge)
		hb.move_child(usage_circle_badge, 0)
		if config and config.is_using_free_trial_mode():
			usage_circle_badge.visible = true
			usage_circle_badge.set_usage(config.usage_info.get("percent_remaining", 100.0), config.get_usage_display_text())
		else:
			usage_circle_badge.visible = false

	_connect_safe(switch_loc_btn, "pressed", func(): emit_signal("switch_location_requested"))
	_connect_safe(reload_plugin_btn, "pressed", _on_reload_plugin_pressed)
	_connect_safe(copy_all_btn, "pressed", _on_copy_all_pressed)
	_connect_safe(diff_btn, "pressed", _on_diff_pressed)
	_connect_safe(revert_btn, "pressed", _on_revert_pressed)
	_connect_safe(tab_btn_chat, "pressed", func(): show_view("chat"))
	_connect_safe(tab_btn_settings, "pressed", func(): show_view("settings"))
	_connect_safe(back_to_chat_btn, "pressed", func(): show_view("chat"))
	_connect_safe(quick_model_option, "item_selected", _on_quick_model_selected)
	_connect_safe(agent_loop_toggle, "toggled", func(v): _agent_loop_enabled = v)
	if free_trial_check:
		free_trial_check.button_pressed = config.use_free_trial_mode
		_connect_safe(free_trial_check, "toggled", _on_free_trial_toggled)

	_setup_support_button()
	_setup_clear_keys_button()

	if provider_option:
		provider_option.clear()
		provider_option.add_item("🤖  OpenAI", 0)
		provider_option.add_item("🧠  Anthropic", 1)
		provider_option.add_item("✨  Gemini", 2)
		provider_option.add_item("🌐  OpenRouter", 3)
		provider_option.add_item("🔵  DeepSeek", 4)
		var _pmap := [AIConfig.PROVIDER_OPENAI, AIConfig.PROVIDER_ANTHROPIC, AIConfig.PROVIDER_GEMINI, AIConfig.PROVIDER_OPENROUTER, AIConfig.PROVIDER_DEEPSEEK]
		for idx in range(_pmap.size()):
			if _pmap[idx] == config.provider:
				provider_option.selected = idx
				break

	if context_bar_tree: context_bar_tree.button_pressed    = config.include_tree
	if context_bar_scripts: context_bar_scripts.button_pressed = config.include_scripts
	if context_bar_scenes: context_bar_scenes.button_pressed  = config.include_scenes
	if context_bar_assets: context_bar_assets.button_pressed  = config.include_assets

	if temp_slider:
		temp_slider.value = config.temperature
		temp_label.text = "%.2f" % config.temperature
		_connect_safe(temp_slider, "value_changed", func(v): config.temperature = v; temp_label.text = "%.2f" % v; config.save_config())

	if use_tokens_check:
		use_tokens_check.button_pressed = config.use_max_tokens
		if tokens_spin: tokens_spin.editable = config.use_max_tokens
		_connect_safe(use_tokens_check, "toggled", func(v): config.use_max_tokens = v; if tokens_spin: tokens_spin.editable = v; config.save_config())

	if tokens_spin:
		tokens_spin.value = config.max_tokens
		_connect_safe(tokens_spin, "value_changed", func(v): config.max_tokens = int(v); config.save_config())

	_connect_safe(provider_option, "item_selected", _on_provider_selected)
	_connect_safe(model_option, "item_selected", _on_model_selected)
	_connect_safe(refresh_model_btn, "pressed", _on_refresh_models_pressed)
	
	# Usage refresh button and auto-refresh setup
	_connect_safe(refresh_usage_btn, "pressed", _on_refresh_usage_pressed)
	_connect_safe(auto_refresh_check, "toggled", _on_auto_refresh_toggled)
	_connect_safe(auto_refresh_interval, "value_changed", _on_auto_refresh_interval_changed)
	_setup_auto_refresh_timer()
	_connect_safe(save_key_btn, "pressed", _on_save_key_pressed)
	_connect_safe(show_key_btn, "pressed", _on_show_key_pressed)

	_connect_safe(context_bar_tree, "toggled", func(v): config.include_tree = v; config.save_config())
	_connect_safe(context_bar_scripts, "toggled", func(v): config.include_scripts = v; config.save_config())
	_connect_safe(context_bar_scenes, "toggled", func(v): config.include_scenes = v; config.save_config())
	_connect_safe(context_bar_assets, "toggled", func(v): config.include_assets = v; config.save_config())

	_connect_safe(attach_file_btn, "pressed", _on_attach_file_pressed)
	_connect_safe(clear_chat_btn, "pressed", _on_clear_chat_pressed)
	_connect_safe(generate_btn, "pressed", _on_generate_pressed)
	
	# Setup autocomplete system
	_setup_autocomplete()
	_connect_safe(approve_btn, "pressed", _on_approve_pressed)
	_connect_safe(reject_btn, "pressed", _on_reject_pressed)
	if clear_console_btn and console_output: _connect_safe(clear_console_btn, "pressed", func(): console_output.clear())

func _notification(what: int) -> void:
	if what == 18: # NOTIFICATION_PARENTED
		_update_location_ui()

func _update_location_ui() -> void:
	if not switch_loc_btn: return
	var p := get_parent()
	if p and p.name == "AlphaAIMainScreenWrapper":
		switch_loc_btn.text = "⏬"
		switch_loc_btn.tooltip_text = "Move to Bottom Panel"
	else:
		switch_loc_btn.text = "⏫"
		switch_loc_btn.tooltip_text = "Expand to Main Screen"

func update_location_ui(current_loc: String) -> void:
	_update_location_ui()

func _on_reload_plugin_pressed() -> void:
	if not editor_interface: return
	log_to_console("[color=#4fc3f7]🔌 Reloading Alpha AI Agent plugin...[/color]")
	var ei := editor_interface
	var base_control := ei.get_base_control()
	if not base_control: return
	
	# Schedule plugin reload via base editor tree so it survives dock destruction
	var t1 := base_control.get_tree().create_timer(0.05)
	t1.timeout.connect(func():
		ei.set_plugin_enabled("alpha_ai_agent", false)
		var t2 := base_control.get_tree().create_timer(0.15)
		t2.timeout.connect(func():
			ei.set_plugin_enabled("alpha_ai_agent", true)
		)
	)

func _on_copy_all_pressed() -> void:
	DisplayServer.clipboard_set(_plain_chat_log)
	_add_bubble("system", "📋 Full chat log copied to clipboard!")

# ─────────────────────────────────────────────────────────────────────────────
# BUBBLE SYSTEM
# Roles: "user", "assistant", "assistant_display" (user-facing only), "step", "error", "system"
# Refactor: "assistant_display" shows ONLY the human-facing summary from the AI.
# Full raw responses are stored in chat_history but NOT shown to user directly.
# ─────────────────────────────────────────────────────────────────────────────
func _add_bubble(role: String, text: String) -> void:
	if not chat_bubble_list: return
	var plain_role := "You" if role == "user" else ("Alpha Agent" if role in ["assistant", "assistant_display"] else "System")
	_plain_chat_log += "[" + plain_role + "]\n" + text + "\n\n"

	var outer := MarginContainer.new()
	outer.layout_mode = 2
	outer.size_flags_horizontal = 3
	outer.add_theme_constant_override("margin_left", 8)
	outer.add_theme_constant_override("margin_right", 8)
	outer.add_theme_constant_override("margin_top", 2)
	outer.add_theme_constant_override("margin_bottom", 2)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = 3 if role != "user" else 0
	panel.mouse_filter = Control.MOUSE_FILTER_PASS

	var style := StyleBoxFlat.new()
	style.corner_radius_top_left    = 10
	style.corner_radius_top_right   = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.set_content_margin_all(10)

	match role:
		"user":
			style.bg_color = Color(0.14, 0.22, 0.38, 1.0)
			style.border_color = Color(0.3, 0.55, 0.9, 0.6)
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_width_left = 1; style.border_width_right = 1
		"assistant":
			style.bg_color = Color(0.10, 0.18, 0.14, 1.0)
			style.border_color = Color(0.20, 0.55, 0.30, 0.4)
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_width_left = 1; style.border_width_right = 1
		"assistant_display":
			# Premium user-facing AI response: deep teal with glowing left accent
			style.bg_color = Color(0.08, 0.16, 0.22, 1.0)
			style.border_color = Color(0.20, 0.80, 0.90, 0.85)
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_width_left = 4; style.border_width_right = 1
		"step":
			style.bg_color = Color(0.14, 0.14, 0.10, 1.0)
			style.border_color = Color(0.7, 0.55, 0.1, 0.4)
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_width_left = 3; style.border_width_right = 1
		"error":
			style.bg_color = Color(0.22, 0.07, 0.07, 1.0)
			style.border_color = Color(0.9, 0.2, 0.2, 0.5)
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_width_left = 3; style.border_width_right = 1
		_:
			style.bg_color = Color(0.12, 0.12, 0.16, 1.0)
			style.border_color = Color(0.35, 0.35, 0.45, 0.3)
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_width_left = 1; style.border_width_right = 1

	panel.add_theme_stylebox_override("panel", style)

	var inner_vbox := VBoxContainer.new()
	inner_vbox.add_theme_constant_override("separation", 4)

	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 4)

	var role_label := Label.new()
	role_label.add_theme_font_size_override("font_size", 11)
	match role:
		"user":
			role_label.text = "👤 You"
			role_label.add_theme_color_override("font_color", Color(0.5, 0.78, 1.0, 1))
		"assistant":
			var model_display_a: String = "Free model" if config.is_using_free_trial_mode() else config.selected_model
			role_label.text = "🤖 Alpha Agent  (" + model_display_a + ")"
			role_label.add_theme_color_override("font_color", Color(0.45, 0.9, 0.55, 1))
		"assistant_display":
			# User-facing AI response — premium cyan styling
			var model_display_b: String = "Free model" if config.is_using_free_trial_mode() else config.selected_model
			role_label.text = "✨ Alpha Agent  (" + model_display_b + ")"
			role_label.add_theme_color_override("font_color", Color(0.20, 0.90, 1.0, 1))
		"step":
			role_label.text = "⚡ Agent Step"
			role_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 1))
		"error":
			role_label.text = "❌ Error"
			role_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4, 1))
		_:
			role_label.text = "● System"
			role_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7, 1))

	header_hbox.add_child(role_label)

	var hspacer := Control.new()
	hspacer.size_flags_horizontal = 3
	header_hbox.add_child(hspacer)

	var copy_btn := Button.new()
	copy_btn.text = "📋"
	copy_btn.flat = true
	copy_btn.tooltip_text = "Copy message"
	copy_btn.custom_minimum_size = Vector2(22, 22)
	copy_btn.add_theme_font_size_override("font_size", 11)
	var msg_text := text
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(msg_text))
	header_hbox.add_child(copy_btn)

	inner_vbox.add_child(header_hbox)
	inner_vbox.add_child(HSeparator.new())

	const MAX_PREVIEW := 800
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.selection_enabled = true
	body.add_theme_font_size_override("font_size", 12)

	var _collapsed := [text.length() > MAX_PREVIEW]
	var _full_text := text
	var show_btn: Button = null

	# Process text to make file paths clickable
	var processed_text := _make_file_paths_clickable(text)
	var processed_preview := _make_file_paths_clickable(text.left(MAX_PREVIEW) + "…") if text.length() > MAX_PREVIEW else processed_text

	if text.length() > MAX_PREVIEW:
		body.text = processed_preview
		show_btn = Button.new()
		show_btn.text = "▶ Read More"
		show_btn.flat = true
		show_btn.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0, 1))
		show_btn.add_theme_font_size_override("font_size", 11)
		show_btn.pressed.connect(func():
			if _collapsed[0]:
				body.text = _make_file_paths_clickable(_full_text)
				show_btn.text = "▲ Show Less"
				_collapsed[0] = false
			else:
				body.text = _make_file_paths_clickable(_full_text.left(MAX_PREVIEW) + "…")
				show_btn.text = "▶ Read More"
				_collapsed[0] = true
		)
	else:
		body.text = processed_text

	# Connect URL click signal to open files
	body.meta_clicked.connect(func(meta: Variant):
		var path := str(meta)
		if path.begins_with("res://"):
			_open_file_in_editor(path)
	)

	inner_vbox.add_child(body)
	if show_btn: inner_vbox.add_child(show_btn)

	panel.add_child(inner_vbox)

	if role == "user":
		var align_hbox := HBoxContainer.new()
		align_hbox.layout_mode = 2
		align_hbox.size_flags_horizontal = 3
		var space := Control.new()
		space.size_flags_horizontal = 3
		space.size_flags_stretch_ratio = 0.15
		align_hbox.add_child(space)
		panel.size_flags_horizontal = 3
		panel.size_flags_stretch_ratio = 0.85
		align_hbox.add_child(panel)
		outer.add_child(align_hbox)
	else:
		outer.add_child(panel)

	chat_bubble_list.add_child(outer)
	_scroll_to_bottom()

func _scroll_to_bottom() -> void:
	if not chat_scroll: return
	await get_tree().process_frame
	if chat_scroll and chat_scroll.get_v_scroll_bar():
		chat_scroll.scroll_vertical = int(chat_scroll.get_v_scroll_bar().max_value)

# ── Typing indicator ──────────────────────────────────────────────────────────
func _show_typing_indicator() -> void:
	if _typing_bubble != null or not chat_bubble_list: return
	var outer := MarginContainer.new()
	outer.layout_mode = 2
	outer.add_theme_constant_override("margin_left", 8)
	outer.add_theme_constant_override("margin_top", 2)
	outer.add_theme_constant_override("margin_bottom", 2)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.22, 0.18, 0.85)
	style.corner_radius_top_left = 10; style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10; style.corner_radius_bottom_right = 10
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text = "🤖  ● ● ●"
	lbl.add_theme_color_override("font_color", Color(0.45, 0.9, 0.55, 0.8))
	lbl.add_theme_font_size_override("font_size", 13)
	panel.add_child(lbl)
	outer.add_child(panel)

	_typing_bubble = outer
	chat_bubble_list.add_child(outer)
	_scroll_to_bottom()

func _remove_typing_indicator() -> void:
	if _typing_bubble != null and is_instance_valid(_typing_bubble):
		_typing_bubble.queue_free()
	_typing_bubble = null

# ── Status bar ────────────────────────────────────────────────────────────────
func _set_status(step_text: String, desc_text: String) -> void:
	if status_bar: status_bar.visible = true
	if status_step_label: status_step_label.text = step_text
	if status_desc_label: status_desc_label.text = desc_text
	_spinning = true

func _clear_status() -> void:
	if status_bar: status_bar.visible = false
	_spinning = false
	if spinner_label: spinner_label.text = "⣾"

# ─────────────────────────────────────────────────────────────────────────────
# ATTACHMENT MANAGER
# ─────────────────────────────────────────────────────────────────────────────
func _on_attach_file_pressed() -> void:
	if not file_dialog:
		file_dialog = EditorFileDialog.new()
		file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		file_dialog.file_selected.connect(_on_file_attached)
		add_child(file_dialog)
	file_dialog.popup_file_dialog()

func _on_file_attached(path: String) -> void:
	if not attached_files.has(path):
		attached_files.append(path)
		_render_attachment_chips()

func _render_attachment_chips() -> void:
	if not attachments_container: return
	for child in attachments_container.get_children():
		child.queue_free()
	for path in attached_files:
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 3)
		var lbl := Button.new()
		lbl.text = "📎 " + path.get_file()
		lbl.tooltip_text = path
		lbl.disabled = true
		lbl.add_theme_font_size_override("font_size", 11)
		chip.add_child(lbl)
		var rm := Button.new()
		rm.text = "✖"
		rm.flat = true
		rm.add_theme_font_size_override("font_size", 10)
		var _p := path
		rm.pressed.connect(func(): attached_files.erase(_p); _render_attachment_chips())
		chip.add_child(rm)
		attachments_container.add_child(chip)

func _on_clear_chat_pressed() -> void:
	chat_history.clear()
	_plain_chat_log = ""
	_last_action_signature = ""
	_missing_json_retry_count = 0
	_consecutive_empty_rounds = 0
	_user_goal = ""
	_state = AgentState.IDLE
	if chat_bubble_list:
		for child in chat_bubble_list.get_children():
			child.queue_free()
	attached_files.clear()
	_render_attachment_chips()
	_add_bubble("system", "🧹 Conversation cleared.")

# ─────────────────────────────────────────────────────────────────────────────
# QUICK MODEL
# ─────────────────────────────────────────────────────────────────────────────
func _populate_quick_model_option() -> void:
	if not quick_model_option: return
	quick_model_option.clear()
	
	if config.is_using_free_trial_mode():
		quick_model_option.add_item("⚡ Free Trial (Auto Server Routing)")
		quick_model_option.disabled = true
		quick_model_option.tooltip_text = "Free Trial Mode Active: Server automatically routes requests to available models"
		if model_option: model_option.disabled = true
		return

	if model_option: model_option.disabled = false
	quick_model_option.disabled = false
	quick_model_option.tooltip_text = "Select model for direct BYOK API requests"

	var all_models: Array[Dictionary] = config.get_all_available_models_with_keys()
	if all_models.is_empty():
		# Fallback: populate models for current provider if no keys are set yet
		var p_models := config.get_models_for_provider(config.provider)
		var sel := -1
		for idx in range(p_models.size()):
			var m_name := p_models[idx]
			quick_model_option.add_item(_provider_icon(config.provider) + " " + config.provider + " › " + m_name, idx)
			if m_name == config.selected_model:
				sel = idx
		quick_model_option.selected = max(sel, 0)
		return

	var sel: int = -1
	for idx in range(all_models.size()):
		var item: Dictionary = all_models[idx]
		quick_model_option.add_item(_provider_icon(item["provider"]) + " " + item["provider"] + " › " + item["model"], idx)
		if item["provider"] == config.provider and item["model"] == config.selected_model:
			sel = idx
	quick_model_option.selected = max(sel, 0)
	if sel == -1 and not all_models.is_empty():
		config.provider = all_models[0]["provider"]
		config.selected_model = all_models[0]["model"]
		config.save_config()

func _on_quick_model_selected(index: int) -> void:
	var all_models: Array[Dictionary] = config.get_all_available_models_with_keys()
	if not all_models.is_empty() and index >= 0 and index < all_models.size():
		config.provider = all_models[index]["provider"]
		config.selected_model = all_models[index]["model"]
		config.save_config()
		_update_key_display()
		_populate_model_dropdown()
		if not _is_initializing:
			_add_bubble("system", "🤖 Active model changed to: " + config.provider + " › " + config.selected_model)
	else:
		var p_models := config.get_models_for_provider(config.provider)
		if index >= 0 and index < p_models.size():
			config.selected_model = p_models[index]
			config.save_config()
			_populate_model_dropdown()
			if not _is_initializing:
				_add_bubble("system", "🤖 Active model changed to: " + config.provider + " › " + config.selected_model)

func _provider_icon(p: String) -> String:
	match p:
		AIConfig.PROVIDER_OPENAI:     return "🤖"
		AIConfig.PROVIDER_ANTHROPIC:  return "🧠"
		AIConfig.PROVIDER_GEMINI:     return "✨"
		AIConfig.PROVIDER_OPENROUTER: return "🌐"
		_:                            return "⚡"

# ─────────────────────────────────────────────────────────────────────────────
# SETTINGS
# ─────────────────────────────────────────────────────────────────────────────
func _populate_model_dropdown() -> void:
	if not model_option: return
	model_option.clear()
	var models: Array[String] = config.get_models_for_provider()
	var found := false
	for idx in range(models.size()):
		model_option.add_item(models[idx])
		if models[idx] == config.selected_model:
			model_option.selected = idx; found = true
	if not found and models.size() > 0:
		model_option.selected = 0
		config.selected_model = models[0]
		config.save_config()
	model_option.disabled = config.is_using_free_trial_mode()

func _update_key_display() -> void:
	if api_key_edit: api_key_edit.text = config.get_api_key()
	_refresh_key_status()

func _on_free_trial_toggled(enabled: bool) -> void:
	config.use_free_trial_mode = enabled
	config.save_config()
	_update_key_display()
	_populate_quick_model_option()
	_populate_model_dropdown()
	if not enabled and not config.get_api_key().is_empty():
		network.fetch_models(config)
	if not _is_initializing:
		if enabled:
			_add_bubble("system", "⚡ Switched to Free Trial Mode (" + config.get_usage_display_text() + ")")
		else:
			_add_bubble("system", "🔑 Switched to BYOK Mode. Active model: " + config.provider + " › " + config.selected_model)

func _refresh_key_status() -> void:
	if not key_status_label or not api_key_edit: return
	var usage_str := config.get_usage_display_text()
	
	if free_usage_label:
		free_usage_label.text = "📊 " + usage_str
		if config.get_free_requests_remaining() <= 0:
			free_usage_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		else:
			free_usage_label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
			
	var is_free := config.is_using_free_trial_mode()
	var key := api_key_edit.text.strip_edges()
	
	if usage_circle_badge:
		usage_circle_badge.visible = is_free
		usage_circle_badge.set_usage(float(config.usage_info.get("percent_remaining", 100.0)), usage_str)
	
	if is_free:
		key_status_label.text = "⚡ Free Trial Mode Active — " + usage_str
		key_status_label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	else:
		if key.is_empty():
			key_status_label.text = "⚠ BYOK Mode Selected, but no key set for " + config.provider
			key_status_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))
		else:
			key_status_label.text = "🔑 BYOK Mode Active (Direct to " + config.provider + " API)"
			key_status_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))

var _pmap_keys := [AIConfig.PROVIDER_OPENAI, AIConfig.PROVIDER_ANTHROPIC, AIConfig.PROVIDER_GEMINI, AIConfig.PROVIDER_OPENROUTER, AIConfig.PROVIDER_DEEPSEEK]

func _on_provider_selected(index: int) -> void:
	var new_prov: String = _pmap_keys[index]
	if new_prov != config.provider:
		config.provider = new_prov
		_populate_model_dropdown()
		_update_key_display()
		_populate_quick_model_option()
		config.save_config()
		if not _is_initializing:
			_add_bubble("system", "🤖 Provider changed to: " + config.provider + " (Active model: " + config.selected_model + ")")

func _on_model_selected(index: int) -> void:
	if model_option:
		var new_model := model_option.get_item_text(index)
		if new_model != config.selected_model:
			config.selected_model = new_model
			_populate_quick_model_option()
			config.save_config()
			if not _is_initializing:
				_add_bubble("system", "🤖 Active model changed to: " + config.provider + " › " + config.selected_model)

func _on_save_key_pressed() -> void:
	if api_key_edit: config.set_api_key(api_key_edit.text.strip_edges())
	_refresh_key_status()
	_populate_model_dropdown()
	_populate_quick_model_option()
	if welcome_banner: welcome_banner.visible = not config.has_any_api_key()
	log_to_console("[color=#66bb6a]🔐 Key saved for " + config.provider + "[/color]")
	if not config.get_api_key().is_empty():
		network.fetch_models(config)

func _on_show_key_pressed() -> void:
	if api_key_edit and show_key_btn:
		api_key_edit.secret = not api_key_edit.secret
		show_key_btn.text = "👁" if api_key_edit.secret else "🙈"

func _on_refresh_models_pressed() -> void:
	if refresh_model_btn:
		refresh_model_btn.disabled = true
		refresh_model_btn.text = "⏳"
	network.fetch_models(config)

func _on_models_fetched(provider: String, models: Array[String]) -> void:
	if refresh_model_btn:
		refresh_model_btn.disabled = false
		refresh_model_btn.text = "🔄"
	if models.is_empty(): return
	config.set_cached_models(provider, models)
	if provider == config.provider: _populate_model_dropdown()
	_populate_quick_model_option()
	log_to_console("[color=#66bb6a]✅ " + str(models.size()) + " models fetched for " + provider + "[/color]")

func _on_models_fetch_failed(provider: String, error_msg: String) -> void:
	if refresh_model_btn:
		refresh_model_btn.disabled = false
		refresh_model_btn.text = "🔄"
	log_to_console("[color=#ef5350]❌ Model fetch failed for " + provider + ": " + error_msg + "[/color]")

# ─────────────────────────────────────────────────────────────────────────────
# CONTEXT + PROMPT BUILD
# ─────────────────────────────────────────────────────────────────────────────
func _build_context(is_small_model: bool = false) -> String:
	var active_file: String = ""
	if editor_interface:
		var se = editor_interface.get_script_editor()
		if se:
			var cs = se.get_current_script()
			if cs: active_file = cs.resource_path

	var ctx := project_context.gather_context(
		context_bar_tree.button_pressed if context_bar_tree else true,
		context_bar_scripts.button_pressed if context_bar_scripts else true,
		context_bar_scenes.button_pressed if context_bar_scenes else true,
		context_bar_assets.button_pressed if context_bar_assets else true,
		context_bar_logs.button_pressed if context_bar_logs else true,
		active_file,
		attached_files,
		editor_interface,
		is_small_model
	)

	# REFACTOR #3: Inject archived task context at the top of every project context.
	# This ensures the model knows which tasks are already done and won't re-verify them.
	if not _archived_context_prefix.is_empty():
		ctx = _archived_context_prefix + ctx

	return ctx

# ─────────────────────────────────────────────────────────────────────────────
# LEAN CONTEXT — used in TRIAGE stage (tree + logs only, no file code)
# Respects user checkbox overrides: if Scripts/Scenes are explicitly checked,
# falls back to full gather_context() as the user intentionally wants all data.
# ─────────────────────────────────────────────────────────────────────────────
func _build_lean_context() -> String:
	var active_file: String = ""
	if editor_interface:
		var se = editor_interface.get_script_editor()
		if se:
			var cs = se.get_current_script()
			if cs: active_file = cs.resource_path

	var ctx := project_context.gather_lean_context(
		active_file,
		attached_files,
		editor_interface
	)
	if not _archived_context_prefix.is_empty():
		ctx = _archived_context_prefix + ctx
	return ctx

# ─────────────────────────────────────────────────────────────────────────────
# TARGETED CONTEXT — used in ANALYZE after TRIAGE file selection
# Combines lean context with ONLY the files the AI specifically requested.
# ─────────────────────────────────────────────────────────────────────────────
func _build_targeted_context(requested_files: Array[String]) -> String:
	var lean := _build_lean_context()
	if requested_files.is_empty():
		return lean
	var targeted := project_context.gather_targeted_context(requested_files)
	return lean + "\n" + targeted

# ─────────────────────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
#  AGENT LOOP — STATE MACHINE ENTRY POINTS
# ══════════════════════════════════════════════════════════════════════════════
# ─────────────────────────────────────────────────────────────────────────────

func _on_generate_pressed() -> void:
	# If we are actively mid-generation, let user cancel
	if _is_generating:
		_abort_agent()
		return

	# Resume interrupted step if agent state was paused by network error
	if _state != AgentState.IDLE and not _user_goal.is_empty():
		# If we were waiting for user gameplay verification, re-run verification
		# with fresh logs to capture the user's actual gameplay session
		if _state == AgentState.VERIFYING:
			log_to_console("[color=#66bb6a]🎮 User completed gameplay. Re-running verification with fresh logs...[/color]")
			_add_bubble("step", "🎮 Gameplay complete — re-running verification to capture results...")
			_show_typing_indicator()
			# Change state away from VERIFYING so we don't re-trigger the gate
			_state = AgentState.REFLECTING
			await _run_verification_and_reflect("User gameplay verification complete.", false)
			return

		log_to_console("[color=#66bb6a]🔄 Resuming agent step for Round " + str(_agent_round) + "...[/color]")
		_add_bubble("step", "🔄 Resuming execution for Round " + str(_agent_round) + "...")
		_show_typing_indicator()
		var resume_prompt := "Please continue executing the task. Original goal: " + _user_goal
		network.send_prompt(config, resume_prompt, _build_context(), chat_history)
		return

	var prompt_text := prompt_edit.text.strip_edges() if prompt_edit else ""
	if prompt_text.is_empty():
		if status_label: status_label.text = "⚠ Enter a prompt"
		return

	# ── REFACTOR #2: STRICT STATE ISOLATION ──────────────────────────────────
	# Archive previous task's logs and reset ALL loop counters on every new prompt.
	# This prevents state bleed where the agent re-verifies completed tasks.
	_pipeline.reset_for_new_prompt()
	_archived_context_prefix = _pipeline.get_archived_task_context()

	_user_goal = prompt_text
	_agent_round = 0
	_last_action_signature = ""
	_last_runtime_errors = ""
	_last_debug_output = ""
	_missing_json_retry_count = 0
	_consecutive_empty_rounds = 0
	_user_verification_count = 0
	_self_corruption_count = 0
	_last_modified_files = []
	_total_actions_executed = 0
	_hallucination_count = 0
	_is_read_only_request = _classify_read_only_request(prompt_text)
	_state = AgentState.PLANNING
	if prompt_edit: prompt_edit.text = ""

	var display_text := prompt_text
	if not attached_files.is_empty():
		display_text += "\n(📎 " + str(attached_files.size()) + " file(s) attached)"
	_add_bubble("user", display_text)

	chat_history.append({"role": "user", "text": prompt_text})
	_run_planning_step()

# ─────────────────────────────────────────────────────────────────────────────
# PLANNING STEP — Agent gets full project context and user goal
# ─────────────────────────────────────────────────────────────────────────────
func _run_planning_step() -> void:
	_agent_round += 1
	_state = AgentState.PLANNING
	_set_status("🗺 Planning", _get_agent_progress() + " — Planning actions...")
	if generate_btn: generate_btn.text = "🛑 Stop"
	log_to_console("[color=#4fc3f7]═══ AGENT ROUND " + str(_agent_round) + " — PLANNING ═══[/color]")
	_show_typing_indicator()
	var use_small := _should_use_small_model_for_stage("CLASSIFY")
	# ── TRIAGE: Send lean context only. AI will request the specific files it needs.
	_add_bubble("step", "🔍 Analyzing your request and identifying relevant files…")
	network.send_prompt(config, _user_goal, _build_lean_context(), chat_history, false, false, "TRIAGE")

# ─────────────────────────────────────────────────────────────────────────────
# REFLECTION STEP — Agent reviews what happened and decides next step
# ─────────────────────────────────────────────────────────────────────────────
func _run_reflection_step(exec_report: String, runtime_errors: String, debug_output: String, is_repeating: bool, truth_log_block: String = "") -> void:
	_agent_round += 1
	_state = AgentState.REFLECTING
	_set_status("🔍 Reflecting", "Round " + str(_agent_round) + ": Reviewing results...")
	log_to_console("[color=#4fc3f7]═══ AGENT ROUND " + str(_agent_round) + " — REFLECTING ═══[/color]")
	_show_typing_indicator()

	var reflect_prompt := ""

	# ── REFACTOR #3: Prepend archived task context ──────────────────────────────────
	# This prevents the agent from re-verifying completed sub-tasks from prior rounds.
	if not _archived_context_prefix.is_empty():
		reflect_prompt += _archived_context_prefix

	# ── Prepend truth-source log block if available ────────────────────────────
	if not truth_log_block.is_empty():
		reflect_prompt += truth_log_block + "\n"

	if is_repeating:
		reflect_prompt  = "## ⚠ CRITICAL: REPEATING LOOP DETECTED\n"
		reflect_prompt += "You proposed the same actions again but they applied 0 changes.\n"
		reflect_prompt += "Previous action signature: " + _last_action_signature + "\n\n"
		reflect_prompt += "## Original User Goal\n" + _user_goal + "\n\n"
		reflect_prompt += exec_report + "\n"
		if not debug_output.is_empty():
			reflect_prompt += "## Game Debug Output (print statements during run)\n```text\n" + debug_output.left(1200) + "\n```\n\n"
		if not runtime_errors.is_empty():
			reflect_prompt += "## Runtime Errors Still Present\n```text\n" + runtime_errors + "\n```\n\n"
		reflect_prompt += "## Your Task\n"
		reflect_prompt += "You MUST use a completely different approach. "
		reflect_prompt += "If the issue is in GDScript code, rewrite the file using update_file with corrected code. "
		reflect_prompt += "Do NOT output the same action again.\n"
		reflect_prompt += "Output the mandatory ```json [...] ``` action block with your new strategy."
	elif not runtime_errors.is_empty():
		reflect_prompt  = "## 🐞 Runtime Errors Detected After Applying Changes\n\n"
		reflect_prompt += "## Original User Goal\n" + _user_goal + "\n\n"
		reflect_prompt += exec_report + "\n"
		if not debug_output.is_empty():
			reflect_prompt += "## 🖨 Game Debug Prints (ALPHA_DEBUG lines from game run)\n```text\n" + debug_output.left(1200) + "\n```\n"
			reflect_prompt += "⚠ READ THE DEBUG PRINTS CAREFULLY — they show actual runtime state (velocity, positions, node paths, signals). Use them to diagnose the root cause.\n\n"
		reflect_prompt += "## Godot Runtime Errors\n```text\n" + runtime_errors + "\n```\n\n"
		if runtime_errors.contains("Failed loading resource") or runtime_errors.contains("referenced non-existent resource"):
			reflect_prompt += "⚠ CRITICAL FIX DIRECTIVE: A resource file fails loading because it DOES NOT EXIST on disk.\n"
			reflect_prompt += "DO NOT keep outputting [ext_resource] lines pointing to missing files in .tscn!\n"
			reflect_prompt += "Either remove the missing ext_resource line entirely or use built-in nodes like ColorRect or PlaceholderTexture2D in GDScript.\n\n"
		if runtime_errors.contains(".tscn") and (runtime_errors.contains("Parse Error") or runtime_errors.contains("Invalid parameter")):
			reflect_prompt += "⚠ CRITICAL WARNING FOR SCENE FILES: You wrote invalid syntax inside a `.tscn` file!\n"
			reflect_prompt += "DO NOT write GDScript code or invalid sub_resources into `.tscn` files.\n"
			reflect_prompt += "INSTEAD: Update the attached `.gd` script and instantiate nodes/shapes programmatically in `_ready()` (e.g. `var col = CollisionShape2D.new(); var s = CircleShape2D.new(); s.radius = 16.0; col.shape = s; add_child(col)`).\n\n"
		reflect_prompt += "## 🎯 HOLISTIC DIAGNOSIS DIRECTIVE\n"
		reflect_prompt += "Do NOT fix just one single line or hyper-specific symptom. Identify 2 or 3 plausible root causes (e.g., script logic, signal connections, node paths, collision layers), verify which exist, and fix ALL applicable root causes together in your action block.\n\n"
		reflect_prompt += "## Your Task\n"
		reflect_prompt += "Analyze these runtime errors carefully. Fix them by outputting the mandatory ```json [...] ``` action block. "
		reflect_prompt += "Rewrite any GDScript or scene file that has errors using the update_file action with the complete corrected code."
	else:
		reflect_prompt  = "## ✅ Changes Applied — No Runtime Errors Detected\n\n"
		reflect_prompt += "## Original User Goal\n" + _user_goal + "\n\n"
		reflect_prompt += exec_report + "\n"
		if not debug_output.is_empty():
			reflect_prompt += "## 🖨 Game Debug Prints (ALPHA_DEBUG lines from game run)\n```text\n" + debug_output.left(1200) + "\n```\n"
		else:
			reflect_prompt += "## 🖨 Game Debug Prints\n**NO [ALPHA_DEBUG] PRINTS WERE FOUND!** This means the code changes did NOT include verification prints.\n\n"
		
		reflect_prompt += "## VERIFICATION RULES\n"
		reflect_prompt += "1. **If 0 runtime errors exist and code edits were successfully applied**: Output task_complete.\n"
		reflect_prompt += "2. Do NOT keep outputting file edits if the code compiled cleanly and ran with zero errors.\n"
		reflect_prompt += "3. If event prints exist ([ALPHA_DEBUG] collected, entered, hit, score): Confirm success.\n"
		reflect_prompt += "4. If actual errors or crashes exist: Output targeted fix actions.\n\n"

		reflect_prompt += "## Your Task\n"
		reflect_prompt += "Review the execution report and original goal.\n"
		reflect_prompt += "- If changes were applied cleanly and no errors exist: Output task_complete.\n"
		reflect_prompt += "- If actual errors exist: Output fix actions.\n\n"
		reflect_prompt += "MANDATORY: End with ```json [...] ``` action block."

	chat_history.append({"role": "user", "text": reflect_prompt})
	var use_small := _should_use_small_model_for_stage("REFLECT")
	network.send_prompt(config, reflect_prompt, _build_context(use_small), chat_history, false, use_small, "REFLECT")

# ─────────────────────────────────────────────────────────────────────────────
# REQUEST CALLBACKS
# ─────────────────────────────────────────────────────────────────────────────
func _on_request_started() -> void:
	_is_generating = true

func _on_request_completed(response_text: String) -> void:
	_is_generating = false
	_remove_typing_indicator()
	_refresh_key_status()

	chat_history.append({"role": "assistant", "text": response_text})

	# ── TRIAGE STAGE BRANCH ────────────────────────────────────────────────────
	# If we are in the TRIAGE stage, the AI either asked for specific files
	# or answered directly. Handle both outcomes before normal processing.
	if _pipeline.current_stage == AIPipeline.PipelineStage.TRIAGE:
		var triage_actions := execution_engine.parse_actions_from_response(response_text)
		var file_requests := ExecutionEngine.extract_file_requests(triage_actions)
		var has_task_complete := _contains_task_complete(triage_actions)

		if not file_requests.is_empty():
			# AI asked for specific files → load them and send to ANALYZE
			_pipeline.set_triage_files(file_requests)
			_pipeline.advance_to_analyze()
			_agent_round += 1
			_state = AgentState.PLANNING
			log_to_console("[color=#4fc3f7]🗂 Triage complete. Loading " + str(file_requests.size()) + " file(s): " + ", ".join(file_requests) + "[/color]")
			_add_bubble("step", "🗂 Loading " + str(file_requests.size()) + " relevant file(s) and analyzing…")
			_show_typing_indicator()
			# Build full targeted context and send ANALYZE request
			var targeted_ctx := _build_targeted_context(file_requests)
			network.send_prompt(config, _user_goal, targeted_ctx, chat_history, false, false, "CLASSIFY")
			return
		elif has_task_complete:
			# AI answered directly from structure (no file read needed)
			var summary_str := ""
			for a in triage_actions:
				if str(a.get("action", "")) == "task_complete":
					summary_str = str(a.get("summary", ""))
					break
			# Show the AI's triage text as the response
			var triage_display := _strip_json_block(response_text).strip_edges()
			if not triage_display.is_empty():
				_add_bubble("assistant_display", triage_display)
			_pipeline.advance_to_analyze()
			_finish_agent(summary_str if not summary_str.is_empty() else "Answered from project structure.")
			return
		else:
			# AI didn't output a request_files or task_complete — fall through to ANALYZE with lean context
			log_to_console("[color=#ffd54f]⚠ Triage returned no file request. Proceeding to analyze with lean context.[/color]")
			_pipeline.advance_to_analyze()
			_agent_round += 1
			_state = AgentState.PLANNING
			_show_typing_indicator()
			network.send_prompt(config, _user_goal, _build_context(), chat_history, false, false, "CLASSIFY")
			return
	# ── END TRIAGE BRANCH ─────────────────────────────────────────────────────

	# Parse structured response sections
	var parsed_sections := _parse_structured_response(response_text)

	# ── REFACTOR #1: MANDATORY JSON VALIDATION ───────────────────────────────
	# SKIP enforcement for read-only/explain requests — they legitimately use
	# task_complete with no file actions. Only enforce for modification tasks.
	var has_valid_json := ExecutionEngine.validate_json_block_present(response_text)
	var json_required: bool = not _is_read_only_request
	if json_required and not has_valid_json and _missing_json_retry_count < 2:
		_missing_json_retry_count += 1
		log_to_console("[color=#ffd54f]⚠ [JSON VALIDATOR] Round " + str(_agent_round) + " response missing valid JSON block (retry " + str(_missing_json_retry_count) + "/2). Injecting retry prompt...[/color]")
		_add_bubble("step", "⚠️ Response missing JSON action block — re-querying agent (retry " + str(_missing_json_retry_count) + "/2)...")
		var retry_injection := ExecutionEngine.get_missing_json_injection_prompt(_user_goal)
		chat_history.append({"role": "user", "text": retry_injection})
		_show_typing_indicator()
		network.send_prompt(config, retry_injection, _build_context(), chat_history)
		return
	elif json_required and not has_valid_json and _missing_json_retry_count >= 2:
		log_to_console("[color=#ef5350]❌ [JSON VALIDATOR] Agent failed to produce valid JSON after 2 retries.[/color]")
		_add_bubble("error", "❌ Agent could not generate valid action block after 2 retries.")

	# ── DISPLAY: ONE CLEAN BUBBLE — NO DOUBLE-RENDERING ──────────────────────
	# The user sees ONE assistant_display bubble with clean, readable content.
	# Full reasoning is stored in chat_history but never duplicated on-screen.
	#
	# Priority order for user-facing text:
	# 1. ## 📋 SUMMARY section  → cleanest, single-line summary
	# 2. ## 🧠 ANALYSIS section  → if no summary, first 500 chars of analysis
	# 3. Fallback                → stripped prose (JSON/fences removed)
	var user_facing_text: String = ""
	if not parsed_sections["summary"].is_empty():
		user_facing_text = parsed_sections["summary"]
	elif not parsed_sections["analysis"].is_empty():
		var clean: String = str(parsed_sections["analysis"])
		user_facing_text = clean.left(500) + ("…" if clean.length() > 500 else "")
	else:
		user_facing_text = _strip_json_block(response_text).strip_edges()
		if user_facing_text.length() > 1200:
			user_facing_text = user_facing_text.left(1200) + "\n\n_(Full details in the Dev Console)_"

	if not user_facing_text.is_empty():
		_add_bubble("assistant_display", user_facing_text)
	# NOTE: No second 'assistant' bubble — that caused the duplicate display.

	# Record to pipeline (prevents re-verification of completed tasks)
	_pipeline.record_execution({"round": _agent_round, "response_summary": user_facing_text.left(200)})

	# Parse actions
	pending_actions = execution_engine.parse_actions_from_response(response_text)

	# Strip request_files actions — they are TRIAGE metadata only, not executable
	pending_actions = pending_actions.filter(func(a): return str(a.get("action", a.get("type", ""))) != "request_files")

	# ── Action processing & task_complete check ─────────────────────────────
	var has_real_actions := false
	for a in pending_actions:
		var act_type := str(a.get("action", a.get("type", "")))
		if act_type != "task_complete":
			has_real_actions = true
			break

	if has_real_actions:
		# If real file/scene actions were provided, execute them first! Strip task_complete for now.
		var filtered_actions: Array[Dictionary] = []
		for a in pending_actions:
			if str(a.get("action", a.get("type", ""))) != "task_complete":
				filtered_actions.append(a)
		pending_actions = filtered_actions
	elif _contains_task_complete(pending_actions):
		var summary := ""
		for a in pending_actions:
			if str(a.get("action", a.get("type", ""))) == "task_complete":
				summary = str(a.get("summary", "Task fully completed."))
				break

		# Guard: detect if the LLM fabricated claims about ALPHA_DEBUG prints
		# that don't actually exist in the captured logs
		if _response_hallucinates_proof(response_text, _last_debug_output):
			_hallucination_count += 1
			log_to_console("[color=#ef5350]🚫 HALLUCINATION DETECTED (attempt " + str(_hallucination_count) + "): Agent claims debug prints exist that are NOT in the actual logs. Rejecting...[/color]")
			_add_bubble("step", "🚫 Hallucination detected (" + str(_hallucination_count) + "/2) — agent claimed verification prints exist that don't.")
			
			# Break the loop after 2 hallucinations - stop the agent
			if _hallucination_count >= 2:
				log_to_console("[color=#ef5350]❌ Agent hallucinated " + str(_hallucination_count) + " times. Stopping to prevent infinite loop.[/color]")
				_add_bubble("error", "❌ Agent hallucinated " + str(_hallucination_count) + " times. Stopping agent to prevent infinite loop. Please rephrase your request.")
				_reset_state()
				return
			
			var hallucination_prompt := (
				"CRITICAL SYSTEM DIRECTIVE: You claimed that [ALPHA_DEBUG] prints confirm the feature works, "
				+ "but those prints DO NOT EXIST in the actual captured game output!\n\n"
				+ "You are HALLUCINATING results. You CANNOT claim a feature works without ACTUAL prints in the logs.\n\n"
				+ "## Actual Debug Output Captured:\n```text\n" + _last_debug_output.left(800) + "\n```\n\n"
				+ "As you can see, there are NO event-triggering prints like 'Item collected!', 'Body entered:', or 'Collision detected'.\n\n"
				+ "Original user goal: " + _user_goal + "\n\n"
				+ "You MUST fix the actual code so the feature works, run the game, and ONLY claim success if the ACTUAL logs contain event prints.\n"
				+ "Output the mandatory ```json [...] ``` action block with corrected code."
			)
			chat_history.append({"role": "user", "text": hallucination_prompt})
			_show_typing_indicator()
			network.send_prompt(config, hallucination_prompt, _build_context(), chat_history)
			return

		# Guard against fake task_complete when 0 actions were executed
		# BUT: Skip this guard for read-only requests (they legitimately have 0 file edits)
		if _total_actions_executed == 0 and not _is_read_only_request:
			log_to_console("[color=#ffd54f]⚠ Agent declared task_complete but 0 file changes were executed. Rejecting fake completion...[/color]")
			_add_bubble("step", "⚠️ Re-querying agent to generate complete script files on disk...")
			var reject_prompt := (
				"CRITICAL SYSTEM DIRECTIVE: You sent 'task_complete', but 0 file edits were applied!\n"
				+ "You outputted markdown text explanations earlier, but you NEVER outputted the 'update_file' or 'create_file' action block!\n\n"
				+ "Original user goal: " + _user_goal + "\n\n"
				+ "You MUST output the mandatory ```json [...] ``` action block containing the 'update_file' or 'create_file' actions for the target script files (e.g. res://scripts/player.gd, res://scripts/item.gd, res://scripts/main.gd) with the FULL corrected GDScript code right now."
			)
			chat_history.append({"role": "user", "text": reject_prompt})
			_show_typing_indicator()
			network.send_prompt(config, reject_prompt, _build_context(), chat_history)
			return

		# Guard against premature completion when active runtime errors exist
		if not _last_runtime_errors.is_empty() and (_last_runtime_errors.contains("ERROR:") or _last_runtime_errors.contains("Parse Error") or _last_runtime_errors.contains("Failed loading")):
			log_to_console("[color=#ef5350]⚠ Agent attempted task_complete, but active runtime/parse errors exist. Rejecting completion...[/color]")
			_add_bubble("step", "⚠️ Active errors detected. Forcing agent to fix runtime issues...")
			var error_fix_prompt := (
				"CRITICAL SYSTEM DIRECTIVE: You declared 'task_complete', but the project STILL HAS ACTIVE RUNTIME / PARSE ERRORS!\n\n"
				+ "## Active Errors\n```text\n" + _last_runtime_errors + "\n```\n\n"
				+ "Original user goal: " + _user_goal + "\n\n"
				+ "You CANNOT complete the task until all runtime and parse errors are completely fixed!\n"
				+ "Output the mandatory ```json [...] ``` action block containing the 'update_file' or 'create_file' actions to fix these errors right now."
			)
			chat_history.append({"role": "user", "text": error_fix_prompt})
			_show_typing_indicator()
			network.send_prompt(config, error_fix_prompt, _build_context(), chat_history)
			return

		# Guard: reject task_complete if goal requires interaction but no feature-confirming prints exist
		if _goal_requires_user_interaction(_user_goal) and not _has_feature_confirming_prints(_last_debug_output):
			log_to_console("[color=#ffd54f]⚠ Agent declared task_complete, but no feature-confirming event prints were seen. Rejecting...[/color]")
			_add_bubble("step", "⚠️ No feature-confirming prints detected (collected, entered, hit, score). Agent must prove the feature works before completing.")
			var proof_prompt := (
				"CRITICAL SYSTEM DIRECTIVE: You declared 'task_complete', but NO EVENT-TRIGGERING [ALPHA_DEBUG] prints were found in the game run!\n\n"
				+ "INFORMATIONAL prints like 'Item spawned at:', 'Player ready at:', 'Item close to player! Distance:' do NOT prove the feature works.\n\n"
				+ "You MUST see prints like:\n"
				+ "  - '[ALPHA_DEBUG] Item collected!' or '[ALPHA_DEBUG] Item successfully collected and freed!'\n"
				+ "  - '[ALPHA_DEBUG] Body entered:' or '[ALPHA_DEBUG] Area entered:'\n"
				+ "  - '[ALPHA_DEBUG] Collision detected' or '[ALPHA_DEBUG] Score updated:'\n\n"
				+ "Original user goal: " + _user_goal + "\n\n"
				+ "Debug output captured:\n```text\n" + _last_debug_output.left(800) + "\n```\n\n"
				+ "The feature is NOT verified. You MUST fix the actual code so the feature works, "
				+ "add event-triggering debug prints, and let the game run to verify.\n"
				+ "Output the mandatory ```json [...] ``` action block with corrected code."
			)
			chat_history.append({"role": "user", "text": proof_prompt})
			_show_typing_indicator()
			network.send_prompt(config, proof_prompt, _build_context(), chat_history)
			return

		_finish_agent(summary if not summary.is_empty() else "Task fully completed.")
		return

	# ── No actions found ───────────────────────────────────────────────────
	if pending_actions.is_empty():
		_missing_json_retry_count += 1
		if _missing_json_retry_count <= 3:
			log_to_console("[color=#ffd54f]⚠ No JSON action block found. Retry " + str(_missing_json_retry_count) + "/3...[/color]")
			_add_bubble("step", "⚠️ No action block returned. Auto-retrying (" + str(_missing_json_retry_count) + "/3)...")
			var force_prompt := (
				"MANDATORY ACTION DIRECTIVE: You MUST output a ```json [...] ``` action block containing the exact file modifications (e.g. update_file, create_file).\n"
				+ "Your last response contained text only — 0 files were edited.\n\n"
				+ "Original user goal: " + _user_goal + "\n\n"
				+ "Output the ```json [...] ``` block containing the update_file or create_file actions to apply changes to disk NOW."
			)
			chat_history.append({"role": "user", "text": force_prompt})
			_show_typing_indicator()
			network.send_prompt(config, force_prompt, _build_context(), chat_history)
		else:
			_missing_json_retry_count = 0
			log_to_console("[color=#ef5350]❌ Agent failed to produce actions after 3 retries.[/color]")
			_add_bubble("error", "❌ Agent could not produce a JSON action block after 3 attempts. Please rephrase your request.")
			_reset_state()
		return

	_missing_json_retry_count = 0

	# ── Show approval panel ────────────────────────────────────────────────
	_show_approval_panel()

	# ── If agent loop is on, auto-execute immediately ──────────────────────
	if _agent_loop_enabled:
		log_to_console("[color=#66bb6a]⚡ Agent Loop ON — auto-executing actions...[/color]")
		_on_approve_pressed()

func _on_request_failed(error_msg: String) -> void:
	_is_generating = false
	_remove_typing_indicator()
	
	if _state != AgentState.IDLE and _agent_round > 0:
		log_to_console("[color=#ef5350]❌ Step interrupted in Round " + str(_agent_round) + ": " + error_msg + "[/color]")
		_set_status("⚠ Step Interrupted", error_msg)
		if status_label: status_label.text = "⚠ Interrupted"
		_add_bubble("error", "❌ Network Error in Round " + str(_agent_round) + ": " + error_msg + "\n[i]Click 🔄 Resume Step to continue the agent from this step.[/i]")
		if generate_btn: generate_btn.text = "🔄 Resume Step"
		return

	_clear_status()
	if generate_btn: generate_btn.text = "🚀 Send"
	if status_label: status_label.text = "❌ Failed"
	_add_bubble("error", "❌ Network Error: " + error_msg)
	log_to_console("[color=#ef5350]❌ Request failed: " + error_msg + "[/color]")
	push_error("Alpha AI Agent: " + error_msg)
	_reset_state()

func _on_network_status_changed(new_status: AINetwork.NetworkStatus) -> void:
	match new_status:
		AINetwork.NetworkStatus.IDLE:
			_clear_status()
			if status_label: status_label.text = "Ready"
		AINetwork.NetworkStatus.THINKING:
			if _state != AgentState.IDLE:
				_set_status("🤔 Thinking", "Agent analyzing context & planning next steps...")
			if status_label: status_label.text = "Thinking..."
		AINetwork.NetworkStatus.CALLING_TOOL:
			_set_status("🛠 Executing Tools", "Applying actions & updating workspace...")
			if status_label: status_label.text = "Executing..."
		AINetwork.NetworkStatus.VPS_AWAITING_RETRY:
			_set_status("⏳ VPS Retrying", "Free tier congested, waiting to retry...")
			if status_label: status_label.text = "Retrying..."

func _on_usage_fetched(data: Dictionary) -> void:
	if config:
		config.update_usage_from_api(data)
		var display := config.get_usage_display_text()
		var pct := float(config.usage_info.get("percent_remaining", 100.0))
		if usage_circle_badge:
			usage_circle_badge.visible = config.is_using_free_trial_mode()
			usage_circle_badge.set_usage(pct, display)
		if free_usage_label:
			free_usage_label.text = display
	_update_refresh_ui_after_fetch()

func _on_usage_fetch_failed(_error_msg: String) -> void:
	if free_usage_label and config:
		free_usage_label.text = config.get_usage_display_text()
	if usage_circle_badge and config:
		usage_circle_badge.visible = config.is_using_free_trial_mode()
		usage_circle_badge.set_usage(float(config.usage_info.get("percent_remaining", 100.0)), config.get_usage_display_text())
	_update_refresh_ui_after_fetch()

func _on_limit_exhausted() -> void:
	_reset_state()
	show_limit_exhausted_dialog()

func _on_server_congested() -> void:
	show_warning_banner("The free tier is currently congested. Please insert your own API key (BYOK) in the plugin settings to bypass the shared queue.")

# ─── Usage Refresh System ────────────────────────────────────────────────────
func _setup_auto_refresh_timer() -> void:
	_usage_refresh_timer = Timer.new()
	add_child(_usage_refresh_timer)
	_usage_refresh_timer.timeout.connect(_on_auto_refresh_timer_timeout)
	
	if auto_refresh_check:
		auto_refresh_check.button_pressed = config.auto_refresh_usage
	if auto_refresh_interval:
		auto_refresh_interval.value = config.auto_refresh_interval_minutes
	
	_start_auto_refresh_timer()

func _start_auto_refresh_timer() -> void:
	if not _usage_refresh_timer:
		return
	_usage_refresh_timer.stop()
	if auto_refresh_check and auto_refresh_check.button_pressed:
		var interval_minutes: float = auto_refresh_interval.value if auto_refresh_interval else 5.0
		_usage_refresh_timer.wait_time = interval_minutes * 60.0
		_usage_refresh_timer.start()

func _on_auto_refresh_toggled(enabled: bool) -> void:
	config.auto_refresh_usage = enabled
	config.save_config()
	if enabled:
		_start_auto_refresh_timer()
	else:
		if _usage_refresh_timer:
			_usage_refresh_timer.stop()

func _on_auto_refresh_interval_changed(value: float) -> void:
	config.auto_refresh_interval_minutes = value
	config.save_config()
	if auto_refresh_check and auto_refresh_check.button_pressed:
		_start_auto_refresh_timer()

func _on_auto_refresh_timer_timeout() -> void:
	if config and config.is_using_free_trial_mode() and not _is_refreshing_usage:
		_refresh_usage()

func _on_refresh_usage_pressed() -> void:
	_refresh_usage()

func _refresh_usage() -> void:
	if not config or not network:
		return
	if _is_refreshing_usage:
		return
	_is_refreshing_usage = true
	if refresh_usage_btn:
		refresh_usage_btn.disabled = true
		refresh_usage_btn.text = "⏳"
	if last_refresh_label:
		last_refresh_label.text = "Refreshing..."
	network.fetch_usage(config)

func _update_refresh_ui_after_fetch() -> void:
	_is_refreshing_usage = false
	if refresh_usage_btn:
		refresh_usage_btn.disabled = false
		refresh_usage_btn.text = "🔄"
	if last_refresh_label:
		last_refresh_label.text = "Last: " + Time.get_time_string_from_system()

func show_limit_exhausted_dialog() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Free Limit Exhausted"
	dialog.dialog_text = "Free trial limit reached for today. Please insert your own API key in the plugin settings to continue seamlessly."
	add_child(dialog)
	dialog.popup_centered()

var _warning_banner: PanelContainer

func show_warning_banner(message: String) -> void:
	if not _warning_banner:
		_warning_banner = PanelContainer.new()
		var style_box := StyleBoxFlat.new()
		style_box.bg_color = Color(0.25, 0.12, 0.12, 0.95)
		style_box.border_color = Color(0.9, 0.3, 0.3, 0.8)
		style_box.border_width_bottom = 2
		style_box.border_width_top = 2
		style_box.border_width_left = 2
		style_box.border_width_right = 2
		style_box.corner_radius_top_left = 4
		style_box.corner_radius_top_right = 4
		style_box.corner_radius_bottom_left = 4
		style_box.corner_radius_bottom_right = 4
		style_box.content_margin_left = 10
		style_box.content_margin_top = 8
		style_box.content_margin_right = 10
		style_box.content_margin_bottom = 8
		_warning_banner.add_theme_stylebox_override("panel", style_box)
		
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 10)
		_warning_banner.add_child(hbox)
		
		var icon_lbl := Label.new()
		icon_lbl.text = "⚠️"
		hbox.add_child(icon_lbl)
		
		var text_lbl := Label.new()
		text_lbl.name = "WarningText"
		text_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		text_lbl.add_theme_font_size_override("font_size", 11)
		hbox.add_child(text_lbl)
		
		var close_btn := Button.new()
		close_btn.text = "✕"
		close_btn.flat = true
		close_btn.add_theme_font_size_override("font_size", 10)
		close_btn.pressed.connect(func(): _warning_banner.visible = false)
		hbox.add_child(close_btn)
		
		if chat_scroll:
			var left_panel = chat_scroll.get_parent()
			left_panel.add_child(_warning_banner)
			left_panel.move_child(_warning_banner, chat_scroll.get_index())
		else:
			add_child(_warning_banner)
		
	var warning_label = _warning_banner.find_child("WarningText", true, false) as Label
	if warning_label:
		warning_label.text = message
	_warning_banner.visible = true
	
	var timer = get_tree().create_timer(10.0)
	timer.timeout.connect(func():
		if is_instance_valid(_warning_banner):
			_warning_banner.visible = false
	)

# ─────────────────────────────────────────────────────────────────────────────
# APPROVAL PANEL
# ─────────────────────────────────────────────────────────────────────────────
func _show_approval_panel() -> void:
	if not changes_list or not approval_panel: return
	changes_list.clear()
	approval_panel.visible = true
	if approval_round_label: approval_round_label.text = "Round " + str(_agent_round)

	_set_status("📋 Round " + str(_agent_round), str(pending_actions.size()) + " action(s) ready — review below")

	var summary := ""
	for action in pending_actions:
		var act_type: String = action.get("action", action.get("type", "unknown"))
		var act_path: String = action.get("path", action.get("scene_path", ""))
		var icon := _action_icon(act_type)
		changes_list.add_item(icon + " [" + act_type.to_upper() + "]  " + act_path)
		summary += "• " + icon + " " + act_type.to_upper() + " " + act_path + "\n"

	_add_bubble("step", "📋 Round " + str(_agent_round) + " — " + str(pending_actions.size()) + " action(s):\n" + summary.strip_edges())

func _action_icon(t: String) -> String:
	match t:
		"create_file":      return "📄"
		"update_file":      return "✏️"
		"delete_file":      return "🗑"
		"modify_scene":     return "🎬"
		"create_scene":     return "🎬"
		"connect_signal":   return "🔌"
		"update_input_map": return "⚙"
		"set_main_scene":   return "🎯"
		"run_project":      return "▶"
		"task_complete":    return "✅"
		_:                  return "⚙"

# ─────────────────────────────────────────────────────────────────────────────
# APPROVE — execute actions then decide: verify or reflect
# ─────────────────────────────────────────────────────────────────────────────
func _on_approve_pressed() -> void:
	if pending_actions.is_empty(): return
	if approval_panel: approval_panel.visible = false

	_state = AgentState.EXECUTING
	if network: network.status = AINetwork.NetworkStatus.CALLING_TOOL
	_set_status("⚙ Executing", "Round " + str(_agent_round) + ": Applying " + str(pending_actions.size()) + " action(s)...")

	# Compute signature to detect repeating loops
	var current_sig := ""
	for a in pending_actions:
		current_sig += str(a.get("action","")) + ":" + str(a.get("path", a.get("scene_path",""))) + ";"

	var is_repeating := (current_sig == _last_action_signature and current_sig != "")
	_last_action_signature = current_sig

	log_to_console("[color=#66bb6a]▶ Executing Round " + str(_agent_round) + " — " + str(pending_actions.size()) + " action(s)...[/color]")

	var target_paths: Array[String] = _extract_action_target_paths(pending_actions)
	var edit_round_num: int = git_manager.get_next_round_number() if git_manager else (_total_actions_executed + 1)

	# Unset read-only classification if write operations are present
	var has_write_actions := false
	for a in pending_actions:
		var act_type := str(a.get("action", a.get("type", "")))
		if act_type not in ["read_file", "task_complete", "select_node", "open_scene", ""]:
			has_write_actions = true
			break
	if has_write_actions:
		_is_read_only_request = false

	# Read AI-requested run_project duration (if specified) before execution
	for a in pending_actions:
		if str(a.get("action", a.get("type", ""))) in ["run_project", "play_scene"]:
			var requested_duration := int(a.get("duration", 0))
			if requested_duration > 0:
				_ai_run_duration = clampi(requested_duration, 2, 30)  # Clamp: 2s min, 30s max
			break

	# Track modified files for self-corruption detection
	_last_modified_files = target_paths.duplicate()

	# 1. Save in-memory Godot scripts before AI modification
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 1/5] Saving open scripts...[/color]")
	ExecutionEngine.save_all_open_scripts(editor_interface)
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 1/5] Done.[/color]")

	# 2. Create pre-edit Git/Fallback checkpoint
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 2/5] Creating pre-edit checkpoint Round " + str(edit_round_num) + " (git_manager=" + str(git_manager != null) + ")...[/color]")
	if git_manager:
		git_manager.create_pre_edit_checkpoint(edit_round_num, _user_goal, target_paths)
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 2/5] Done.[/color]")

	# 3. Execute actions
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 3/5] Calling execute_actions on " + str(pending_actions.size()) + " actions...[/color]")
	for dbg_a in pending_actions:
		log_to_console("[color=#b0bec5]  → action=" + str(dbg_a.get("action","?")) + " path=" + str(dbg_a.get("path","?")) + "[/color]")
	var result: Dictionary = execution_engine.execute_actions(pending_actions, editor_interface)
	var success_cnt := int(result.get("success_count", 0))
	_total_actions_executed += success_cnt
	if success_cnt > 0:
		_is_read_only_request = false
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 3/5] Done. success_count=" + str(success_cnt) + " errors=" + str(result.get("errors", [])) + "[/color]")
	if network: network.status = AINetwork.NetworkStatus.IDLE

	# Merge actual modified files returned by execution engine into target_paths
	var exec_modified: Array = result.get("modified_files", [])
	for m_file in exec_modified:
		var sm := str(m_file)
		if not sm.is_empty() and not target_paths.has(sm):
			target_paths.append(sm)

	# 4. Force EditorFileSystem scan & create post-edit Git/Fallback commit checkpoint
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 4/5] Rescanning filesystem & creating post-edit checkpoint Round " + str(edit_round_num) + "...[/color]")
	if editor_interface and editor_interface.get_resource_filesystem():
		editor_interface.get_resource_filesystem().scan()

	if git_manager:
		git_manager.create_post_edit_checkpoint(edit_round_num, "Round " + str(edit_round_num) + " AI edits", target_paths)

	# Automatically update Diff Window if open
	if is_instance_valid(_diff_window_instance) and _diff_window_instance.has_method("refresh_history"):
		_diff_window_instance.call("refresh_history")

	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 4/5] Done.[/color]")

	# 5. Schedule deferred script reload
	log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 5/5] Scheduling editor script reload...[/color]")
	var reload_timer := get_tree().create_timer(0.2)
	reload_timer.timeout.connect(func():
		ExecutionEngine.reload_editor_scripts(editor_interface)
		log_to_console("[color=#4fc3f7]🔧 DEBUG [Step 5/5] Editor scripts reloaded.[/color]")
	)

	for l in result.get("logs", []):
		log_to_console("[color=#a5d6a7]  " + l + "[/color]")
	for e in result.get("errors", []):
		log_to_console("[color=#ef5350]  ✖ " + e + "[/color]")
		push_error(e)

	var applied: int = result.get("success_count", 0)
	var exec_errors: Array = result.get("errors", [])

	var exec_report := "=== Round " + str(_agent_round) + " Execution Report ===\n"
	exec_report += "Actions Requested: " + str(pending_actions.size()) + "\n"
	exec_report += "Actions Applied:   " + str(applied) + "\n"
	if not result.get("logs", []).is_empty():
		exec_report += "Success Logs:\n  • " + "\n  • ".join(result.get("logs", [])) + "\n"
	if not exec_errors.is_empty():
		exec_report += "Execution Errors:\n  • " + "\n  • ".join(exec_errors) + "\n"

	# Self-corruption warning: remind the agent of the ORIGINAL goal
	if _self_corruption_count > 0:
		exec_report += "\n⚠ SELF-CORRUPTION WARNING (attempt " + str(_self_corruption_count) + "): Your OWN changes caused the errors above!\n"
		exec_report += "Files you modified that now have errors: " + ", ".join(_last_modified_files) + "\n"
		if _self_corruption_count >= 2:
			exec_report += "CRITICAL: You have corrupted files " + str(_self_corruption_count) + " times. STOP modifying .tscn scene files!\n"
			exec_report += "Use ONLY GDScript (update_file on .gd files) to create nodes and shapes programmatically in _ready().\n"
		exec_report += "\n⚠ REMINDER — Original user goal: " + _user_goal + "\n"
		exec_report += "Do NOT forget the original task while fixing your own mistakes!\n"

	# Include git diff summary so reflection can verify what ACTUALLY changed on disk
	if git_manager and git_manager.is_git_available() and git_manager.is_git_repo():
		var diff_text := git_manager.get_last_diff_bbcode()
		if not diff_text.is_empty() and not diff_text.contains("No edit snapshots") and not diff_text.contains("No diff changes"):
			# Strip BBCode formatting for the text-based exec report
			var plain_diff := diff_text.replace("[color=#81c784]", "").replace("[color=#e57373]", "").replace("[color=#e0e0e0]", "").replace("[color=#90caf9]", "").replace("[color=#ce93d8]", "").replace("[/color]", "").replace("[b]", "").replace("[/b]", "").replace("[lb]", "[").replace("[rb]", "]")
			exec_report += "\n## Files Changed on Disk (Git Diff)\n```\n" + plain_diff.left(2000) + "\n```\n"

	# Store for reflection
	chat_history.append({"role": "user", "text": exec_report})

	_add_bubble("step",
		"✅ Round " + str(_agent_round) + " — Applied " + str(applied) + "/" + str(pending_actions.size()) + " action(s).\n"
		+ ("⚠ " + str(exec_errors.size()) + " execution error(s)." if not exec_errors.is_empty() else "")
	)

	pending_actions.clear()

	# Guard: if nothing applies repeatedly, detect immediately
	if is_repeating and applied == 0:
		log_to_console("[color=#ffd54f]⚠ Repeating loop detected — forcing strategy change...[/color]")
		_consecutive_empty_rounds += 1
	else:
		_consecutive_empty_rounds = 0

	if _consecutive_empty_rounds >= 3:
		_add_bubble("error", "❌ Agent is stuck: " + str(_consecutive_empty_rounds) + " rounds produced no applied changes. Stopping to prevent infinite loop.")
		_reset_state()
		return

	# ── Check round limit ──────────────────────────────────────────────────
	if _agent_round >= _max_agent_rounds:
		_add_bubble("step", "⚠️ Reached maximum rounds (" + str(_max_agent_rounds) + "). Stopping agent loop.")
		_finish_agent("Reached maximum rounds limit.")
		return

	# ── Skip verification for read-only or non-verifiable requests ────────
	if _should_skip_verification(has_write_actions):
		if _total_actions_executed > 0 or not _is_read_only_request:
			log_to_console("[color=#66bb6a]✅ File modifications completed successfully.[/color]")
			_add_bubble("step", "✅ File modifications applied successfully.")
			_finish_agent("File modifications completed successfully.")
		else:
			log_to_console("[color=#66bb6a]✅ Read-only request completed.[/color]")
			_add_bubble("step", "✅ Request completed — no verification needed for read-only operations.")
			_finish_agent("Read-only request completed successfully.")
		return

	# ── Auto-complete for read-only actions ───────────────────────────────
	if _should_auto_complete_after_actions(has_write_actions):
		log_to_console("[color=#66bb6a]✅ File reading complete. Auto-completing.[/color]")
		_add_bubble("step", "✅ Files read successfully.")
		_finish_agent("File reading completed.")
		return

	# ── Verification: run project and read logs ────────────────────────────
	if _agent_loop_enabled:
		await _run_verification_and_reflect(exec_report, is_repeating and applied == 0)
	else:
		# Manual mode: just stop and let user approve next round manually
		_clear_status()
		if generate_btn: generate_btn.text = "🚀 Send"

# Clear the runtime log file so verification only captures THIS run's output.
# Without this, stale prints from previous runs contaminate the data and allow
# false-positive feature verification.
func _clear_runtime_log_file() -> void:
	var godot_log_path := OS.get_user_data_dir().path_join("logs/godot.log")
	if FileAccess.file_exists(godot_log_path):
		var f := FileAccess.open(godot_log_path, FileAccess.WRITE)
		if f:
			f.store_string("")
			f.close()

# ─────────────────────────────────────────────────────────────────────────────
# VERIFICATION — run game, read all logs, then reflect
# ─────────────────────────────────────────────────────────────────────────────
func _run_verification_and_reflect(exec_report: String, is_repeating: bool) -> void:
	_state = AgentState.VERIFYING
	_set_status("▶ Verifying", "Running project to detect runtime errors...")

	var runtime_errors := ""
	var debug_output := ""

	if editor_interface:
		_add_bubble("step", "▶ Launching Godot project to verify changes...")
		log_to_console("[color=#4fc3f7]▶ Playing main scene...[/color]")

		# Clear the runtime log file BEFORE running so we only capture THIS run's output
		_clear_runtime_log_file()

		editor_interface.play_main_scene()
		# Use AI-requested duration if set, otherwise default 5 seconds
		var run_secs: float = float(_ai_run_duration) if _ai_run_duration > 0 else 5.0
		log_to_console("[color=#4fc3f7]⏱ Running project for " + str(run_secs) + "s (" + ("AI-requested" if _ai_run_duration > 0 else "default") + ")...[/color]")
		await get_tree().create_timer(run_secs).timeout
		editor_interface.stop_playing_scene()
		_ai_run_duration = 0  # Reset after use
		# Give editor a moment to flush logs
		await get_tree().create_timer(1.0).timeout
		log_to_console("[color=#4fc3f7]⏹ Test run complete. Reading all logs...[/color]")

	# Read all available log streams
	var all_raw_logs := project_context.fetch_all_native_logs(editor_interface)
	runtime_errors = _extract_errors_from_logs(all_raw_logs)
	debug_output = _extract_debug_prints_from_logs(all_raw_logs)
	_last_debug_output = debug_output  # Store for task_complete guard

	# ── REFACTOR #3: TRUTH-SOURCE INJECTION ────────────────────────────────
	# Wrap the raw log output in strict anti-hallucination delimiters.
	# This prevents the agent from inventing log lines that didn't occur.
	var truth_log_block := ProjectContext.build_truth_log_block(all_raw_logs.left(3000))
	log_to_console("[color=#b0bec5]📋 Truth-Source Logs captured. " + str(all_raw_logs.count("\n")) + " lines.[/color]")

	var same_error_persists: bool = (not runtime_errors.is_empty() and runtime_errors == _last_runtime_errors)
	_last_runtime_errors = runtime_errors

	if runtime_errors.is_empty():
		log_to_console("[color=#66bb6a]✅ No errors found in runtime logs.[/color]")
		_add_bubble("step", "✅ No runtime errors detected. Verification passed.")
		# If code modifications were applied and 0 runtime errors exist, complete task cleanly!
		if _total_actions_executed > 0:
			log_to_console("[color=#66bb6a]✅ All code modifications verified clean with 0 errors. Task complete.[/color]")
			_finish_agent("All code modifications applied and verified clean with 0 runtime errors.")
			return
	else:
		log_to_console("[color=#ffd54f]⚠ Errors found in logs — sending to agent for fixing...[/color]")
		_add_bubble("step", "🐞 Runtime errors detected:\n[color=#ef5350]" + runtime_errors.left(600) + "[/color]")

	if not debug_output.is_empty():
		log_to_console("[color=#b0bec5]📋 Debug prints captured from game run.[/color]")

	# Self-corruption detection: check if errors are in files the agent just modified
	if not runtime_errors.is_empty() and not _last_modified_files.is_empty():
		var self_inflicted := false
		for modified_file in _last_modified_files:
			if runtime_errors.contains(modified_file.trim_prefix("res://")) or runtime_errors.contains(modified_file):
				self_inflicted = true
				break
		if self_inflicted:
			_self_corruption_count += 1
			log_to_console("[color=#ef5350]⚠ SELF-CORRUPTION DETECTED (attempt " + str(_self_corruption_count) + "): Agent's own changes caused new errors![/color]")
			_add_bubble("step", "⚠️ Self-corruption detected — the agent's changes broke files that previously worked.")
		else:
			_self_corruption_count = 0  # Reset if errors are in different files
	else:
		_self_corruption_count = 0

	# Check if the goal requires user interaction to verify
	var needs_user_verification := _goal_requires_user_interaction(_user_goal)
	var has_alpha_debug := debug_output.contains("[ALPHA_DEBUG]")
	var has_feature_proof := _has_feature_confirming_prints(debug_output)

	# NEVER ask for user gameplay verification when runtime errors exist.
	# If the game crashes, the user CAN'T interact with it — send to reflection
	# so the agent can fix the errors first.
	# Only ask ONCE for user verification per goal to prevent infinite loops.
	if runtime_errors.is_empty() and needs_user_verification and not has_feature_proof and _user_verification_count == 0:
		_user_verification_count += 1
		# Ask user to interact with the game to verify
		_add_bubble("step", "🎮 This task requires gameplay verification. Please click Play in Godot, interact with the game (move, collect items, etc.), then click 'Resume Step' to continue.")
		log_to_console("[color=#ffd54f]🎮 Waiting for user gameplay verification — no feature-confirming prints detected.[/color]")
		_state = AgentState.VERIFYING
		if generate_btn: generate_btn.text = "🔄 Resume Step"
		return

	_run_reflection_step(exec_report, runtime_errors, debug_output, is_repeating or same_error_persists, truth_log_block)

func _goal_requires_user_interaction(goal: String) -> bool:
	var lower_goal := goal.to_lower()
	# Goals that need actual gameplay testing
	var interaction_keywords := [
		"collid", "collect", "pickup", "pick up", "score", "point",
		"move", "walk", "run", "jump", "dash",
		"damage", "health", "die", "death", "kill",
		"enemy", "attack", "fight", "battle",
		"button", "click", "press", "input",
		"signal", "connect", "emit",
		"animation", "animate", "tween",
		"physics", "gravity", "velocity", "acceleration"
	]
	for keyword in interaction_keywords:
		if lower_goal.contains(keyword):
			return true
	return false

# ─────────────────────────────────────────────────────────────────────────────
# REQUEST CLASSIFICATION — Determine if request is read-only or needs modifications
# ─────────────────────────────────────────────────────────────────────────────
func _classify_read_only_request(goal: String) -> bool:
	var lower_goal := goal.to_lower().strip_edges()
	
	# Read-only request patterns
	var read_only_patterns := [
		"read my code", "read the code", "read code", "show me code", "show code",
		"view code", "view my code", "display code", "display my code",
		"what does", "what is in", "what's in", "explain code", "explain my code",
		"analyze code", "analyze my code", "review code", "review my code",
		"check code", "check my code", "look at code", "look at my code",
		"inspect code", "inspect my code", "examine code", "examine my code",
		"show me the", "show the", "list files", "list all", "what files",
		"what's in the project", "what is in the project", "project structure",
		"file structure", "folder structure", "directory structure",
		"can you read", "could you read", "please read", "read the file",
		"read file", "read this file", "read these files"
	]
	
	for pattern in read_only_patterns:
		if lower_goal.contains(pattern):
			return true
	
	# If it's a very short request (likely simple), classify as read-only
	if lower_goal.length() < 50 and not lower_goal.contains("fix") and not lower_goal.contains("add") and not lower_goal.contains("create") and not lower_goal.contains("change") and not lower_goal.contains("update") and not lower_goal.contains("modify") and not lower_goal.contains("delete") and not lower_goal.contains("remove"):
		# Check if it's asking about code/files
		if lower_goal.contains("code") or lower_goal.contains("file") or lower_goal.contains("script") or lower_goal.contains("scene"):
			return true
	
	return false

func _should_skip_verification(has_write_actions: bool = false) -> bool:
	# Skip verification for read-only requests
	if _is_read_only_request:
		return true
	
	# Skip verification if no file modifications were made
	if _total_actions_executed == 0:
		return true
	
	return not has_write_actions

func _should_auto_complete_after_actions(has_write_actions: bool = false) -> bool:
	if has_write_actions:
		return false
	# Auto-complete for read-only requests after first round
	if _is_read_only_request and _total_actions_executed > 0:
		return true
	return false

# ─────────────────────────────────────────────────────────────────────────────
# LOG READING — all sources, comprehensive
# ─────────────────────────────────────────────────────────────────────────────
func _read_all_errors() -> String:
	var all_logs: String = project_context.fetch_all_native_logs(editor_interface)
	if all_logs.is_empty():
		return ""

	var lines: PackedStringArray = all_logs.split("\n")
	var error_lines: Array[String] = []
	var seen: Dictionary = {}

	for raw_line in lines:
		var l: String = raw_line.strip_edges()
		if l.is_empty(): continue
		var lower: String = l.to_lower()
		if lower.contains("alpha_ai_agent") or lower.contains("addons/alpha_ai_agent"):
			continue
		var is_error: bool = (
			lower.contains("error:") or
			lower.contains("script error") or
			lower.contains("parse error") or
			lower.contains("invalid call") or
			lower.contains("invalid get index") or
			lower.contains("null instance") or
			lower.contains("failed loading") or
			lower.contains("failed to open") or
			lower.contains("cannot open") or
			lower.contains("does not exist") or
			lower.contains("is not declared") or
			lower.contains("identifier") and lower.contains("not found") or
			lower.contains("missing") and lower.contains("scene") or
			lower.contains("cannot find") or
			lower.contains("@warning_ignore") == false and lower.contains("warning:") == false and lower.contains("inputmap action") and lower.contains("doesn't exist")
		)
		if is_error and not seen.has(l):
			seen[l] = true
			error_lines.append(l)

	# Cap to last 30 unique errors to avoid overwhelming the prompt
	if error_lines.size() > 30:
		error_lines = error_lines.slice(error_lines.size() - 30)

	return "\n".join(error_lines)

func _extract_errors_from_logs(all_logs: String) -> String:
	if all_logs.is_empty():
		return ""
	var lines := all_logs.split("\n")
	var error_lines: Array[String] = []
	var seen: Dictionary = {}
	for raw_line in lines:
		var l := raw_line.strip_edges()
		if l.is_empty(): continue
		var lower := l.to_lower()
		if lower.contains("alpha_ai_agent") or lower.contains("addons/alpha_ai_agent"): continue
		var is_error: bool = (
			lower.contains("error:") or lower.contains("script error") or
			lower.contains("parse error") or lower.contains("invalid call") or
			lower.contains("invalid get index") or lower.contains("null instance") or
			lower.contains("failed loading") or lower.contains("failed to open") or
			lower.contains("cannot open") or lower.contains("does not exist") or
			lower.contains("is not declared") or
			(lower.contains("identifier") and lower.contains("not found")) or
			(lower.contains("missing") and lower.contains("scene")) or
			lower.contains("cannot find") or
			(lower.contains("inputmap action") and lower.contains("doesn't exist") and not lower.contains("@warning_ignore"))
		)
		if is_error and not seen.has(l):
			seen[l] = true
			error_lines.append(l)
	if error_lines.size() > 30:
		error_lines = error_lines.slice(error_lines.size() - 30)
	return "\n".join(error_lines)

func _extract_debug_prints_from_logs(all_logs: String) -> String:
	if all_logs.is_empty():
		return ""
	var lines := all_logs.split("\n")
	var debug_lines: Array[String] = []
	for raw_line in lines:
		var l := raw_line.strip_edges()
		if l.is_empty(): continue
		if l.to_lower().contains("alpha_ai_agent") or l.to_lower().contains("addons/alpha_ai_agent"): continue
		# ONLY capture lines that explicitly contain [ALPHA_DEBUG] marker
		# This prevents stale output, normal engine prints, and other noise
		# from contaminating the verification data
		if l.contains("[ALPHA_DEBUG]"):
			debug_lines.append(l)
	# Keep last 60 debug lines
	if debug_lines.size() > 60:
		debug_lines = debug_lines.slice(debug_lines.size() - 60)
	return "\n".join(debug_lines)


# ─────────────────────────────────────────────────────────────────────────────
# REJECT / ABORT
# ─────────────────────────────────────────────────────────────────────────────

func _on_reject_pressed() -> void:
	pending_actions.clear()
	if approval_panel: approval_panel.visible = false
	_add_bubble("system", "🚫 Proposed changes rejected by user.")
	_reset_state()

func _abort_agent() -> void:
	network.cancel_request()
	_is_generating = false
	_remove_typing_indicator()
	_clear_status()
	if generate_btn: generate_btn.text = "🚀 Send"
	if status_label: status_label.text = "Cancelled"
	_add_bubble("error", "🛑 Agent stopped by user.")
	_reset_state()

# ─────────────────────────────────────────────────────────────────────────────
# AUTOCOMPLETE SYSTEM
# ─────────────────────────────────────────────────────────────────────────────
func _setup_autocomplete() -> void:
	if not prompt_edit:
		return
	
	# Find autocomplete nodes dynamically
	autocomplete_panel = get_node_or_null("RootVBox/ViewContainer/ChatView/LeftPanel/AutocompletePanel")
	if autocomplete_panel:
		autocomplete_list = autocomplete_panel.get_node_or_null("AutocompleteMargin/AutocompleteScroll/AutocompleteList")
		print("[ALPHA_DEBUG] AutocompletePanel found: ", autocomplete_panel != null)
		print("[ALPHA_DEBUG] AutocompleteList found: ", autocomplete_list != null)
	else:
		print("[ALPHA_DEBUG] AutocompletePanel NOT FOUND at path: RootVBox/ViewContainer/ChatView/LeftPanel/AutocompletePanel")
		# Try alternative path
		autocomplete_panel = find_child("AutocompletePanel", true, false)
		if autocomplete_panel:
			print("[ALPHA_DEBUG] Found AutocompletePanel via find_child")
			autocomplete_list = autocomplete_panel.find_child("AutocompleteList", true, false)
	
	# Connect text change signal
	prompt_edit.text_changed.connect(_on_prompt_text_changed)
	print("[ALPHA_DEBUG] Autocomplete text_changed signal connected")
	
	# Load all project resources
	_refresh_project_resources()
	print("[ALPHA_DEBUG] Project resources loaded: ", _all_project_resources.size())
	
	# Hide autocomplete when input loses focus (but not when clicking suggestions)
	prompt_edit.focus_exited.connect(func():
		# Delay to allow clicking on suggestions
		get_tree().create_timer(0.3).timeout.connect(func():
			if _autocomplete_active and not _autocomplete_clicking:
				_hide_autocomplete()
		)
	)
	
	# Load all project resources
	_refresh_project_resources()

func _refresh_project_resources() -> void:
	_all_project_resources.clear()
	
	# Use global path for DirAccess
	var global_path := ProjectSettings.globalize_path("res://")
	if global_path.is_empty():
		print("[ALPHA_DEBUG] Could not globalize res:// path")
		return
	
	print("[ALPHA_DEBUG] Scanning project at: ", global_path)
	
	# Scan for scripts
	var scripts := _find_files_by_extension_global(global_path, ".gd")
	for script_path in scripts:
		if script_path.contains("addons/alpha_ai_agent/"):
			continue
		# Convert back to res:// path
		var res_path := "res://" + script_path.trim_prefix(global_path).replace("\\", "/")
		_all_project_resources.append({
			"path": res_path,
			"name": res_path.get_file().get_basename(),
			"type": "script",
			"icon": "📜",
			"trigger": "/"
		})
	
	# Scan for scenes
	var scenes := _find_files_by_extension_global(global_path, ".tscn")
	for scene_path in scenes:
		if scene_path.contains("addons/alpha_ai_agent/"):
			continue
		var res_path := "res://" + scene_path.trim_prefix(global_path).replace("\\", "/")
		_all_project_resources.append({
			"path": res_path,
			"name": res_path.get_file().get_basename(),
			"type": "scene",
			"icon": "🎬",
			"trigger": "#"
		})
	
	# Scan for resources
	var resource_exts := [".tres", ".res", ".gdshader"]
	for ext in resource_exts:
		var resources := _find_files_by_extension_global(global_path, ext)
		for res_path_raw in resources:
			if res_path_raw.contains("addons/alpha_ai_agent/"):
				continue
			var res_path := "res://" + res_path_raw.trim_prefix(global_path).replace("\\", "/")
			_all_project_resources.append({
				"path": res_path,
				"name": res_path.get_file().get_basename(),
				"type": "resource",
				"icon": "📦",
				"trigger": "/"
			})
	
	print("[ALPHA_DEBUG] Total resources found: ", _all_project_resources.size())
	
	# Scan for nodes in current scene (if open)
	_scan_scene_nodes()

func _find_files_by_extension_global(global_path: String, ext: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(global_path)
	if not dir:
		print("[ALPHA_DEBUG] Could not open directory: ", global_path, " error: ", DirAccess.get_open_error())
		return result
	
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not file_name.begins_with("."):
			var full_path := global_path.path_join(file_name)
			if dir.current_is_dir():
				if file_name != ".godot" and file_name != ".git" and file_name != "addons":
					result.append_array(_find_files_by_extension_global(full_path, ext))
			elif file_name.ends_with(ext):
				result.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return result

func _scan_scene_nodes() -> void:
	if not editor_interface:
		return
	var edited_scene := editor_interface.get_edited_scene_root()
	if not edited_scene:
		return
	_collect_nodes_recursive(edited_scene, "")

func _collect_nodes_recursive(node: Node, path_prefix: String) -> void:
	var node_path := path_prefix + node.name if path_prefix.is_empty() else path_prefix + "/" + node.name
	var node_type := node.get_class()
	var icon := "🔵"  # Default node icon
	
	# Set icon based on type
	match node_type:
		"CharacterBody2D", "CharacterBody3D":
			icon = "🏃"
		"Area2D", "Area3D":
			icon = "⭕"
		"Sprite2D", "Sprite3D", "AnimatedSprite2D", "AnimatedSprite3D":
			icon = "🖼️"
		"CollisionShape2D", "CollisionShape3D":
			icon = "🔷"
		"Camera2D", "Camera3D":
			icon = "📷"
		"AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D":
			icon = "🔊"
		"Timer":
			icon = "⏱️"
		"Label", "RichTextLabel":
			icon = "📝"
		"Button", "TextureButton":
			icon = "🔘"
		"Control", "Container", "Panel", "PanelContainer":
			icon = "📐"
		_:
			icon = "🔵"
	
	_all_project_resources.append({
		"path": node_path,
		"name": node.name,
		"type": "node",
		"node_type": node_type,
		"icon": icon,
		"trigger": "@"
	})
	
	for child in node.get_children():
		_collect_nodes_recursive(child, node_path)

func _on_prompt_text_changed() -> void:
	if not prompt_edit:
		return
	
	var text := prompt_edit.text
	var cursor_pos := prompt_edit.get_caret_column()
	
	# Check if we just typed a trigger character
	if cursor_pos > 0:
		var last_char := text.substr(cursor_pos - 1, 1)
		if last_char in ["/", "@", "#"]:
			_autocomplete_trigger = last_char
			_autocomplete_start_pos = cursor_pos
			print("[ALPHA_DEBUG] Trigger detected: ", last_char, " at pos ", cursor_pos)
			_show_autocomplete("")
			return
	
	# If autocomplete is active, update suggestions based on current word
	if _autocomplete_active and _autocomplete_start_pos >= 0:
		var current_word := ""
		var pos := cursor_pos - 1
		while pos >= _autocomplete_start_pos:
			var c := text.substr(pos, 1)
			if c == " " or c == "\n":
				break
			current_word = c + current_word
			pos -= 1
		
		print("[ALPHA_DEBUG] Autocomplete active, current_word: '", current_word, "', trigger: ", _autocomplete_trigger)
		if current_word.is_empty() and _autocomplete_trigger != "":
			_show_autocomplete("")
		else:
			_show_autocomplete(current_word)
	else:
		if _autocomplete_active:
			_hide_autocomplete()

func _show_autocomplete(filter: String) -> void:
	if not autocomplete_list or not autocomplete_panel:
		print("[ALPHA_DEBUG] _show_autocomplete: autocomplete_list or autocomplete_panel is null")
		return
	
	print("[ALPHA_DEBUG] _show_autocomplete called with filter: '", filter, "', trigger: ", _autocomplete_trigger)
	
	# Refresh node list if using @ trigger
	if _autocomplete_trigger == "@":
		_scan_scene_nodes()
	
	# Clear existing items
	for child in autocomplete_list.get_children():
		child.queue_free()
	
	_autocomplete_suggestions.clear()
	
	var filter_lower := filter.to_lower()
	
	for resource in _all_project_resources:
		if resource["trigger"] != _autocomplete_trigger:
			continue
		
		var name_lower: String = str(resource["name"]).to_lower()
		var path_lower: String = str(resource["path"]).to_lower()
		
		if filter.is_empty() or name_lower.contains(filter_lower) or path_lower.contains(filter_lower):
			_autocomplete_suggestions.append(resource)
	
	print("[ALPHA_DEBUG] Suggestions found: ", _autocomplete_suggestions.size())
	
	if _autocomplete_suggestions.is_empty():
		_hide_autocomplete()
		return
	
	# Build suggestion buttons
	var idx := 0
	for resource in _autocomplete_suggestions:
		var btn := Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		
		var display_text: String = resource["icon"] + " " + resource["name"]
		if resource["type"] == "node":
			display_text += " (" + str(resource["node_type"]) + ")"
		else:
			display_text += " (" + resource["type"] + ")"
		
		btn.text = display_text
		btn.custom_minimum_size = Vector2(0, 30)
		
		# Style the button
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.2, 0.22, 0.28, 0.95)
		style.corner_radius_top_left = 4
		style.corner_radius_top_right = 4
		style.corner_radius_bottom_left = 4
		style.corner_radius_bottom_right = 4
		style.set_content_margin_all(8)
		btn.add_theme_stylebox_override("normal", style)
		
		var hover_style := StyleBoxFlat.new()
		hover_style.bg_color = Color(0.3, 0.4, 0.6, 0.95)
		hover_style.corner_radius_top_left = 4
		hover_style.corner_radius_top_right = 4
		hover_style.corner_radius_bottom_left = 4
		hover_style.corner_radius_bottom_right = 4
		hover_style.set_content_margin_all(8)
		btn.add_theme_stylebox_override("hover", hover_style)
		
		btn.add_theme_font_size_override("font_size", 12)
		btn.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
		
		var selected_idx := idx
		btn.pressed.connect(func():
			_autocomplete_clicking = true
			_on_autocomplete_item_clicked(selected_idx)
			_autocomplete_clicking = false
		)
		
		autocomplete_list.add_child(btn)
		idx += 1
	
	# Position the panel above the input area
	_autocomplete_active = true
	
	# Add a background style to the panel
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.15, 0.17, 0.22, 0.98)
	panel_style.border_color = Color(0.4, 0.5, 0.7, 0.8)
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.set_content_margin_all(4)
	autocomplete_panel.add_theme_stylebox_override("panel", panel_style)
	
	# Find InputArea for positioning
	var input_area := prompt_edit.get_parent().get_parent().get_parent()  # InputHBox -> InputMargin -> InputArea
	if input_area:
		var panel_height := min(_autocomplete_suggestions.size() * 34 + 12, 250)
		var panel_width := max(input_area.size.x - 16, 300)
		
		# Force size on all children
		autocomplete_panel.custom_minimum_size = Vector2(panel_width, panel_height)
		autocomplete_panel.size = Vector2(panel_width, panel_height)
		
		# Position above the input area
		autocomplete_panel.position = Vector2(
			input_area.global_position.x + 8,
			input_area.global_position.y - panel_height - 4
		)
		print("[ALPHA_DEBUG] Panel positioned at: ", autocomplete_panel.position, " size: ", autocomplete_panel.size)
		print("[ALPHA_DEBUG] Input area at: ", input_area.global_position, " size: ", input_area.size)
	
	autocomplete_panel.visible = true
	autocomplete_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	
	# Force the panel to update
	autocomplete_panel.queue_redraw()
	if autocomplete_list:
		autocomplete_list.queue_redraw()
	
	# Keep focus on prompt edit
	prompt_edit.grab_focus()

func _hide_autocomplete() -> void:
	if autocomplete_panel:
		autocomplete_panel.visible = false
		autocomplete_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_autocomplete_active = false
	_autocomplete_trigger = ""
	_autocomplete_start_pos = -1

func _on_autocomplete_item_clicked(index: int) -> void:
	print("[ALPHA_DEBUG] Item clicked: ", index)
	if index < 0 or index >= _autocomplete_suggestions.size():
		print("[ALPHA_DEBUG] Invalid index: ", index, " suggestions size: ", _autocomplete_suggestions.size())
		return
	
	var selected: Dictionary = _autocomplete_suggestions[index]
	var path: String = selected["path"]
	print("[ALPHA_DEBUG] Selected path: ", path)
	
	if not prompt_edit:
		print("[ALPHA_DEBUG] prompt_edit is null")
		return
	
	# Replace the trigger + partial text with the selected path
	var text := prompt_edit.text
	var cursor_pos := prompt_edit.get_caret_column()
	
	# Find the start of the current word (after trigger)
	var word_start := _autocomplete_start_pos
	var word_end := cursor_pos
	
	print("[ALPHA_DEBUG] Text: '", text, "', cursor: ", cursor_pos, " word_start: ", word_start, " word_end: ", word_end)
	
	# Replace the text
	var before := text.substr(0, word_start - 1)  # Before the trigger
	var after := text.substr(word_end)
	
	# Insert the path with proper formatting
	var insertion := _autocomplete_trigger + path
	prompt_edit.text = before + insertion + after
	prompt_edit.set_caret_column(before.length() + insertion.length())
	
	print("[ALPHA_DEBUG] New text: '", prompt_edit.text, "'")
	
	_hide_autocomplete()
	prompt_edit.grab_focus()

func _find_files_by_extension(path: String, ext: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(path)
	if not dir:
		return result
	
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not file_name.begins_with("."):
			var full_path := path.path_join(file_name)
			if dir.current_is_dir():
				if file_name != ".godot" and file_name != ".git":
					result.append_array(_find_files_by_extension(full_path, ext))
			elif file_name.ends_with(ext):
				result.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return result

# ─────────────────────────────────────────────────────────────────────────────
# FILE PATH CLICKABLE HELPERS
# ─────────────────────────────────────────────────────────────────────────────
func _make_file_paths_clickable(text: String) -> String:
	# Pattern to match res:// paths (scripts, scenes, resources)
	var regex := RegEx.new()
	regex.compile("(res://[\\w/\\.\\-]+\\.(gd|tscn|tres|gdshader|json|cfg|godot))")
	var result := text
	var matches := regex.search_all(text)
	
	# Process matches in reverse to avoid offset issues
	for i in range(matches.size() - 1, -1, -1):
		var m := matches[i]
		var path := m.get_string(1)
		var start := m.get_start(1)
		var end := m.get_end(1)
		
		# Create clickable link with BBCode
		var file_name := path.get_file()
		var icon := _get_file_icon(path)
		var replacement := "[url=" + path + "]" + icon + " " + file_name + "[/url]"
		result = result.substr(0, start) + replacement + result.substr(end)
	
	return result

func _get_file_icon(path: String) -> String:
	var ext := path.get_extension().to_lower()
	match ext:
		"gd": return "📜"
		"tscn": return "🎬"
		"tres": return "📦"
		"gdshader": return "🎨"
		"json": return "📋"
		"cfg", "godot": return "⚙️"
		_: return "📄"

func _open_file_in_editor(path: String) -> void:
	if not editor_interface:
		return
	
	var ext := path.get_extension().to_lower()
	match ext:
		"gd":
			# Open script in script editor
			var script := ResourceLoader.load(path) as Script
			if script:
				editor_interface.edit_script(script)
				log_to_console("[color=#4fc3f7]📜 Opened script: " + path + "[/color]")
		"tscn":
			# Open scene in scene editor
			if FileAccess.file_exists(path):
				editor_interface.open_scene_from_path(path)
				log_to_console("[color=#4fc3f7]🎬 Opened scene: " + path + "[/color]")
		"tres":
			# Open resource in inspector
			var resource := ResourceLoader.load(path)
			if resource:
				editor_interface.inspect_object(resource)
				log_to_console("[color=#4fc3f7]📦 Opened resource: " + path + "[/color]")
		_:
			# Try to open in filesystem
			if FileAccess.file_exists(path):
				editor_interface.get_resource_filesystem().call_deferred("navigate_to_path", path)
				log_to_console("[color=#4fc3f7]📄 Navigated to: " + path + "[/color]")

# ─────────────────────────────────────────────────────────────────────────────
# FINISH / RESET
# ─────────────────────────────────────────────────────────────────────────────
func _finish_agent(summary: String) -> void:
	_state = AgentState.DONE
	_clear_status()
	if generate_btn: generate_btn.text = "🚀 Send"
	if status_label: status_label.text = "✅ Done"
	
	# Show appropriate message based on request type and actual file modifications
	if _is_read_only_request and _total_actions_executed == 0:
		log_to_console("[color=#66bb6a]✅ Read-only request completed in " + str(_agent_round) + " round(s).[/color]")
		_add_bubble("system", "✨ [b]Request Complete[/b] (Read-only)\n\n" + summary)
	else:
		log_to_console("[color=#66bb6a]✅ Agent task complete after " + str(_agent_round) + " round(s).[/color]")
		_add_bubble("system", "✨ [b]Task Complete[/b] (after " + str(_agent_round) + " round(s))\n\n" + summary)
	
	_agent_round = 0
	_state = AgentState.IDLE

func _reset_state() -> void:
	_state = AgentState.IDLE
	_agent_round = 0
	_is_generating = false
	_missing_json_retry_count = 0
	_consecutive_empty_rounds = 0
	_last_action_signature = ""
	_last_runtime_errors = ""
	_last_debug_output = ""
	_user_verification_count = 0
	_self_corruption_count = 0
	_last_modified_files = []
	_total_actions_executed = 0
	_hallucination_count = 0
	_is_read_only_request = false
	_archived_context_prefix = ""
	_ai_run_duration = 0
	_pipeline.reset_for_new_prompt()  # Archive completed task, reset loop counter
	_clear_status()
	if generate_btn: generate_btn.text = "🚀 Send"
	if status_label: status_label.text = "Ready"

func _get_agent_progress() -> String:
	return "Round " + str(_agent_round) + "/" + str(_max_agent_rounds) + " | Actions executed: " + str(_total_actions_executed)

func _should_use_small_model_for_stage(stage: String) -> bool:
	# Use small model for quick decisions, big model for code generation
	match stage:
		"CLASSIFY", "CONTEXT_SELECT", "DECOMPOSE", "AUDIT":
			return true
		"REFLECT":
			# ALWAYS use big model for interactive goals (collision, movement, collection)
			# Small models are too eager to claim completion without real proof
			if _goal_requires_user_interaction(_user_goal):
				return false
			# Use small model for simple reflections, big model for complex error analysis
			return _last_runtime_errors.is_empty() or _consecutive_empty_rounds == 0
		_:
			return false

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
func _contains_task_complete(actions: Array[Dictionary]) -> bool:
	for a in actions:
		if str(a.get("action", a.get("type", ""))) == "task_complete":
			return true
	return false

func _user_goal_requests_action_or_testing(goal: String) -> bool:
	var g := goal.to_lower()
	return (
		g.contains("run") or
		g.contains("play") or
		g.contains("test") or
		g.contains("fix") or
		g.contains("check") or
		g.contains("wrong") or
		g.contains("error") or
		g.contains("log") or
		g.contains("bug") or
		g.contains("debug")
	)

# ─────────────────────────────────────────────────────────────────────────────
# FEATURE-CONFIRMING PRINT DETECTION
# Distinguishes prints that PROVE a feature fired from informational prints
# ─────────────────────────────────────────────────────────────────────────────
# Informational prints like "Item spawned at:", "Player ready at:", "Distance:",
# "Item close to player!" only show state, NOT that a feature actually triggered.
# Feature-confirming prints show an EVENT occurred: collection, collision, signal
# firing, score change, state transition, etc.
var _FEATURE_CONFIRM_KEYWORDS: PackedStringArray = PackedStringArray([
	"item collected",
	"item successfully collected",
	"body entered",
	"body_exited",
	"area entered",
	"area_exited",
	"collision detected",
	"player hit",
	"player damaged",
	"score updated",
	"score:",
	"health changed",
	"state changed to",
	"signal emitted",
	"on_collect",
	"on_body_entered",
	"on_area_entered",
	"consumed",
	"picked up",
])

func _has_feature_confirming_prints(debug_output: String) -> bool:
	if debug_output.is_empty():
		return false
	# Check each line individually — must be an [ALPHA_DEBUG] line with an event keyword
	var lines := debug_output.split("\n")
	for line in lines:
		var l := line.strip_edges()
		if l.is_empty() or not l.contains("[ALPHA_DEBUG]"):
			continue
		var lower_line := l.to_lower()
		for keyword in _FEATURE_CONFIRM_KEYWORDS:
			if lower_line.contains(keyword):
				return true
	return false

# Detect if the LLM's response FABRICATES claims about ALPHA_DEBUG prints
# that don't actually exist in the captured logs. This catches hallucination
# where the LLM says "prints confirm feature works" but no such prints exist.
func _response_hallucinates_proof(response_text: String, actual_debug_output: String) -> bool:
	var lower_response := response_text.to_lower()
	var lower_actual := actual_debug_output.to_lower()

	# Method 1: Check if the response QUOTES specific [ALPHA_DEBUG] output that doesn't exist in logs
	# Extract any text the LLM puts inside quotes after mentioning ALPHA_DEBUG
	var regex := RegEx.new()
	regex.compile("\\[alpha_debug\\][^\\]\\n]{5,80}")
	var matches := regex.search_all(lower_response)
	for m in matches:
		var claimed_print := m.get_string().strip_edges()
		if not claimed_print.is_empty() and not lower_actual.contains(claimed_print):
			return true

	# Method 2: Check for common false-proof claim phrases
	var false_claim_phrases := [
		"verified event-triggering debug print",
		"debug print confirms",
		"debug logs confirm",
		"prints confirm the feature",
		"prints show the feature is working",
		"prints confirm",
		"event-triggering debug",
		"confirming that",
		"are occurring during gameplay",
		"collision detected with",
		"item collected and",
		"item successfully collected",
	]

	for phrase in false_claim_phrases:
		if lower_response.contains(phrase):
			# The LLM claims this was found in prints.
			# Verify the ACTUAL debug output contains a matching [ALPHA_DEBUG] line.
			if not lower_actual.contains(phrase):
				return true

	# Method 3: If the response claims task is complete but actual logs are empty.
	# IMPORTANT: SKIP this check entirely for read-only requests — they never run
	# the game so logs are always empty. False-positive on every read/explain task.
	if not _is_read_only_request and lower_actual.strip_edges().is_empty():
		# Only trigger if agent is claiming runtime EVENT evidence in a modification context
		if lower_response.contains("verified event-triggering") or lower_response.contains("prints confirm the feature") or lower_response.contains("working correctly based on debug"):
			return true

	return false

# ─────────────────────────────────────────────────────────────────────────────
# STRUCTURED RESPONSE PARSING
# Extracts sections from the mega-prompt's structured format
# ─────────────────────────────────────────────────────────────────────────────
func _parse_structured_response(response_text: String) -> Dictionary:
	var sections := {
		"summary": "",
		"analysis": "",
		"actions": "",
		"verification": "",
		"next_steps": "",
		"raw": response_text
	}
	
	var current_section := ""
	var lines := response_text.split("\n")
	
	for line in lines:
		var trimmed := line.strip_edges()
		
		# Detect section headers
		if trimmed.begins_with("## 📋 SUMMARY") or trimmed.begins_with("## SUMMARY"):
			current_section = "summary"
			continue
		elif trimmed.begins_with("## 🧠 DETAILED ANALYSIS") or trimmed.begins_with("## DETAILED ANALYSIS") or trimmed.begins_with("## ANALYSIS"):
			current_section = "analysis"
			continue
		elif trimmed.begins_with("## 🔧 ACTIONS TAKEN") or trimmed.begins_with("## ACTIONS TAKEN") or trimmed.begins_with("## ACTIONS"):
			current_section = "actions"
			continue
		elif trimmed.begins_with("## ✅ VERIFICATION EVIDENCE") or trimmed.begins_with("## VERIFICATION") or trimmed.begins_with("## VERIFICATION EVIDENCE"):
			current_section = "verification"
			continue
		elif trimmed.begins_with("## 📝 NEXT STEPS") or trimmed.begins_with("## NEXT STEPS"):
			current_section = "next_steps"
			continue
		elif trimmed.begins_with("## ") and not trimmed.begins_with("## 📋") and not trimmed.begins_with("## 🧠") and not trimmed.begins_with("## 🔧") and not trimmed.begins_with("## ✅") and not trimmed.begins_with("## 📝"):
			# Unknown section header, stop parsing
			current_section = ""
			continue
		
		# Append to current section
		if current_section != "" and not current_section.is_empty():
			sections[current_section] += line + "\n"
	
	# Trim whitespace from all sections
	for key in sections:
		if key != "raw":
			sections[key] = sections[key].strip_edges()
	
	return sections

func _format_structured_display(sections: Dictionary) -> String:
	var display := ""
	
	# Show Summary (always visible)
	if not sections["summary"].is_empty():
		display += "[b]📋 Summary:[/b]\n" + sections["summary"] + "\n\n"
	
	# Show Analysis (collapsed if long)
	if not sections["analysis"].is_empty():
		if sections["analysis"].length() > 500:
			display += "[b]🧠 Analysis:[/b] (see full response for details)\n" + sections["analysis"].left(500) + "...\n\n"
		else:
			display += "[b]🧠 Analysis:[/b]\n" + sections["analysis"] + "\n\n"
	
	# Show Actions taken (always visible)
	if not sections["actions"].is_empty():
		display += "[b]🔧 Actions:[/b]\n" + sections["actions"] + "\n\n"
	
	# Show Verification (always visible - critical for proof)
	if not sections["verification"].is_empty():
		display += "[b]✅ Verification:[/b]\n" + sections["verification"] + "\n\n"
	
	# Show Next Steps (always visible)
	if not sections["next_steps"].is_empty():
		display += "[b]📝 Next Steps:[/b]\n" + sections["next_steps"] + "\n\n"
	
	# Fallback: if no sections were parsed, show stripped raw text
	if display.is_empty():
		display = _strip_json_block(sections["raw"])
		if display.is_empty():
			display = "Changes have been prepared and are ready for review."
	
	return display.strip_edges()

func _strip_json_block(text: String) -> String:
	# Walk through and collect all text outside of ```...``` fences
	var result := ""
	var in_block := false
	var i := 0
	var lines := text.split("\n")
	for line in lines:
		var stripped := line.strip_edges()
		if stripped.begins_with("```"):
			in_block = not in_block
			continue
		if not in_block:
			result += line + "\n"
	var cleaned := result.strip_edges()
	return cleaned if not cleaned.is_empty() else "Changes have been prepared and are ready for review."

func _extract_action_target_paths(actions: Array) -> Array[String]:
	var result_paths: Array[String] = []
	for a in actions:
		if not (a is Dictionary): continue
		for key in ["path", "target_file", "file_path", "scene_path", "script_path", "file", "target_path", "script", "scene"]:
			var val := str(a.get(key, "")).strip_edges()
			if not val.is_empty() and (val.begins_with("res://") or val.contains(".")):
				if not result_paths.has(val):
					result_paths.append(val)
				break
	return result_paths

func log_to_console(msg: String) -> void:
	if console_output: console_output.append_text(msg + "\n")

# ─────────────────────────────────────────────────────────────────────────────
# GIT DIFF & REVERT HANDLERS
# ─────────────────────────────────────────────────────────────────────────────
func _on_diff_pressed() -> void:
	if not git_manager: return

	if not _diff_window_instance:
		_diff_window_instance = AIDiffWindowScene.instantiate() as Window
		add_child(_diff_window_instance)
		if _diff_window_instance.has_signal("confirmed_edits"):
			_diff_window_instance.connect("confirmed_edits", func(msg: String):
				log_to_console("[color=#81c784]✅ " + msg + "[/color]")
				_add_bubble("system", "✅ " + msg)
			)
		if _diff_window_instance.has_signal("reverted_round"):
			_diff_window_instance.connect("reverted_round", func(msg: String):
				log_to_console("[color=#ef5350]↩ " + msg + "[/color]")
				_add_bubble("system", "↩ " + msg)
				var reload_timer := get_tree().create_timer(0.2)
				reload_timer.timeout.connect(func():
					ExecutionEngine.reload_editor_scripts(editor_interface)
				)
			)
 
	_diff_window_instance.call("setup", git_manager, editor_interface)
	_diff_window_instance.popup_centered(Vector2i(960, 620))
 
func _on_revert_pressed() -> void:
	if not git_manager: return
	ExecutionEngine.save_all_open_scripts(editor_interface)
	var res: Dictionary = git_manager.revert_last_ai_commit()
	var msg: String = str(res.get("message", ""))
	if bool(res.get("success", false)):
		log_to_console("[color=#66bb6a]↩ " + msg + "[/color]")
		_add_bubble("system", "↩ " + msg)
		var reload_timer := get_tree().create_timer(0.2)
		reload_timer.timeout.connect(func():
			ExecutionEngine.reload_editor_scripts(editor_interface)
		)
		if _diff_window_instance and _diff_window_instance.visible:
			_diff_window_instance.call("refresh_history")
	else:
		log_to_console("[color=#ef5350]✖ Revert failed: " + msg + "[/color]")
		_add_bubble("system", "✖ Revert failed: " + msg)

# ─────────────────────────────────────────────────────────────────────────────
# VERSION CHECKER SYSTEM
# Checks version on load and hourly (3600s). Prompts user if a new update is available.
# ─────────────────────────────────────────────────────────────────────────────
func _setup_version_checker() -> void:
	_version_http_request = HTTPRequest.new()
	_version_http_request.name = "VersionCheckHTTPRequest"
	add_child(_version_http_request)
	_version_http_request.request_completed.connect(_on_version_check_completed)

	_version_check_timer = Timer.new()
	_version_check_timer.name = "VersionCheckTimer"
	_version_check_timer.wait_time = 3600.0  # Check every 1 hour (3600 seconds)
	_version_check_timer.autostart = true
	_version_check_timer.one_shot = false
	add_child(_version_check_timer)
	_version_check_timer.timeout.connect(_check_plugin_version)

	# Trigger initial check on load
	_check_plugin_version()

func _check_plugin_version() -> void:
	if not _version_http_request: return
	if _version_http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	# Cache buster query parameter ensures fresh responses from GitHub Pages CDN
	var cache_buster_url := VERSION_CHECK_URL + "?t=" + str(Time.get_unix_time_from_system())
	_version_http_request.request(cache_buster_url)

func _on_version_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		return

	var raw_text := body.get_string_from_utf8().strip_edges()
	if raw_text.is_empty():
		return

	var latest_version := ""
	var download_url := UPDATE_REDIRECT_URL
	var changelog_text := ""

	# Extract JSON string {...} if raw_text contains HTML tags from Jekyll/GitHub Pages
	var json_str := raw_text
	var brace_start := json_str.find("{")
	var brace_end := json_str.rfind("}")
	if brace_start != -1 and brace_end != -1 and brace_end > brace_start:
		json_str = json_str.substr(brace_start, brace_end - brace_start + 1)

	# 1. Try parsing as JSON first (supports structured version + changelog)
	var json := JSON.new()
	if json.parse(json_str) == OK and json.data is Dictionary:
		var data: Dictionary = json.data
		latest_version = str(data.get("version", "")).strip_edges()
		if data.has("download_url") and not str(data["download_url"]).is_empty():
			download_url = str(data["download_url"]).strip_edges()

		if data.has("changes"):
			if data["changes"] is Array:
				var list_items: Array = data["changes"]
				var formatted_items: Array[String] = []
				for item in list_items:
					formatted_items.append("• " + str(item))
				changelog_text = "\n".join(formatted_items)
			elif data["changes"] is String:
				changelog_text = str(data["changes"])
		elif data.has("changelog"):
			changelog_text = str(data["changelog"])

		# 2. Extract Notice / Announcement data
		if data.has("notice"):
			_pending_notice_data = data["notice"]
		elif data.has("notices"):
			_pending_notice_data = data["notices"]
	else:
		# Fallback to plain text version string
		latest_version = _parse_version_string(raw_text)

	if latest_version.is_empty():
		if _pending_notice_data != null:
			_process_notice_data(_pending_notice_data)
			_pending_notice_data = null
		return

	_latest_detected_version = latest_version
	if _is_version_newer(latest_version, PLUGIN_CURRENT_VERSION):
		log_to_console("[color=#ffd54f]🚀 A new version of Alpha AI Agent is available: v" + latest_version + " (installed: v" + PLUGIN_CURRENT_VERSION + ")[/color]")
		var bubble_msg := "🚀 [b]New Update Available![/b] v" + latest_version + " is available. (Installed: v" + PLUGIN_CURRENT_VERSION + ")"
		if not changelog_text.is_empty():
			bubble_msg += "\n\n[b]What's New in v" + latest_version + ":[/b]\n" + changelog_text
		_add_bubble("system", bubble_msg)
		_show_version_update_popup(latest_version, changelog_text, download_url)
	else:
		# If no update dialog is needed, process notices immediately
		if _pending_notice_data != null:
			_process_notice_data(_pending_notice_data)
			_pending_notice_data = null

func _parse_version_string(raw: String) -> String:
	var regex := RegEx.new()
	regex.compile("\\d+\\.\\d+\\.\\d+(?:-[a-zA-Z0-9.]+)?")
	var m := regex.search(raw)
	if m:
		return m.get_string()
	return raw.strip_edges()

func _is_version_newer(latest: String, current: String) -> bool:
	var l_parts := latest.split(".")
	var c_parts := current.split(".")
	var count := max(l_parts.size(), c_parts.size())
	for i in range(count):
		var l_num := int(l_parts[i]) if i < l_parts.size() else 0
		var c_num := int(c_parts[i]) if i < c_parts.size() else 0
		if l_num > c_num:
			return true
		elif l_num < c_num:
			return false
	return false

func _show_version_update_popup(latest_version: String, changelog_text: String = "", redirect_url: String = UPDATE_REDIRECT_URL) -> void:
	if not _update_popup_dialog or not is_instance_valid(_update_popup_dialog):
		_update_popup_dialog = AcceptDialog.new()
		_update_popup_dialog.title = "🚀 Alpha AI Agent — Update Available!"
		_update_popup_dialog.ok_button_text = "🌐 Download Update (itch.io)"
		_update_popup_dialog.add_cancel_button("Later")
		_update_popup_dialog.exclusive = false
		add_child(_update_popup_dialog)

	if _update_popup_dialog.is_connected("confirmed", _on_update_dialog_confirmed):
		_update_popup_dialog.disconnect("confirmed", _on_update_dialog_confirmed)
	if _update_popup_dialog.is_connected("canceled", _on_update_dialog_closed):
		_update_popup_dialog.disconnect("canceled", _on_update_dialog_closed)

	_update_popup_dialog.set_meta("redirect_url", redirect_url)
	_update_popup_dialog.confirmed.connect(_on_update_dialog_confirmed)
	_update_popup_dialog.canceled.connect(_on_update_dialog_closed)

	var msg := (
		"A new version of Alpha AI Agent is available!\n\n"
		+ "• Installed Version: v" + PLUGIN_CURRENT_VERSION + "\n"
		+ "• Latest Version: v" + latest_version + "\n\n"
	)
	if not changelog_text.is_empty():
		msg += "What's New in v" + latest_version + ":\n" + changelog_text + "\n\n"

	msg += "Click below to open the download page."
	_update_popup_dialog.dialog_text = msg
	_update_popup_dialog.popup_centered(Vector2i(520, 300))

func _on_update_dialog_confirmed() -> void:
	var url := UPDATE_REDIRECT_URL
	if _update_popup_dialog and _update_popup_dialog.has_meta("redirect_url"):
		url = str(_update_popup_dialog.get_meta("redirect_url"))
	OS.shell_open(url)
	_on_update_dialog_closed()

func _on_update_dialog_closed() -> void:
	# Show queued notices after update dialog is closed
	if _pending_notice_data != null:
		var notice_data := _pending_notice_data
		_pending_notice_data = null
		_process_notice_data(notice_data)

# ─────────────────────────────────────────────────────────────────────────────
# REMOTE NOTICE / ANNOUNCEMENT SYSTEM (WITH SEQUENTIAL QUEUE)
# ─────────────────────────────────────────────────────────────────────────────
var _notice_queue: Array[Dictionary] = []

func _process_notice_data(notice_data: Variant) -> void:
	_notice_queue.clear()
	var notices_list: Array = []
	if notice_data is Dictionary:
		notices_list.append(notice_data)
	elif notice_data is Array:
		notices_list = notice_data

	for n in notices_list:
		if not (n is Dictionary): continue
		var n_dict: Dictionary = n
		var n_id: int = int(n_dict.get("id", 0))
		if n_id <= 0: continue

		# Skip if user already marked this notice ID as done
		if _is_notice_dismissed(n_id):
			continue

		var n_title: String = str(n_dict.get("title", "📢 Notice"))
		var n_message: String = str(n_dict.get("message", ""))
		var n_url: String = str(n_dict.get("url", ""))
		var n_btn_text: String = str(n_dict.get("button_text", "🌐 Open Link"))

		if not n_message.is_empty():
			_notice_queue.append({
				"id": n_id,
				"title": n_title,
				"message": n_message,
				"url": n_url,
				"button_text": n_btn_text
			})

	# Show first notice in queue
	_show_next_notice_in_queue()

func _show_next_notice_in_queue() -> void:
	if _notice_queue.is_empty():
		return

	var notice: Dictionary = _notice_queue.pop_front()
	_show_notice_dialog(
		int(notice.get("id", 0)),
		str(notice.get("title", "")),
		str(notice.get("message", "")),
		str(notice.get("url", "")),
		str(notice.get("button_text", ""))
	)

func _show_notice_dialog(notice_id: int, title: String, message: String, url: String, button_text: String) -> void:
	if is_instance_valid(_notice_popup_dialog):
		_notice_popup_dialog.queue_free()

	_notice_popup_dialog = AcceptDialog.new()
	_notice_popup_dialog.title = title
	_notice_popup_dialog.ok_button_text = "✔ Mark as Done"
	_notice_popup_dialog.exclusive = false
	add_child(_notice_popup_dialog)

	if not url.is_empty():
		var btn_label := button_text if not button_text.is_empty() else "🌐 Open Link"
		_notice_popup_dialog.add_button(btn_label, false, "open_url")

	_notice_popup_dialog.add_button("Skip", false, "skip")

	_notice_popup_dialog.custom_action.connect(func(action_name: String):
		if action_name == "open_url":
			OS.shell_open(url)
		elif action_name == "skip":
			_notice_popup_dialog.hide()
			_show_next_notice_in_queue()
	)

	_notice_popup_dialog.confirmed.connect(func():
		_save_dismissed_notice(notice_id)
		_notice_popup_dialog.hide()
		log_to_console("[color=#81c784]✅ Notice ID " + str(notice_id) + " marked as done.[/color]")
		_show_next_notice_in_queue()
	)

	_notice_popup_dialog.dialog_text = message
	_notice_popup_dialog.popup_centered(Vector2i(500, 240))

# ── Notice Persistence Helpers ────────────────────────────────────────────────
func _load_dismissed_notices() -> Array[int]:
	var result: Array[int] = []
	if not FileAccess.file_exists(DISMISSED_NOTICES_FILE):
		return result
	var f := FileAccess.open(DISMISSED_NOTICES_FILE, FileAccess.READ)
	if not f: return result
	var content := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(content) == OK and json.data is Array:
		for item in json.data:
			result.append(int(item))
	return result

func _is_notice_dismissed(notice_id: int) -> bool:
	var dismissed := _load_dismissed_notices()
	return dismissed.has(notice_id)

func _save_dismissed_notice(notice_id: int) -> void:
	var dismissed := _load_dismissed_notices()
	if not dismissed.has(notice_id):
		dismissed.append(notice_id)
		var f := FileAccess.open(DISMISSED_NOTICES_FILE, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(dismissed))
			f.close()

# ─────────────────────────────────────────────────────────────────────────────
# SUPPORT & COMMUNITY BUTTONS
# ─────────────────────────────────────────────────────────────────────────────
func _setup_support_button() -> void:
	if support_dev_btn and is_instance_valid(support_dev_btn):
		return

	# 1. Support Button (itch.io)
	support_dev_btn = Button.new()
	support_dev_btn.name = "SupportDevBtn"
	support_dev_btn.text = "❤️ Support"
	support_dev_btn.tooltip_text = "Support Alpha AI Agent development on itch.io"
	support_dev_btn.focus_mode = Control.FOCUS_NONE

	var support_normal := StyleBoxFlat.new()
	support_normal.bg_color = Color("#e91e63")
	support_normal.corner_radius_top_left = 4
	support_normal.corner_radius_top_right = 4
	support_normal.corner_radius_bottom_left = 4
	support_normal.corner_radius_bottom_right = 4
	support_normal.content_margin_left = 8
	support_normal.content_margin_right = 8
	support_normal.content_margin_top = 3
	support_normal.content_margin_bottom = 3

	var support_hover := support_normal.duplicate() as StyleBoxFlat
	support_hover.bg_color = Color("#ff4081")

	var support_pressed := support_normal.duplicate() as StyleBoxFlat
	support_pressed.bg_color = Color("#c2185b")

	support_dev_btn.add_theme_stylebox_override("normal", support_normal)
	support_dev_btn.add_theme_stylebox_override("hover", support_hover)
	support_dev_btn.add_theme_stylebox_override("pressed", support_pressed)
	support_dev_btn.add_theme_color_override("font_color", Color.WHITE)
	support_dev_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	support_dev_btn.pressed.connect(func(): OS.shell_open(UPDATE_REDIRECT_URL))

	# 2. Discord Button
	discord_btn = Button.new()
	discord_btn.name = "DiscordBtn"
	discord_btn.text = "💬 Discord"
	discord_btn.tooltip_text = "Join our Discord Community (" + DISCORD_URL + ")"
	discord_btn.focus_mode = Control.FOCUS_NONE

	var discord_normal := support_normal.duplicate() as StyleBoxFlat
	discord_normal.bg_color = Color("#5865F2")

	var discord_hover := support_normal.duplicate() as StyleBoxFlat
	discord_hover.bg_color = Color("#7983F5")

	var discord_pressed := support_normal.duplicate() as StyleBoxFlat
	discord_pressed.bg_color = Color("#4752C4")

	discord_btn.add_theme_stylebox_override("normal", discord_normal)
	discord_btn.add_theme_stylebox_override("hover", discord_hover)
	discord_btn.add_theme_stylebox_override("pressed", discord_pressed)
	discord_btn.add_theme_color_override("font_color", Color.WHITE)
	discord_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	discord_btn.pressed.connect(func(): OS.shell_open(DISCORD_URL))

	# 3. Report Bug Button (GitHub Issues)
	report_bug_btn = Button.new()
	report_bug_btn.name = "ReportBugBtn"
	report_bug_btn.text = "🐛 Report Bug"
	report_bug_btn.tooltip_text = "Report an issue or request a feature on GitHub"
	report_bug_btn.focus_mode = Control.FOCUS_NONE

	var bug_normal := support_normal.duplicate() as StyleBoxFlat
	bug_normal.bg_color = Color("#238636")

	var bug_hover := support_normal.duplicate() as StyleBoxFlat
	bug_hover.bg_color = Color("#2ea44f")

	var bug_pressed := support_normal.duplicate() as StyleBoxFlat
	bug_pressed.bg_color = Color("#1e7e34")

	report_bug_btn.add_theme_stylebox_override("normal", bug_normal)
	report_bug_btn.add_theme_stylebox_override("hover", bug_hover)
	report_bug_btn.add_theme_stylebox_override("pressed", bug_pressed)
	report_bug_btn.add_theme_color_override("font_color", Color.WHITE)
	report_bug_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	report_bug_btn.pressed.connect(func(): OS.shell_open(GITHUB_ISSUES_URL))

	# Place in top toolbar beside Settings button (Report Bug & Support only)
	if tab_btn_settings and tab_btn_settings.get_parent():
		var parent_box = tab_btn_settings.get_parent()
		var settings_idx := tab_btn_settings.get_index()
		parent_box.add_child(report_bug_btn)
		parent_box.add_child(support_dev_btn)
		parent_box.move_child(report_bug_btn, settings_idx + 1)
		parent_box.move_child(support_dev_btn, settings_idx + 2)

	# Setup Banners in Settings View
	if settings_view and settings_view.get_child_count() > 0:
		var container = settings_view.get_child(0)
		if container is VBoxContainer:
			pass  # Banners removed

# ─────────────────────────────────────────────────────────────────────────────
# CLEAR API KEYS
# ─────────────────────────────────────────────────────────────────────────────
func _setup_clear_keys_button() -> void:
	if save_key_btn and save_key_btn.get_parent():
		var parent_box = save_key_btn.get_parent()
		if not parent_box.has_node("ClearKeysBtn"):
			clear_keys_btn = Button.new()
			clear_keys_btn.name = "ClearKeysBtn"
			clear_keys_btn.text = "🗑️ Clear Keys"
			clear_keys_btn.tooltip_text = "Clear all saved API keys and return to Free Trial mode"
			parent_box.add_child(clear_keys_btn)
			_connect_safe(clear_keys_btn, "pressed", _on_clear_keys_pressed)

func _on_clear_keys_pressed() -> void:
	if config:
		config.clear_all_api_keys()
	if api_key_edit:
		api_key_edit.text = ""
	if key_status_label:
		key_status_label.text = "Keys Cleared (Using Free Trial Mode)"
		key_status_label.add_theme_color_override("font_color", Color("#81c784"))
	if free_trial_check:
		free_trial_check.button_pressed = true
	_update_key_display()
	log_to_console("[color=#81c784]🧹 All saved API keys have been cleared successfully.[/color]")
