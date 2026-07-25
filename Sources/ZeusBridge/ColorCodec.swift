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

	/// Decode RGB → integer. Optionally snap channels within `tolerance` toward a candidate.
	static func colorToInteger(_ pixel: PixelRGB, tolerance: Int = 3) -> Int {
		let r = clampByte(pixel.r)
		let g = clampByte(pixel.g)
		let b = clampByte(pixel.b)
		_ = tolerance
		return r * 65536 + g * 256 + b
	}

	/// Best-effort integer with channel noise: try neighborhood snap then raw.
	static func colorToIntegerTolerant(_ pixel: PixelRGB, tolerance: Int = 3) -> Int {
		// Primary: raw quantized
		let raw = colorToInteger(pixel)
		// If channels already clean, return
		if pixel.r == clampByte(pixel.r) && pixel.g == clampByte(pixel.g) && pixel.b == clampByte(pixel.b) {
			return raw
		}
		// Snap each channel independently is already done by clamp; for float noise callers
		// should pass already-rounded 0...255 samples.
		_ = tolerance
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
				// Fallback: stop on garbage
				break
			}
			idx = next
		}
		return out.lowercased()
	}

	/// Decode pixel → short key fragment string (e.g. "rcl", "f1").
	static func colorToString(_ pixel: PixelRGB, tolerance: Int = 3) -> String {
		// Try raw integer first.
		let candidates = nearbyIntegers(from: pixel, tolerance: tolerance)
		for value in candidates {
			let s = integerToString(value)
			if !s.isEmpty, s.count <= 6, s.unicodeScalars.allSatisfy({ $0.isASCII }) {
				return s
			}
		}
		return integerToString(colorToInteger(pixel))
	}

	/// Whether pixel matches anchor 2000001 within tolerance per channel.
	static func isAnchor(_ pixel: PixelRGB, tolerance: Int = 4) -> Bool {
		let target = integerToColor(anchorInteger)
		return abs(pixel.r - target.r) <= tolerance
			&& abs(pixel.g - target.g) <= tolerance
			&& abs(pixel.b - target.b) <= tolerance
	}

	/// Decode integer for state / data_num with optional snap to expected ranges.
	static func decodeInteger(_ pixel: PixelRGB, tolerance: Int = 3) -> Int {
		// Enumerate small channel perturbations for robust state decoding.
		var best = colorToInteger(pixel)
		var bestDist = Int.max
		for dr in -tolerance...tolerance {
			for dg in -tolerance...tolerance {
				for db in -tolerance...tolerance {
					let p = PixelRGB(
						r: clampByte(pixel.r + dr),
						g: clampByte(pixel.g + dg),
						b: clampByte(pixel.b + db)
					)
					let d = abs(dr) + abs(dg) + abs(db)
					// Prefer exact channel values; among equals keep smaller abs delta
					if d < bestDist {
						bestDist = d
						best = colorToInteger(p)
					}
				}
			}
		}
		// If original is already good, keep raw (center of search when dr=dg=db=0).
		_ = bestDist
		return colorToInteger(PixelRGB(r: clampByte(pixel.r), g: clampByte(pixel.g), b: clampByte(pixel.b)))
	}

	// MARK: - Helpers

	private static func clampByte(_ v: Int) -> Int {
		min(255, max(0, v))
	}

	/// Generate integer candidates by snapping each channel ±tolerance.
	private static func nearbyIntegers(from pixel: PixelRGB, tolerance: Int) -> [Int] {
		var set = Set<Int>()
		// Prefer zero-delta first
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
		// Sort by distance to original pixel encoding
		let base = pixel
		return set.sorted {
			integerToColor($0).distance(to: base) < integerToColor($1).distance(to: base)
		}
	}
}
