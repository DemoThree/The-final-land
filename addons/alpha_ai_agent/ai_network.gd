@tool
class_name AINetwork
extends Node

enum NetworkStatus {
	IDLE,
	THINKING,
	CALLING_TOOL,
	VPS_AWAITING_RETRY
}

const VPS_ROUTE_URL: String = "https://api.alphasoft.website/api/route"
const VPS_SMALL_URL: String = "https://api.alphasoft.website/api/route"
const VPS_USAGE_URL: String = "https://api.alphasoft.website/api/usage"
const VPS_MODELS_URL: String = "https://api.alphasoft.website/api/models"
#const VPS_ROUTE_URL: String = "http://localhost:8000/api/route"
#const VPS_SMALL_URL: String = "http://localhost:8000/api/route"
#const VPS_USAGE_URL: String = "http://localhost:8000/api/usage"
#const VPS_MODELS_URL: String = "http://localhost:8000/api/models"

signal request_started
signal request_completed(response_text: String)
signal request_failed(error_message: String)
signal models_fetched(provider: String, models: Array[String])
signal models_fetch_failed(provider: String, error_message: String)
signal usage_fetched(usage_data: Dictionary)
signal usage_fetch_failed(error_message: String)
signal status_changed(new_status: NetworkStatus)
signal limit_exhausted
signal server_congested

var status: NetworkStatus = NetworkStatus.IDLE:
	set(val):
		if status != val:
			status = val
			emit_signal("status_changed", status)

var http_request: HTTPRequest
var models_http_request: HTTPRequest
var usage_http_request: HTTPRequest
var _fetching_provider: String = ""

# Fallback retry state for OpenRouter low-credit token limits
var _last_config: AIConfig
var _last_prompt: String
var _last_context: String
var _last_history: Array[Dictionary]
var _is_retrying_fallback: bool = false
var _is_request_cancelled: bool = false
var _last_use_small_model: bool = false

func _ready() -> void:
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_http_request_completed)

	models_http_request = HTTPRequest.new()
	add_child(models_http_request)
	models_http_request.request_completed.connect(_on_models_request_completed)

	usage_http_request = HTTPRequest.new()
	add_child(usage_http_request)
	usage_http_request.request_completed.connect(_on_usage_request_completed)

func cancel_request() -> void:
	_is_request_cancelled = true
	if http_request:
		http_request.cancel_request()
	status = NetworkStatus.IDLE
	emit_signal("request_failed", "Request cancelled by user.")

func fetch_usage(config: AIConfig) -> void:
	if not usage_http_request:
		return
	var url := VPS_USAGE_URL
	var headers: PackedStringArray = [
		"X-Device-ID: " + AIConfig.get_device_id()
	]
	usage_http_request.request(url, headers, HTTPClient.METHOD_GET)

func _on_usage_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		emit_signal("usage_fetch_failed", "Failed to fetch usage statistics (Code: " + str(response_code) + ")")
		return
	
	var body_text := body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(body_text) == OK and json.data is Dictionary:
		emit_signal("usage_fetched", json.data)

func send_prompt(config: AIConfig, user_prompt: String, project_context: String, chat_history: Array[Dictionary] = [], is_fallback_retry: bool = false, use_small_model: bool = false, stage_prompt_type: String = "") -> void:
	if not http_request:
		emit_signal("request_failed", "HTTPRequest node not initialized.")
		return
		
	var api_key := config.get_api_key()
	var is_proxied := config.is_using_free_trial_mode()

	if is_proxied and config.get_free_requests_remaining() <= 0:
		emit_signal("limit_exhausted")
		emit_signal("request_failed", "Free trial limit reached for today. Please insert your own API key in the plugin settings to continue seamlessly.")
		return
		
	if not is_fallback_retry:
		_last_config = config
		_last_prompt = user_prompt
		_last_context = project_context
		_last_history = chat_history.duplicate(true)
		_last_use_small_model = use_small_model
		_is_retrying_fallback = false
		_is_request_cancelled = false

	# Append explicit JSON action mandate to every prompt
	var enforced_prompt := user_prompt
	var already_has_enforcement := (
		user_prompt.contains("```json") or
		user_prompt.contains("MANDATORY") or
		user_prompt.contains("Execution Report") or
		user_prompt.contains("Runtime Errors") or
		user_prompt.contains("REPEATING LOOP") or
		user_prompt.contains("task_complete")
	)
	if not already_has_enforcement:
		enforced_prompt += (
			"\n\n---\n"
			+ "REMINDER: You MUST end your response with a ```json [...] ``` action block.\n"
			+ "If there is nothing left to do, output: ```json\n[{\"action\": \"task_complete\", \"summary\": \"description\"}]\n```\n"
			+ "DO NOT end your response with only text."
		)

	var system_instruction := _get_system_prompt(stage_prompt_type, use_small_model) + "\n\n" + project_context
	
	var url := ""
	var headers: PackedStringArray = ["Content-Type: application/json"]
	var body_dict: Dictionary = {}
	
	var messages_list: Array[Dictionary] = []
	for hist in chat_history:
		var role: String = str(hist.get("role", "user"))
		var text: String = str(hist.get("text", ""))
		if not text.is_empty():
			messages_list.append({
				"role": "assistant" if role == "assistant" or role == "model" else "user",
				"content": text
			})
	
	messages_list.append({
		"role": "user",
		"content": enforced_prompt
	})
	
	if is_proxied:
		# Free Trial Mode (Proxied to VPS) - small endpoint vs route endpoint
		url = VPS_SMALL_URL if use_small_model else VPS_ROUTE_URL
		headers.append("X-Device-ID: " + AIConfig.get_device_id())
		
		var full_msgs: Array[Dictionary] = [{"role": "system", "content": system_instruction}]
		full_msgs.append_array(messages_list)
		
		var params: Dictionary = {
			"temperature": config.temperature
		}
		# Smart token limits: small models compact, big models uncapped
		if use_small_model:
			params["max_tokens"] = AIPrompts.get_max_tokens_for_model(true, 0)
		elif is_fallback_retry:
			params["max_tokens"] = 1500
		elif config.use_max_tokens and config.max_tokens > 0:
			params["max_tokens"] = config.max_tokens
		else:
			# No cap for big models in proxied mode either
			params["max_tokens"] = AIPrompts.get_max_tokens_for_model(false, 0)
			
		body_dict = {
			"messages": full_msgs,
			"params": params
		}
	else:
		# BYOK Mode (Direct to provider)
		var chosen_model := get_small_model_for_provider(config.provider, config.selected_model) if use_small_model else config.selected_model
		# Smart token limits based on model size
		var max_tok_override: int
		if use_small_model:
			max_tok_override = AIPrompts.get_max_tokens_for_model(true, 0)
		elif is_fallback_retry:
			max_tok_override = 1500
		else:
			max_tok_override = AIPrompts.get_max_tokens_for_model(false, config.max_tokens)
		
		match config.provider:
			AIConfig.PROVIDER_OPENAI:
				url = "https://api.openai.com/v1/chat/completions"
				headers.append("Authorization: Bearer " + api_key)
				
				var full_msgs: Array[Dictionary] = [{"role": "system", "content": system_instruction}]
				full_msgs.append_array(messages_list)
				
				body_dict = {
					"model": chosen_model,
					"messages": full_msgs,
					"temperature": config.temperature,
					"max_tokens": max_tok_override
				}
				
			AIConfig.PROVIDER_OPENROUTER:
				url = "https://openrouter.ai/api/v1/chat/completions"
				headers.append("Authorization: Bearer " + api_key)
				headers.append("HTTP-Referer: https://godotengine.org")
				headers.append("X-Title: Alpha AI Agent for Godot")
				
				var full_msgs: Array[Dictionary] = [{"role": "system", "content": system_instruction}]
				full_msgs.append_array(messages_list)
				
				body_dict = {
					"model": chosen_model,
					"messages": full_msgs,
					"temperature": config.temperature,
					"max_tokens": max_tok_override
				}
				
			AIConfig.PROVIDER_ANTHROPIC:
				url = "https://api.anthropic.com/v1/messages"
				headers.append("x-api-key: " + api_key)
				headers.append("anthropic-version: 2023-06-01")
				
				body_dict = {
					"model": chosen_model,
					"system": system_instruction,
					"messages": messages_list,
					"temperature": config.temperature,
					"max_tokens": max_tok_override
				}
				
			AIConfig.PROVIDER_GEMINI:
				var model_name = chosen_model
				if not model_name.begins_with("models/"):
					model_name = "models/" + model_name
				url = "https://generativelanguage.googleapis.com/v1beta/" + model_name + ":generateContent?key=" + api_key

				var gemini_contents: Array[Dictionary] = []
				for m in messages_list:
					gemini_contents.append({
						"role": "model" if m["role"] == "assistant" else "user",
						"parts": [{"text": m["content"]}]
					})

				var gen_config: Dictionary = {
					"temperature": config.temperature,
					"maxOutputTokens": max_tok_override
				}

				body_dict = {
					"system_instruction": {
						"parts": [{"text": system_instruction}]
					},
					"contents": gemini_contents,
					"generationConfig": gen_config
				}

			AIConfig.PROVIDER_DEEPSEEK:
				url = "https://api.deepseek.com/v1/chat/completions"
				headers.append("Authorization: Bearer " + api_key)

				var full_msgs: Array[Dictionary] = [{"role": "system", "content": system_instruction}]
				full_msgs.append_array(messages_list)

				body_dict = {
					"model": chosen_model,
					"messages": full_msgs,
					"temperature": config.temperature,
					"max_tokens": max_tok_override
				}
	var json_body := JSON.stringify(body_dict)
	if not is_fallback_retry:
		emit_signal("request_started")
	
	status = NetworkStatus.VPS_AWAITING_RETRY if is_fallback_retry else NetworkStatus.THINKING
	var err := http_request.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		status = NetworkStatus.IDLE
		emit_signal("request_failed", "Failed to send HTTP request (Code: " + str(err) + ")")

var _vps_retry_count: int = 0

func _on_http_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	status = NetworkStatus.IDLE
	if _is_request_cancelled:
		return

	if result != HTTPRequest.RESULT_SUCCESS:
		if _vps_retry_count < 2:
			_vps_retry_count += 1
			status = NetworkStatus.VPS_AWAITING_RETRY
			var timer := get_tree().create_timer(1.5)
			timer.timeout.connect(func():
				if not _is_request_cancelled:
					send_prompt(_last_config, _last_prompt, _last_context, _last_history, true)
			)
			return
		_vps_retry_count = 0
		emit_signal("request_failed", "Network request failed with result code: " + str(result))
		return

	# Granular Status Code Parsing & Auto-Retry
	if response_code == 403:
		_vps_retry_count = 0
		emit_signal("limit_exhausted")
		emit_signal("request_failed", "Free trial limit reached for today. Please insert your own API key in the plugin settings to continue seamlessly.")
		return
	elif response_code == 429 or response_code == 503:
		if _vps_retry_count < 3:
			_vps_retry_count += 1
			status = NetworkStatus.VPS_AWAITING_RETRY
			emit_signal("server_congested")
			var timer := get_tree().create_timer(2.0)
			timer.timeout.connect(func():
				if not _is_request_cancelled:
					send_prompt(_last_config, _last_prompt, _last_context, _last_history, true)
			)
			return
		_vps_retry_count = 0
		emit_signal("request_failed", "Free tier is congested (HTTP " + str(response_code) + "). Suggesting BYOK to bypass the shared queue.")
	elif response_code < 200 or response_code >= 300:
		var body_text := body.get_string_from_utf8().strip_edges()
		# Clean HTML error pages (e.g. 404 Page Not Found HTML responses)
		if body_text.begins_with("<!") or body_text.begins_with("<html") or body_text.contains("<title>"):
			var t_start := body_text.find("<title>")
			var t_end := body_text.find("</title>")
			if t_start != -1 and t_end != -1 and t_end > t_start:
				body_text = body_text.substr(t_start + 7, t_end - t_start - 7).strip_edges()
			else:
				body_text = "Server returned an HTML error page."
		_vps_retry_count = 0
		emit_signal("request_failed", "API Error (HTTP " + str(response_code) + "): " + body_text)
		return
		
	var body_text := body.get_string_from_utf8()
	var json := JSON.new()
	var parse_err := json.parse(body_text)
	if parse_err != OK:
		# Attempt clean JSON extraction if wrapped in text/BOM/HTML
		var first_b := body_text.find("{")
		var last_b := body_text.rfind("}")
		if first_b >= 0 and last_b > first_b:
			var clean_str := body_text.substr(first_b, last_b - first_b + 1)
			parse_err = json.parse(clean_str)

	if parse_err != OK:
		if _vps_retry_count < 2:
			_vps_retry_count += 1
			status = NetworkStatus.VPS_AWAITING_RETRY
			var timer := get_tree().create_timer(1.5)
			timer.timeout.connect(func():
				if not _is_request_cancelled:
					send_prompt(_last_config, _last_prompt, _last_context, _last_history, true)
			)
			return
		_vps_retry_count = 0
		emit_signal("request_failed", "Failed to parse API JSON response.")
		return

	# Reset retry count on successful response parse
	_vps_retry_count = 0
		
	var raw_data: Dictionary = json.data
	# If proxied response, actual payload is nested under "data" key
	var data: Dictionary = raw_data.get("data", raw_data) if (raw_data.has("success") and raw_data.has("data") and raw_data["data"] is Dictionary) else raw_data
	var extracted_text := ""
	
	if data.has("choices") and data["choices"] is Array and not data["choices"].is_empty():
		var choice = data["choices"][0]
		if choice is Dictionary:
			if choice.has("message") and choice["message"] is Dictionary:
				var msg: Dictionary = choice["message"]
				var raw_content = msg.get("content", null)
				if raw_content != null and not str(raw_content).is_empty() and str(raw_content) != "<null>":
					extracted_text = str(raw_content)
				elif msg.has("reasoning_content") and msg["reasoning_content"] != null:
					extracted_text = str(msg["reasoning_content"])
				elif msg.has("reasoning") and msg["reasoning"] != null:
					extracted_text = str(msg["reasoning"])
				elif msg.has("text") and msg["text"] != null:
					extracted_text = str(msg["text"])
			elif choice.has("text") and choice["text"] != null:
				extracted_text = str(choice["text"])
			
	elif data.has("content") and data["content"] is Array and not data["content"].is_empty():
		var first_content = data["content"][0]
		if first_content is Dictionary and first_content.has("text"):
			extracted_text = str(first_content["text"])
			
	elif data.has("candidates") and data["candidates"] is Array and not data["candidates"].is_empty():
		var cand = data["candidates"][0]
		if cand.has("content") and cand["content"].has("parts") and not cand["content"]["parts"].is_empty():
			extracted_text = str(cand["content"]["parts"][0].get("text", ""))
			
	if extracted_text.is_empty():
		emit_signal("request_failed", "No text content found in LLM response:\n" + body_text)
	else:
		if _last_config and _last_config.is_using_free_trial_mode():
			fetch_usage(_last_config)
		emit_signal("request_completed", extracted_text)

func fetch_models(config: AIConfig) -> void:
	_fetching_provider = config.provider
	var api_key := config.get_api_key()

	var url := ""
	var headers: PackedStringArray = []

	if api_key.is_empty():
		emit_signal("models_fetched", config.provider, AIConfig.get_default_models_for_provider(config.provider))
		return

	match config.provider:
		AIConfig.PROVIDER_OPENAI:
			url = "https://api.openai.com/v1/models"
			headers.append("Authorization: Bearer " + api_key)
		AIConfig.PROVIDER_GEMINI:
			url = "https://generativelanguage.googleapis.com/v1/models?key=" + api_key
		AIConfig.PROVIDER_OPENROUTER:
			url = "https://openrouter.ai/api/v1/models"
			headers.append("Authorization: Bearer " + api_key)
		AIConfig.PROVIDER_ANTHROPIC:
			emit_signal("models_fetched", config.provider, AIConfig.get_default_models_for_provider(config.provider))
			return
		AIConfig.PROVIDER_DEEPSEEK:
			url = "https://api.deepseek.com/v1/models"
			headers.append("Authorization: Bearer " + api_key)
		_:
			emit_signal("models_fetch_failed", config.provider, "Unsupported provider: " + config.provider)
			return

	status = NetworkStatus.THINKING
	var err := models_http_request.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		status = NetworkStatus.IDLE
		emit_signal("models_fetch_failed", config.provider, "Failed to send request (Code: " + str(err) + ")")

func _on_models_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var provider := _fetching_provider
	status = NetworkStatus.IDLE

	if result != HTTPRequest.RESULT_SUCCESS:
		emit_signal("models_fetch_failed", provider, "Network request failed (Code: " + str(result) + ")")
		return

	if response_code < 200 or response_code >= 300:
		var hint := ""
		if response_code == 401 or response_code == 403:
			hint = " (add a valid API key and try again)"
		emit_signal("models_fetch_failed", provider, "API Error (HTTP " + str(response_code) + ")" + hint)
		return

	var body_text := body.get_string_from_utf8()
	var json := JSON.new()
	var parse_err := json.parse(body_text)
	if parse_err != OK:
		emit_signal("models_fetch_failed", provider, "Failed to parse models JSON response.")
		return

	var data: Dictionary = json.data
	var models: Array[String] = []

	match provider:
		AIConfig.PROVIDER_OPENAI:
			if data.has("data") and data["data"] is Array:
				for model_data in data["data"]:
					if model_data is Dictionary and model_data.has("id"):
						var model_id := str(model_data["id"])
						if not _is_excluded_openai_model(model_id):
							models.append(model_id)

		AIConfig.PROVIDER_GEMINI:
			if data.has("models") and data["models"] is Array:
				for model_data in data["models"]:
					if model_data is Dictionary and model_data.has("name"):
						var methods: Array = model_data.get("supportedGenerationMethods", [])
						if not methods.has("generateContent"):
							continue
						var raw_name := str(model_data["name"])
						if raw_name.begins_with("models/"):
							raw_name = raw_name.substr(7)
						models.append(raw_name)

		AIConfig.PROVIDER_OPENROUTER:
			if data.has("data") and data["data"] is Array:
				for model_data in data["data"]:
					if model_data is Dictionary and model_data.has("id"):
						models.append(str(model_data["id"]))

		AIConfig.PROVIDER_DEEPSEEK:
			if data.has("data") and data["data"] is Array:
				for model_data in data["data"]:
					if model_data is Dictionary and model_data.has("id"):
						models.append(str(model_data["id"]))

	models.sort()
	emit_signal("models_fetched", provider, models)

func _is_excluded_openai_model(model_id: String) -> bool:
	var excluded := ["ft:", "embedding", "whisper", "tts", "dall-e", "dalle", "babbage", "curie", "davinci", "moderation", "audio", "transcription", "realtime"]
	var lower := model_id.to_lower()
	for keyword in excluded:
		if lower.contains(keyword):
			return true
	return false

func _get_system_prompt(stage_type: String = "", is_small_model: bool = false) -> String:
	if stage_type == "TRIAGE":
		return AIPrompts.get_triage_system_prompt()
	# For big models (non-small), use the unified mega-prompt for all other stages
	if not is_small_model:
		return AIPrompts.get_unified_system_prompt()
	# Small models still use stage-specific compact prompts
	return AIPrompts.get_prompt_for_stage(stage_type, is_small_model)

static func get_small_model_for_provider(p: String, fallback_model: String) -> String:
	match p:
		AIConfig.PROVIDER_OPENAI:
			return "gpt-4o-mini"
		AIConfig.PROVIDER_ANTHROPIC:
			return "claude-3-5-haiku-latest"
		AIConfig.PROVIDER_GEMINI:
			return "gemini-1.5-flash"
		AIConfig.PROVIDER_OPENROUTER:
			return "google/gemini-2.0-flash-001"
		AIConfig.PROVIDER_DEEPSEEK:
			return "deepseek-coder"
		_:
			return fallback_model
