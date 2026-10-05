@tool
class_name ProjectContext
extends RefCounted

const MAX_FILE_SIZE_FOR_CONTEXT: int = 50000
const MAX_FILE_SIZE_FOR_SMALL_MODEL: int = 8000

# ═══════════════════════════════════════════════════════════════════════════════
# TRUTH SOURCE DELIMITERS — anti-hallucination log isolation
# ═══════════════════════════════════════════════════════════════════════════════
const TRUTH_LOG_HEADER: String = """
--- ACTUAL RUNTIME LOGS ---
[SYSTEM: Only lines below occurred. If empty, no prints happened. Do NOT invent outputs.]
--- BEGIN ACTUAL OUTPUT ---
"""
const TRUTH_LOG_FOOTER: String = """--- END ACTUAL OUTPUT ---
"""
const TRUTH_EMPTY_NOTE: String = "System Note: The project ran successfully but generated exactly 0 lines of print console output."

static func gather_context(
		include_tree: bool = true,
		include_scripts: bool = true,
		include_scenes: bool = true,
		include_assets: bool = true,
		include_logs: bool = true,
		active_file_path: String = "",
		attached_files: Array[String] = [],
		editor_interface: EditorInterface = null,
		is_small_model: bool = false
) -> String:
	var output := "## GODOT PROJECT CONTEXT\n\n"

	if include_tree:
		output += "### 📁 Project File Structure (`res://`)\n```\n"
		output += _scan_dir_tree("res://", "")
		output += "```\n\n"

	if FileAccess.file_exists("res://project.godot"):
		output += "### ⚙ Project Settings & Input Map (`res://project.godot`)\n```ini\n"
		var pf := FileAccess.open("res://project.godot", FileAccess.READ)
		if pf:
			output += pf.get_as_text()
			pf.close()
		output += "\n```\n\n"

	if active_file_path != "" and FileAccess.file_exists(active_file_path):
		output += "### 📄 Currently Active Editor File (`" + active_file_path + "`)\n"
		var f := FileAccess.open(active_file_path, FileAccess.READ)
		if f:
			output += "```gdscript\n" + f.get_as_text() + "\n```\n\n"
			f.close()

	if not attached_files.is_empty():
		output += "### 📎 USER ATTACHED SPECIFIC CONTEXT FILES\n"
		for att_path in attached_files:
			if FileAccess.file_exists(att_path):
				var ext := att_path.get_extension().to_lower()
				if ext in ["gd", "tscn", "gdshader", "json", "txt", "cfg", "godot", "tres"]:
					var f := FileAccess.open(att_path, FileAccess.READ)
					if f:
						output += "#### Attached File: `" + att_path + "`\n```" + ("gdscript" if ext == "gd" else "") + "\n" + f.get_as_text() + "\n```\n\n"
						f.close()
				else:
					output += "#### Attached Asset: `" + att_path + "` (Binary Asset/Texture/Sound)\n\n"

	if include_scripts:
		output += "### 📜 Project GDScript Files\n"
		var scripts := _find_files_by_extension("res://", ".gd")
		var max_size := MAX_FILE_SIZE_FOR_SMALL_MODEL if is_small_model else MAX_FILE_SIZE_FOR_CONTEXT
		for script_path in scripts:
			if script_path.begins_with("res://addons/alpha_ai_agent/"):
				continue
			var f := FileAccess.open(script_path, FileAccess.READ)
			if f:
				var content := f.get_as_text()
				f.close()
				if content.length() > max_size:
					content = content.left(max_size) + "\n# ... [Truncated due to size]"
				output += "#### `" + script_path + "`\n```gdscript\n" + content + "\n```\n\n"

	if include_scenes:
		output += "### 🎬 Project Scene Structure (`.tscn` Files)\n"
		var scenes := _find_files_by_extension("res://", ".tscn")
		for scene_path in scenes:
			if scene_path.begins_with("res://addons/alpha_ai_agent/"):
				continue
			var scene_info := _parse_scene_file_lightweight(scene_path)
			output += "#### `" + scene_path + "`\n" + scene_info + "\n\n"

	if include_assets:
		output += "### 🖼 Project Assets & Media Files (Textures, Sounds, Shaders)\n"
		var asset_exts := [".png", ".svg", ".jpg", ".jpeg", ".wav", ".ogg", ".mp3", ".tres", ".res", ".gdshader"]
		var assets: Array[String] = []
		for ext in asset_exts:
			assets.append_array(_find_files_by_extension("res://", ext))
		for asset_path in assets:
			if asset_path.begins_with("res://addons/alpha_ai_agent/"):
				continue
			output += "- `" + asset_path + "`\n"
		output += "\n"

	var autoloads := _get_autoloads()
	if not autoloads.is_empty():
		output += "### 🔧 Registered Autoloads & Singletons\n"
		for autoload_info in autoloads:
			output += "- `" + autoload_info["name"] + "` → `" + autoload_info["path"] + "`\n"
		output += "\n"

	if include_logs:
		var native_logs := fetch_all_native_logs(editor_interface)
		if not native_logs.is_empty():
			output += "### 🐞 NATIVE GODOT ENGINE & EDITOR OUTPUT LOGS\n```text\n"
			output += native_logs
			output += "```\n\n"

	return output

# ═══════════════════════════════════════════════════════════════════════════════
# LEAN CONTEXT — TRIAGE STAGE
# Sends only structure + logs to the AI. No file contents.
# The AI uses this to decide which specific files it needs.
# ═══════════════════════════════════════════════════════════════════════════════
static func gather_lean_context(
		active_file_path: String = "",
		attached_files: Array[String] = [],
		editor_interface: EditorInterface = null
) -> String:
	var output := "## GODOT PROJECT CONTEXT (STRUCTURE ONLY — File contents not yet loaded)\n\n"

	# Always include: full file tree
	output += "### 📁 Project File Structure (`res://`)\n```\n"
	output += _scan_dir_tree("res://", "")
	output += "```\n\n"

	# Always include: project settings
	if FileAccess.file_exists("res://project.godot"):
		output += "### ⚙ Project Settings & Input Map (`res://project.godot`)\n```ini\n"
		var pf := FileAccess.open("res://project.godot", FileAccess.READ)
		if pf:
			output += pf.get_as_text()
			pf.close()
		output += "\n```\n\n"

	# Active editor file path (mention path only in lean mode, no code dump)
	if active_file_path != "" and FileAccess.file_exists(active_file_path):
		output += "### 📄 Currently Active Editor File: `" + active_file_path + "`\n\n"

	# Always include: user-attached files (full content, always)
	if not attached_files.is_empty():
		output += "### 📎 USER ATTACHED SPECIFIC CONTEXT FILES\n"
		for att_path in attached_files:
			if FileAccess.file_exists(att_path):
				var ext := att_path.get_extension().to_lower()
				if ext in ["gd", "tscn", "gdshader", "json", "txt", "cfg", "godot", "tres"]:
					var f := FileAccess.open(att_path, FileAccess.READ)
					if f:
						output += "#### Attached File: `" + att_path + "`\n```" + ("gdscript" if ext == "gd" else "") + "\n" + f.get_as_text() + "\n```\n\n"
						f.close()
				else:
					output += "#### Attached Asset: `" + att_path + "` (Binary Asset/Texture/Sound)\n\n"

	# Always include: autoloads
	var autoloads := _get_autoloads()
	if not autoloads.is_empty():
		output += "### 🔧 Registered Autoloads & Singletons\n"
		for autoload_info in autoloads:
			output += "- `" + autoload_info["name"] + "` → `" + autoload_info["path"] + "`\n"
		output += "\n"

	# Always include: runtime & error logs
	var native_logs := fetch_all_native_logs(editor_interface)
	if not native_logs.is_empty():
		output += "### 🐞 NATIVE GODOT ENGINE & EDITOR OUTPUT LOGS\n```text\n"
		output += native_logs
		output += "```\n\n"

	output += "---\n"
	output += "⚠ NOTE TO AI: The file tree above shows all file paths, but NO file code is loaded yet.\n"
	output += "To proceed, output a `request_files` action listing exactly which files you need to read.\n"

	return output

# ═══════════════════════════════════════════════════════════════════════════════
# TARGETED CONTEXT — POST-TRIAGE FILE LOADING
# Called after the AI has selected files during TRIAGE.
# Reads only the explicitly requested files and returns their contents.
# Max 15 files, 50,000 chars each.
# ═══════════════════════════════════════════════════════════════════════════════
static func gather_targeted_context(
		requested_files: Array[String],
		max_chars_per_file: int = MAX_FILE_SIZE_FOR_CONTEXT
) -> String:
	if requested_files.is_empty():
		return ""
	var output := "### 📂 AI-Requested File Contents\n"
	output += "_(These files were loaded based on the AI's triage request)_\n\n"
	var loaded := 0
	for path in requested_files:
		if loaded >= 15:
			output += "_(Max 15 files reached — remaining files skipped)_\n"
			break
		# Never load addon files for security
		if path.begins_with("res://addons/"):
			continue
		if not FileAccess.file_exists(path):
			output += "#### ❌ File not found: `" + path + "`\n\n"
			continue
		var ext := path.get_extension().to_lower()
		var f := FileAccess.open(path, FileAccess.READ)
		if not f:
			continue
		var content := f.get_as_text()
		f.close()
		if content.length() > max_chars_per_file:
			content = content.left(max_chars_per_file) + "\n# ... [Truncated due to size]"
		var lang := "gdscript" if ext == "gd" else ("ini" if ext in ["tscn", "tres", "cfg", "godot"] else "")
		output += "#### `" + path + "`\n```" + lang + "\n" + content + "\n```\n\n"
		loaded += 1
	return output

# ═══════════════════════════════════════════════════════════════════════════════
# TRUTH-SOURCE LOG FETCHER
# Returns actual captured stdout/stderr with strict anti-hallucination delimiters.
# The caller (ai_dock.gd) must use build_truth_log_block() to wrap these.
# ═══════════════════════════════════════════════════════════════════════════════
static func fetch_all_native_logs(editor_interface: EditorInterface = null) -> String:
	var combined_logs := ""

	# Source 1: Editor Console Output UI Dock (EditorLog / RichTextLabel)
	if editor_interface:
		var editor_dock_text := _extract_editor_output_dock_text(editor_interface)
		if not editor_dock_text.is_empty():
			combined_logs += "--- [GODOT EDITOR OUTPUT DOCK] ---\n" + editor_dock_text + "\n\n"

	# Source 2: Project runtime user://logs/godot.log
	var godot_log_path := OS.get_user_data_dir().path_join("logs/godot.log")
	if FileAccess.file_exists(godot_log_path):
		var f := FileAccess.open(godot_log_path, FileAccess.READ)
		if f:
			var log_lines: Array[String] = []
			while not f.eof_reached():
				var l := f.get_line()
				if not l.strip_edges().is_empty():
					log_lines.append(l)
			f.close()
			if not log_lines.is_empty():
				var start_idx := max(0, log_lines.size() - 60)
				combined_logs += "--- [PROJECT RUNTIME DISK LOGS (user://logs/godot.log)] ---\n"
				for i in range(start_idx, log_lines.size()):
					combined_logs += log_lines[i] + "\n"
				combined_logs += "\n"

	# Source 3: OS Global Godot AppData logs if available
	var config_dir := OS.get_config_dir()
	var global_log_path := config_dir.path_join("logs/godot.log")
	if FileAccess.file_exists(global_log_path) and global_log_path != godot_log_path:
		var f2 := FileAccess.open(global_log_path, FileAccess.READ)
		if f2:
			var g_lines: Array[String] = []
			while not f2.eof_reached():
				var l2 := f2.get_line()
				if not l2.strip_edges().is_empty():
					g_lines.append(l2)
			f2.close()
			if not g_lines.is_empty():
				var start_idx2 := max(0, g_lines.size() - 30)
				combined_logs += "--- [GLOBAL GODOT ENGINE LOGS] ---\n"
				for i in range(start_idx2, g_lines.size()):
					combined_logs += g_lines[i] + "\n"

	return combined_logs

## Wraps raw log output in truth-source delimiters for anti-hallucination injection.
## If the output buffer is empty, injects the hardcoded "0 output lines" system note.
static func build_truth_log_block(raw_logs: String) -> String:
	var block := TRUTH_LOG_HEADER
	if raw_logs.strip_edges().is_empty():
		block += TRUTH_EMPTY_NOTE + "\n"
	else:
		block += raw_logs
	block += TRUTH_LOG_FOOTER
	return block

static func _extract_editor_output_dock_text(editor_interface: EditorInterface) -> String:
	if not editor_interface: return ""
	var base := editor_interface.get_base_control()
	if not base: return ""

	var editor_logs := _find_nodes_by_class_name(base, "EditorLog")
	for node in editor_logs:
		var rtl_nodes := _find_nodes_by_class_name(node, "RichTextLabel")
		for rtl in rtl_nodes:
			if rtl is RichTextLabel:
				var text: String = (rtl as RichTextLabel).get_parsed_text()
				if not text.is_empty():
					var lines := text.split("\n")
					var start := max(0, lines.size() - 80)
					var recent: Array[String] = []
					for idx in range(start, lines.size()):
						var l_str := lines[idx].strip_edges()
						var l_lower := l_str.to_lower()
						if not l_str.is_empty() and not l_lower.contains("alpha_ai_agent") and not l_lower.contains("addons/alpha_ai_agent"):
							recent.append(l_str)
					return "\n".join(recent)
	return ""

static func _find_nodes_by_class_name(node: Node, class_name_str: String) -> Array[Node]:
	var found: Array[Node] = []
	if node.get_class() == class_name_str:
		found.append(node)
	for child in node.get_children():
		found.append_array(_find_nodes_by_class_name(child, class_name_str))
	return found

static func _scan_dir_tree(path: String, indent: String) -> String:
	var result := ""
	var dir := DirAccess.open(path)
	if not dir:
		return ""

	dir.list_dir_begin()
	var file_name := dir.get_next()
	var dirs: Array[String] = []
	var files: Array[String] = []

	while file_name != "":
		if not file_name.begins_with("."):
			if dir.current_is_dir():
				dirs.append(file_name)
			else:
				files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	dirs.sort()
	files.sort()

	for d in dirs:
		if d == ".godot" or d == ".git" or d == "addons" or d == "alpha_ai_agent":
			continue
		result += indent + "├── 📂 " + d + "/\n"
		var sub_path := path.path_join(d)
		result += _scan_dir_tree(sub_path, indent + "│   ")

	for f in files:
		result += indent + "├── 📄 " + f + "\n"

	return result

static func _find_files_by_extension(path: String, ext: String) -> Array[String]:
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

# ═══════════════════════════════════════════════════════════════════════════════
# LIGHTWEIGHT TSCN PARSER (Refactor #4)
# Strips unnecessary engine binary metadata from .tscn files.
# Only keeps: [gd_scene header], [ext_resource], [node], [connection], script paths.
# This reduces token cost by ~70% for large scene files.
# ═══════════════════════════════════════════════════════════════════════════════
static func _parse_scene_file_lightweight(scene_path: String) -> String:
	var f := FileAccess.open(scene_path, FileAccess.READ)
	if not f:
		return "*(Unable to read scene file)*"

	var output_lines: Array[String] = []
	var line_count := 0
	var in_sub_resource := false  # Skip sub_resource blocks (binary/shader data)

	while not f.eof_reached():
		var raw_line := f.get_line()
		var line := raw_line.strip_edges()
		line_count += 1

		# Detect start of sub_resource block (binary metadata, skip it)
		if line.begins_with("[sub_resource "):
			in_sub_resource = true
			continue

		# End of any section block
		if in_sub_resource and line.begins_with("["):
			in_sub_resource = false
			# Fall through to process this new section header

		if in_sub_resource:
			continue

		# Keep only semantically important lines
		if (
			line.begins_with("[gd_scene") or
			line.begins_with("[ext_resource") or
			line.begins_with("[node") or
			line.begins_with("[connection") or
			line.begins_with("script =") or
			line.begins_with("name =") or
			line.begins_with("unique_name_in_owner =") or
			(line.begins_with("[resource") and not line.begins_with("[resource_internal"))
		):
			output_lines.append(line)

		# Cap to prevent huge scenes from bloating context
		if output_lines.size() >= 120:
			output_lines.append("# ... [Scene truncated — too many nodes]")
			break

	f.close()

	if output_lines.is_empty():
		return "*(Empty or unreadable scene file)*"

	return "```ini\n" + "\n".join(output_lines) + "\n```"

static func _parse_scene_file(scene_path: String, is_small_model: bool = false) -> String:
	# Legacy wrapper — uses the new lightweight parser
	return _parse_scene_file_lightweight(scene_path)

static func _get_autoloads() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var proj_file := "res://project.godot"
	if not FileAccess.file_exists(proj_file):
		return result

	var f := FileAccess.open(proj_file, FileAccess.READ)
	if not f:
		return result

	var content := f.get_as_text()
	f.close()

	var in_autoload := false
	var lines := content.split("\n")
	for line in lines:
		var stripped := line.strip_edges()
		if stripped == "[autoload]":
			in_autoload = true
			continue
		if in_autoload and stripped.begins_with("["):
			break
		if in_autoload and "=" in stripped:
			var parts := stripped.split("=", true, 1)
			if parts.size() == 2:
				var name := parts[0].strip_edges()
				var path := parts[1].strip_edges().trim_prefix("\"").trim_suffix("\"")
				result.append({"name": name, "path": path})

	return result
