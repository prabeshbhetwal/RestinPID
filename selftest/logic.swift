import AppKit
@main enum T { static func main() {
  _ = NSApplication.shared
  let d = UserDefaults.standard
  d.set(false, forKey: "notify"); d.set(false, forKey: "confirmActions"); d.set(5.0, forKey: "frozenThreshold")
  d.removeObject(forKey: "excluded"); d.removeObject(forKey: "history"); d.set(["com.test.ARDummy"], forKey: "watched")
  d.set(true, forKey: "selfHeal"); d.removeObject(forKey: "selfRestartedAt"); d.removeObject(forKey: "selfRestartReason")
  let m = AppModel.shared
  var selfReasons: [String] = []
  m.selfRestartAction = { reason in DispatchQueue.main.async { selfReasons.append(reason) } } // never really relaunch the test
  m.start()
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
  // Grouping: no nested helpers, never loginwindow, Finder counts as macOS
  let paths = m.all.compactMap { $0.app.bundleURL?.path }
  let finder = m.all.first { $0.bundleID == "com.apple.finder" }
  let grouped = !paths.contains { $0.dropLast(4).contains(".app/") } && !m.all.contains { $0.bundleID == "com.apple.loginwindow" } && finder?.kind == .system
  print("6 grouping:", grouped ? "PASS" : "FAIL", "apps \(m.all.filter { $0.kind == .app }.count), background \(m.all.filter { $0.kind == .background }.count), macOS \(m.all.filter { $0.kind == .system }.count) (\(m.visible.filter { $0.kind == .system }.count) shown)")
  print("  background:", m.all.filter { $0.kind == .background }.map(\.name).sorted().joined(separator: ", "))
  // Self-watch: own usage shows; a stuck main thread and RAM over the limit both trigger a self-restart
  print("7 own usage:", m.ownMemory > 0 && m.ownCPU != nil ? "PASS" : "FAIL", formatBytes(m.ownMemory), m.ownCPU.map(formatCPU) ?? "-")
  m.selfLimits.warmup = 0; m.selfLimits.freeze = 3; m.selfLimits.cooldown = 0
  Thread.sleep(forTimeInterval: 6) // main thread stuck
  wait(1)
  print("8 self-restart when frozen:", selfReasons.contains { $0.contains("stopped responding") } ? "PASS" : "FAIL", selfReasons)
  selfReasons = []; m.selfLimits.ram = 1
  wait(5)
  print("9 self-restart over RAM limit:", selfReasons.contains { $0.contains("RAM") } ? "PASS" : "FAIL", selfReasons.first ?? "")
  selfReasons = []; m.selfLimits.ram = UInt64(500) << 20; d.set(false, forKey: "selfHeal")
  wait(5)
  m.selfLimits.ram = 1; wait(5)
  print("10 setting off = no self-restart:", selfReasons.isEmpty ? "PASS" : "FAIL")
  d.removeObject(forKey: "selfRestartedAt")
  d.removeObject(forKey: "watched")
}}
