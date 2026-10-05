@tool
class_name AIPipeline
extends RefCounted

# ══════════════════════════════════════════════════════════════════════════════
# OPTIMIZED PIPELINE v3 — Strict State Isolation + Anti-Hallucination Guards
# ══════════════════════════════════════════════════════════════════════════════
#
# PIPELINE STAGES:
# 1. ANALYZE  (big model) - Analyze goal, plan approach, generate all actions
# 2. EXECUTE  (internal) - Apply changes to disk (no API call needed)
# 3. VERIFY   (big model) - Review results, verify with ACTUAL logs, decide next
# 4. COMPLETE - Task finished
#
# KEY IMPROVEMENTS v3:
# - AgentState enum enforced at pipeline level
# - Sub-task logs are flagged as ARCHIVED to prevent re-verification bleed
# - Execution loop counter resets on every new user prompt
# - Past tool-execution logs truncated to prevent context bloat
# ══════════════════════════════════════════════════════════════════════════════

enum PipelineStage {
	IDLE,
	TRIAGE,     # Lean context: AI sees file tree + logs only, asks for specific files it needs
	ANALYZE,    # Big model: Analyze goal, plan approach, generate comprehensive actions
	EXECUTE,    # Internal: Apply file changes to disk (no API call needed)
	VERIFY,     # Big model: Review execution results, verify with ACTUAL logs
	COMPLETE    # Task finished
}

var current_stage: PipelineStage = PipelineStage.IDLE
var task_category: String = "GENERAL"
var target_files: Array[String] = []
var sub_task_plan: Array[Dictionary] = []

# ── Private history — archived after each new user prompt ────────────────────
var _execution_history: Array[Dictionary] = []
var _verification_results: Array[Dictionary] = []
var _archived_task_logs: Array[String] = []  # Flattened summaries of past tasks
var _loop_counter: int = 0  # Reset to 0 on every new user prompt
var _triage_requested_files: Array[String] = []  # Files the AI asked for during TRIAGE

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────
func reset_for_new_prompt() -> void:
	# Archive current task logs as completed summaries (prevents re-verification bleed)
	if not _execution_history.is_empty():
		var archived_summary := "[ARCHIVED/COMPLETED TASK — " + str(Time.get_datetime_string_from_system()) + "] "
		archived_summary += "Executed " + str(_execution_history.size()) + " action round(s). Status: DONE."
		_archived_task_logs.append(archived_summary)
		# Keep only last 3 archived task summaries to limit context bloat
		if _archived_task_logs.size() > 3:
			_archived_task_logs = _archived_task_logs.slice(_archived_task_logs.size() - 3)

	# Hard reset all live state
	_execution_history.clear()
	_verification_results.clear()
	_loop_counter = 0
	current_stage = PipelineStage.IDLE
	task_category = "GENERAL"
	target_files.clear()
	sub_task_plan.clear()
	_triage_requested_files.clear()

func start_pipeline(user_goal: String) -> Dictionary:
	_loop_counter += 1
	current_stage = PipelineStage.TRIAGE
	return {
		"stage": PipelineStage.TRIAGE,
		"prompt_type": "TRIAGE",
		"use_small_model": false,
		"max_tokens": 1200,
		"loop_counter": _loop_counter,
		"instructions": "Review the project structure and logs. Decide which files you need, then output a request_files action. If no files needed, answer directly."
	}

func advance_to_analyze() -> Dictionary:
	current_stage = PipelineStage.ANALYZE
	return {
		"stage": PipelineStage.ANALYZE,
		"prompt_type": "ANALYZE",
		"use_small_model": false,
		"max_tokens": 8192,
		"loop_counter": _loop_counter,
		"instructions": "You now have the files you requested. Analyze the goal fully and generate ALL necessary actions."
	}

# Store which files the AI requested during TRIAGE
func set_triage_files(files: Array[String]) -> void:
	_triage_requested_files = files.duplicate()

func get_triage_files() -> Array[String]:
	return _triage_requested_files

func advance_to_execution() -> Dictionary:
	current_stage = PipelineStage.EXECUTE
	return {
		"stage": PipelineStage.EXECUTE,
		"prompt_type": "EXECUTE",
		"use_small_model": false,
		"max_tokens": 0,
		"instructions": "Apply the planned actions to disk."
	}

func advance_to_verification() -> Dictionary:
	current_stage = PipelineStage.VERIFY
	return {
		"stage": PipelineStage.VERIFY,
		"prompt_type": "VERIFY",
		"use_small_model": false,
		"max_tokens": 8192,
		"instructions": "Review execution results, verify with ACTUAL RUNTIME LOGS (not assumptions), decide if task is complete."
	}

func advance_to_completion() -> Dictionary:
	current_stage = PipelineStage.COMPLETE
	return {
		"stage": PipelineStage.COMPLETE,
		"prompt_type": "COMPLETE",
		"use_small_model": false,
		"max_tokens": 0,
		"instructions": "Task completed successfully."
	}

func record_execution(execution_data: Dictionary) -> void:
	_execution_history.append({
		"timestamp": Time.get_unix_time_from_system(),
		"loop": _loop_counter,
		"data": execution_data
	})

func record_verification(verification_data: Dictionary) -> void:
	_verification_results.append({
		"timestamp": Time.get_unix_time_from_system(),
		"loop": _loop_counter,
		"data": verification_data
	})

func get_loop_counter() -> int:
	return _loop_counter

func get_execution_summary() -> String:
	if _execution_history.is_empty():
		return "No executions recorded."
	var summary := "Execution History:\n"
	for i in range(_execution_history.size()):
		var exec := _execution_history[i]
		summary += str(i + 1) + ". [Round " + str(exec.get("loop", 0)) + "] " + str(exec["data"].get("summary", "Execution")) + "\n"
	return summary

func get_archived_task_context() -> String:
	## Returns a compact summary of previously COMPLETED tasks.
	## These are injected as ARCHIVED context to prevent re-verification attempts.
	if _archived_task_logs.is_empty():
		return ""
	return "## PREVIOUSLY COMPLETED TASKS (ARCHIVED — DO NOT RE-VERIFY)\n" + "\n".join(_archived_task_logs) + "\n\n"

func should_continue() -> bool:
	return current_stage != PipelineStage.COMPLETE

func get_system_prompt_for_stage(stage: PipelineStage) -> String:
	match stage:
		PipelineStage.TRIAGE:
			return AIPrompts.get_triage_system_prompt()
		PipelineStage.ANALYZE:
			return AIPrompts.get_unified_system_prompt()
		PipelineStage.EXECUTE:
			return AIPrompts.get_execution_prompt()
		PipelineStage.VERIFY:
			return AIPrompts.get_unified_system_prompt()
		PipelineStage.COMPLETE:
			return ""
		_:
			return AIPrompts.get_unified_system_prompt()

# ══════════════════════════════════════════════════════════════════════════════
# LEGACY COMPATIBILITY
# ══════════════════════════════════════════════════════════════════════════════
func advance_to_synthesis(_plan_data: Dictionary) -> Dictionary:
	return advance_to_execution()

func advance_to_reflection() -> Dictionary:
	return advance_to_verification()

func get_prompt_for_stage(stage: String, is_small_model: bool) -> String:
	if not is_small_model:
		return AIPrompts.get_unified_system_prompt()
	return AIPrompts.get_prompt_for_stage(stage, is_small_model)
