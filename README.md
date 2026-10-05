# 🤖 Alpha AI Agent for Godot

![Godot Engine](https://img.shields.io/badge/Godot-v4.x-blue?logo=godotengine&logoColor=white)
![GDScript 2.0](https://img.shields.io/badge/GDScript-2.0-green)
![Version](https://img.shields.io/badge/Version-v0.57.2-brightgreen)
![Discord](https://img.shields.io/badge/Discord-Join%20Community-5865F2?logo=discord&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-orange)

> Turn prompts into production-ready GDScript, scene modifications, and game logic directly inside Godot 4.

**Alpha AI Agent** is an in-editor agentic coding assistant built specifically for Godot 4 developers who prioritize fast execution and working solutions. It reads your project structure, modifies scripts, connects signals, inspects runtime logs, and executes multi-file changes with built-in version safety.

---

## ✨ Key Features

* 🚀 **3-Stage Agentic Execution Pipeline:** `ANALYZE → EXECUTE → VERIFY` stage management reads `.gd` files, updates `.tscn` scenes, and wires signals automatically.
* 🛡️ **Anti-Hallucination & Truth Logs:** Verifies execution by inspecting actual runtime output and `user://logs/godot.log` traces instead of assuming success.
* 🔄 **Monotonic Diff Viewer & Snapshot Safety:** Automatic pre-edit checkpoints and a line-by-line diff viewer (`AIGitManager`) with 1-click round reverts so you never lose working code.
* ⚡ **Multi-Editor Sync:** Automatically saves open Godot scripts and reloads files to prevent "Modified on disk" popups when switching between Godot and external editors.
* 🎯 **Holistic Multi-Cause Diagnosis:** Analyzes inter-script relationships, node trees, and collision layers together rather than making isolated micro-patches.
* 🔔 **Auto Version & Remote Announcement System:** Built-in automatic update notifications and remote notice popups with cache-busting.
* 🔑 **BYOK & Free Trial Mode:** Use built-in daily free requests or bring your own API keys for OpenAI, Anthropic, Gemini, or OpenRouter.
* ❤️ **Developer & Community Support:** Quick access to support developers on itch.io and community support from Discord.

---

## 🌐 Community, Bug Reports & Support

* 💬 **Join Discord Community**: [https://discord.gg/sWM8xUEq9](https://discord.gg/sWM8xUEq9)
* 🐛 **Report a Bug / Request Feature**: [https://github.com/mdabunafisniloy/Alpha-Ai-Plugin/issues](https://github.com/mdabunafisniloy/Alpha-Ai-Plugin/issues)
* ❤️ **Support Development on itch.io**: [https://nafisniloy.itch.io/alpha-ai-agent](https://nafisniloy.itch.io/alpha-ai-agent)

---

## 📦 Installation

1. Download the latest release `.zip` from [itch.io](https://nafisniloy.itch.io/alpha-ai-agent) or GitHub Releases.
2. Extract the `addons/alpha_ai_agent` folder into your Godot project's `res://addons/` directory.
3. In Godot, go to **Project -> Project Settings -> Plugins**.
4. Check the **Enable** box next to **Alpha AI Agent**.
5. The **Alpha AI** panel will appear in your left editor dock!

---

## ⚙️ Settings & API Keys

* Click the **⚙ Settings** tab in the dock to switch between **Free Trial Mode** and custom API keys for **OpenAI**, **Anthropic**, **Gemini**, or **OpenRouter**.
* Credentials are saved locally to `user://ai_config.json` and are never sent to external third-party servers.
* Use the **🗑️ Clear Keys** button at any time to wipe saved credentials and return to Free Trial mode.

---

## 📂 Plugin Directory Structure

```text
addons/alpha_ai_agent/
├── plugin.cfg                 # Godot Editor plugin configuration
├── alpha_ai_agent.gd          # Main EditorPlugin entry point
├── ai_dock.gd                 # UI Dock controller & main orchestration engine
├── ai_dock.tscn               # UI Dock scene file
├── ai_pipeline.gd             # 3-stage agentic pipeline state machine
├── ai_prompts.gd              # System prompts & anti-hallucination instructions
├── execution_engine.gd        # Non-blocking file & scene execution engine
├── project_context.gd         # Project structure parser & truth log extractor
├── ai_git_manager.gd          # Monotonic snapshot & backup round manager
├── ai_diff_window.gd          # UI controller for side-by-side diff window
├── ai_diff_window.tscn        # UI scene for diff window
├── ai_network.gd              # HTTP network manager for LLM API requests
└── ai_config.gd               # Persistent user configuration manager (user://ai_config.json)
```

---

## 📜 License

This project is licensed under the **MIT License**. Feel free to use, modify, and distribute it in your commercial or open-source Godot projects.
