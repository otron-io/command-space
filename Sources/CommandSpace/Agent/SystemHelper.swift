//
//  SystemHelper.swift
//  Command Space
//
//  Shortcuts, opencode service control, Accessibility and brightness. In Notch Agent this
//  ran in an XPC helper outside the sandbox; Command Space is not sandboxed, so it runs
//  in-process. SystemBridge (below) is the async front door the rest of the app uses.
//

import AppKit
import Foundation
import ApplicationServices
import IOKit
import CoreGraphics

final class SystemHelper: NSObject, @unchecked Sendable {
    static let shared = SystemHelper()

    // MARK: - Shortcuts

    func listShortcuts(with reply: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = Self.run("/usr/bin/shortcuts", ["list"], wait: 10) ?? ""
            let names = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            reply(names)
        }
    }

    func runShortcut(_ name: String, with reply: @escaping (Bool) -> Void) {
        // Start it and reply right away; shortcuts can run for a long time.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        do {
            try process.run()
            reply(true)
        } catch {
            reply(false)
        }
    }

    // MARK: - Replacing Notch Agent

    /// Quits every running copy of the app and moves its bundles in /Applications to the Trash.
    func retireApp(bundleIdentifier: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            running.forEach { $0.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
                var removed = false
                let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
                for url in urls where url.path.hasPrefix("/Applications/") || url.path.contains("/Applications/") {
                    if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { removed = true }
                }
                reply(removed || !running.isEmpty)
            }
        }
    }

    /// Reads another (sandboxed) app's preferences plist so its settings can be carried over.
    func exportPreferences(bundleIdentifier: String, with reply: @escaping (Data?) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Containers/\(bundleIdentifier)/Data/Library/Preferences/\(bundleIdentifier).plist",
            "\(home)/Library/Preferences/\(bundleIdentifier).plist",
        ]
        reply(candidates.lazy.compactMap { FileManager.default.contents(atPath: $0) }.first)
    }

    // MARK: - opencode server

    static let serviceLabel = "io.otron.commandspace.opencode"
    /// Notch Agent's service; still used until `agent/setup.sh` is run for Command Space.
    static let legacyServiceLabel = "io.otron.notch.opencode"

    private static func launchAgentPath(_ label: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    /// The installed service: Command Space's, or Notch Agent's if only that one exists.
    static var opencodeLabel: String {
        !FileManager.default.fileExists(atPath: launchAgentPath(serviceLabel))
            && FileManager.default.fileExists(atPath: launchAgentPath(legacyServiceLabel)) ? legacyServiceLabel : serviceLabel
    }

    /// The opencode agent the workspace defines ("notch" in a Notch Agent workspace).
    static var opencodeAgentName: String { opencodeLabel == legacyServiceLabel ? "notch" : "space" }

    /// The LaunchAgent that the agent setup installs, read for the binary and log paths.
    private static var opencodeAgent: [String: Any] {
        let path = URL(fileURLWithPath: launchAgentPath(opencodeLabel))
        guard let data = FileManager.default.contents(atPath: path.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    private static var opencodeBinary: String {
        (opencodeAgent["ProgramArguments"] as? [String])?.first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path
    }

    /// Version of the installed opencode binary (the running server may still be older).
    func opencodeServerInfo(with reply: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            let out = Self.runCombined(Self.opencodeBinary, ["--version"], wait: 15)
            reply(out.map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    func restartOpencodeServer(with reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global().async { let (ok, message) = Self.restartOpencode(); reply(ok, message) }
    }

    private static func restartOpencode() -> (Bool, String) {
        let target = "gui/\(getuid())/\(opencodeLabel)"
        if let r = runCombined("/bin/launchctl", ["kickstart", "-k", target], wait: 30), r.status == 0 {
            return (true, "Restarted")
        }
        // not loaded (e.g. after a logout): load it from its plist
        let plist = launchAgentPath(opencodeLabel)
        guard FileManager.default.fileExists(atPath: plist) else { return (false, "The agent service isn't installed. Run the setup command.") }
        let r = runCombined("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist], wait: 30)
        return r?.status == 0 ? (true, "Started") : (false, r?.output.lastLines(3) ?? "launchctl failed")
    }

    /// `opencode upgrade`, then a restart so the server runs the new version.
    func upgradeOpencode(with reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global().async {
            let before = Self.runCombined(Self.opencodeBinary, ["--version"], wait: 15)?.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let r = Self.runCombined(Self.opencodeBinary, ["upgrade"], wait: 600) else {
                reply(false, "The update didn't finish within 10 minutes.")
                return
            }
            guard r.status == 0 else {
                reply(false, r.output.lastLines(4).isEmpty ? "opencode upgrade failed" : r.output.lastLines(4))
                return
            }
            let after = Self.runCombined(Self.opencodeBinary, ["--version"], wait: 15)?.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let before, let after, before == after {
                reply(true, "Already up to date (\(after))")
                return
            }
            let (restarted, message) = Self.restartOpencode()
            reply(restarted, restarted ? "Updated \(before ?? "?") → \(after ?? "?") and restarted" : "Updated to \(after ?? "?"), but restart failed: \(message)")
        }
    }

    func revealOpencodeLog() {
        let log = (Self.opencodeAgent["StandardOutPath"] as? String)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CommandSpace/logs/opencode.log").path
        _ = Self.runCombined("/usr/bin/open", ["-R", log], wait: 10)
    }

    /// Runs a tool and returns its exit status with stdout and stderr together; nil on timeout.
    private static func runCombined(_ path: String, _ arguments: [String], wait seconds: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (opencodeAgent["EnvironmentVariables"] as? [String: String])?["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var data = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); data.append(chunk); lock.unlock()
        }
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); pipe.fileHandleForReading.readabilityHandler = nil; return nil }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); data.append(pipe.fileHandleForReading.readDataToEndOfFile()); lock.unlock()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func run(_ path: String, _ arguments: [String], wait seconds: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
    
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

private extension String {
    func lastLines(_ n: Int) -> String {
        split(whereSeparator: \.isNewline).suffix(n).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Async front door

/// Async API over SystemHelper (same shape as Notch Agent's SystemBridge).
final class SystemBridge: Sendable {
    static let shared = SystemBridge()
    private var helper: SystemHelper { .shared }

    private func call<T: Sendable>(_ body: @escaping (SystemHelper, @escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { continuation in
            body(helper) { continuation.resume(returning: $0) }
        }
    }

    func isAccessibilityAuthorized() async -> Bool { AXIsProcessTrusted() }
    func requestAccessibilityAuthorization() { helper.requestAccessibilityAuthorization() }
    func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        await call { $0.ensureAccessibilityAuthorization(promptIfNeeded, with: $1) }
    }

    func isKeyboardBrightnessAvailable() async -> Bool { await call { $0.isKeyboardBrightnessAvailable(with: $1) } }
    func currentKeyboardBrightness() async -> Float? { await call { h, r in h.currentKeyboardBrightness { r($0?.floatValue) } } }
    func setKeyboardBrightness(_ value: Float) async -> Bool { await call { $0.setKeyboardBrightness(value, with: $1) } }
    func isScreenBrightnessAvailable() async -> Bool { await call { $0.isScreenBrightnessAvailable(with: $1) } }
    func currentScreenBrightness() async -> Float? { await call { h, r in h.currentScreenBrightness { r($0?.floatValue) } } }
    func setScreenBrightness(_ value: Float) async -> Bool { await call { $0.setScreenBrightness(value, with: $1) } }

    func listShortcuts() async -> [String] { await call { $0.listShortcuts(with: $1) } }
    func runShortcut(_ name: String) async -> Bool { await call { $0.runShortcut(name, with: $1) } }
    func retireApp(bundleIdentifier: String) async -> Bool { await call { $0.retireApp(bundleIdentifier: bundleIdentifier, with: $1) } }
    func exportPreferences(bundleIdentifier: String) async -> Data? { await call { $0.exportPreferences(bundleIdentifier: bundleIdentifier, with: $1) } }

    func opencodeInstalledVersion() async -> String? { await call { $0.opencodeServerInfo(with: $1) } }
    func restartOpencodeServer() async -> (ok: Bool, message: String) {
        await call { h, r in h.restartOpencodeServer { ok, message in r((ok, message)) } }
    }
    func upgradeOpencode() async -> (ok: Bool, message: String) {
        await call { h, r in h.upgradeOpencode { ok, message in r((ok, message)) } }
    }
    func revealOpencodeLog() async { helper.revealOpencodeLog() }

    func menuItems(processIdentifier: pid_t) async -> [String] { await call { $0.menuItems(processIdentifier: processIdentifier, with: $1) } }
    func pressMenuItem(processIdentifier: pid_t, path: String) async -> Bool {
        await call { $0.pressMenuItem(processIdentifier: processIdentifier, path: path, with: $1) }
    }
    func captureContext(processIdentifier: pid_t, allowCopyFallback: Bool) async -> Data? {
        await call { $0.captureContext(processIdentifier: processIdentifier, allowCopyFallback: allowCopyFallback, with: $1) }
    }
}

// MARK: - Shell

/// Runs shell commands directly (learned actions, instant actions). Notch Agent had to route
/// these through an opencode session because it was sandboxed; that also cluttered history.
enum Shell {
    /// Output of `command` in a login zsh (so PATH matches Terminal), or nil if it failed.
    static func run(_ command: String, timeout: TimeInterval = 30) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                var data = Data()
                let lock = NSLock()
                out.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    lock.lock(); data.append(chunk); lock.unlock()
                }
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { process.terminate() }
                out.fileHandleForReading.readabilityHandler = nil
                lock.lock(); data.append(out.fileHandleForReading.readDataToEndOfFile()); lock.unlock()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else { return continuation.resume(returning: nil) }
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
