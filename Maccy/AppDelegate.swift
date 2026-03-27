import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI
import Sauce
import Observation

@Observable
class QueueClipboard {
  static let shared = QueueClipboard()

  struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    let item: HistoryItem
  }

  private(set) var items: [QueueItem] = []
  var isModeActive: Bool = false

  func add(_ item: HistoryItem) {
    items.append(QueueItem(item: item))
  }

  func addFromClipboard(_ item: HistoryItem) {
    guard Defaults[.queueAutoSplitText] else {
      add(item)
      return
    }

    let splitItems = QueueTextSplitter.split(item: item)
    guard splitItems.count > 1 else {
      add(item)
      return
    }

    splitItems.forEach { splitText in
      let queueItem = HistoryItem(contents: [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: Data(splitText.utf8)
        )
      ])
      queueItem.application = item.application
      queueItem.title = queueItem.generateTitle()
      add(queueItem)
    }
  }

  func remove(id: UUID) {
    items.removeAll(where: { $0.id == id })
  }

  func move(from source: IndexSet, to destination: Int) {
    items.move(fromOffsets: source, toOffset: destination)
  }

  func move(itemWithID sourceID: UUID, beforeItemWithID destinationID: UUID) {
    guard sourceID != destinationID,
          let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
          let destinationIndex = items.firstIndex(where: { $0.id == destinationID }) else {
      return
    }

    let newOffset = destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
    items.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: newOffset)
  }

  func moveToEnd(itemWithID id: UUID) {
    guard let sourceIndex = items.firstIndex(where: { $0.id == id }) else {
      return
    }

    items.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: items.count)
  }

  func clear() {
    items.removeAll()
  }
}

enum QueueTextSplitter {
  static func split(item: HistoryItem) -> [String] {
    guard let text = extractedText(from: item) else {
      return []
    }

    return split(text: text)
  }

  static func split(text: String) -> [String] {
    let normalized = normalize(text)
    guard normalized.contains("\n") else {
      return [normalized]
    }

    let lines = normalized
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    return lines.count > 1 ? lines : [normalized]
  }

  private static func extractedText(from item: HistoryItem) -> String? {
    if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      return text
    }

    if !item.fileURLs.isEmpty || item.image != nil {
      return nil
    }

    if let text = item.rtf?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      return text
    }

    if let text = item.html?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      return text
    }

    return nil
  }

  private static func normalize(_ text: String) -> String {
    return text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

}

class QueueClipboardManager {
  static let shared = QueueClipboardManager()
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  func startMonitoring() {
    stopMonitoring()
    let eventMask = (1 << CGEventType.keyDown.rawValue)
    eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(eventMask),
      callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
        if type == .keyDown {
          let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
          let flags = event.flags
          let isV = keyCode == Sauce.shared.keyCode(for: .v)
          let isCommand = flags.contains(.maskCommand)

          // Suppress Cmd+V during recording — content is already queued via onNewCopy
          if isV && isCommand {
            return nil
          }
        }
        return Unmanaged.passUnretained(event)
      },
      userInfo: nil
    )
    if let eventTap = eventTap {
      runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
      CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
      CGEvent.tapEnable(tap: eventTap, enable: true)
    }
  }

  func stopMonitoring() {
    if let eventTap = eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
    if let runLoopSource = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
    eventTap = nil
    runLoopSource = nil
  }
}


class AppDelegate: NSObject, NSApplicationDelegate {
  var panel: FloatingPanel<ContentView>!
  private var queuePulseTimer: Timer?
  private var queuePulseVisible = true

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      SPUUpdater(hostBundle: Bundle.main,
                 applicationBundle: Bundle.main,
                 userDriver: SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil),
                 delegate: nil)
      .automaticallyChecksForUpdates = false
    }
    #endif

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { item in
      if QueueClipboard.shared.isModeActive {
        // Ignore items already in Maccy or those we just put for pasting
        if !item.fromMaccy {
          QueueClipboard.shared.addFromClipboard(item)
        }
      } else {
        History.shared.add(item)
      }
    }
    Clipboard.shared.start()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    synchronizeQueueBadge()
    Task {
      for await _ in Defaults.updates(.showRecentCopyInMenuBar) {
        updateStatusBarTitle()
      }
    }

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    Accessibility.check()
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "org.p0deje.Maccy",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }

    KeyboardShortcuts.onKeyDown(for: .queue) { [weak self] in
      self?.toggleQueue()
    }
    
    KeyboardShortcuts.onKeyDown(for: .queueClear) {
      QueueClipboard.shared.clear()
      NSSound.playMorseFeedback()
    }
    
    KeyboardShortcuts.onKeyDown(for: .queuePasteAll) { [weak self] in
       self?.toggleQueue()
    }

    KeyboardShortcuts.onKeyDown(for: .queueToggleSplit) {
      Defaults[.queueAutoSplitText].toggle()
      NSSound.playMorseFeedback()
    }

    KeyboardShortcuts.onKeyDown(for: .queueTogglePasteOrder) {
      Defaults[.queuePasteLifo].toggle()
      NSSound.playMorseFeedback()
    }

    KeyboardShortcuts.onKeyDown(for: .queueCycleSeparatorPreset) {
      Defaults[.queueSeparator] = .custom
      _ = QueueSeparator.cycleCurrentPreset()
      NSSound.playMorseFeedback()
    }
  }

  @MainActor
  private func toggleQueue() {
    guard Accessibility.allowed else {
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("AccessibilityPermissionRequired", comment: "")
      alert.informativeText = NSLocalizedString("AccessibilityPermissionRequiredMessage", comment: "")
      alert.addButton(withTitle: NSLocalizedString("OpenSystemSettings", comment: ""))
      alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

      if alert.runModal() == .alertFirstButtonReturn {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
          NSWorkspace.shared.open(url)
        }
        Accessibility.check()
      }
      return
    }

    if QueueClipboard.shared.isModeActive {
      // Stop recording and paste everything in one shot
      if !QueueClipboard.shared.items.isEmpty {
        QueueClipboardManager.shared.stopMonitoring()

        let separator = Defaults[.queueSeparator].value ?? ""
        let itemsToPaste = Defaults[.queuePasteLifo]
          ? QueueClipboard.shared.items.reversed()
          : Array(QueueClipboard.shared.items)
        let itemsText = itemsToPaste.compactMap { $0.item.previewableText }.joined(separator: separator)

        Clipboard.shared.copy(itemsText, fromMaccy: true)
        Clipboard.shared.paste()

        QueueClipboard.shared.clear()
      } else {
        QueueClipboardManager.shared.stopMonitoring()
      }
      QueueClipboard.shared.isModeActive = false
    } else {
      QueueClipboard.shared.clear()
      QueueClipboard.shared.isModeActive = true
      QueueClipboardManager.shared.startMonitoring()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  func applicationWillTerminate(_ notification: Notification) {
    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  private func migrateUserDefaults() {
    if Defaults[.migrations]["2024-07-01-version-2"] != true {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")

      Defaults[.migrations]["2024-07-01-version-2"] = true
    }

    if Defaults[.migrations]["2026-02-23-queue-separator-presets"] != true {
      var presets = QueueSeparator.normalizedPresetSlots(Defaults[.queueSeparatorPresets])
      let legacyCustomSeparator = Defaults[.customQueueSeparator]
      if !legacyCustomSeparator.isEmpty {
        presets[0] = legacyCustomSeparator
      }

      Defaults[.queueSeparatorPresets] = presets
      Defaults[.queueActiveSeparatorPresetIndex] = QueueSeparator.normalizedPresetIndex(
        Defaults[.queueActiveSeparatorPresetIndex],
        presets: presets
      )
      Defaults[.migrations]["2026-02-23-queue-separator-presets"] = true
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    if let event = NSApp.currentEvent {
      let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      if modifierFlags.contains(.option) {
        Defaults[.ignoreEvents].toggle()

        if modifierFlags.contains(.shift) {
          Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
        }

        return
      }
    }

    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        self.updateStatusBarTitle()
        self.synchronizeMenuIconText()
      }
    }
  }

  private func synchronizeQueueBadge() {
    _ = withObservationTracking {
      _ = QueueClipboard.shared.isModeActive
      _ = QueueClipboard.shared.items.count
    } onChange: {
      DispatchQueue.main.async {
        self.updateStatusBarTitle()
        self.synchronizeQueueBadge()
      }
    }
  }

  private func updateStatusBarTitle() {
    if QueueClipboard.shared.isModeActive {
      let count = QueueClipboard.shared.items.count
      let dot = queuePulseVisible ? "\u{25CF} " : "  "  // Pulsing red dot (rendered via attributedTitle)
      let badge = count > 0 ? "\u{00D7}\(count)" : "Q"
      applyQueueBadge(dot: dot, badge: badge)
      startQueuePulse()
    } else {
      stopQueuePulse()
      if Defaults[.showRecentCopyInMenuBar] {
        statusItem.button?.attributedTitle = NSAttributedString()
        statusItem.button?.title = AppState.shared.menuIconText
      } else {
        statusItem.button?.attributedTitle = NSAttributedString()
        statusItem.button?.title = ""
      }
    }
  }

  private func applyQueueBadge(dot: String, badge: String) {
    let attributed = NSMutableAttributedString()
    attributed.append(NSAttributedString(
      string: dot,
      attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 8)]
    ))
    attributed.append(NSAttributedString(
      string: badge,
      attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)]
    ))
    statusItem.button?.attributedTitle = attributed
  }

  private func startQueuePulse() {
    guard queuePulseTimer == nil else { return }
    queuePulseVisible = true
    queuePulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.queuePulseVisible.toggle()
      if QueueClipboard.shared.isModeActive {
        let count = QueueClipboard.shared.items.count
        let dot = self.queuePulseVisible ? "\u{25CF} " : "  "
        let badge = count > 0 ? "\u{00D7}\(count)" : "Q"
        self.applyQueueBadge(dot: dot, badge: badge)
      }
    }
  }

  private func stopQueuePulse() {
    queuePulseTimer?.invalidate()
    queuePulseTimer = nil
    queuePulseVisible = true
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name, names.contains(name) {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}

