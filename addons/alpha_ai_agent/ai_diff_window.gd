@tool
extends Window

signal confirmed_edits(msg: String)
signal reverted_round(msg: String)

var git_manager: AIGitManager
var editor_interface: EditorInterface

@onready var rounds_list: ItemList               = %RoundsList
@onready var files_list: ItemList                = %FilesList
@onready var before_code_label: RichTextLabel   = %BeforeCodeLabel
@onready var after_code_label: RichTextLabel    = %AfterCodeLabel
@onready var diff_code_label: RichTextLabel     = %DiffCodeLabel
@onready var confirm_edits_btn: Button           = %ConfirmEditsBtn
@onready var revert_round_btn: Button            = %RevertRoundBtn
@onready var close_btn: Button                   = %CloseBtn

var _rounds_data: Array[Dictionary] = []
var _selected_round: int = -1
var _selected_file: String = ""

func _ready() -> void:
	close_requested.connect(func(): hide())
	if close_btn: close_btn.pressed.connect(func(): hide())
	if rounds_list: rounds_list.item_selected.connect(_on_round_selected)
	if files_list: files_list.item_selected.connect(_on_file_selected)
	if confirm_edits_btn: confirm_edits_btn.pressed.connect(_on_confirm_edits_pressed)
	if revert_round_btn: revert_round_btn.pressed.connect(_on_revert_round_pressed)

func setup(p_git_manager: AIGitManager, p_editor_interface: EditorInterface) -> void:
	git_manager = p_git_manager
	editor_interface = p_editor_interface
	refresh_history()

func refresh_history() -> void:
	if not git_manager: return
	rounds_list.clear()
	files_list.clear()
	before_code_label.clear()
	after_code_label.clear()
	diff_code_label.clear()

	_rounds_data = git_manager.get_history_rounds()
	if _rounds_data.is_empty():
		rounds_list.add_item("No AI edit history rounds found")
		return

	for idx in range(_rounds_data.size()):
		var r_data: Dictionary = _rounds_data[idx]
		var r_num: int = int(r_data.get("round", idx + 1))
		var r_files: Array = r_data.get("files", [])
		var confirmed: bool = bool(r_data.get("confirmed", false))
		
		var status_icon := "✅" if confirmed else "📝"
		var status_text := " [CONFIRMED]" if confirmed else " [UNCONFIRMED]"
		rounds_list.add_item(status_icon + " Round " + str(r_num) + " (" + str(r_files.size()) + " file(s))" + status_text)

	# Select latest unconfirmed round by default, or latest round if all confirmed
	var default_idx := _rounds_data.size() - 1
	for idx in range(_rounds_data.size() - 1, -1, -1):
		var r_data: Dictionary = _rounds_data[idx]
		if not bool(r_data.get("confirmed", false)):
			default_idx = idx
			break
	
	if _rounds_data.size() > 0:
		rounds_list.select(default_idx)
		_on_round_selected(default_idx)

func _on_round_selected(index: int) -> void:
	if index < 0 or index >= _rounds_data.size(): return
	files_list.clear()
	before_code_label.clear()
	after_code_label.clear()
	diff_code_label.clear()

	var r_data: Dictionary = _rounds_data[index]
	_selected_round = int(r_data.get("round", index + 1))
	var files: Array = r_data.get("files", [])
	var confirmed: bool = bool(r_data.get("confirmed", false))

	# Update button states based on confirmation status
	if confirm_edits_btn:
		confirm_edits_btn.disabled = confirmed
		confirm_edits_btn.text = "✅ Already Confirmed" if confirmed else "✅ Confirm All Edits"
	if revert_round_btn:
		revert_round_btn.disabled = false

	if files.is_empty():
		files_list.add_item("No project files modified in this round")
		return

	for f_path in files:
		files_list.add_item("📄 " + str(f_path))

	files_list.select(0)
	_on_file_selected(0)

func _on_file_selected(index: int) -> void:
	if _selected_round <= 0 or index < 0: return
	if index >= files_list.item_count: return

	var item_text := files_list.get_item_text(index)
	_selected_file = item_text.trim_prefix("📄 ").strip_edges()

	if not git_manager: return
	var comp: Dictionary = git_manager.get_file_comparison(_selected_round, _selected_file)
	var before_text: String = str(comp.get("before", ""))
	var after_text: String = str(comp.get("after", ""))
	var diff_bb: String = str(comp.get("diff_bb", ""))

	before_code_label.clear()
	before_code_label.append_text(_format_numbered_code(before_text, "#ffcdd2"))

	after_code_label.clear()
	after_code_label.append_text(_format_numbered_code(after_text, "#c8e6c9"))

	diff_code_label.clear()
	diff_code_label.append_text(diff_bb)

func _format_numbered_code(code: String, bg_color: String) -> String:
	if code.is_empty():
		return "[color=#888888](File did not exist)[/color]"
	var lines := code.split("\n")
	var formatted: Array[String] = []
	for i in range(lines.size()):
		var line_num := str(i + 1).lpad(4, " ")
		var safe_line := lines[i].replace("[", "[lb]").replace("]", "[rb]")
		formatted.append("[color=#777777]" + line_num + " │ [/color]" + safe_line)
	return "\n".join(formatted)

func _on_confirm_edits_pressed() -> void:
	if not git_manager: return
	var res: Dictionary = git_manager.confirm_and_lock_edits()
	var msg: String = str(res.get("message", "Edits confirmed and locked."))
	confirmed_edits.emit(msg)
	refresh_history()

func _on_revert_round_pressed() -> void:
	if not git_manager: return
	if _selected_round <= 0:
		return
	
	var res: Dictionary = git_manager.revert_specific_round(_selected_round)
	var msg: String = str(res.get("message", "Reverted round."))
	var success: bool = bool(res.get("success", false))
	
	if success:
		reverted_round.emit(msg)
		refresh_history()
	else:
		# Show error in the diff view
		diff_code_label.clear()
		diff_code_label.append_text("[color=#ef5350]❌ " + msg + "[/color]")