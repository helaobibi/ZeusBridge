import ApplicationServices
import CoreGraphics
import Foundation

enum KeySynthesizer {
	/// Check Accessibility (trusted for input monitoring / posting events).
	static func isAccessibilityTrusted(prompt: Bool) -> Bool {
		let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
		return AXIsProcessTrustedWithOptions(opts)
	}

	/// Tap key: modifiers down → key down → key up → modifiers up.
	static func tap(_ stroke: KeyStroke, holdMs: Int = 30) {
		keyDown(stroke)
		if holdMs > 0 {
			usleep(useconds_t(holdMs * 1000))
		}
		keyUp(stroke)
	}

	/// Press without release (for state=3 hold-until-clear).
	static func keyDown(_ stroke: KeyStroke) {
		let source = CGEventSource(stateID: .hidSystemState)
		for mod in stroke.modifierKeyCodes {
			if let e = CGEvent(keyboardEventSource: source, virtualKey: mod, keyDown: true) {
				e.flags = flags(for: stroke.modifierKeyCodes, including: mod, downSoFar: true)
				e.post(tap: .cghidEventTap)
			}
		}
		let fullFlags = flags(for: stroke.modifierKeyCodes, including: nil, downSoFar: true)
		if let down = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: true) {
			down.flags = fullFlags
			down.post(tap: .cghidEventTap)
		}
	}

	/// Release a previously held stroke.
	static func keyUp(_ stroke: KeyStroke) {
		let source = CGEventSource(stateID: .hidSystemState)
		let fullFlags = flags(for: stroke.modifierKeyCodes, including: nil, downSoFar: true)
		if let up = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: false) {
			up.flags = fullFlags
			up.post(tap: .cghidEventTap)
		}
		for mod in stroke.modifierKeyCodes.reversed() {
			if let e = CGEvent(keyboardEventSource: source, virtualKey: mod, keyDown: false) {
				e.flags = []
				e.post(tap: .cghidEventTap)
			}
		}
	}

	/// Hold for a fixed duration then release (legacy helper).
	static func hold(_ stroke: KeyStroke, durationMs: Int) {
		keyDown(stroke)
		usleep(useconds_t(max(1, durationMs) * 1000))
		keyUp(stroke)
	}

	/// Tap a sequence of strokes with a small gap (Macro_AI base-14 digits).
	static func tapSequence(_ strokes: [KeyStroke], gapMs: Int = 25, holdMs: Int = 25) {
		for (i, s) in strokes.enumerated() {
			tap(s, holdMs: holdMs)
			if i + 1 < strokes.count, gapMs > 0 {
				usleep(useconds_t(gapMs * 1000))
			}
		}
	}

	// MARK: - Flags

	private static func flags(
		for mods: [CGKeyCode],
		including: CGKeyCode?,
		downSoFar: Bool
	) -> CGEventFlags {
		var f: CGEventFlags = []
		let list: [CGKeyCode]
		if let including, downSoFar {
			if let idx = mods.firstIndex(of: including) {
				list = Array(mods[0...idx])
			} else {
				list = mods
			}
		} else {
			list = mods
		}
		for m in list {
			switch m {
			case 59, 62: f.insert(.maskControl)   // left/right control
			case 58, 61: f.insert(.maskAlternate) // left/right option
			case 56, 60: f.insert(.maskShift)
			case 55, 54: f.insert(.maskCommand)
			default: break
			}
		}
		return f
	}
}
