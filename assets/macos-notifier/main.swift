// Organ.nvim native macOS notification helper.
//
// Invoked by the per-user LaunchAgent that fires at each reminder's
// scheduled time. Reads the next-due entries from the organ state file
// and posts a UNNotificationRequest for each via the modern
// UserNotifications framework.
//
// Bundle layout: this binary lives at
//   ~/Library/Application Support/organ/Organ.app/Contents/MacOS/organ-notify
// alongside an Info.plist with bundle id `sh.organ.notifier`. macOS
// attributes the notification to that bundle id, so the user grants
// permission to "Organ" (not "Script Editor").
//
// Usage:
//   organ-notify <state-json-path>
//
// The state JSON is the organ.notifier state file:
//   { "version": 1, "platform": "macos", "entries": [
//       { "id": "...", "at": 1735689600, "title": "...", "body": "...",
//         "fired": false }, ...
//   ] }
//
// We fire any entry whose `at` is within [now-30, now+5] seconds and
// hasn't been fired. We mark it fired and write the file back. The grace
// window is generous so a slightly-late launchd invocation still
// delivers (and a slightly-early one is allowed).

import Foundation
import UserNotifications

// MARK: - State file I/O

struct Entry: Codable {
    let id: String
    let at: Int64
    let title: String
    let body: String
    var fired: Bool?
}

struct State: Codable {
    var version: Int?
    var platform: String?
    var entries: [Entry]
}

func loadState(_ path: String) -> State? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let decoder = JSONDecoder()
    return try? decoder.decode(State.self, from: data)
}

func saveStateAtomic(_ state: State, _ path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(state) else { return }
    let tmp = path + ".tmp"
    do {
        try data.write(to: URL(fileURLWithPath: tmp), options: [.atomic])
        try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                              withItemAt: URL(fileURLWithPath: tmp))
    } catch {
        // Last-ditch: write directly. Worst case we lose the fired flag for
        // one cycle and re-fire on the next tick.
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Notification posting

// Always calls `requestAuthorization` so the macOS permission prompt
// triggers the first time the helper runs as a proper app session
// (e.g. via `open -gj -a Organ.app`).  Subsequent calls are a no-op
// once the system has cached a decision.  Posts due entries only
// when permission is granted.
func authorizeAndPost(_ entries: [Entry], completion: @escaping (Bool) -> Void) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        if !granted {
            FileHandle.standardError.write(
                "organ-notify: notification permission denied\n".data(using: .utf8)!)
            completion(false)
            return
        }
        if entries.isEmpty {
            completion(true)
            return
        }
        let group = DispatchGroup()
        for e in entries {
            group.enter()
            let content = UNMutableNotificationContent()
            content.title = e.title
            content.body  = e.body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: e.id, content: content, trigger: nil)
            center.add(req) { _ in group.leave() }
        }
        group.notify(queue: .main) { completion(true) }
    }
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(
        "usage: organ-notify <state-json-path>\n".data(using: .utf8)!)
    exit(2)
}
let statePath = CommandLine.arguments[1]
guard var state = loadState(statePath) else {
    // Missing or unparseable state is not an error here — there might
    // simply be no scheduled reminders.
    exit(0)
}

let now = Int64(Date().timeIntervalSince1970)
// Grace window: fire anything from 30s ago through 5s ahead.
let lo = now - 30
let hi = now + 5

var dueIndices: [Int] = []
for (i, e) in state.entries.enumerated() {
    if e.at >= lo && e.at <= hi && (e.fired ?? false) == false {
        dueIndices.append(i)
    }
}
let dueEntries = dueIndices.map { state.entries[$0] }

// Mark fired BEFORE posting so a crash mid-post doesn't double-fire on
// the next tick.  Skipped when there's nothing due (e.g. an install-time
// "prime" run with empty state, or a launchd tick whose window hasn't
// arrived yet) so we don't churn the file pointlessly.
if !dueEntries.isEmpty {
    for i in dueIndices { state.entries[i].fired = true }
    saveStateAtomic(state, statePath)
}

// Always pass through `authorizeAndPost` even with an empty due list:
// the call to `requestAuthorization` is what surfaces the macOS
// permission prompt the first time the helper runs.  Without this,
// users see the Organ entry appear in System Settings -> Notifications
// (registered via lsregister) but never get a prompt to enable it.
let sema = DispatchSemaphore(value: 0)
authorizeAndPost(dueEntries) { _ in sema.signal() }
// Cap the wait so a hung permission prompt doesn't hold launchd open.
_ = sema.wait(timeout: .now() + 30)
exit(0)
