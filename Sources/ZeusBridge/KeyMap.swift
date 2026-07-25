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

	/// Collapse L/R modifiers to left-side only (macOS/WoW compatibility fallback).
	func unifiedLeftModifiers() -> KeyStroke {
		let map: [CGKeyCode: CGKeyCode] = [
			62: 59, // right control → left
			61: 58, // right option → left
			60: 56, // right shift → left
		]
		var seen = Set<CGKeyCode>()
		var mods: [CGKeyCode] = []
		for m in modifierKeyCodes {
			let u = map[m] ?? m
			if !seen.contains(u) {
				seen.insert(u)
				mods.append(u)
			}
		}
		return KeyStroke(modifierKeyCodes: mods, keyCode: keyCode, label: label + " [L]")
	}
}

enum KeyMapError: Error, CustomStringConvertible {
	case empty
	case unknownPrefix(String)
	case unknownKey(String)
	case invalidAI(String)

	var description: String {
		switch self {
		case .empty: return "empty sendkey"
		case .unknownPrefix(let p): return "unknown prefix: \(p)"
		case .unknownKey(let k): return "unknown key: \(k)"
		case .invalidAI(let m): return "invalid AI payload: \(m)"
		}
	}
}

/// Maps plugin `sendkey` fragments to macOS CGKeyCodes.
/// Aligns with `DEFAULT_KEY_POOL` / `SplitBindingKey` / Uzi Macro_AI in compatibility.lua + bm_functions.lua.
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

		let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
		for i in 1...12 {
			m["f\(i)"] = fkeys[i - 1]
		}

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
		m["kpe"] = 76

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
		m["cpl"] = 57
		m["num"] = 71

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

	/// Uzi.Z_key digit 0...13 → RALT + numpad key (KNum = n-1, Z_key index = n).
	/// Matches bm_functions.lua Uzi.Z_key[1..14].
	private static let aiDigitKeys: [CGKeyCode] = [
		83, // 0 → NUMPAD1
		84, // 1 → NUMPAD2
		85, // 2 → NUMPAD3
		86, // 3 → NUMPAD4
		87, // 4 → NUMPAD5
		88, // 5 → NUMPAD6
		89, // 6 → NUMPAD7
		91, // 7 → NUMPAD8
		92, // 8 → NUMPAD9
		// digit 9 → NUMPADDIVIDE (Z_key[10])
		75,
		// digit 10 → NUMPADMULTIPLY
		67,
		// digit 11 → NUMPADMINUS
		78,
		// digit 12 → NUMPADPLUS
		69,
		// digit 13 → NUMPADDECIMAL
		65,
	]

	private static let aiDigitLabels = [
		"KP1", "KP2", "KP3", "KP4", "KP5", "KP6", "KP7", "KP8", "KP9",
		"KP/", "KP*", "KP-", "KP+", "KP.",
	]

	/// Parse full sendkey like "rcl-f1" or single fragment "f1".
	static func parse(_ sendkey: String) throws -> KeyStroke {
		let raw = sendkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if raw.isEmpty { throw KeyMapError.empty }
		if raw == "-" {
			return KeyStroke(modifierKeyCodes: [], keyCode: 27, label: "-")
		}

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
		}

		if let kc = resolveKey(raw) {
			return KeyStroke(modifierKeyCodes: [], keyCode: kc, label: raw.uppercased())
		}

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
		return "\(a)-\(b)"
	}

	/// Macro_AI: encode TNum/ANum as 4 base-14 RALT+NUMPAD taps (Uzi secure handler).
	/// Plugin: `DTC:SetKeyPixel_AI({0, TNum/255, ANum/255})` with state=5.
	static func aiSequence(tNum: Int, aNum: Int) throws -> [KeyStroke] {
		let t = tNum
		let a = aNum
		let maxV = 14 * 14 - 1
		guard t >= 0, t <= maxV, a >= 0, a <= maxV else {
			throw KeyMapError.invalidAI("TNum=\(t) ANum=\(a) out of 0...\(maxV)")
		}
		let digits = [
			t / 14,
			t % 14,
			a / 14,
			a % 14,
		]
		return try digits.map { d in
			guard d >= 0, d < aiDigitKeys.count else {
				throw KeyMapError.invalidAI("digit \(d)")
			}
			return KeyStroke(
				modifierKeyCodes: [kRightOption],
				keyCode: aiDigitKeys[d],
				label: "RALT+\(aiDigitLabels[d])"
			)
		}
	}

	private static func resolveKey(_ token: String) -> CGKeyCode? {
		let t = token.lowercased()
		if let kc = keyCodes[t] { return kc }
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
