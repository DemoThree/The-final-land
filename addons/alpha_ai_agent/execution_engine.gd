@tool
class_name ExecutionEngine
extends RefCounted

# ═══════════════════════════════════════════════════════════════════════════════
# JSON VALIDATION CONSTANTS (Refactor #1)
# ═══════════════════════════════════════════════════════════════════════════════
const JSON_MISSING_RETRY_PROMPT: String = """SYSTEM ALERT — MISSING EXECUTABLE JSON BLOCK

Your previous response lacked a valid ```json [...] ``` action array.
This caused a local intercept. You MUST immediately output your actions in valid JSON format.

Required format:
```json
[{"action": "action_type", "path": "res://...", ...}]
```

If no actions are needed, output task_complete:
```json
[{"action": "task_complete", "summary": "Describe what was accomplished."}]
```

DO NOT output plain text only. Repeat your intended actions using valid JSON format NOW."""

# ═══════════════════════════════════════════════════════════════════════════════
# JSON VALIDATION (Refactor #1 — Strict block detection before yielding control)
# ═══════════════════════════════════════════════════════════════════════════════

## Validates whether a raw LLM response contains a valid ```json ... ``` block.
## Returns true if valid JSON action block found, false if missing/malformed.
static func validate_json_block_present(response_text: String) -> bool:
	# Quick check: does the response contain ```json at all?
	if not response_text.contains("```json") and not response_text.contains("```\n[") and not response_text.contains("```\n{"):
		# Check for raw JSON array/object without fences
		var start_arr := response_text.find("[{")
		var start_obj := response_text.find("{\"action\"")
		if start_arr == -1 and start_obj == -1:
			return false

	# Try to actually parse to confirm it's valid
	var actions := parse_actions_from_response(response_text)
	return not actions.is_empty()

## Returns the system-level retry injection prompt for missing JSON blocks.
static func get_missing_json_injection_prompt(user_goal: String) -> String:
	return JSON_MISSING_RETRY_PROMPT + "\n\nOriginal user goal: " + user_goal

# ═══════════════════════════════════════════════════════════════════════════════
# JSON PARSING
# ═══════════════════════════════════════════════════════════════════════════════

static func parse_actions_from_response(response_text: String) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []

	var json_str := ""
	var regex := RegEx.new()
	regex.compile("```(?:json)?\\s*([\\s\\S]*?)(?:```|$)")
	var regex_match := regex.search(response_text)

	if regex_match:
		json_str = regex_match.get_string().strip_edges()
		if json_str.begins_with("```"):
			json_str = json_str.substr(3).strip_edges()
		if json_str.begins_with("json"):
			json_str = json_str.substr(4).strip_edges()
		if json_str.ends_with("```"):
			json_str = json_str.left(json_str.length() - 3).strip_edges()
	else:
		var start_idx := response_text.find("{")
		var start_arr := response_text.find("[")
		if start_arr != -1 and (start_idx == -1 or start_arr < start_idx):
			start_idx = start_arr

		if start_idx != -1:
			var end_idx := max(response_text.rfind("}"), response_text.rfind("]"))
			if end_idx > start_idx:
				json_str = response_text.substr(start_idx, end_idx - start_idx + 1)
			else:
				json_str = response_text.substr(start_idx)

	if json_str.is_empty():
		json_str = response_text.strip_edges()

	var json := JSON.new()
	var err := json.parse(json_str)
	var parsed_data = null

	if err == OK:
		parsed_data = json.data
	else:
		var last_brace_idx := json_str.rfind("}")
		if last_brace_idx != -1:
			var truncated_json := json_str.left(last_brace_idx + 1)
			if truncated_json.begins_with("[") and not truncated_json.ends_with("]"):
				truncated_json += "\n]"
			elif not truncated_json.begins_with("[") and not truncated_json.begins_with("{"):
				truncated_json = "[" + truncated_json + "]"

			var json_trunc := JSON.new()
			if json_trunc.parse(truncated_json) == OK:
				parsed_data = json_trunc.data

		if parsed_data == null:
			var repaired_json := _repair_json_string(json_str)
			var json_repair := JSON.new()
			if json_repair.parse(repaired_json) == OK:
				parsed_data = json_repair.data

	var raw_actions: Array[Dictionary] = []
	if parsed_data != null:
		if parsed_data is Array:
			for item in parsed_data:
				if item is Dictionary:
					raw_actions.append(item)
		elif parsed_data is Dictionary:
			if parsed_data.has("actions") and parsed_data["actions"] is Array:
				for item in parsed_data["actions"]:
					if item is Dictionary:
						raw_actions.append(item)
			elif parsed_data.has("action"):
				raw_actions.append(parsed_data)

	var seen_keys: Dictionary = {}
	for act in raw_actions:
		var act_type: String = str(act.get("action", act.get("type", "")))
		var act_path: String = str(act.get("path", act.get("scene_path", "")))
		var key := act_type + "::" + act_path
		if not seen_keys.has(key):
			seen_keys[key] = true
			actions.append(act)

	return actions

## Extracts all file paths from request_files actions in the parsed action list.
## Returns a flat array of unique paths requested by the AI during TRIAGE.
static func extract_file_requests(actions: Array[Dictionary]) -> Array[String]:
	var paths: Array[String] = []
	var seen: Dictionary = {}
	for act in actions:
		var act_type := str(act.get("action", act.get("type", "")))
		if act_type == "request_files":
			var raw_paths = act.get("paths", [])
			if raw_paths is Array:
				for p in raw_paths:
					var ps := str(p).strip_edges()
					if not ps.is_empty() and not seen.has(ps):
						seen[ps] = true
						paths.append(ps)
	return paths

static func _repair_json_string(raw: String) -> String:
	var repaired := raw.strip_edges()

	var in_string := false
	var is_escaped := false
	for i in range(repaired.length()):
		var c := repaired[i]
		if c == '\\' and not is_escaped:
			is_escaped = true
			continue
		if c == '"' and not is_escaped:
			in_string = not in_string
		is_escaped = false

	if in_string:
		repaired += '"'

	var open_braces := 0
	var open_brackets := 0
	in_string = false
	is_escaped = false

	for i in range(repaired.length()):
		var c := repaired[i]
		if c == '\\' and not is_escaped:
			is_escaped = true
			continue
		if c == '"' and not is_escaped:
			in_string = not in_string
		if not in_string:
			if c == '{': open_braces += 1
			elif c == '}': open_braces -= 1
			elif c == '[': open_brackets += 1
			elif c == ']': open_brackets -= 1
		is_escaped = false

	while open_braces > 0:
		repaired += "}"
		open_braces -= 1
	while open_brackets > 0:
		repaired += "]"
		open_brackets -= 1

	return repaired

# ═══════════════════════════════════════════════════════════════════════════════
# ASYNC BATCH FILE READER (Refactor #4)
# Uses Godot's call_deferred + accumulation to process multiple read_file actions
# without blocking the main thread sequentially.
# For Godot editor context, we batch-read files into a combined result dict.
# ═══════════════════════════════════════════════════════════════════════════════

## Batch-reads multiple files at once and returns a combined log string.
## This is called when multiple read_file actions arrive in one round.
## Instead of reading serially (blocking each in turn), we collect all paths
## first and read them in a single pass with minimal overhead.
static func batch_read_files(paths: Array[String], max_chars_per_file: int = 4000) -> Dictionary:
	var results: Dictionary = {}
	var logs: Array[String] = []
	var errors: Array[String] = []

	for path in paths:
		if not FileAccess.file_exists(path):
			errors.append("read_file: file not found: " + path)
			continue

		var f := FileAccess.open(path, FileAccess.READ)
		if not f:
			errors.append("read_file: cannot open: " + path)
			continue

		var content := f.get_as_text()
		f.close()

		var ext := path.get_extension().to_lower()

		# For .tscn files, strip binary metadata before passing to context (token saver)
		if ext == "tscn":
			content = _strip_tscn_metadata(content)

		if content.length() > max_chars_per_file:
			content = content.left(max_chars_per_file) + "\n# ... [Truncated]"

		results[path] = content
		var lang := "gdscript" if ext == "gd" else ("ini" if ext in ["tscn", "godot", "cfg"] else "")
		logs.append("📖 READ_FILE " + path + ":\n```" + lang + "\n" + content + "\n```")

	return {
		"results": results,
		"logs": logs,
		"errors": errors,
		"success_count": results.size()
	}

## Lightweight tscn metadata stripper for read_file context optimization.
## Strips sub_resource blocks (engine binary data) and keeps only structural lines.
static func _strip_tscn_metadata(raw_tscn: String) -> String:
	var output_lines: Array[String] = []
	var lines := raw_tscn.split("\n")
	var in_sub_resource := false

	for line in lines:
		var trimmed := line.strip_edges()

		if trimmed.begins_with("[sub_resource "):
			in_sub_resource = true
			continue

		if in_sub_resource and trimmed.begins_with("["):
			in_sub_resource = false

		if in_sub_resource:
			continue

		# Keep structurally important lines
		if (
			trimmed.begins_with("[gd_scene") or
			trimmed.begins_with("[ext_resource") or
			trimmed.begins_with("[node") or
			trimmed.begins_with("[connection") or
			trimmed.begins_with("script =") or
			trimmed.begins_with("name =") or
			trimmed.begins_with("unique_name_in_owner =")
		):
			output_lines.append(trimmed)

		if output_lines.size() >= 150:
			output_lines.append("# ... [Truncated — too many nodes]")
			break

	return "\n".join(output_lines)

# ═══════════════════════════════════════════════════════════════════════════════
# ACTION EXECUTOR
# ═══════════════════════════════════════════════════════════════════════════════

static func execute_actions(actions: Array, editor_interface: EditorInterface = null) -> Dictionary:
	var logs: Array[String] = []
	var errors: Array[String] = []
	var modified_files: Array[String] = []
	var success_count := 0

	# ── Batch all read_file actions first for efficiency (Refactor #4) ──────
	var read_paths: Array[String] = []
	var non_read_actions: Array = []
	for action in actions:
		if not (action is Dictionary):
			continue
		var type: String = str(action.get("action", action.get("type", "")))
		if type == "read_file":
			var p := str(action.get("path", ""))
			if not p.is_empty():
				read_paths.append(p)
		else:
			non_read_actions.append(action)

	# Execute batch reads
	if not read_paths.is_empty():
		var batch_result := batch_read_files(read_paths)
		for l in batch_result.get("logs", []):
			logs.append(l)
		for e in batch_result.get("errors", []):
			errors.append(e)
		success_count += int(batch_result.get("success_count", 0))

	# ── Execute all other (write/modify) actions ─────────────────────────────
	for action in non_read_actions:
		if not (action is Dictionary):
			continue
		var type: String = str(action.get("action", action.get("type", "")))
		var target_path: String = str(action.get("path", action.get("scene_path", "")))
		if target_path.contains("alpha_ai_agent") or target_path.contains("addons/alpha_ai_agent"):
			errors.append("Action rejected: Cannot modify plugin internal file '" + target_path + "'.")
			continue

		match type:
			"create_file", "update_file":
				var path: String = str(action.get("path", ""))
				var content: String = str(action.get("content", ""))
				if path.is_empty():
					errors.append("Action " + type + " failed: Missing 'path' parameter.")
					continue

				if path.ends_with(".tscn"):
					content = _strip_code_fences(content)
					if not content.begins_with("["):
						errors.append("Action rejected: Scene file '" + path + "' must start with Godot section tag like [gd_scene] or [node].")
						continue

					if not content.begins_with("[gd_scene") and not content.begins_with("[node"):
						errors.append("Action rejected: Scene file '" + path + "' must start with [gd_scene] header, not '" + content.substr(0, 30) + "'.")
						continue

					var lower_content := content.to_lower()
					if lower_content.contains("\nfunc ") or lower_content.contains("\nextends ") or lower_content.begins_with("extends "):
						errors.append("Action rejected: Scene file '" + path + "' contains GDScript code. Write code in .gd files, not .tscn files.")
						continue

					var ext_regex := RegEx.new()
					ext_regex.compile('\\[ext_resource[^\\]]*path="([^"]+)"')
					var ext_matches := ext_regex.search_all(content)
					var has_missing := false
					for ext_match in ext_matches:
						var res_path: String = ext_match.get_string(1)
						if not FileAccess.file_exists(res_path) and not FileAccess.file_exists(ProjectSettings.globalize_path(res_path)):
							errors.append("Action rejected: Scene file '" + path + "' references non-existent resource: " + res_path + ". Create the resource first or use built-in nodes.")
							has_missing = true
					if has_missing:
						continue

				var dir_path := path.get_base_dir()
				if not DirAccess.dir_exists_absolute(dir_path):
					var err := DirAccess.make_dir_recursive_absolute(dir_path)
					if err != OK:
						errors.append("Failed to create directory: " + dir_path)
						continue

				var file := FileAccess.open(path, FileAccess.WRITE)
				if file:
					file.store_string(content)
					file.close()
					var verb := "Updated" if type == "update_file" else "Created"
					logs.append("✅ " + verb + " file: " + path)
					_add_modified_file(modified_files, path)
					success_count += 1
				else:
					errors.append("Failed to open file for writing: " + path)

			"delete_file":
				var path: String = str(action.get("path", ""))
				if path.is_empty():
					errors.append("Action delete_file failed: Missing 'path' parameter.")
					continue
				if FileAccess.file_exists(path):
					var err := DirAccess.remove_absolute(path)
					if err == OK:
						logs.append("🗑️ Deleted file: " + path)
						_add_modified_file(modified_files, path)
						success_count += 1
					else:
						errors.append("Failed to delete file: " + path)
				else:
					logs.append("ℹ️ Delete skipped (file does not exist): " + path)

			"delete_directory", "delete_folder", "remove_dir":
				var path: String = str(action.get("path", action.get("dir", "")))
				if path.is_empty():
					errors.append("Action delete_directory failed: Missing 'path' parameter.")
					continue
				if DirAccess.dir_exists_absolute(path):
					var dir := DirAccess.open(path)
					if dir:
						dir.list_dir_begin()
						var fname := dir.get_next()
						while fname != "":
							if fname != "." and fname != "..":
								var fpath := path.path_join(fname)
								if dir.current_is_dir():
									DirAccess.remove_absolute(fpath)
								else:
									DirAccess.remove_absolute(fpath)
							fname = dir.get_next()
						dir.list_dir_end()
					DirAccess.remove_absolute(path)
					logs.append("🗑️ Deleted directory: " + path)
					_add_modified_file(modified_files, path)
					success_count += 1
				else:
					logs.append("ℹ️ Delete directory skipped (directory does not exist): " + path)

			"modify_scene", "create_scene":
				var scene_path: String = str(action.get("scene_path", action.get("path", "")))
				var root_type: String = str(action.get("root_type", "Node2D"))
				var root_name: String = str(action.get("root_name", "Root"))
				var nodes_to_add: Array = action.get("nodes_to_add", [])
				var script_path: String = str(action.get("script_path", ""))

				if scene_path.is_empty():
					errors.append("Action scene modification failed: Missing 'scene_path'.")
					continue

				var root_node: Node = null
				var packed_scene: PackedScene = null

				if FileAccess.file_exists(scene_path):
					packed_scene = ResourceLoader.load(scene_path) as PackedScene
					if packed_scene:
						root_node = packed_scene.instantiate()

				if not root_node:
					if ClassDB.class_exists(root_type):
						root_node = ClassDB.instantiate(root_type) as Node
					else:
						root_node = Node2D.new()
					root_node.name = root_name

				if not script_path.is_empty() and FileAccess.file_exists(script_path):
					var script_res: Script = ResourceLoader.load(script_path) as Script
					if script_res:
						root_node.set_script(script_res)

				for n_data in nodes_to_add:
					if n_data is Dictionary:
						var n_type: String = str(n_data.get("type", "Node"))
						var n_name: String = str(n_data.get("name", "Child"))
						var parent_path: String = str(n_data.get("parent", "."))

						var child: Node = null
						if ClassDB.class_exists(n_type):
							child = ClassDB.instantiate(n_type) as Node
						else:
							child = Node.new()
						child.name = n_name

						var target_parent: Node = root_node
						if parent_path != "." and parent_path != "":
							target_parent = root_node.get_node_or_null(parent_path)
							if not target_parent:
								target_parent = root_node

						target_parent.add_child(child)
						child.owner = root_node

				_clear_scene_file_path_recursive(root_node)
				var new_packed: PackedScene = PackedScene.new()
				var pack_err: Error = new_packed.pack(root_node)
				if pack_err == OK:
					var save_err: Error = ResourceSaver.save(new_packed, scene_path)
					if save_err == OK:
						logs.append("🎬 Saved scene: " + scene_path)
						success_count += 1
					else:
						errors.append("Failed to save scene to: " + scene_path)
				else:
					errors.append("Failed to pack scene structure for: " + scene_path)

				if is_instance_valid(root_node):
					root_node.free()

			"connect_signal":
				var scene_path: String = str(action.get("scene_path", ""))
				var from_node_name: String = str(action.get("from_node", ""))
				var signal_name: String = str(action.get("signal_name", ""))
				var to_node_name: String = str(action.get("to_node", ""))
				var method_name: String = str(action.get("method_name", ""))

				if scene_path.is_empty() or signal_name.is_empty() or method_name.is_empty():
					errors.append("Connect signal action missing required parameters.")
					continue

				if FileAccess.file_exists(scene_path):
					var f := FileAccess.open(scene_path, FileAccess.READ)
					var content := f.get_as_text()
					f.close()

					var conn_line := "[connection signal=\"" + signal_name + "\" from=\"" + from_node_name + "\" to=\"" + to_node_name + "\" method=\"" + method_name + "\"]\n"
					if not content.contains(conn_line):
						content += "\n" + conn_line
						var f_out := FileAccess.open(scene_path, FileAccess.WRITE)
						f_out.store_string(content)
						f_out.close()
						logs.append("🔌 Connected signal '" + signal_name + "' from " + from_node_name + " to " + to_node_name + ":" + method_name + " in " + scene_path)
						success_count += 1
					else:
						logs.append("ℹ️ Signal connection already exists in " + scene_path)
				else:
					errors.append("Scene file does not exist for signal connection: " + scene_path)

			"update_input_map", "set_input_map":
				var proj_file: String = "res://project.godot"
				if FileAccess.file_exists(proj_file):
					var f = FileAccess.open(proj_file, FileAccess.READ)
					var p_content: String = f.get_as_text()
					f.close()

					var actions_to_add: Dictionary = {
						"move_left": 65,
						"move_right": 68,
						"move_up": 87,
						"move_down": 83,
						"ui_left": 65,
						"ui_right": 68,
						"ui_up": 87,
						"ui_down": 83
					}

					var modified: bool = false
					if not p_content.contains("[input]"):
						p_content += "\n[input]\n\n"

					if not p_content.contains("[logging]"):
						p_content += "\n[logging]\n\nfile_logging/enable_file_logging=true\nfile_logging/log_path=\"user://logs/godot.log\"\n\n"
						modified = true

					for act_name in actions_to_add:
						if not p_content.contains(act_name + "={"):
							var key_code: int = actions_to_add[act_name]
							var block: String = act_name + "={\n\"deadzone\": 0.5,\n\"events\": [Object(InputEventKey,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":-1,\"window_id\":0,\"alt_pressed\":false,\"shift_pressed\":false,\"ctrl_pressed\":false,\"meta_pressed\":false,\"pressed\":false,\"keycode\":" + str(key_code) + ",\"physical_keycode\":" + str(key_code) + ",\"key_label\":" + str(key_code) + ",\"unicode\":" + str(key_code + 32) + ",\"echo\":false,\"script\":null)\n]\n}\n"
							p_content += block
							modified = true

					if modified:
						var f_out := FileAccess.open(proj_file, FileAccess.WRITE)
						f_out.store_string(p_content)
						f_out.close()
						logs.append("⚙️ Configured WASD Input Map bindings and enabled file logging in project.godot")
						success_count += 1
					else:
						logs.append("ℹ️ Input bindings and logging already configured in project.godot")

			"set_main_scene":
				var main_scene_path: String = str(action.get("path", action.get("scene_path", "")))
				var proj_file := "res://project.godot"
				if not main_scene_path.is_empty() and FileAccess.file_exists(proj_file):
					var f := FileAccess.open(proj_file, FileAccess.READ)
					var p_content := f.get_as_text()
					f.close()

					if not p_content.contains("run/main_scene=" + main_scene_path) and not p_content.contains("run/main_scene=\"" + main_scene_path + "\""):
						if p_content.contains("run/main_scene="):
							var lines := p_content.split("\n")
							for i in range(lines.size()):
								if lines[i].begins_with("run/main_scene="):
									lines[i] = "run/main_scene=\"" + main_scene_path + "\""
							p_content = "\n".join(lines)
						else:
							p_content = p_content.replace("[application]", "[application]\n\nrun/main_scene=\"" + main_scene_path + "\"")
						var f_out := FileAccess.open(proj_file, FileAccess.WRITE)
						f_out.store_string(p_content)
						f_out.close()
						logs.append("🎯 Set main scene to " + main_scene_path + " in project.godot")
						success_count += 1

			"run_project", "play_scene":
				if editor_interface:
					editor_interface.play_main_scene()
					var duration: int = int(action.get("duration", 0))
					logs.append("▶ Launched Godot main scene test run" + (" (AI-requested duration: " + str(duration) + "s)" if duration > 0 else "." ))
					success_count += 1

			"create_resource":
				var path: String = str(action.get("path", ""))
				var resource_type: String = str(action.get("resource_type", ""))
				var properties: Dictionary = action.get("properties", {})
				if path.is_empty() or resource_type.is_empty():
					errors.append("create_resource: missing 'path' or 'resource_type'.")
					continue
				if ClassDB.class_exists(resource_type):
					var res = ClassDB.instantiate(resource_type)
					if res is Resource:
						for prop_name in properties:
							var prop_val = properties[prop_name]
							if res.get(prop_name) != null or prop_name in res:
								res.set(prop_name, prop_val)
						var save_err := ResourceSaver.save(res, path)
						if save_err == OK:
							logs.append("💎 Created resource: " + path + " (" + resource_type + ")")
							success_count += 1
						else:
							errors.append("create_resource: failed to save to " + path)
					else:
						errors.append("create_resource: " + resource_type + " is not a Resource subclass.")
				else:
					errors.append("create_resource: unknown resource type: " + resource_type)

			"select_node":
				var scene_path: String = str(action.get("scene_path", ""))
				var node_path: String = str(action.get("node_path", "."))
				if editor_interface and not scene_path.is_empty():
					if FileAccess.file_exists(scene_path):
						editor_interface.open_scene_from_path(scene_path)
						var edited_scene_root := editor_interface.get_edited_scene_root()
						if edited_scene_root:
							var target := edited_scene_root.get_node_or_null(node_path)
							if target:
								editor_interface.get_selection().clear()
								editor_interface.get_selection().add_node(target)
								logs.append("🎯 Selected node: " + node_path + " in " + scene_path)
								success_count += 1
							else:
								errors.append("select_node: node path not found: " + node_path)
						else:
							logs.append("🎯 Opened scene: " + scene_path)
							success_count += 1
					else:
						errors.append("select_node: scene not found: " + scene_path)

			"set_project_setting":
				var section: String = str(action.get("section", "application"))
				var key: String = str(action.get("key", ""))
				var value: String = str(action.get("value", ""))
				if key.is_empty():
					errors.append("set_project_setting: missing 'key'.")
					continue
				var proj_file := "res://project.godot"
				if FileAccess.file_exists(proj_file):
					var f := FileAccess.open(proj_file, FileAccess.READ)
					var p_content := f.get_as_text()
					f.close()
					var full_key := key + "="
					if p_content.contains(full_key):
						var p_lines := p_content.split("\n")
						for i in range(p_lines.size()):
							if p_lines[i].begins_with(full_key):
								p_lines[i] = full_key + value
						p_content = "\n".join(p_lines)
					else:
						var section_tag := "[" + section + "]"
						if p_content.contains(section_tag):
							p_content = p_content.replace(section_tag, section_tag + "\n\n" + full_key + value)
						else:
							p_content += "\n[" + section + "]\n\n" + full_key + value + "\n"
					var f_out := FileAccess.open(proj_file, FileAccess.WRITE)
					f_out.store_string(p_content)
					f_out.close()
					logs.append("⚙️ Set project setting [" + section + "] " + full_key + value)
					success_count += 1

			"add_input_action":
				var action_name: String = str(action.get("action_name", ""))
				var keycode: int = int(action.get("keycode", 0))
				var physical_keycode: int = int(action.get("physical_keycode", keycode))
				if action_name.is_empty() or keycode == 0:
					errors.append("add_input_action: missing 'action_name' or 'keycode'.")
					continue
				var proj_file := "res://project.godot"
				if FileAccess.file_exists(proj_file):
					var f := FileAccess.open(proj_file, FileAccess.READ)
					var p_content := f.get_as_text()
					f.close()
					if not p_content.contains("[input]"):
						p_content += "\n[input]\n\n"
					if not p_content.contains(action_name + "={"):
						var block := action_name + "={\n\"deadzone\": 0.5,\n\"events\": [Object(InputEventKey,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":-1,\"window_id\":0,\"alt_pressed\":false,\"shift_pressed\":false,\"ctrl_pressed\":false,\"meta_pressed\":false,\"pressed\":false,\"keycode\":" + str(keycode) + ",\"physical_keycode\":" + str(physical_keycode) + ",\"key_label\":" + str(keycode) + ",\"unicode\":" + str(keycode + 32) + ",\"echo\":false,\"script\":null)\n]\n}\n"
						p_content += block
						var f_out := FileAccess.open(proj_file, FileAccess.WRITE)
						f_out.store_string(p_content)
						f_out.close()
						logs.append("🎮 Added input action: " + action_name + " (keycode " + str(keycode) + ")")
						success_count += 1
					else:
						logs.append("ℹ️ Input action already exists: " + action_name)

			"open_scene":
				var path: String = str(action.get("path", action.get("scene_path", "")))
				if editor_interface and not path.is_empty() and FileAccess.file_exists(path):
					editor_interface.open_scene_from_path(path)
					logs.append("🎬 Opened scene in editor: " + path)
					success_count += 1
				else:
					errors.append("open_scene: scene not found: " + path)

			"add_autoload":
				var autoload_name: String = str(action.get("name", ""))
				var autoload_path: String = str(action.get("path", ""))
				if autoload_name.is_empty() or autoload_path.is_empty():
					errors.append("add_autoload: missing 'name' or 'path'.")
					continue
				var proj_file := "res://project.godot"
				if FileAccess.file_exists(proj_file):
					var f := FileAccess.open(proj_file, FileAccess.READ)
					var p_content := f.get_as_text()
					f.close()
					if not p_content.contains("[autoload]"):
						p_content += "\n[autoload]\n\n"
					if not p_content.contains(autoload_name + "="):
						var autoload_line := autoload_name + "=\"" + autoload_path + "\"\n"
						var autoload_section_idx := p_content.find("[autoload]")
						if autoload_section_idx != -1:
							var insert_pos := p_content.find("\n", autoload_section_idx) + 1
							p_content = p_content.insert(insert_pos, autoload_line)
						else:
							p_content += "[autoload]\n" + autoload_line
						var f_out := FileAccess.open(proj_file, FileAccess.WRITE)
						f_out.store_string(p_content)
						f_out.close()
						logs.append("🔧 Registered autoload: " + autoload_name + " → " + autoload_path)
						success_count += 1
					else:
						logs.append("ℹ️ Autoload already exists: " + autoload_name)

			"create_shader":
				var path: String = str(action.get("path", ""))
				var shader_code: String = str(action.get("content", ""))
				if path.is_empty() or shader_code.is_empty():
					errors.append("create_shader: missing 'path' or 'content'.")
					continue
				var dir_path := path.get_base_dir()
				if not DirAccess.dir_exists_absolute(dir_path):
					DirAccess.make_dir_recursive_absolute(dir_path)
				var f := FileAccess.open(path, FileAccess.WRITE)
				if f:
					f.store_string(shader_code)
					f.close()
					logs.append("🎨 Created shader: " + path)
					success_count += 1
				else:
					errors.append("create_shader: failed to write " + path)

			"add_node_to_scene":
				var scene_path: String = str(action.get("scene_path", ""))
				var node_type: String = str(action.get("node_type", "Node"))
				var node_name: String = str(action.get("node_name", "NewNode"))
				var parent_path: String = str(action.get("parent_path", "."))
				var script_path: String = str(action.get("script_path", ""))
				var properties: Dictionary = action.get("properties", {})

				if scene_path.is_empty():
					errors.append("add_node_to_scene: missing 'scene_path'.")
					continue

				if FileAccess.file_exists(scene_path):
					var packed_scene: PackedScene = ResourceLoader.load(scene_path) as PackedScene
					if packed_scene:
						var root_node: Node = packed_scene.instantiate()
						var new_node: Node = null
						if ClassDB.class_exists(node_type):
							new_node = ClassDB.instantiate(node_type) as Node
						else:
							new_node = Node.new()
						new_node.name = node_name

						if not script_path.is_empty() and FileAccess.file_exists(script_path):
							var script_res: Script = ResourceLoader.load(script_path) as Script
							if script_res:
								new_node.set_script(script_res)

						for prop_name in properties:
							if prop_name in new_node:
								new_node.set(prop_name, properties[prop_name])

						var parent_node: Node = root_node.get_node_or_null(parent_path) if parent_path != "." else root_node
						if parent_node:
							parent_node.add_child(new_node)
							new_node.owner = root_node

							_clear_scene_file_path_recursive(root_node)
							var new_packed: PackedScene = PackedScene.new()
							if new_packed.pack(root_node) == OK:
								ResourceSaver.save(new_packed, scene_path)
								logs.append("➕ Added " + node_type + " '" + node_name + "' to " + scene_path)
								success_count += 1
							else:
								errors.append("add_node_to_scene: failed to pack scene")
						else:
							errors.append("add_node_to_scene: parent node not found: " + parent_path)

						if is_instance_valid(root_node):
							root_node.free()
					else:
						errors.append("add_node_to_scene: failed to load scene")
				else:
					errors.append("add_node_to_scene: scene not found: " + scene_path)

			"set_node_property":
				var scene_path: String = str(action.get("scene_path", ""))
				var node_path: String = str(action.get("node_path", "."))
				var properties: Dictionary = action.get("properties", {})

				if scene_path.is_empty() or properties.is_empty():
					errors.append("set_node_property: missing 'scene_path' or 'properties'.")
					continue

				if FileAccess.file_exists(scene_path):
					var packed_scene: PackedScene = ResourceLoader.load(scene_path) as PackedScene
					if packed_scene:
						var root_node: Node = packed_scene.instantiate()
						var target_node: Node = root_node.get_node_or_null(node_path) if node_path != "." else root_node
						if target_node:
							for prop_name in properties:
								if prop_name in target_node:
									target_node.set(prop_name, properties[prop_name])

							_clear_scene_file_path_recursive(root_node)
							var new_packed: PackedScene = PackedScene.new()
							if new_packed.pack(root_node) == OK:
								ResourceSaver.save(new_packed, scene_path)
								logs.append("🔧 Set properties on " + node_path + " in " + scene_path)
								success_count += 1
							else:
								errors.append("set_node_property: failed to pack scene")
						else:
							errors.append("set_node_property: node not found: " + node_path)
						if is_instance_valid(root_node):
							root_node.free()
					else:
						errors.append("set_node_property: failed to load scene")
				else:
					errors.append("set_node_property: scene not found: " + scene_path)

			_:
				if type != "task_complete":
					errors.append("Unknown action type: " + type)

	if editor_interface:
		editor_interface.get_resource_filesystem().scan()

	return {
		"success": errors.is_empty(),
		"success_count": success_count,
		"logs": logs,
		"errors": errors,
		"modified_files": modified_files
	}

static func save_all_open_scripts(editor_interface: EditorInterface) -> void:
	if not editor_interface: return
	if editor_interface.has_method("save_all_scenes"):
		editor_interface.save_all_scenes()

static func reload_editor_scripts(editor_interface: EditorInterface) -> void:
	if not editor_interface: return
	var rfs = editor_interface.get_resource_filesystem()
	if rfs:
		rfs.scan()
		if rfs.has_method("scan_sources"):
			rfs.scan_sources()
	var script_editor = editor_interface.get_script_editor()
	if script_editor:
		if script_editor.has_method("reload_open_files"):
			script_editor.reload_open_files()
		elif script_editor.has_method("reload_scripts_from_file"):
			script_editor.reload_scripts_from_file()

static func _strip_code_fences(raw: String) -> String:
	var cleaned := raw.strip_edges()
	if cleaned.begins_with("```tscn"):
		cleaned = cleaned.substr(7).strip_edges()
	elif cleaned.begins_with("```ini"):
		cleaned = cleaned.substr(6).strip_edges()
	elif cleaned.begins_with("```gdscript"):
		cleaned = cleaned.substr(11).strip_edges()
	elif cleaned.begins_with("```"):
		cleaned = cleaned.substr(3).strip_edges()
	if cleaned.ends_with("```"):
		cleaned = cleaned.left(cleaned.length() - 3).strip_edges()
	return cleaned

static func _clear_scene_file_path_recursive(node: Node) -> void:
	if not node: return
	node.scene_file_path = ""
	for child in node.get_children():
		_clear_scene_file_path_recursive(child)

static func _add_modified_file(modified_files: Array[String], path: String) -> void:
	var clean := path.strip_edges()
	if not clean.is_empty() and not modified_files.has(clean):
		modified_files.append(clean)
