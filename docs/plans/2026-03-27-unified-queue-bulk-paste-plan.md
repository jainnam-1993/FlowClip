# Unified Queue Bulk Paste Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rewrite the queue paste mechanism so all clipboard changes (manual copy + dictation) feed into a unified queue, with a single atomic "Paste All" output that eliminates timing races and event tap complexity.

**Architecture:** The CGEvent tap is simplified to suppress-only (Cmd+V returns nil, everything else passes through). The Paste All hotkey stops the tap first, joins items with the separator, then fires a single clipboard write + paste. The `isInternalPaste` flag, nested timing delays, and separate separator paste are all removed.

**Tech Stack:** Swift, CGEvent API, NSPasteboard, KeyboardShortcuts, Defaults

---

### Task 1: Rewrite QueueClipboardManager to suppress-only event tap

**Files:**
- Modify: `Maccy/AppDelegate.swift:162-257` (QueueClipboardManager class)

**Step 1: Remove `isInternalPaste` flag**

Replace the entire `QueueClipboardManager` class (lines 162-257) with:

```swift
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
```

Key changes:
- `isInternalPaste` flag removed entirely
- Cmd+C interception removed (no more deactivate + re-fire hack)
- Cmd+V returns nil (suppress) with no drain logic, no timing delays
- All other events use `passUnretained` (fixes memory leak from `passRetained`)

**Step 2: Build and verify compilation**

Run: `cd /Volumes/workplace/tools/FlowMaccy && xcodebuild -scheme Maccy -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (or compilation errors to fix if `isInternalPaste` is referenced elsewhere)

**Step 3: Fix any remaining references to `isInternalPaste`**

Search for remaining references:
Run: `grep -rn 'isInternalPaste' Maccy/`

If any remain (they will, in the `queuePasteAll` handler), they'll be fixed in Task 2.

**Step 4: Commit**

```bash
git add Maccy/AppDelegate.swift
git commit -m "Simplify QueueClipboardManager to suppress-only event tap

Remove isInternalPaste flag, Cmd+C re-fire hack, individual Cmd+V
drain logic, nested asyncAfter timing delays, and separate separator
paste. Event tap now just suppresses Cmd+V (return nil) and passes
everything else through with passUnretained (fixes event memory leak)."
```

---

### Task 2: Rewrite Paste All handler

**Files:**
- Modify: `Maccy/AppDelegate.swift:376-391` (queuePasteAll hotkey handler)

**Step 1: Replace the Paste All handler**

Replace lines 376-391 with:

```swift
    KeyboardShortcuts.onKeyDown(for: .queuePasteAll) {
       guard !QueueClipboard.shared.items.isEmpty else { return }

       // 1. Stop the event tap FIRST so our Cmd+V isn't intercepted
       QueueClipboardManager.shared.stopMonitoring()

       // 2. Join items with separator (respecting LIFO/FIFO order)
       let separator = Defaults[.queueSeparator].value ?? ""
       let itemsToPaste = Defaults[.queuePasteLifo]
         ? QueueClipboard.shared.items.reversed()
         : Array(QueueClipboard.shared.items)
       let itemsText = itemsToPaste.compactMap { $0.item.previewableText }.joined(separator: separator)

       // 3. Single atomic paste
       Clipboard.shared.copy(itemsText, fromMaccy: true)
       Clipboard.shared.paste()

       // 4. Clean up: clear queue and deactivate
       QueueClipboard.shared.clear()
       QueueClipboard.shared.isModeActive = false
    }
```

Key changes:
- Stops event tap BEFORE pasting (no `isInternalPaste` flag needed)
- Trailing separator bug fixed: `joined(separator:)` without `+ separator`
- No `isInternalPaste` reference
- `stopMonitoring()` is called instead of being called inside the handler AND redundantly

**Step 2: Build and verify compilation**

Run: `cd /Volumes/workplace/tools/FlowMaccy && xcodebuild -scheme Maccy -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Verify no remaining `isInternalPaste` references**

Run: `grep -rn 'isInternalPaste' Maccy/`
Expected: No matches

**Step 4: Commit**

```bash
git add Maccy/AppDelegate.swift
git commit -m "Rewrite Paste All to stop tap first, single atomic paste

Stop event tap before pasting so simulated Cmd+V passes through
without interception. Join items inline with separator (no trailing
separator bug). Remove isInternalPaste flag entirely."
```

---

### Task 3: Run existing tests and verify no regressions

**Files:**
- Test: `MaccyTests/ClipboardTests.swift`

**Step 1: Run the full test suite**

Run: `cd /Volumes/workplace/tools/FlowMaccy && xcodebuild test -scheme Maccy -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E '(Test Case|Tests? (passed|failed)|BUILD)'`
Expected: All existing queue tests pass (testQueueTextSplitter*, testQueueClipboard*, testQueuePasteCopy*)

**Step 2: If any tests fail, investigate and fix**

The tests for `QueueTextSplitter`, `QueueClipboard.addFromClipboard`, move operations, and formatting preferences should all still pass since we didn't change `QueueClipboard` model or `QueueTextSplitter`.

If `testQueuePasteCopyRespectsRemoveFormattingPreference` references `isInternalPaste` or the old paste flow, update it.

**Step 3: Commit if any test fixes were needed**

```bash
git add MaccyTests/ClipboardTests.swift
git commit -m "Update tests for simplified queue paste mechanism"
```

---

### Task 4: Manual integration test

**No files changed.** This is a manual verification step.

**Step 1: Build and run the app**

Run: `cd /Volumes/workplace/tools/FlowMaccy && xcodebuild -scheme Maccy -configuration Debug build 2>&1 | tail -3`

Launch the built app from the build products directory, or run from Xcode.

**Step 2: Test queue recording**

1. Press queue hotkey (Opt+Shift+V) to activate queue mode
2. Verify status bar shows pulsing red dot + "Q"
3. Open TextEdit, copy some text (Cmd+C) from one location
4. Verify badge updates to show count (e.g., "x1")
5. Copy more text from another source
6. Verify count increments

**Step 3: Test Cmd+V suppression**

1. While queue mode is active, press Cmd+V
2. Verify nothing is pasted (Cmd+V is suppressed)

**Step 4: Test Paste All**

1. Press Paste All hotkey
2. Verify all queued items are pasted as a single block with separator
3. Verify queue mode deactivates (badge disappears)
4. Verify Cmd+V works normally again

**Step 5: Test dictation integration**

1. Activate queue mode
2. Use Handy to dictate some text (it will write to clipboard + simulate Cmd+V)
3. Verify transcription appears in queue count (badge increments)
4. Verify Handy's simulated Cmd+V doesn't paste anything
5. Copy some text manually
6. Press Paste All
7. Verify both dictation and manual copy appear in the pasted output

**Step 6: Test cancel flow**

1. Activate queue mode, add some items
2. Press queue hotkey again (toggle off)
3. Verify queue mode deactivates without pasting
4. Verify Cmd+V works normally

---
