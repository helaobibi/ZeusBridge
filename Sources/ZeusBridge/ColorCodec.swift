import Foundation

/// Pixel RGB in 0...255 (sRGB-ish, as sampled from framebuffer).
struct PixelRGB: Equatable, CustomStringConvertible {
	var r: Int
	var g: Int
	var b: Int

	var description: String { "(\(r),\(g),\(b))" }

	func distance(to other: PixelRGB) -> Int {
		abs(r - other.r) + abs(g - other.g) + abs(b - other.b)
	}
}

/// DTC color codec mirroring `core/api/compatibility.lua`
/// (`IntegerToColor` / `StringToASCIIHex` / `StringToColor`).
enum ColorCodec {
	/// Plugin anchor constant on slot 4.
	static let anchorInteger: Int = 2_000_001

	/// Known DTC state values from the plugin.
	static let knownStates: [Int] = [0, 1, 3, 5]

	/// Encode integer → RGB (same as Lua IntegerToColor).
	static func integerToColor(_ value: Int) -> PixelRGB {
		var i = max(0, value)
		let b = i % 256
		i /= 256
		let g = i % 256
		i /= 256
		let r = i % 256
		return PixelRGB(r: r, g: g, b: b)
	}

	/// Decode RGB → integer (exact channels, clamped).
	static func colorToInteger(_ pixel: PixelRGB) -> Int {
		let r = clampByte(pixel.r)
		let g = clampByte(pixel.g)
		let b = clampByte(pixel.b)
		return r * 65536 + g * 256 + b
	}

	/// Best integer within per-channel tolerance (min RGB distance to encoded color).
	static func decodeInteger(_ pixel: PixelRGB, tolerance: Int = 3) -> Int {
		var best = colorToInteger(pixel)
		var bestDist = integerToColor(best).distance(to: pixel)
		for dr in -tolerance...tolerance {
			for dg in -tolerance...tolerance {
				for db in -tolerance...tolerance {
					let p = PixelRGB(
						r: clampByte(pixel.r + dr),
						g: clampByte(pixel.g + dg),
						b: clampByte(pixel.b + db)
					)
					let value = colorToInteger(p)
					let dist = integerToColor(value).distance(to: pixel)
					if dist < bestDist {
						bestDist = dist
						best = value
					}
				}
			}
		}
		return best
	}

	/// Decode state slot: snap to {0,1,3,5} when close enough.
	static func decodeState(_ pixel: PixelRGB, tolerance: Int = 4) -> Int {
		let raw = decodeInteger(pixel, tolerance: tolerance)
		// Small integers live mostly in blue channel (and tiny green/red).
		var bestState = raw
		var bestDist = Int.max
		for s in knownStates {
			let d = integerToColor(s).distance(to: pixel)
			if d < bestDist {
				bestDist = d
				bestState = s
			}
		}
		// Only snap if the match is plausible; otherwise keep raw.
		let threshold = tolerance * 3 + 2
		if bestDist <= threshold {
			return bestState
		}
		return raw
	}

	/// Lua StringToASCIIHex: upper, up to 6 chars, concat decimal ASCII codes → Int.
	static func stringToInteger(_ str: String) -> Int {
		let upper = String(str.uppercased().prefix(6))
		var digits = ""
		for ch in upper.utf8 {
			digits += String(ch)
		}
		return Int(digits) ?? 0
	}

	/// Lua StringToColor (rejects len > 3 in plugin; we still encode).
	static func stringToColor(_ str: String) -> PixelRGB {
		integerToColor(stringToInteger(str))
	}

	/// Reverse of StringToASCIIHex: split decimal digit string into 2-digit ASCII codes.
	static func integerToString(_ value: Int) -> String {
		if value <= 0 { return "" }
		var digits = String(value)
		// Odd length: left-pad with 0 so pairing from the left still works for small codes.
		if digits.count % 2 == 1 {
			digits = "0" + digits
		}
		var out = ""
		var idx = digits.startIndex
		while idx < digits.endIndex {
			let next = digits.index(idx, offsetBy: 2, limitedBy: digits.endIndex) ?? digits.endIndex
			let pair = String(digits[idx..<next])
			if let code = Int(pair), code >= 32, code <= 126, let u = UnicodeScalar(code) {
				out.append(Character(u))
			} else {
				break
			}
			idx = next
		}
		return out.lowercased()
	}

	/// Decode pixel → short key fragment string (e.g. "rcl", "f1").
	/// Prefers candidates whose decoded string looks like a known token.
	static func colorToString(_ pixel: PixelRGB, tolerance: Int = 3) -> String {
		let candidates = nearbyIntegers(from: pixel, tolerance: tolerance)
		var fallback = ""
		for value in candidates {
			let s = integerToString(value)
			if s.isEmpty { continue }
			if fallback.isEmpty { fallback = s }
			if isPlausibleKeyFragment(s) {
				return s
			}
		}
		return fallback
	}

	/// Whether pixel matches anchor 2000001 within tolerance per channel.
	/// Default tolerance is looser: macOS display/ICC can shift game UI colors.
	static func isAnchor(_ pixel: PixelRGB, tolerance: Int = 18) -> Bool {
		let target = integerToColor(anchorInteger)
		return abs(pixel.r - target.r) <= tolerance
			&& abs(pixel.g - target.g) <= tolerance
			&& abs(pixel.b - target.b) <= tolerance
	}

	/// Decode 0...255 channel value with tolerance (for AI TNum/ANum).
	static func decodeChannel(_ value: Int, tolerance: Int = 3) -> Int {
		// Round noise toward nearest int already; clamp.
		_ = tolerance
		return clampByte(value)
	}

	// MARK: - Helpers

	private static func clampByte(_ v: Int) -> Int {
		min(255, max(0, v))
	}

	/// Known short fragments from DEFAULT_KEY_POOL / SplitBindingKey.
	private static let knownFragments: Set<String> = [
		"rcl", "rat", "rst", "rcs", "rac", "ras", "rrr",
		"lcl", "lat", "lst", "lcs", "lac", "las", "lll",
		"ctl", "alt", "sft", "ac", "as", "acs", "cs", "esc",
		"f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
		"kp0", "kp1", "kp2", "kp3", "kp4", "kp5", "kp6", "kp7", "kp8", "kp9",
		"kp.", "kp*", "kp+", "kp/", "kp-", "kpe",
		"up", "dwn", "lft", "rht", "ins", "del", "hom", "end", "pgu", "pgd",
		"spc", "ent", "tab", "cpl", "num",
		"u", "i", "o", "p", "h", "j", "k", "l", "b", "n", "m",
		"7", "8", "9", "0", "=", "[", "]", ";", "'", ",", ".", "/",
		"g", "1", "2", "3", "4", "5", "6", "a", "s", "d", "f", "q", "w", "e", "r", "t", "y", "z", "x", "c", "v",
	]

	private static func isPlausibleKeyFragment(_ s: String) -> Bool {
		if knownFragments.contains(s) { return true }
		if s.count == 1, s.unicodeScalars.first.map({ CharacterSet.alphanumerics.contains($0) }) == true {
			return true
		}
		// f10 style already in set; accept f\d{1,2}
		if s.range(of: #"^f\d{1,2}$"#, options: .regularExpression) != nil { return true }
		if s.range(of: #"^kp.+$"#, options: .regularExpression) != nil { return true }
		return s.count <= 3 && s.unicodeScalars.allSatisfy { $0.isASCII }
	}

	/// Generate integer candidates by snapping each channel ±tolerance.
	private static func nearbyIntegers(from pixel: PixelRGB, tolerance: Int) -> [Int] {
		var set = Set<Int>()
		set.insert(colorToInteger(pixel))
		for dr in -tolerance...tolerance {
			for dg in -tolerance...tolerance {
				for db in -tolerance...tolerance {
					let p = PixelRGB(
						r: clampByte(pixel.r + dr),
						g: clampByte(pixel.g + dg),
						b: clampByte(pixel.b + db)
					)
					set.insert(colorToInteger(p))
				}
			}
		}
		let base = pixel
		return set.sorted {
			integerToColor($0).distance(to: base) < integerToColor($1).distance(to: base)
		}
	}
}
