// MacCommandPalette - Universal Claude Code command interface
// Complete Xcode project - just paste into new macOS App

import SwiftUI
import AppKit
import ApplicationServices
import Carbon
import Combine

// MARK: - Main App
@main
struct MacCommandPaletteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("⚡", systemImage: "bolt.fill") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var commandInterceptor: CommandInterceptor?
    var agentRegistry: AgentRegistry?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - we only need menubar
        NSApp.setActivationPolicy(.accessory)

        // Request accessibility permissions
        requestAccessibilityPermissions()

        // Check if we actually have accessibility permissions
        let trusted = AXIsProcessTrusted()
        print("DEBUG: Accessibility trusted status: \(trusted)")

        // Create agent registry and command interceptor via AppState
        let registry = AgentRegistry()
        print("DEBUG: Created AgentRegistry with \(registry.agents.count) agents")

        let interceptor = CommandInterceptor()
        interceptor.agentRegistry = registry
        print("DEBUG: Set agentRegistry on CommandInterceptor")
        interceptor.start()

        // Store in both local variables and AppState
        agentRegistry = registry
        commandInterceptor = interceptor
        AppState.shared.agentRegistry = registry
        AppState.shared.commandInterceptor = interceptor
        AppState.shared.setupObservers()

        print("MacCommandPalette started. Type askclaude, askcopilot, or askcodex anywhere!")
    }

    func requestAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "MacCommandPalette needs Accessibility access to work. Please enable it in System Settings > Privacy & Security > Accessibility"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")

                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
    }
}

// MARK: - Command Interceptor
class CommandInterceptor: ObservableObject {
    @Published var commandHistory: [CommandExecution] = []
    var agentRegistry: AgentRegistry?
    private var typingBuffer = ""
    private let commandTriggers = ["askclaude ", "askcopilot ", "askcodex "]
    private var eventTap: CFMachPort?
    private let lock = NSLock()
    private var commandActive = false
    private var activeTrigger: String?
    private var pendingTimer: DispatchWorkItem?
    private var isTypingProgrammatically = false // Flag to prevent capturing our own keystrokes

    func start() {
        // Create event tap for global keyboard monitoring
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                let interceptor = Unmanaged<CommandInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
                return interceptor.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap")
            return
        }

        self.eventTap = eventTap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("Event tap created successfully")
    }

    nonisolated func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            // Skip ALL keyboard events if we're typing programmatically
            lock.lock()
            let skipCapture = isTypingProgrammatically
            lock.unlock()

            if skipCapture {
                print("DEBUG: Skipping event capture - isTypingProgrammatically = true")
                return Unmanaged.passRetained(event)
            }

            if let nsEvent = NSEvent(cgEvent: event) {
                let keyCode = nsEvent.keyCode

                // Check for Return/Enter key (keyCode 36 or 76)
                if (keyCode == 36 || keyCode == 76) && commandActive {
                    print("DEBUG: Enter pressed, executing command")

                    // Capture buffer snapshot immediately before execution
                    lock.lock()
                    let bufferSnapshot = typingBuffer
                    let triggerSnapshot = activeTrigger
                    commandActive = false
                    typingBuffer = "" // Clear buffer for next command
                    activeTrigger = nil
                    lock.unlock()

                    DispatchQueue.main.async {
                        self.extractAndExecuteCommand(bufferSnapshot: bufferSnapshot, triggerSnapshot: triggerSnapshot)
                    }
                    return Unmanaged.passRetained(event)
                }

                if let characters = nsEvent.charactersIgnoringModifiers {
                    lock.lock()

                    typingBuffer += characters

                    // Keep buffer manageable (increased to 1000 for longer commands)
                    if typingBuffer.count > 1000 {
                        typingBuffer = String(typingBuffer.suffix(1000))
                    }

                    // Check for any command trigger
                    let detectedTrigger = commandTriggers.first { typingBuffer.hasSuffix($0) }

                    if let trigger = detectedTrigger, !commandActive {
                        commandActive = true
                        activeTrigger = trigger
                        lock.unlock()
                        print("Command trigger detected (\(trigger))! Type your command and press Enter")
                    } else {
                        lock.unlock()
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }

    func extractAndExecuteCommand(bufferSnapshot: String? = nil, triggerSnapshot: String? = nil) {
        print("DEBUG: Starting extractAndExecuteCommand")

        // Use snapshots if provided, otherwise read from current buffer
        let bufferCopy: String
        let detectedTrigger: String?

        if let snapshot = bufferSnapshot, let trigger = triggerSnapshot {
            bufferCopy = snapshot
            detectedTrigger = trigger
            print("DEBUG: Using buffer snapshot: \(bufferCopy)")
        } else {
            lock.lock()
            bufferCopy = typingBuffer
            detectedTrigger = activeTrigger
            lock.unlock()
        }

        // Get the frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            print("ERROR: Could not get frontmost application")
            return
        }

        print("DEBUG: Frontmost app: \(frontApp.localizedName ?? "unknown")")

        // Get the focused element via the application
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        print("DEBUG: Accessibility result code: \(result.rawValue)")

        if result != .success {
            print("Could not get focused element - Error code: \(result.rawValue)")
            if result.rawValue == -25200 {
                print("ERROR: Not trusted for accessibility! Go to System Settings > Privacy & Security > Accessibility")
            } else if result.rawValue == -25204 {
                print("ERROR: Attribute not found - trying alternate method")
                // Try to get focused window instead
                var focusedWindow: AnyObject?
                let windowResult = AXUIElementCopyAttributeValue(
                    appElement,
                    kAXFocusedWindowAttribute as CFString,
                    &focusedWindow
                )
                print("DEBUG: Window result code: \(windowResult.rawValue)")

                if windowResult == .success, let window = focusedWindow {
                    print("DEBUG: Got focused window, trying to find text field")
                    // Try to get first text field from window
                    var children: AnyObject?
                    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXChildrenAttribute as CFString, &children)
                    if let childArray = children as? [AXUIElement], !childArray.isEmpty {
                        print("DEBUG: Found \(childArray.count) children in window")
                        focusedElement = childArray.first(where: { child in
                            var role: AnyObject?
                            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                            return (role as? String) == kAXTextAreaRole
                        })
                    }
                }
            }

            if focusedElement == nil {
                print("ERROR: Could not get any text element - using keyboard simulation fallback")
                // Fallback: use keyboard simulation
                useKeyboardSimulation(bufferSnapshot: bufferCopy, triggerSnapshot: detectedTrigger)
                return
            }
        }

        guard let element = focusedElement else {
            print("ERROR: Element is nil")
            return
        }

        print("DEBUG: Got focused element successfully")

        // Try to get text from element
        var value: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXValueAttribute as CFString,
            &value
        )

        print("DEBUG: Get value result code: \(valueResult.rawValue)")

        // Try different attributes if AXValue doesn't work
        if valueResult != .success {
            print("DEBUG: AXValue failed, trying AXSelectedText...")
            let selectedTextResult = AXUIElementCopyAttributeValue(
                element as! AXUIElement,
                kAXSelectedTextAttribute as CFString,
                &value
            )
            print("DEBUG: AXSelectedText result code: \(selectedTextResult.rawValue)")
        }

        guard let text = value as? String else {
            print("Could not get text value - using keyboard simulation fallback for Office apps")
            // Use keyboard simulation for Office apps where Accessibility API doesn't work
            useKeyboardSimulation(bufferSnapshot: bufferCopy, triggerSnapshot: detectedTrigger)
            return
        }

        print("DEBUG: Got text value: \(text.prefix(50))...")

        // Extract command based on detected trigger
        for triggerWithSpace in commandTriggers {
            if let range = text.range(of: triggerWithSpace) {
                let command = String(text[range.upperBound...])

                // Remove trailing space from trigger for agent lookup
                let trigger = triggerWithSpace.trimmingCharacters(in: .whitespaces)

                // Delete the trigger text (with space)
                deleteCommandText(from: element as! AXUIElement, fullText: text, trigger: triggerWithSpace)

                // Execute command with full document context (use trigger without space)
                executeCommand(command, trigger: trigger, fullText: text, in: element as! AXUIElement)
                return
            }
        }
    }

    func showQuickResult(in element: AXUIElement) {
        // Fallback: just try to insert a test message using keyboard simulation
        print("DEBUG: Attempting to insert text via keyboard simulation")
        insertText("⚡ Claude detected! (Debug mode - can't read text field)", into: element)
    }

    func deleteCommandText(from element: AXUIElement, fullText: String, trigger: String) {
        // Find position of trigger
        if let range = fullText.range(of: trigger) {
            let beforeCommand = String(fullText[..<range.lowerBound])

            // Set text to everything before trigger
            AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                beforeCommand as CFString
            )
        }
    }

    func executeCommand(_ command: String, trigger: String, fullText: String, in element: AXUIElement) {
        print("Executing command: \(command) with trigger: \(trigger)")

        // Check if dangerous
        if isDangerousCommand(command) {
            showConfirmationDialog(command: command) { confirmed in
                if confirmed {
                    self.runAgentCommand(command: command, trigger: trigger, documentContext: fullText, in: element)
                } else {
                    self.insertText("Command cancelled", into: element)
                }
            }
        } else {
            runAgentCommand(command: command, trigger: trigger, documentContext: fullText, in: element)
        }
    }

    func isDangerousCommand(_ command: String) -> Bool {
        let dangerous = ["delete", "rm -rf", "drop", "force", "production", "prod"]
        return dangerous.contains { command.lowercased().contains($0) }
    }

    func showConfirmationDialog(command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "⚠️ Confirm Dangerous Command"
            alert.informativeText = "About to execute:\n\n\(command)\n\nThis might be destructive. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Execute")
            alert.addButton(withTitle: "Cancel")

            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func runAgentCommand(command: String, trigger: String, documentContext: String, in element: AXUIElement) {
        print("DEBUG: runAgentCommand called with trigger: \(trigger)")
        print("DEBUG: agentRegistry is nil: \(agentRegistry == nil)")

        guard let registry = agentRegistry else {
            print("ERROR: agentRegistry is nil!")
            insertText("Error: Agent registry not initialized", into: element)
            return
        }

        print("DEBUG: Registry has \(registry.agents.count) agents")
        for agent in registry.agents {
            print("DEBUG: Agent: \(agent.name) with trigger: \(agent.trigger)")
        }

        guard let agent = registry.getAgent(for: trigger) else {
            print("ERROR: No agent found for trigger: \(trigger)")
            insertText("Error: Agent not found for \(trigger)", into: element)
            return
        }

        print("DEBUG: Found agent: \(agent.name)")

        // Get context
        let appContext = getContext()

        // Extract document content (everything before trigger)
        let docContent: String
        if let range = documentContext.range(of: trigger) {
            docContent = String(documentContext[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            docContent = ""
        }

        // Show loading indicator
        print("DEBUG: About to insert 'Executing...'")
        insertText("Executing...", into: element)
        print("DEBUG: Finished inserting 'Executing...'")

        Task {
            print("DEBUG: Task started, calling agent.execute")
            let result = await agent.execute(command: command, context: appContext, documentContent: docContent)
            print("DEBUG: agent.execute completed with result: \(result.prefix(50))...")

            // Replace loading with result
            await MainActor.run {
                var currentValue: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)

                if let current = currentValue as? String {
                    let updated = current.replacingOccurrences(of: "Executing...", with: result)
                    AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFString)
                }

                // Log to history
                let execution = CommandExecution(
                    command: command,
                    result: result,
                    timestamp: Date(),
                    agentUsed: agent.name
                )
                self.commandHistory.append(execution)
                print("DEBUG: Added to history. Total commands: \(self.commandHistory.count)")

                // Trigger update on AppState and UI
                self.objectWillChange.send()
                NotificationCenter.default.post(name: NSNotification.Name("RefreshUI"), object: nil)
            }
        }
    }

    func useKeyboardSimulation(bufferSnapshot: String?, triggerSnapshot: String?) {
        print("DEBUG: Using keyboard simulation for Office apps")

        guard let bufferCopy = bufferSnapshot else {
            print("ERROR: No buffer snapshot provided")
            return
        }

        guard let detectedTrigger = triggerSnapshot else {
            print("ERROR: No trigger detected")
            return
        }

        // Find the command after trigger
        guard let range = bufferCopy.range(of: detectedTrigger) else {
            print("ERROR: Could not find \(detectedTrigger) in buffer")
            return
        }

        let command = String(bufferCopy[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("DEBUG: Extracted command: '\(command)' with trigger: \(detectedTrigger)")

        if command.isEmpty {
            print("ERROR: Command is empty")
            return
        }

        // Strip trailing space from trigger for agent lookup
        let triggerWithoutSpace = detectedTrigger.trimmingCharacters(in: .whitespaces)

        guard let agent = agentRegistry?.getAgent(for: triggerWithoutSpace) else {
            typeString("Error: Agent not found for \(triggerWithoutSpace)")
            return
        }

        // Skip document context capture to avoid file permission prompts
        // Document context will be empty, which is fine for most use cases
        let documentContext = ""
        print("DEBUG: Skipping document context capture to avoid permission prompts")

        // Execute Agent command (no loading indicator - just wait for result)
        Task { [documentContext] in
            let context = self.getContext()

            // Use the captured document context from clipboard
            let result = await agent.execute(command: command, context: context, documentContent: documentContext)

            print("DEBUG: Got result from \(agent.name): \(result.prefix(50))...")

            // Type the result directly
            await MainActor.run {
                // Set flag again before typing result
                self.lock.lock()
                self.isTypingProgrammatically = true
                self.lock.unlock()

                self.typeString(result)

                // Wait for typing to complete
                usleep(100000) // 100ms safety margin

                // Check if we're in a chat app - if so, press Enter to send
                if let app = NSWorkspace.shared.frontmostApplication {
                    let chatApps = [
                        "com.tinyspeck.slackmacgap",  // Slack
                        "com.hnc.Discord",             // Discord
                        "com.microsoft.teams2",        // Teams
                        "org.whispersystems.signal-desktop", // Signal
                        "com.apple.MobileSMS"          // Messages
                    ]

                    if let bundleId = app.bundleIdentifier, chatApps.contains(bundleId) {
                        print("DEBUG: Chat app detected, pressing Enter to send message")
                        usleep(50000) // Small delay before Enter

                        let enterDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true) // Enter key
                        enterDown?.post(tap: .cghidEventTap)
                        usleep(10000)
                        let enterUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false)
                        enterUp?.post(tap: .cghidEventTap)

                        usleep(50000) // Wait for message to send
                    }
                }

                // Clear flag after typing result
                self.lock.lock()
                self.isTypingProgrammatically = false
                self.typingBuffer = "" // Clear buffer for next command
                self.lock.unlock()

                print("DEBUG: Cleared isTypingProgrammatically flag and buffer after typing result")

                // Log to history
                let execution = CommandExecution(
                    command: command,
                    result: result,
                    timestamp: Date(),
                    agentUsed: agent.name
                )
                self.commandHistory.append(execution)
                print("DEBUG: Added to history. Total commands: \(self.commandHistory.count)")

                // Trigger update on AppState and UI
                self.objectWillChange.send()
                NotificationCenter.default.post(name: NSNotification.Name("RefreshUI"), object: nil)
            }
        }
    }

    func typeString(_ string: String) {
        // Note: isTypingProgrammatically flag is managed by the caller
        for char in string {
            let charString = String(char)
            if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                let utf16 = Array(charString.utf16)
                cgEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                cgEvent.post(tap: .cghidEventTap)
            }
            usleep(50000) // Increased to 50ms between characters for better reliability in chat apps
        }
    }

    func getContext() -> String {
        var context = ""

        // Get active app - this doesn't require file access permissions
        if let app = NSWorkspace.shared.frontmostApplication {
            context += "Active app: \(app.localizedName ?? "Unknown")\n"

            // Add simple app context without file system access
            switch app.bundleIdentifier {
            case "com.tinyspeck.slackmacgap":
                context += "Context: Slack conversation\n"
            case "com.microsoft.VSCode":
                context += "Context: VS Code editor\n"
            case "com.apple.Terminal":
                context += "Context: Terminal\n"
            default:
                break
            }
        }

        return context
    }

    func getVSCodeContext() -> String {
        // Try to get VS Code workspace via AppleScript
        let script = """
        tell application "System Events"
            tell process "Code"
                get value of attribute "AXTitle" of window 1
            end tell
        end tell
        """

        if let result = runAppleScript(script) {
            return "VS Code: \(result)\n"
        }

        return ""
    }

    func getTerminalContext() -> String {
        // Get current directory from terminal
        let script = """
        tell application "Terminal"
            do script "pwd" in front window
        end tell
        """

        if let result = runAppleScript(script) {
            return "Terminal CWD: \(result)\n"
        }

        return ""
    }

    func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: source) {
            let output = scriptObject.executeAndReturnError(&error)
            return output.stringValue
        }
        return nil
    }

    func insertText(_ text: String, into element: AXUIElement) {
        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)

        let current = currentValue as? String ?? ""
        let updated = current + text

        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFString)
    }
}

// MARK: - AI Agent Protocol
enum AgentStatus {
    case available
    case notInstalled
    case error(String)
}

struct DiagnosticResult {
    let isAvailable: Bool
    let executablePath: String?
    let version: String?
    let errorMessage: String?
}

protocol AIAgent {
    var name: String { get }
    var trigger: String { get }
    var status: AgentStatus { get }
    var executablePath: String? { get }

    func execute(command: String, context: String, documentContent: String) async -> String
    func diagnose() async -> DiagnosticResult
}

// MARK: - Data Models
struct CommandExecution: Identifiable {
    let id = UUID()
    let command: String
    let result: String
    let timestamp: Date
    let agentUsed: String
}

struct AgentConfig: Codable {
    var enabled: Bool = true
    var customPath: String?
    var additionalArgs: [String] = []
}

// MARK: - Claude Agent
class ClaudeAgent: AIAgent {
    var name: String { "Claude Code" }
    var trigger: String { "askclaude" }
    var status: AgentStatus {
        executablePath != nil ? .available : .notInstalled
    }
    var executablePath: String?

    init() {
        self.executablePath = detectClaudePath()
    }

    private func detectClaudePath() -> String? {
        // Try custom path from config first
        if let customPath = loadConfig().customPath, FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }

        // Auto-detect common locations
        let commonPaths = [
            "/Users/allannapier/.nvm/versions/node/v22.19.0/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try using which command via zsh
        let whichResult = runShellCommand("/bin/zsh", args: ["-l", "-c", "which claude"])
        if let path = whichResult.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           path.hasPrefix("/") {
            return path
        }

        return nil
    }

    func execute(command: String, context: String, documentContent: String) async -> String {
        guard let claudePath = executablePath else {
            return "Error: Claude Code not found. Please install it or configure the path in settings."
        }

        // Build full prompt
        var promptParts: [String] = []

        if !context.isEmpty {
            promptParts.append("# System Context:\n\(context)")
        }

        if !documentContent.isEmpty {
            promptParts.append("# Document Content:\n\(documentContent)")
        }

        promptParts.append("# User Request:\n\(command)")
        promptParts.append("# Instructions:\nNEVER use emojis in your response. Provide clear, professional text only.")

        let fullPrompt = promptParts.joined(separator: "\n\n")
        let escapedPrompt = fullPrompt.replacingOccurrences(of: "'", with: "'\\''")

        // Set up environment
        let nodePath = (claudePath as NSString).deletingLastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(nodePath):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let result = runShellCommand("/bin/zsh", args: ["-c", "\(claudePath) -p '\(escapedPrompt)'"], environment: environment)

        if result.exitCode != 0 {
            return "Error: \(result.error ?? "Unknown error")"
        }

        return result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Command completed (no output)"
    }

    func diagnose() async -> DiagnosticResult {
        guard let path = executablePath else {
            return DiagnosticResult(
                isAvailable: false,
                executablePath: nil,
                version: nil,
                errorMessage: "Claude Code executable not found"
            )
        }

        // Set up environment with node path for diagnostics
        let nodePath = (path as NSString).deletingLastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(nodePath):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let result = runShellCommand(path, args: ["--version"], environment: environment)

        return DiagnosticResult(
            isAvailable: result.exitCode == 0,
            executablePath: path,
            version: result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
            errorMessage: result.exitCode != 0 ? result.error : nil
        )
    }

    private func loadConfig() -> AgentConfig {
        guard let data = UserDefaults.standard.data(forKey: "ClaudeAgentConfig"),
              let config = try? JSONDecoder().decode(AgentConfig.self, from: data) else {
            return AgentConfig()
        }
        return config
    }

    private func runShellCommand(_ executable: String, args: [String], environment: [String: String]? = nil) -> (output: String?, error: String?, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        if let env = environment {
            process.environment = env
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8)
            let error = String(data: errorData, encoding: .utf8)

            return (output, error, process.terminationStatus)
        } catch {
            return (nil, error.localizedDescription, -1)
        }
    }
}

// MARK: - Copilot Agent
class CopilotAgent: AIAgent {
    var name: String { "GitHub Copilot" }
    var trigger: String { "askcopilot" }
    var status: AgentStatus {
        executablePath != nil ? .available : .notInstalled
    }
    var executablePath: String?

    init() {
        self.executablePath = detectCopilotPath()
    }

    private func detectCopilotPath() -> String? {
        if let customPath = loadConfig().customPath, FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }

        // Check common paths first
        let commonPaths = [
            "/Users/allannapier/.nvm/versions/node/v22.19.0/bin/copilot",
            "/usr/local/bin/copilot",
            "/opt/homebrew/bin/copilot"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try standalone copilot via which
        let whichResult = runShellCommand("/bin/zsh", args: ["-l", "-c", "which copilot"])
        if let path = whichResult.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           path.hasPrefix("/") {
            return path
        }

        return nil
    }

    func execute(command: String, context: String, documentContent: String) async -> String {
        guard let copilotPath = executablePath else {
            return "Error: GitHub Copilot CLI not found. Please install it."
        }

        var promptParts: [String] = []
        if !context.isEmpty { promptParts.append(context) }
        if !documentContent.isEmpty { promptParts.append("Document:\n\(documentContent)") }
        promptParts.append(command)
        promptParts.append("(No emojis in response)")

        let fullPrompt = promptParts.joined(separator: "\n\n")
        let escapedPrompt = fullPrompt.replacingOccurrences(of: "'", with: "'\\''")

        // Set up environment with node path
        let nodePath = (copilotPath as NSString).deletingLastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(nodePath):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let result = runShellCommand(
            "/bin/zsh",
            args: ["-c", "\(copilotPath) -p '\(escapedPrompt)' --allow-all-tools"],
            environment: environment
        )

        if result.exitCode != 0 {
            return "Error: \(result.error ?? "Unknown error")"
        }

        return result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Command completed (no output)"
    }

    func diagnose() async -> DiagnosticResult {
        guard let path = executablePath else {
            return DiagnosticResult(
                isAvailable: false,
                executablePath: nil,
                version: nil,
                errorMessage: "GitHub Copilot not found"
            )
        }

        // Set up environment with node path
        let nodePath = (path as NSString).deletingLastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(nodePath):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let result = runShellCommand(path, args: ["--version"], environment: environment)

        return DiagnosticResult(
            isAvailable: result.exitCode == 0,
            executablePath: path,
            version: result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
            errorMessage: result.exitCode != 0 ? result.error : nil
        )
    }

    private func loadConfig() -> AgentConfig {
        guard let data = UserDefaults.standard.data(forKey: "CopilotAgentConfig"),
              let config = try? JSONDecoder().decode(AgentConfig.self, from: data) else {
            return AgentConfig()
        }
        return config
    }

    private func runShellCommand(_ executable: String, args: [String], environment: [String: String]? = nil, timeout: TimeInterval = 60) -> (output: String?, error: String?, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        if let env = environment {
            process.environment = env
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var didTimeout = false

        do {
            try process.run()

            // Set up timeout
            let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                if process.isRunning {
                    process.terminate()
                    didTimeout = true
                }
            }

            process.waitUntilExit()
            timer.invalidate()

            if didTimeout {
                return (nil, "Command timed out after \(Int(timeout)) seconds", -1)
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            return (String(data: outputData, encoding: .utf8), String(data: errorData, encoding: .utf8), process.terminationStatus)
        } catch {
            return (nil, error.localizedDescription, -1)
        }
    }
}

// MARK: - Codex Agent
class CodexAgent: AIAgent {
    var name: String { "OpenAI Codex" }
    var trigger: String { "askcodex" }
    var status: AgentStatus {
        executablePath != nil ? .available : .notInstalled
    }
    var executablePath: String?

    init() {
        self.executablePath = detectCodexPath()
    }

    private func detectCodexPath() -> String? {
        if let customPath = loadConfig().customPath, FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }

        let commonPaths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try npm global
        let whichResult = runShellCommand("/bin/zsh", args: ["-l", "-c", "which codex"])
        if let path = whichResult.output?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return path
        }

        return nil
    }

    func execute(command: String, context: String, documentContent: String) async -> String {
        guard let codexPath = executablePath else {
            return "Error: OpenAI Codex not found. Install with: brew install codex"
        }

        var promptParts: [String] = []
        if !context.isEmpty { promptParts.append(context) }
        if !documentContent.isEmpty { promptParts.append("Document:\n\(documentContent)") }
        promptParts.append(command)
        promptParts.append("(No emojis)")

        let fullPrompt = promptParts.joined(separator: "\n\n")
        let escapedPrompt = fullPrompt.replacingOccurrences(of: "'", with: "'\\''")

        // Use 'exec' subcommand for non-interactive mode with --skip-git-repo-check
        let result = runShellCommand("/bin/zsh", args: ["-c", "\(codexPath) exec --skip-git-repo-check '\(escapedPrompt)'"])

        if result.exitCode != 0 {
            return "Error: \(result.error ?? "Unknown error")"
        }

        // Parse Codex output - extract only the actual response after "] codex\n\n"
        if let output = result.output {
            // Look for the last occurrence of "] codex\n" which marks the start of the actual response
            if let codexMarkerRange = output.range(of: "] codex\n", options: .backwards) {
                var response = String(output[codexMarkerRange.upperBound...])

                // Remove the trailing tokens line if present
                if let tokensRange = response.range(of: "\n[", options: .backwards) {
                    response = String(response[..<tokensRange.lowerBound])
                }

                return response.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return "Command completed (no output)"
    }

    func diagnose() async -> DiagnosticResult {
        guard let path = executablePath else {
            return DiagnosticResult(
                isAvailable: false,
                executablePath: nil,
                version: nil,
                errorMessage: "OpenAI Codex not found. Install with: npm install -g @openai/codex"
            )
        }

        let result = runShellCommand(path, args: ["--version"])

        return DiagnosticResult(
            isAvailable: result.exitCode == 0,
            executablePath: path,
            version: result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
            errorMessage: result.exitCode != 0 ? result.error : nil
        )
    }

    private func loadConfig() -> AgentConfig {
        guard let data = UserDefaults.standard.data(forKey: "CodexAgentConfig"),
              let config = try? JSONDecoder().decode(AgentConfig.self, from: data) else {
            return AgentConfig()
        }
        return config
    }

    private func runShellCommand(_ executable: String, args: [String], timeout: TimeInterval = 60) -> (output: String?, error: String?, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var didTimeout = false

        do {
            try process.run()

            // Set up timeout
            let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                if process.isRunning {
                    process.terminate()
                    didTimeout = true
                }
            }

            process.waitUntilExit()
            timer.invalidate()

            if didTimeout {
                return (nil, "Command timed out after \(Int(timeout)) seconds", -1)
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            return (String(data: outputData, encoding: .utf8), String(data: errorData, encoding: .utf8), process.terminationStatus)
        } catch {
            return (nil, error.localizedDescription, -1)
        }
    }
}

// MARK: - Agent Registry
class AgentRegistry: ObservableObject {
    @Published var agents: [AIAgent] = []
    @Published var diagnosticResults: [String: DiagnosticResult] = [:]

    init() {
        // Initialize all agents
        agents = [
            ClaudeAgent(),
            CopilotAgent(),
            CodexAgent()
        ]

        // Run diagnostics on init
        Task {
            await runDiagnostics()
        }
    }

    func getAgent(for trigger: String) -> AIAgent? {
        return agents.first { $0.trigger == trigger }
    }

    func runDiagnostics() async {
        for agent in agents {
            let result = await agent.diagnose()
            await MainActor.run {
                diagnosticResults[agent.name] = result
            }
        }
    }
}

// MARK: - App State
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var agentRegistry: AgentRegistry?
    @Published var commandInterceptor: CommandInterceptor?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func setupObservers() {
        // Observe changes to commandHistory and propagate to AppState
        commandInterceptor?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Observe changes to agentRegistry and propagate to AppState
        agentRegistry?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }
}

// MARK: - MenuBar View
struct MenuBarView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var refreshID = UUID()
    @State private var diagnosticResults: [String: DiagnosticResult] = [:]
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.yellow)
                Text("AI Command Palette")
                    .font(.headline)
            }
            .padding(.horizontal)

            Divider()

            // Agent Status
            Text("Agents")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if let registry = appState.agentRegistry {
                ForEach(registry.agents.indices, id: \.self) { index in
                    let agent = registry.agents[index]
                    AgentStatusRow(
                        agent: agent,
                        diagnostic: registry.diagnosticResults[agent.name]
                    )
                }
            }

            Divider()

            // Command History
            Text("Recent Commands")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if let interceptor = appState.commandInterceptor, !interceptor.commandHistory.isEmpty {
                let _ = print("DEBUG: UI showing \(interceptor.commandHistory.count) commands")

                // Debug text to confirm data exists
                Text("History count: \(interceptor.commandHistory.count)")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(interceptor.commandHistory.prefix(5)) { execution in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(execution.agentUsed)
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                Text(execution.command)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            Text(execution.result)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)

                            Text(execution.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))

                        if execution.id != interceptor.commandHistory.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.1))
            } else {
                Text("No commands yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            Divider()

            // Diagnostic Results
            if showingDiagnostics {
                Text("Diagnostic Results")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(diagnosticResults.sorted(by: { $0.key < $1.key }), id: \.key) { agentName, result in
                        HStack {
                            Image(systemName: result.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result.isAvailable ? .green : .red)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(agentName)
                                    .font(.caption)
                                    .fontWeight(.medium)

                                if let version = result.version {
                                    Text("Version: \(version)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else if let error = result.errorMessage {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                } else {
                                    Text("Not available")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    Button("Dismiss") {
                        showingDiagnostics = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal)
                }

                Divider()
            }

            // Actions
            HStack {
                Button("Run Diagnostics") {
                    print("DEBUG: Run Diagnostics button clicked")
                    Task {
                        print("DEBUG: Running diagnostics...")
                        if let registry = appState.agentRegistry {
                            await registry.runDiagnostics()
                            // Collect results
                            var results: [String: DiagnosticResult] = [:]
                            for agent in registry.agents {
                                let result = await agent.diagnose()
                                results[agent.name] = result
                            }
                            diagnosticResults = results
                            showingDiagnostics = true
                        }
                        print("DEBUG: Diagnostics completed")
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Clear History") {
                    appState.commandInterceptor?.commandHistory.removeAll()
                }
                .buttonStyle(.plain)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
        .frame(width: 350)
        .padding(.vertical, 8)
        .id(refreshID)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RefreshUI"))) { _ in
            print("DEBUG: RefreshUI notification received, refreshing view")
            print("DEBUG: Command history count: \(appState.commandInterceptor?.commandHistory.count ?? 0)")
            refreshID = UUID()
        }
    }
}

// MARK: - Agent Status Row
struct AgentStatusRow: View {
    let agent: AIAgent
    let diagnostic: DiagnosticResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                    .font(.caption)

                Text(agent.name)
                    .font(.caption)
                    .fontWeight(.medium)

                Spacer()

                Text(agent.trigger)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let path = diagnostic?.executablePath {
                Text(path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if let error = diagnostic?.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            if let version = diagnostic?.version {
                Text("Version: \(version)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        if diagnostic?.isAvailable == true {
            return "checkmark.circle.fill"
        } else {
            return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        if diagnostic?.isAvailable == true {
            return .green
        } else {
            return .red
        }
    }
}

// MARK: - Preview
struct MenuBarView_Previews: PreviewProvider {
    static var previews: some View {
        MenuBarView()
    }
}

