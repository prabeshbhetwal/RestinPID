import AppKit
@main enum T { static func main() {
  _ = NSApplication.shared
  let d = UserDefaults.standard
  d.set(false, forKey: "notify"); d.set(false, forKey: "confirmActions"); d.set(5.0, forKey: "frozenThreshold")
  d.removeObject(forKey: "excluded"); d.removeObject(forKey: "history"); d.set(["com.test.ARDummy"], forKey: "watched")
  let m = AppModel.shared; m.start()
  func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
  func te() -> AppItem? { m.all.first { $0.bundleID == "com.test.ARDummy" } }
  NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "\(CommandLine.arguments[1])"), configuration: .init()) { _, _ in }
  wait(3)
  guard let a = te() else { print("FAIL: copy not listed"); exit(1) }
  print("1 listed from /tmp: PASS")
  // Watchdog: freeze, expect auto-restart after >= 5 s
  let oldPid = a.id; kill(oldPid, SIGSTOP)
  wait(4); print("2 frozen badge:", te()?.frozen == true ? "PASS" : "FAIL")
  wait(14)
  let b = te(); let h = m.history.first
  print("3 watchdog restarted:", (b != nil && b!.id != oldPid && !isAlive(oldPid) && h?.automatic == true && h?.ok == true) ? "PASS" : "FAIL", "history:", h.map { "\($0.action) auto=\($0.automatic) ok=\($0.ok)" } ?? "none")
  // Exclude
  m.excluded.insert("com.test.ARDummy"); print("4 exclude hides:", te() == nil ? "PASS" : "FAIL")
  m.excluded.remove("com.test.ARDummy"); wait(0.5)
  // Force quit only (no relaunch)
  if let c = te() { m.perform(.forceQuit, on: [c]); wait(3)
    print("5 force quit, no relaunch:", (te() == nil && !isAlive(c.id) && m.history.first?.action == "Force Quit") ? "PASS" : "FAIL") }
  d.removeObject(forKey: "watched")
}}
