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
		let source = CGEventSource(stateID: .hidSystemState)

		// Press modifiers
		for mod in stroke.modifierKeyCodes {
			if let e = CGEvent(keyboardEventSource: source, virtualKey: mod, keyDown: true) {
				e.flags = flags(for: stroke.modifierKeyCodes, including: mod, downSoFar: true)
				e.post(tap: .cghidEventTap)
			}
		}

		// Main key down/up with full modifier flags
		let fullFlags = flags(for: stroke.modifierKeyCodes, including: nil, downSoFar: true)
		if let down = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: true) {
			down.flags = fullFlags
			down.post(tap: .cghidEventTap)
		}
		if holdMs > 0 {
			usleep(useconds_t(holdMs * 1000))
		}
		if let up = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: false) {
			up.flags = fullFlags
			up.post(tap: .cghidEventTap)
		}

		// Release modifiers reverse order
		for mod in stroke.modifierKeyCodes.reversed() {
			if let e = CGEvent(keyboardEventSource: source, virtualKey: mod, keyDown: false) {
				e.flags = []
				e.post(tap: .cghidEventTap)
			}
		}
	}

	/// Hold key for duration (state=3 style).
	static func hold(_ stroke: KeyStroke, durationMs: Int) {
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
		usleep(useconds_t(max(1, durationMs) * 1000))
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

	// MARK: - Flags

	private static func flags(
		for mods: [CGKeyCode],
		including: CGKeyCode?,
		downSoFar: Bool
	) -> CGEventFlags {
		var f: CGEventFlags = []
		let list: [CGKeyCode]
		if let including, downSoFar {
			// flags for events after this mod is considered down: all mods up to and including
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
