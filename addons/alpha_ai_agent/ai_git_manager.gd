@tool
class_name AIGitManager
extends RefCounted

const COMMIT_PREFIX := "Alpha AI Agent: "
const BACKUP_DIR := "user://ai_agent_backups"
const CONFIRMED_FILE := "user://ai_agent_backups/confirmed.json"

var _project_path: String = ""
var _is_git_present: bool = false
var _checkpoint_history: Array[String] = []
var _confirmed_rounds: Array[int] = []

func _init(p_project_path: String = "res://") -> void:
	_project_path = ProjectSettings.globalize_path(p_project_path)
	_check_git_environment()
	_load_confirmed_state()

func _check_git_environment() -> void:
	var res := _run_git(["--version"])
	_is_git_present = (res.get("exit_code", -1) == 0)

func _load_confirmed_state() -> void:
	if _confirmed_rounds == null:
		_confirmed_rounds = []
	if not FileAccess.file_exists(CONFIRMED_FILE):
		return
	var f := FileAccess.open(CONFIRMED_FILE, FileAccess.READ)
	if not f:
		return
	var content := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(content) == OK and json.data is Array:
		_confirmed_rounds.clear()
		for item in json.data:
			_confirmed_rounds.append(int(item))

func _save_confirmed_state() -> void:
	if _confirmed_rounds == null:
		_confirmed_rounds = []
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BACKUP_DIR))
	var f := FileAccess.open(CONFIRMED_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_confirmed_rounds))
		f.close()

func is_round_confirmed(round_num: int) -> bool:
	if _confirmed_rounds == null:
		_confirmed_rounds = []
	return _confirmed_rounds.has(round_num)

func confirm_round(round_num: int) -> void:
	if _confirmed_rounds == null:
		_confirmed_rounds = []
	if not _confirmed_rounds.has(round_num):
		_confirmed_rounds.append(round_num)
		_confirmed_rounds.sort()
		_save_confirmed_state()

func confirm_all_rounds() -> void:
	if _confirmed_rounds == null:
		_confirmed_rounds = []
	var all_rounds := get_history_rounds()
	for r_data in all_rounds:
		var r_num: int = int(r_data.get("round", 0))
		if r_num > 0 and not _confirmed_rounds.has(r_num):
			_confirmed_rounds.append(r_num)
	_confirmed_rounds.sort()
	_save_confirmed_state()

func is_git_available() -> bool:
	return _is_git_present

func is_git_repo() -> bool:
	if not _is_git_present: return false
	var res := _run_git(["rev-parse", "--is-inside-work-tree"])
	return res.get("exit_code", -1) == 0 and str(res.get("output", "")).strip_edges() == "true"

func ensure_git_repo() -> bool:
	if not _is_git_present: return false
	if is_git_repo():
		_ensure_gitignore()
		return true

	var res := _run_git(["init"])
	if res.get("exit_code", -1) == 0:
		_ensure_gitignore()
		_run_git(["add", "--", ".", ":(exclude)addons/alpha_ai_agent/"])
		_run_git(["commit", "-m", COMMIT_PREFIX + "Initial repository creation"])
		return true
	return false

func _ensure_gitignore() -> void:
	var gitignore_path := _project_path.path_join(".gitignore")
	var content := ""
	if FileAccess.file_exists(gitignore_path):
		var f := FileAccess.open(gitignore_path, FileAccess.READ)
		if f:
			content = f.get_as_text()
			f.close()

	var modified := false
	if not content.contains(".godot/"):
		content += "\n.godot/\n"
		modified = true
	if not content.contains("*.tmp"):
		content += "*.tmp\n"
		modified = true

	if modified:
		var f_out := FileAccess.open(gitignore_path, FileAccess.WRITE)
		if f_out:
			f_out.store_string(content)
			f_out.close()

func _is_addon_path(path: String) -> bool:
	var clean := path.trim_prefix("res://").strip_edges()
	return clean.begins_with("addons/alpha_ai_agent") or clean.begins_with("addons/")

# ─────────────────────────────────────────────────────────────────────────────
# CHECKPOINT CREATION (Git + Fallback)
# ─────────────────────────────────────────────────────────────────────────────
func create_pre_edit_checkpoint(round_num: int, goal_summary: String, target_paths: Array = []) -> String:
	# Filter out any addon/plugin paths
	var filtered_paths: Array[String] = []
	for p in target_paths:
		var sp := str(p)
		if not sp.is_empty() and not _is_addon_path(sp):
			filtered_paths.append(sp)

	# 1. ALWAYS copy target files to user:// pre-edit backup folder for Diff Viewer
	var round_dir := BACKUP_DIR.path_join("round_" + str(round_num)).path_join("before")
	DirAccess.make_dir_recursive_absolute(round_dir)
	
	for path_val in filtered_paths:
		var global_p := ProjectSettings.globalize_path(path_val) if path_val.begins_with("res://") else path_val
		if FileAccess.file_exists(global_p):
			var rel_p := path_val.trim_prefix("res://")
			var backup_dst := round_dir.path_join(rel_p)
			DirAccess.make_dir_recursive_absolute(backup_dst.get_base_dir())
			DirAccess.copy_absolute(global_p, backup_dst)

	# 2. Stage & commit in Git if available
	if _is_git_present and ensure_git_repo():
		var status_res := _run_git(["status", "--porcelain", "--", ".", ":(exclude)addons/alpha_ai_agent/"])
		var status_out: String = str(status_res.get("output", "")).strip_edges()
		if status_res.get("exit_code", -1) == 0 and not status_out.is_empty():
			_run_git(["add", "--", ".", ":(exclude)addons/alpha_ai_agent/"])
			var msg := COMMIT_PREFIX + "Pre-edit snapshot for Round " + str(round_num) + " (External Changes: " + goal_summary.left(40) + ")"
			_run_git(["commit", "-m", msg])

		var rev_res := _run_git(["rev-parse", "HEAD"])
		if rev_res.get("exit_code", -1) == 0:
			var sha: String = str(rev_res.get("output", "")).strip_edges()
			_checkpoint_history.append(sha)
			return sha

	var snapshot_id := "round_" + str(round_num)
	_checkpoint_history.append(snapshot_id)
	return snapshot_id

func create_post_edit_checkpoint(round_num: int, summary: String, target_paths: Array = []) -> String:
	# Filter out any addon/plugin paths
	var filtered_paths: Array[String] = []
	for p in target_paths:
		var sp := str(p)
		if not sp.is_empty() and not _is_addon_path(sp):
			filtered_paths.append(sp)

	# 1. ALWAYS copy modified files to user:// post-edit backup folder for Diff Viewer
	var round_dir := BACKUP_DIR.path_join("round_" + str(round_num)).path_join("after")
	DirAccess.make_dir_recursive_absolute(round_dir)

	for path_val in filtered_paths:
		var global_p := ProjectSettings.globalize_path(path_val) if path_val.begins_with("res://") else path_val
		if FileAccess.file_exists(global_p):
			var rel_p := path_val.trim_prefix("res://")
			var backup_dst := round_dir.path_join(rel_p)
			DirAccess.make_dir_recursive_absolute(backup_dst.get_base_dir())
			DirAccess.copy_absolute(global_p, backup_dst)

	# 2. Stage & commit in Git if available
	if _is_git_present and is_git_repo():
		_run_git(["add", "--", ".", ":(exclude)addons/alpha_ai_agent/"])
		var status_res := _run_git(["status", "--porcelain", "--", ".", ":(exclude)addons/alpha_ai_agent/"])
		var status_out: String = str(status_res.get("output", "")).strip_edges()
		if status_res.get("exit_code", -1) == 0 and not status_out.is_empty():
			var clean_summary := summary.replace("\n", " ").strip_edges()
			if clean_summary.is_empty():
				clean_summary = "Applied file modifications"
			var msg := COMMIT_PREFIX + "Round " + str(round_num) + " - " + clean_summary.left(70)
			_run_git(["commit", "-m", msg])

		var rev_res := _run_git(["rev-parse", "HEAD"])
		if rev_res.get("exit_code", -1) == 0:
			return str(rev_res.get("output", "")).strip_edges()

	return "round_" + str(round_num)

# ─────────────────────────────────────────────────────────────────────────────
# HISTORY & COMPARISON API
# ─────────────────────────────────────────────────────────────────────────────
func get_next_round_number() -> int:
	var backup_base := ProjectSettings.globalize_path(BACKUP_DIR)
	if not DirAccess.dir_exists_absolute(backup_base):
		return 1
	var dir := DirAccess.open(backup_base)
	if not dir: return 1

	var max_round := 0
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		if dir.current_is_dir() and fname.begins_with("round_"):
			var r_num := int(fname.trim_prefix("round_"))
			if r_num > max_round:
				max_round = r_num
		fname = dir.get_next()
	dir.list_dir_end()

	return max_round + 1

func get_history_rounds() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var backup_base := ProjectSettings.globalize_path(BACKUP_DIR)
	if not DirAccess.dir_exists_absolute(backup_base):
		return result

	var dir := DirAccess.open(backup_base)
	if not dir: return result

	var rounds: Array[int] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		if dir.current_is_dir() and fname.begins_with("round_"):
			var r_num := int(fname.trim_prefix("round_"))
			rounds.append(r_num)
		fname = dir.get_next()
	dir.list_dir_end()

	rounds.sort()
	for r in rounds:
		var before_dir := backup_base.path_join("round_" + str(r)).path_join("before")
		var after_dir := backup_base.path_join("round_" + str(r)).path_join("after")
		var files: Array[String] = []
		_collect_relative_files(before_dir, "", files)
		_collect_relative_files(after_dir, "", files)
		var confirmed := is_round_confirmed(r)
		result.append({
			"round": r,
			"title": "Round " + str(r) + " Edits",
			"files": files,
			"confirmed": confirmed
		})
	return result

func _collect_relative_files(base_dir: String, rel_path: String, out_files: Array[String]) -> void:
	var current := base_dir.path_join(rel_path) if not rel_path.is_empty() else base_dir
	if not DirAccess.dir_exists_absolute(current): return
	var dir := DirAccess.open(current)
	if not dir: return

	dir.list_dir_begin()
	var fn := dir.get_next()
	while not fn.is_empty():
		if fn != "." and fn != "..":
			var item_rel := rel_path.path_join(fn) if not rel_path.is_empty() else fn
			if dir.current_is_dir():
				_collect_relative_files(base_dir, item_rel, out_files)
			else:
				if not _is_addon_path(item_rel):
					var res_p := "res://" + item_rel.replace("\\", "/")
					if not out_files.has(res_p):
						out_files.append(res_p)
		fn = dir.get_next()
	dir.list_dir_end()

func get_file_comparison(round_num: int, rel_path: String) -> Dictionary:
	var clean_rel := rel_path.trim_prefix("res://").replace("\\", "/")
	var backup_base := ProjectSettings.globalize_path(BACKUP_DIR)
	var before_file := backup_base.path_join("round_" + str(round_num)).path_join("before").path_join(clean_rel)
	var after_file := backup_base.path_join("round_" + str(round_num)).path_join("after").path_join(clean_rel)

	var before_text := ""
	if FileAccess.file_exists(before_file):
		var fb := FileAccess.open(before_file, FileAccess.READ)
		if fb: before_text = fb.get_as_text(); fb.close()

	var after_text := ""
	if FileAccess.file_exists(after_file):
		var fa := FileAccess.open(after_file, FileAccess.READ)
		if fa: after_text = fa.get_as_text(); fa.close()

	var diff_bb := _generate_text_diff(before_text, after_text, clean_rel)
	return {
		"before": before_text,
		"after": after_text,
		"diff_bb": diff_bb
	}

func confirm_and_lock_edits() -> Dictionary:
	# Mark all existing rounds as confirmed
	confirm_all_rounds()
	
	if _is_git_present and is_git_repo():
		_run_git(["add", "--", ".", ":(exclude)addons/alpha_ai_agent/"])
		var res := _run_git(["commit", "--allow-empty", "-m", COMMIT_PREFIX + "Confirmed & Accepted Edits Milestone"])
		if res.get("exit_code", -1) == 0:
			return {"success": true, "message": "All current edits confirmed and committed as a milestone."}

	return {"success": true, "message": "All current edits confirmed and locked."}

# ─────────────────────────────────────────────────────────────────────────────
# DIFF EXTRACTION (Git + Fallback)
# ─────────────────────────────────────────────────────────────────────────────
func get_last_diff_bbcode() -> String:
	if _is_git_present:
		if not is_git_repo():
			ensure_git_repo()

		var res := _run_git(["diff", "HEAD~1", "HEAD", "--", ".", ":(exclude)addons/alpha_ai_agent/"])
		var diff_out: String = str(res.get("output", "")).strip_edges()
		if res.get("exit_code", -1) != 0 or diff_out.is_empty():
			res = _run_git(["diff", "HEAD", "--", ".", ":(exclude)addons/alpha_ai_agent/"])

		var raw_diff: String = str(res.get("output", "")).strip_edges()
		if not raw_diff.is_empty():
			return _format_diff_to_bbcode(raw_diff)

	# Fallback Snapshot Diff Generator
	return _generate_fallback_diff_bbcode()

func _generate_fallback_diff_bbcode() -> String:
	var backup_base := ProjectSettings.globalize_path(BACKUP_DIR)
	if not DirAccess.dir_exists_absolute(backup_base):
		return "[color=#b0bec5]No edit snapshots found.[/color]"

	var dir := DirAccess.open(backup_base)
	if not dir:
		return "[color=#b0bec5]No edit snapshots found.[/color]"

	var rounds: Array[int] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		if dir.current_is_dir() and fname.begins_with("round_"):
			var r_num := int(fname.trim_prefix("round_"))
			rounds.append(r_num)
		fname = dir.get_next()
	dir.list_dir_end()

	if rounds.is_empty():
		return "[color=#b0bec5]No edit snapshots found in backup history.[/color]"

	rounds.sort()
	var latest_round := rounds.back()
	var before_dir := backup_base.path_join("round_" + str(latest_round)).path_join("before")
	var after_dir := backup_base.path_join("round_" + str(latest_round)).path_join("after")

	var diff_outputs: Array[String] = []
	_collect_snapshot_diffs(before_dir, after_dir, "", diff_outputs)

	if diff_outputs.is_empty():
		return "[color=#b0bec5]No diff changes detected in Round " + str(latest_round) + " snapshot.[/color]"

	return "[color=#ce93d8][b]📦 Local File Snapshot Diff (Round " + str(latest_round) + ")[/b][/color]\n\n" + "\n\n".join(diff_outputs)

func _collect_snapshot_diffs(before_base: String, after_base: String, rel_path: String, diff_outputs: Array[String]) -> void:
	var current_after := after_base.path_join(rel_path) if not rel_path.is_empty() else after_base
	if not DirAccess.dir_exists_absolute(current_after): return

	var dir := DirAccess.open(current_after)
	if not dir: return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name != "." and file_name != "..":
			var item_rel := rel_path.path_join(file_name) if not rel_path.is_empty() else file_name
			if _is_addon_path(item_rel):
				file_name = dir.get_next()
				continue

			if dir.current_is_dir():
				_collect_snapshot_diffs(before_base, after_base, item_rel, diff_outputs)
			else:
				var before_file := before_base.path_join(item_rel)
				var after_file := after_base.path_join(item_rel)
				
				var before_text := ""
				if FileAccess.file_exists(before_file):
					var fb := FileAccess.open(before_file, FileAccess.READ)
					if fb: before_text = fb.get_as_text(); fb.close()
					
				var after_text := ""
				if FileAccess.file_exists(after_file):
					var fa := FileAccess.open(after_file, FileAccess.READ)
					if fa: after_text = fa.get_as_text(); fa.close()
					
				if before_text != after_text:
					diff_outputs.append(_generate_text_diff(before_text, after_text, item_rel))

		file_name = dir.get_next()
	dir.list_dir_end()

func _generate_text_diff(before_text: String, after_text: String, file_label: String) -> String:
	var before_lines := before_text.split("\n")
	var after_lines := after_text.split("\n")
	var diff_lines: Array[String] = []

	var safe_label := file_label.replace("[", "[lb]").replace("]", "[rb]")
	diff_lines.append("[color=#90caf9][b]--- a/" + safe_label + "[/b][/color]")
	diff_lines.append("[color=#90caf9][b]+++ b/" + safe_label + "[/b][/color]")

	var b_idx := 0
	var a_idx := 0

	while b_idx < before_lines.size() or a_idx < after_lines.size():
		if b_idx < before_lines.size() and a_idx < after_lines.size():
			var raw_b := before_lines[b_idx]
			var raw_a := after_lines[a_idx]
			if raw_b == raw_a:
				var safe_line := raw_b.replace("[", "[lb]").replace("]", "[rb]")
				diff_lines.append("[color=#e0e0e0] " + safe_line + "[/color]")
				b_idx += 1
				a_idx += 1
			else:
				var safe_b := raw_b.replace("[", "[lb]").replace("]", "[rb]")
				var safe_a := raw_a.replace("[", "[lb]").replace("]", "[rb]")
				diff_lines.append("[color=#e57373]- " + safe_b + "[/color]")
				diff_lines.append("[color=#81c784]+ " + safe_a + "[/color]")
				b_idx += 1
				a_idx += 1
		elif b_idx < before_lines.size():
			var safe_b := before_lines[b_idx].replace("[", "[lb]").replace("]", "[rb]")
			diff_lines.append("[color=#e57373]- " + safe_b + "[/color]")
			b_idx += 1
		elif a_idx < after_lines.size():
			var safe_a := after_lines[a_idx].replace("[", "[lb]").replace("]", "[rb]")
			diff_lines.append("[color=#81c784]+ " + safe_a + "[/color]")
			a_idx += 1

	return "\n".join(diff_lines)

# ─────────────────────────────────────────────────────────────────────────────
# REVERT HANDLER (Git + Fallback)
# ─────────────────────────────────────────────────────────────────────────────
func revert_last_ai_commit() -> Dictionary:
	if _is_git_present and is_git_repo():
		var log_res := _run_git(["log", "-1", "--pretty=%B"])
		if log_res.get("exit_code", -1) == 0:
			var commit_msg: String = str(log_res.get("output", "")).strip_edges()
			if commit_msg.contains(COMMIT_PREFIX):
				var revert_res := _run_git(["revert", "HEAD", "--no-edit"])
				if revert_res.get("exit_code", -1) == 0:
					return {"success": true, "message": "Reverted AI commit: " + commit_msg.left(60)}
				else:
					var reset_res := _run_git(["reset", "--hard", "HEAD~1"])
					if reset_res.get("exit_code", -1) == 0:
						return {"success": true, "message": "Reset HEAD to state before AI edit: " + commit_msg.left(60)}

	# Fallback Revert: Restore files from user:// pre-edit backup folder
	return _revert_fallback_snapshot()

func revert_specific_round(round_num: int) -> Dictionary:
	var backup_base := ProjectSettings.globalize_path(BACKUP_DIR)
	var before_dir := backup_base.path_join("round_" + str(round_num)).path_join("before")
	var after_dir := backup_base.path_join("round_" + str(round_num)).path_join("after")

	if not DirAccess.dir_exists_absolute(before_dir):
		return {"success": false, "message": "Pre-edit backup folder missing for Round " + str(round_num)}

	var restored_files: Array[String] = []
	_restore_snapshot_files(before_dir, after_dir, "", restored_files)

	# Remove from confirmed list if it was confirmed
	if _confirmed_rounds != null:
		_confirmed_rounds.erase(round_num)
	_save_confirmed_state()

	# Rescan filesystem
	return {
		"success": true,
		"message": "Reverted Round " + str(round_num) + " (" + str(restored_files.size()) + " file(s) restored)"
	}

func _revert_fallback_snapshot() -> Dictionary:
	var backup_base := ProjectSettings.globalize_path(BACKUP_DIR)
	if not DirAccess.dir_exists_absolute(backup_base):
		return {"success": false, "message": "No backup snapshots found to revert."}

	var dir := DirAccess.open(backup_base)
	if not dir:
		return {"success": false, "message": "Failed to access backup folder."}

	var rounds: Array[int] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		if dir.current_is_dir() and fname.begins_with("round_"):
			var r_num := int(fname.trim_prefix("round_"))
			rounds.append(r_num)
		fname = dir.get_next()
	dir.list_dir_end()

	if rounds.is_empty():
		return {"success": false, "message": "No backup snapshots found."}

	rounds.sort()
	var latest_round := rounds.back()
	var before_dir := backup_base.path_join("round_" + str(latest_round)).path_join("before")
	var after_dir := backup_base.path_join("round_" + str(latest_round)).path_join("after")

	if not DirAccess.dir_exists_absolute(before_dir):
		return {"success": false, "message": "Pre-edit backup folder missing for Round " + str(latest_round)}

	var restored_files: Array[String] = []
	_restore_snapshot_files(before_dir, after_dir, "", restored_files)

	return {
		"success": true,
		"message": "Reverted Round " + str(latest_round) + " (" + str(restored_files.size()) + " file(s) restored from local backup snapshot)"
	}

func _restore_snapshot_files(before_base: String, after_base: String, rel_path: String, restored_files: Array[String]) -> void:
	# Restore files from before_base to res://
	var current_before := before_base.path_join(rel_path) if not rel_path.is_empty() else before_base
	if DirAccess.dir_exists_absolute(current_before):
		var dir := DirAccess.open(current_before)
		if dir:
			dir.list_dir_begin()
			var fn := dir.get_next()
			while not fn.is_empty():
				if fn != "." and fn != "..":
					var item_rel := rel_path.path_join(fn) if not rel_path.is_empty() else fn
					if _is_addon_path(item_rel):
						fn = dir.get_next()
						continue

					if dir.current_is_dir():
						_restore_snapshot_files(before_base, after_base, item_rel, restored_files)
					else:
						var src := before_base.path_join(item_rel)
						var dst := _project_path.path_join(item_rel)
						DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
						DirAccess.copy_absolute(src, dst)
						restored_files.append(item_rel)
				fn = dir.get_next()
			dir.list_dir_end()

	# Remove files that were newly created in after_base but didn't exist in before_base
	var current_after := after_base.path_join(rel_path) if not rel_path.is_empty() else after_base
	if DirAccess.dir_exists_absolute(current_after):
		var dir_after := DirAccess.open(current_after)
		if dir_after:
			dir_after.list_dir_begin()
			var fn_after := dir_after.get_next()
			while not fn_after.is_empty():
				if fn_after != "." and fn_after != "..":
					var item_rel_after := rel_path.path_join(fn_after) if not rel_path.is_empty() else fn_after
					if _is_addon_path(item_rel_after):
						fn_after = dir_after.get_next()
						continue

					if not dir_after.current_is_dir():
						var src_before := before_base.path_join(item_rel_after)
						if not FileAccess.file_exists(src_before):
							var created_dst := _project_path.path_join(item_rel_after)
							if FileAccess.file_exists(created_dst):
								DirAccess.remove_absolute(created_dst)
				fn_after = dir_after.get_next()
			dir_after.list_dir_end()

func _format_diff_to_bbcode(raw_diff: String) -> String:
	var lines := raw_diff.split("\n")
	var result_lines: Array[String] = []

	for line in lines:
		# First sanitize raw line brackets so code arrays [1, 2] don't break RichTextLabel
		var safe_line := line.replace("[", "[lb]").replace("]", "[rb]")
		if safe_line.begins_with("+++") or safe_line.begins_with("---"):
			result_lines.append("[color=#90caf9][b]" + safe_line + "[/b][/color]")
		elif safe_line.begins_with("diff --git") or safe_line.begins_with("index "):
			result_lines.append("[color=#b0bec5]" + safe_line + "[/color]")
		elif safe_line.begins_with("@@"):
			result_lines.append("[color=#ce93d8][b]" + safe_line + "[/b][/color]")
		elif safe_line.begins_with("+"):
			result_lines.append("[color=#81c784]" + safe_line + "[/color]")
		elif safe_line.begins_with("-"):
			result_lines.append("[color=#e57373]" + safe_line + "[/color]")
		else:
			result_lines.append("[color=#e0e0e0]" + safe_line + "[/color]")

	return "\n".join(result_lines)

func _run_git(args: Array) -> Dictionary:
	# Guard: skip if git not available to prevent blocking the editor thread
	if not _is_git_present:
		return {"exit_code": -1, "output": ""}
	var output: Array = []
	# Use non-blocking with a 5s watchdog via OS timeout if possible
	var exit_code := OS.execute("git", args, output, true)
	var out_str := ""
	if not output.is_empty():
		out_str = str(output[0])
	return {
		"exit_code": exit_code,
		"output": out_str
	}
