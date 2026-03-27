# Unified Queue with Bulk Paste

**Date:** 2026-03-27
**Status:** Approved

## Problem

FlowMaccy's queue mode captures manual copies (Cmd+C) for sequential paste, but:

1. Dictation apps (Handy, SuperWhisper) write transcriptions to the clipboard then simulate Cmd+V. The CGEvent tap intercepts that Cmd+V as a queue drain, causing the transcription to be pasted out-of-order instead of queued.
2. The individual-drain-via-Cmd+V mechanism has race conditions: `isInternalPaste` flag isn't thread-safe, nested `asyncAfter` delays (0.0/0.1/0.2s) fail on slow apps, separator pasted as a separate delayed Cmd+V can arrive before the main content, and `passRetained(event)` leaks every keypress.
3. There's no way to combine dictation and manual copies into a single bulk output.

## Solution

Split queue mode into two clean phases with a hard boundary:

- **Record:** All clipboard changes are queued. ALL Cmd+V is suppressed. No drain occurs.
- **Paste:** Event tap is stopped first, then a single atomic paste fires with all items joined.

### Recording Phase

The event tap becomes trivial:
- Cmd+V → return nil (suppress silently)
- Everything else → `Unmanaged.passUnretained(event)` (passthrough, no leak)

Clipboard changes from any source (manual Cmd+C, dictation app clipboard write, any app) are captured via the existing `onNewCopy` hook and routed to the queue. Items marked `fromMaccy` are ignored to prevent re-ingestion.

Dictation workflow: Handy writes transcription to clipboard → `onNewCopy` fires → queued. Handy simulates Cmd+V → event tap suppresses. Net: transcription queued, not pasted, no duplicate.

### Paste Phase (Paste All hotkey)

1. Stop the CGEvent tap (Cmd+V no longer intercepted)
2. Join queue items with configured separator (respecting LIFO/FIFO order)
3. Copy joined text to clipboard (`fromMaccy: true`)
4. Simulate single Cmd+V
5. Clear queue, deactivate queue mode

No `isInternalPaste` flag needed — the tap is stopped before the paste. No timing delays — single atomic paste. No separate separator paste — separator is joined inline.

### Lifecycle States

```
NORMAL MODE ──(queue hotkey)──▶ RECORDING MODE
     ▲                              │
     │                              │──(queue hotkey)──▶ NORMAL (cancel)
     │                              │
     └──(paste all hotkey)──────────┘
         via transient PASTE state
```

### What Gets Removed

- `isInternalPaste` flag and all checks
- Nested `DispatchQueue.main.asyncAfter` timing delays
- Separator-as-separate-paste logic (the 0.1s delayed second Cmd+V)
- Individual Cmd+V queue drain logic
- Queue-exhaustion beep
- Cmd+C re-fire hack when Maccy is active
- `Unmanaged.passRetained(event)` (replaced with `passUnretained`)

### What Stays

- `QueueClipboard` model (items, add/remove/move/clear, isPasted tracking)
- `QueueTextSplitter` (auto-split on newlines)
- `QueueSeparator` enum and preset system
- Status bar badge with pulsing dot and count
- All queue hotkeys (toggle, clear, paste-all, toggle-split, toggle-order, cycle-separator)
- Queue settings UI in GeneralSettingsPane

### Bug Fixes Included

1. **Trailing separator:** `joined(separator:) + separator` → `joined(separator:)` (no trailing junk)
2. **Event memory leak:** `passRetained` → `passUnretained` for passthrough events
3. **Deactivation timing:** removed entirely (tap stopped before paste, no deactivation check needed)
4. **Thread safety:** `isInternalPaste` removed entirely (no cross-thread flag)

## Files Changed

| File | Change |
|------|--------|
| `Maccy/AppDelegate.swift` | Rewrite `QueueClipboardManager.startMonitoring()` to suppress-only event tap. Simplify `queuePasteAll` handler. Remove individual drain logic. Fix `passRetained` → `passUnretained`. |
| `Maccy/AppDelegate.swift` | Fix trailing separator in paste-all: remove `+ separator`. |

## Out of Scope

- Queue persistence across app restarts
- In-popup queue visualization/reorder UI
- Queue size limits
- Sequential one-at-a-time drain via Cmd+V (removed in favor of bulk-only)
- Dictation app detection/allowlisting
