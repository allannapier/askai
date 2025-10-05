# AskAI - Multi-Agent Command Palette for macOS

A powerful macOS menu bar application that intercepts AI command triggers typed anywhere on your system and replaces them with AI-generated responses inline.

## Features

- **Multi-Agent Support**: Works with Claude Code, GitHub Copilot CLI, and OpenAI Codex CLI
- **Global Text Interception**: Type `/askclaude`, `/askcopilot`, or `/askcodex` followed by your prompt anywhere on macOS
- **Inline Replacement**: AI responses replace your typed text directly in the active application
- **Auto-Detection**: Automatically detects which AI agents are installed on your system
- **Menu Bar UI**: Status indicator showing available agents and recent command history
- **Diagnostics**: Built-in diagnostic tool to verify agent installations
- **Document Context**: Passes surrounding text context to AI agents for better responses

## Requirements

### System Requirements
- macOS 15.6 or later
- Xcode 16.0 or later (for building)

### AI Agent Requirements

Install at least one of the following AI CLIs:

#### Claude Code CLI
```bash
npm install -g @anthropic-ai/claude-code
```
Documentation: https://docs.anthropic.com/claude/docs/claude-code

#### GitHub Copilot CLI
```bash
npm install -g @githubnext/github-copilot-cli
```
Documentation: https://githubnext.com/projects/copilot-cli

#### OpenAI Codex CLI
```bash
brew install codex
```
Documentation: https://github.com/openai/codex-cli

## Installation

1. Clone the repository:
```bash
git clone https://github.com/allannapier/askai.git
cd askai
```

2. Open the Xcode project:
```bash
open MacCommandPalette/MacCommandPalette.xcodeproj
```

3. Build and run the project in Xcode (⌘R)

4. **Grant Accessibility Permissions**:
   - When prompted, go to System Settings > Privacy & Security > Accessibility
   - Enable permissions for MacCommandPalette

## Usage

1. Launch the app - a ⚡ icon will appear in your menu bar

2. Type any of the following triggers in any text field across macOS:
   - `/askclaude <your prompt>` - Uses Claude Code
   - `/askcopilot <your prompt>` - Uses GitHub Copilot CLI
   - `/askcodex <your prompt>` - Uses OpenAI Codex CLI

3. Press **Return** to execute the command

4. The trigger text will be replaced with "Executing..." while processing

5. Once complete, the AI response will replace the text inline

### Example
```
Type: /askclaude explain what a binary search tree is
Press: Return
Result: AI response appears directly in your text field
```

## Menu Bar Features

Click the ⚡ icon to access:

- **Agents**: Shows status (✓ or ✗) for each installed AI agent
- **Recent Commands**: Last 5 commands with their results and timestamps
- **Run Diagnostics**: Tests all agents and displays version information
- **Clear History**: Removes all command history
- **Quit**: Exit the application

## Configuration

### Agent Paths

The app auto-detects agents at these default locations:

- **Claude**: `/Users/<you>/.nvm/versions/node/*/bin/claude`
- **Copilot**: `/Users/<you>/.nvm/versions/node/*/bin/copilot`
- **Codex**: `/opt/homebrew/bin/codex`

If your installations are in different locations, update the paths in `ContentView.swift`:
- `ClaudeAgent.init()` around line 650
- `CopilotAgent.init()` around line 750
- `CodexAgent.init()` around line 850

### Customizing Triggers

To change the trigger patterns, modify the `commandTriggers` array in `CommandInterceptor` (around line 1050):

```swift
private let commandTriggers = ["/askclaude ", "/askcopilot ", "/askcodex "]
```

## Troubleshooting

### "Operation not permitted" errors
- Ensure Accessibility permissions are granted in System Settings

### Agent shows red ✗ in menu
- Run diagnostics to see the specific error
- Verify the agent is installed: `which claude` / `which copilot` / `which codex`
- Check the agent path in the code matches your installation

### Commands not being detected
- Make sure to press Return after typing the trigger + prompt
- Verify the trigger pattern matches exactly (including the space after the command)

### "command not found" errors
- For Claude/Copilot: Ensure node is in your PATH
- For Codex: Ensure Homebrew's bin directory is accessible

## Architecture

- **AIAgent Protocol**: Common interface for all AI agents
- **AgentRegistry**: Manages agent discovery and status
- **CommandInterceptor**: Global keyboard event monitoring
- **AppState**: Centralized observable state management
- **MenuBarView**: SwiftUI-based menu bar interface

## Security & Privacy

- App sandboxing is **disabled** to access external CLI executables
- Requires Accessibility API permissions to read/write text fields
- No data is collected or transmitted except to the AI services you've configured
- All processing happens locally on your machine

## License

MIT

## Contributing

Contributions welcome! Please open an issue or submit a PR.

## Credits

Built with Claude Code CLI integration.
