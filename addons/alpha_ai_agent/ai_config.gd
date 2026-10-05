@tool
class_name AIConfig
extends RefCounted

const CONFIG_PATH: String = "user://ai_config.json"

const PROVIDER_OPENAI: String = "OpenAI"
const PROVIDER_ANTHROPIC: String = "Anthropic"
const PROVIDER_GEMINI: String = "Gemini"
const PROVIDER_OPENROUTER: String = "OpenRouter"
const PROVIDER_DEEPSEEK: String = "DeepSeek"

var provider: String = PROVIDER_OPENAI
var selected_model: String = "gpt-4o"
var api_keys: Dictionary = {
	PROVIDER_OPENAI: "",
	PROVIDER_ANTHROPIC: "",
	PROVIDER_GEMINI: "",
	PROVIDER_OPENROUTER: "",
	PROVIDER_DEEPSEEK: ""
}
var temperature: float = 0.7
var use_max_tokens: bool = false
var max_tokens: int = 2048
var include_tree: bool = true
var include_scripts: bool = true
var include_scenes: bool = true
var include_assets: bool = true
var cached_models: Dictionary = {}

var use_free_trial_mode: bool = true
var auto_refresh_usage: bool = true
var auto_refresh_interval_minutes: float = 5.0
var usage_info: Dictionary = {
	"used_today": 0,
	"limit": 10,
	"remaining": 10,
	"percent_remaining": 100.0,
	"reset_human": ""
}

func _init() -> void:
	load_config()

func load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	
	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if not file:
		return
	
	var content := file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(content)
	if parse_result != OK:
		push_warning("Alpha AI Agent: Failed to parse config JSON.")
		return
	
	var data: Dictionary = json.data
	if data.has("provider"):
		provider = str(data["provider"])
	if data.has("selected_model"):
		selected_model = str(data["selected_model"])
	if data.has("api_keys") and data["api_keys"] is Dictionary:
		for k in data["api_keys"]:
			api_keys[str(k)] = str(data["api_keys"][k])
	if data.has("temperature"):
		temperature = float(data["temperature"])
	if data.has("use_max_tokens"):
		use_max_tokens = bool(data["use_max_tokens"])
	else:
		use_max_tokens = false
	if data.has("max_tokens"):
		max_tokens = int(data["max_tokens"])
	if data.has("include_tree"):
		include_tree = bool(data["include_tree"])
	if data.has("include_scripts"):
		include_scripts = bool(data["include_scripts"])
	if data.has("include_scenes"):
		include_scenes = bool(data["include_scenes"])
	if data.has("include_assets"):
		include_assets = bool(data["include_assets"])
	if data.has("use_free_trial_mode"):
		use_free_trial_mode = bool(data["use_free_trial_mode"])
	if data.has("auto_refresh_usage"):
		auto_refresh_usage = bool(data["auto_refresh_usage"])
	if data.has("auto_refresh_interval_minutes"):
		auto_refresh_interval_minutes = float(data["auto_refresh_interval_minutes"])
	if data.has("cached_models") and data["cached_models"] is Dictionary:
		for k in data["cached_models"]:
			var models: Array[String] = []
			for m in data["cached_models"][k]:
				models.append(str(m))
			cached_models[str(k)] = models

func save_config() -> void:
	var data: Dictionary = {
		"provider": provider,
		"selected_model": selected_model,
		"api_keys": api_keys,
		"temperature": temperature,
		"use_max_tokens": use_max_tokens,
		"max_tokens": max_tokens,
		"include_tree": include_tree,
		"include_scripts": include_scripts,
		"include_scenes": include_scenes,
		"include_assets": include_assets,
		"cached_models": cached_models,
		"use_free_trial_mode": use_free_trial_mode,
		"auto_refresh_usage": auto_refresh_usage,
		"auto_refresh_interval_minutes": auto_refresh_interval_minutes
	}
	
	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if not file:
		push_error("Alpha AI Agent: Failed to open config file for writing.")
		return
	
	file.store_string(JSON.stringify(data, "\t"))
	file.close()

static func get_device_id() -> String:
	return OS.get_unique_id()

func update_usage_from_api(data: Dictionary) -> void:
	if data.has("device") and data["device"] is Dictionary:
		var dev: Dictionary = data["device"]
		usage_info["used_today"] = int(dev.get("used_today", 0))
		usage_info["limit"] = int(dev.get("limit", 10))
		usage_info["remaining"] = int(dev.get("remaining", 10))
		usage_info["percent_remaining"] = float(dev.get("percent_remaining", 100.0))
	if data.has("reset") and data["reset"] is Dictionary:
		var r: Dictionary = data["reset"]
		usage_info["reset_human"] = str(r.get("human_readable", ""))

func get_free_requests_remaining() -> int:
	return int(usage_info.get("remaining", 10))

func get_usage_display_text() -> String:
	var pct := float(usage_info.get("percent_remaining", 100.0))
	var r_str := str(usage_info.get("reset_human", ""))
	var text := "Free Mode: %.0f%% usage left today" % [pct]
	if not r_str.is_empty():
		text += " • Resets in " + r_str
	return text

func is_using_free_trial_mode() -> bool:
	if use_free_trial_mode:
		return true
	var current_key := get_api_key()
	return current_key.is_empty()

func get_api_key(p_provider: String = "") -> String:
	var p = p_provider if not p_provider.is_empty() else provider
	return api_keys.get(p, "")

func set_api_key(p_key: String, p_provider: String = "") -> void:
	var p = p_provider if not p_provider.is_empty() else provider
	api_keys[p] = p_key.strip_edges()
	save_config()

func clear_all_api_keys() -> void:
	for p in api_keys:
		api_keys[p] = ""
	use_free_trial_mode = true
	save_config()

func has_any_api_key() -> bool:
	for p in api_keys:
		if not str(api_keys[p]).strip_edges().is_empty():
			return true
	return false

func get_all_available_models_with_keys() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var all_providers := [PROVIDER_OPENAI, PROVIDER_ANTHROPIC, PROVIDER_GEMINI, PROVIDER_OPENROUTER, PROVIDER_DEEPSEEK]
	
	for p in all_providers:
		var key: String = api_keys.get(p, "").strip_edges()
		if not key.is_empty():
			var models := get_models_for_provider(p)
			for m in models:
				result.append({
					"provider": p,
					"model": m
				})
				
	return result

func get_models_for_provider(p_provider: String = "") -> Array[String]:
	var p = p_provider if not p_provider.is_empty() else provider
	if cached_models.has(p) and cached_models[p] is Array and not cached_models[p].is_empty():
		return cached_models[p]
	return get_default_models_for_provider(p)

func set_cached_models(p_provider: String, models: Array[String]) -> void:
	cached_models[p_provider] = models
	save_config()

static func get_default_models_for_provider(p_provider: String) -> Array[String]:
	match p_provider:
		PROVIDER_OPENAI:
			return ["gpt-4o", "gpt-4o-mini", "o3-mini"]
		PROVIDER_ANTHROPIC:
			return ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest", "claude-3-opus-latest"]
		PROVIDER_GEMINI:
			return ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"]
		PROVIDER_OPENROUTER:
			return ["anthropic/claude-3.5-sonnet", "openai/gpt-4o", "google/gemini-2.0-flash-001", "deepseek/deepseek-r1"]
		PROVIDER_DEEPSEEK:
			return ["deepseek-chat", "deepseek-coder"]
		_:
			return ["gpt-4o"]
