import CoreGraphics
import Foundation

/// Parsed sendkey (e.g. "rcl-f1") → modifiers + virtual key.
struct KeyStroke: Equatable, CustomStringConvertible {
	/// Modifier keycodes to hold (left/right ctrl/alt/shift).
	var modifierKeyCodes: [CGKeyCode]
	/// Main key.
	var keyCode: CGKeyCode
	/// Human-readable label.
	var label: String

	var description: String { label }
}

enum KeyMapError: Error, CustomStringConvertible {
	case empty
	case unknownPrefix(String)
	case unknownKey(String)

	var description: String {
		switch self {
		case .empty: return "empty sendkey"
		case .unknownPrefix(let p): return "unknown prefix: \(p)"
		case .unknownKey(let k): return "unknown key: \(k)"
		}
	}
}

/// Maps plugin `sendkey` fragments to macOS CGKeyCodes.
/// Aligns with `DEFAULT_KEY_POOL` / `SplitBindingKey` in compatibility.lua.
enum KeyMap {
	// macOS virtual key codes (ANSI)
	private static let kLeftShift: CGKeyCode = 56
	private static let kRightShift: CGKeyCode = 60
	private static let kLeftControl: CGKeyCode = 59
	private static let kRightControl: CGKeyCode = 62
	private static let kLeftOption: CGKeyCode = 58
	private static let kRightOption: CGKeyCode = 61

	/// Prefix → ordered modifier keycodes.
	private static let prefixModifiers: [String: [CGKeyCode]] = [
		// Right-side combos (primary pool)
		"rcl": [kRightControl],
		"rat": [kRightOption],
		"rst": [kRightShift],
		"rcs": [kRightControl, kRightShift],
		"rac": [kRightOption, kRightControl],
		"ras": [kRightOption, kRightShift],
		"rrr": [kRightOption, kRightControl, kRightShift],
		// Left-side combos
		"lcl": [kLeftControl],
		"lat": [kLeftOption],
		"lst": [kLeftShift],
		"lcs": [kLeftControl, kLeftShift],
		"lac": [kLeftOption, kLeftControl],
		"las": [kLeftOption, kLeftShift],
		"lll": [kLeftOption, kLeftControl, kLeftShift],
		// Generic short prefixes (from SplitBindingKey fallbacks)
		"ctl": [kLeftControl],
		"alt": [kLeftOption],
		"sft": [kLeftShift],
		"ac": [kLeftOption, kLeftControl],
		"as": [kLeftOption, kLeftShift],
		"acs": [kLeftOption, kLeftControl, kLeftShift],
		"cs": [kLeftControl, kLeftShift],
	]

	/// Key token → CGKeyCode (lowercase).
	private static let keyCodes: [String: CGKeyCode] = {
		var m: [String: CGKeyCode] = [:]
		// Letters
		let letters: [(String, CGKeyCode)] = [
			("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
			("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
			("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
			("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
			("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37),
			("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
			("n", 45), ("m", 46), (".", 47),
		]
		for (k, v) in letters { m[k] = v }

		// Function keys
		let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
		for i in 1...12 {
			m["f\(i)"] = fkeys[i - 1]
		}

		// Keypad
		m["kp0"] = 82
		m["kp1"] = 83
		m["kp2"] = 84
		m["kp3"] = 85
		m["kp4"] = 86
		m["kp5"] = 87
		m["kp6"] = 88
		m["kp7"] = 89
		m["kp8"] = 91
		m["kp9"] = 92
		m["kp."] = 65
		m["kp*"] = 67
		m["kp+"] = 69
		m["kp/"] = 75
		m["kp-"] = 78
		m["kpe"] = 76 // keypad enter

		// Navigation / specials (plugin short names)
		m["up"] = 126
		m["dwn"] = 125
		m["lft"] = 123
		m["rht"] = 124
		m["ins"] = 114
		m["del"] = 117
		m["hom"] = 115
		m["end"] = 119
		m["pgu"] = 116
		m["pgd"] = 121
		m["spc"] = 49
		m["ent"] = 36
		m["tab"] = 48
		m["esc"] = 53
		m["cpl"] = 57 // caps lock
		m["num"] = 71 // num lock / clear

		// Full english aliases
		m["down"] = 125
		m["left"] = 123
		m["right"] = 124
		m["insert"] = 114
		m["delete"] = 117
		m["home"] = 115
		m["pageup"] = 116
		m["pagedown"] = 121
		m["space"] = 49
		m["enter"] = 36
		m["return"] = 36

		return m
	}()

	/// Parse full sendkey like "rcl-f1" or single fragment "f1".
	static func parse(_ sendkey: String) throws -> KeyStroke {
		let raw = sendkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if raw.isEmpty { throw KeyMapError.empty }
		if raw == "-" {
			// Plugin sentinel; map to minus key without mods
			return KeyStroke(modifierKeyCodes: [], keyCode: 27, label: "-")
		}

		// Longest-prefix match among known prefixes + "-"
		let prefixes = prefixModifiers.keys.sorted { $0.count > $1.count }
		for prefix in prefixes {
			let head = prefix + "-"
			if raw.hasPrefix(head) {
				let rest = String(raw.dropFirst(head.count))
				guard let kc = resolveKey(rest) else { throw KeyMapError.unknownKey(rest) }
				let mods = prefixModifiers[prefix] ?? []
				return KeyStroke(
					modifierKeyCodes: mods,
					keyCode: kc,
					label: formatLabel(prefix: prefix, key: rest)
				)
			}
			// Bare prefix alone (no key) — invalid for casting, ignore
		}

		// No known prefix: treat whole string as key token (e.g. "f1", "g")
		if let kc = resolveKey(raw) {
			return KeyStroke(modifierKeyCodes: [], keyCode: kc, label: raw.uppercased())
		}

		// Split on first "-" as generic prefix-key
		if let idx = raw.firstIndex(of: "-") {
			let p = String(raw[..<idx])
			let k = String(raw[raw.index(after: idx)...])
			if let mods = prefixModifiers[p], let kc = resolveKey(k) {
				return KeyStroke(modifierKeyCodes: mods, keyCode: kc, label: formatLabel(prefix: p, key: k))
			}
			throw KeyMapError.unknownPrefix(p)
		}

		throw KeyMapError.unknownKey(raw)
	}

	/// Build sendkey from two pixel-decoded fragments.
	static func joinFragments(key1: String, key2: String) -> String {
		let a = key1.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let b = key2.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if a.isEmpty && b.isEmpty { return "" }
		if a.isEmpty { return b }
		if b.isEmpty { return a }
		// key1 is prefix without trailing dash (plugin SplitBindingKey)
		if prefixModifiers[a] != nil {
			return "\(a)-\(b)"
		}
		return "\(a)-\(b)"
	}

	private static func resolveKey(_ token: String) -> CGKeyCode? {
		let t = token.lowercased()
		if let kc = keyCodes[t] { return kc }
		// Single character
		if t.count == 1, let kc = keyCodes[t] { return kc }
		return nil
	}

	private static func formatLabel(prefix: String, key: String) -> String {
		let modNames: [String: String] = [
			"rcl": "RCTRL", "rat": "RALT", "rst": "RSHIFT",
			"rcs": "RCTRL+RSHIFT", "rac": "RALT+RCTRL", "ras": "RALT+RSHIFT",
			"rrr": "RALT+RCTRL+RSHIFT",
			"lcl": "LCTRL", "lat": "LALT", "lst": "LSHIFT",
			"lcs": "LCTRL+LSHIFT", "lac": "LALT+LCTRL", "las": "LALT+LSHIFT",
			"lll": "LALT+LCTRL+LSHIFT",
			"ctl": "CTRL", "alt": "ALT", "sft": "SHIFT",
		]
		let mod = modNames[prefix] ?? prefix.uppercased()
		return "\(mod)+\(key.uppercased())"
	}
}
