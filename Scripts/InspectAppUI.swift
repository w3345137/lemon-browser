import AppKit
import ApplicationServices

/// 精确按 PID 核对候选包，避免同名已安装 App 的 AppleScript 对象解析歧义。
@main
struct InspectAppUI {
    static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &result) == .success ? result : nil
    }

    static func main() {
        guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else { exit(1) }
        if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "--quit" {
            guard let running = NSRunningApplication(processIdentifier: pid) else { exit(1) }
            print("quit-requested=\(running.terminate())")
            return
        }
        if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "--window-ids" {
            let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            for info in infos where info[kCGWindowOwnerPID as String] as? Int32 == pid {
                print("\(info[kCGWindowNumber as String] ?? "") | \(info[kCGWindowName as String] ?? "")")
            }
            return
        }
        let app = AXUIElementCreateApplication(pid)
        let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        if CommandLine.arguments.count > 3, CommandLine.arguments[2] == "--menu" {
            for window in windows {
                if showMenu(window, title: CommandLine.arguments[3]) { return }
            }
            print("menu-target-not-found")
            exit(2)
        }
        if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "--all" {
            var visited = 0
            dump(app, depth: 0, visited: &visited)
            return
        }
        if CommandLine.arguments.count > 4, CommandLine.arguments[2] == "--set-text" {
            for window in windows {
                if setText(window, identifier: CommandLine.arguments[3], text: CommandLine.arguments[4]) { return }
            }
            print("text-field-not-found")
            exit(2)
        }
        if CommandLine.arguments.count > 2 {
            let needle = CommandLine.arguments[2]
            if press(app, needle: needle) { return }
            print("button-not-found=\(needle)")
            exit(2)
        }
        print("pid=\(pid) windows=\(windows.count)")
        for window in windows {
            var visited = 0
            dump(window, depth: 0, visited: &visited)
        }
    }

    static func dump(_ element: AXUIElement, depth: Int, visited: inout Int) {
        guard visited < 180 else { return }
        visited += 1
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
        let label = attribute(element, kAXTitleAttribute as CFString) as? String
            ?? attribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
        let value = attribute(element, kAXValueAttribute as CFString) as? String ?? ""
        if !label.isEmpty || !value.isEmpty { print("\(role) | \(label) | \(value)") }
        guard role != "AXWebArea" else { return }
        for child in attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
            dump(child, depth: depth + 1, visited: &visited)
        }
    }

    static func press(_ element: AXUIElement, needle: String) -> Bool {
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
        let description = attribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
        let help = attribute(element, kAXHelpAttribute as CFString) as? String ?? ""
        let identifier = attribute(element, "AXIdentifier" as CFString) as? String ?? ""
        if ["AXButton", "AXMenuButton", "AXCheckBox", "AXMenuItem"].contains(role), [title, description, help, identifier].contains(needle) {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            print("press=\(needle) result=\(result.rawValue)")
            return result == .success
        }
        guard role != "AXWebArea" else { return false }
        for child in attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
            if press(child, needle: needle) { return true }
        }
        return false
    }

    static func setText(_ element: AXUIElement, identifier: String, text: String) -> Bool {
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
        let id = attribute(element, "AXIdentifier" as CFString) as? String ?? ""
        if role == "AXTextField", id == identifier {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            print("set-text=\(identifier) result=\(result.rawValue)")
            return result == .success
        }
        guard role != "AXWebArea" else { return false }
        for child in attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
            if setText(child, identifier: identifier, text: text) { return true }
        }
        return false
    }

    static func showMenu(_ element: AXUIElement, title: String) -> Bool {
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
        let label = attribute(element, kAXTitleAttribute as CFString) as? String
            ?? attribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
        if role == "AXButton", label == title {
            let result = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            print("show-menu=\(title) result=\(result.rawValue)")
            return result == .success
        }
        guard role != "AXWebArea" else { return false }
        for child in attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
            if showMenu(child, title: title) { return true }
        }
        return false
    }
}
