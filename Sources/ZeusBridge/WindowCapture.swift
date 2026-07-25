import AppKit
import CoreGraphics
import Foundation

struct WindowInfo: CustomStringConvertible {
	var windowID: CGWindowID
	var pid: pid_t
	var name: String
	var owner: String
	var bounds: CGRect
	var layer: Int

	var description: String {
		"id=\(windowID) pid=\(pid) layer=\(layer) owner=\(owner) name=\(name) bounds=\(Int(bounds.width))x\(Int(bounds.height))"
	}
}

/// Flat RGBA8 top-left origin bitmap for fast scanning.
struct PixelBuffer {
	let width: Int
	let height: Int
	let rgba: [UInt8] // row-major, 4 bytes/pixel, top-left origin

	func pixel(x: Int, y: Int) -> PixelRGB? {
		guard x >= 0, y >= 0, x < width, y < height else { return nil }
		let i = (y * width + x) * 4
		let a = Int(rgba[i + 3])
		if a == 0 { return PixelRGB(r: 0, g: 0, b: 0) }
		if a < 255 {
			return PixelRGB(
				r: min(255, Int(rgba[i]) * 255 / a),
				g: min(255, Int(rgba[i + 1]) * 255 / a),
				b: min(255, Int(rgba[i + 2]) * 255 / a)
			)
		}
		return PixelRGB(r: Int(rgba[i]), g: Int(rgba[i + 1]), b: Int(rgba[i + 2]))
	}
}

enum WindowCaptureError: Error, CustomStringConvertible {
	case noWindows
	case notFound(String)
	case captureFailed
	case invalidImage

	var description: String {
		switch self {
		case .noWindows: return "no on-screen windows"
		case .notFound(let m): return "window not found: \(m)"
		case .captureFailed: return "CGWindowListCreateImage failed (grant Screen Recording?)"
		case .invalidImage: return "captured image invalid"
		}
	}
}

enum WindowCapture {
	/// List on-screen windows (layer 0 mostly).
	static func listWindows() -> [WindowInfo] {
		let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
			return []
		}
		var result: [WindowInfo] = []
		for item in info {
			let id = item[kCGWindowNumber as String] as? CGWindowID ?? 0
			let pid = item[kCGWindowOwnerPID as String] as? pid_t ?? 0
			let name = item[kCGWindowName as String] as? String ?? ""
			let owner = item[kCGWindowOwnerName as String] as? String ?? ""
			let layer = item[kCGWindowLayer as String] as? Int ?? 0
			var bounds = CGRect.zero
			if let b = item[kCGWindowBounds as String] as? [String: Any] {
				bounds = CGRect(
					x: (b["X"] as? NSNumber)?.doubleValue ?? 0,
					y: (b["Y"] as? NSNumber)?.doubleValue ?? 0,
					width: (b["Width"] as? NSNumber)?.doubleValue ?? 0,
					height: (b["Height"] as? NSNumber)?.doubleValue ?? 0
				)
			}
			if id == 0 { continue }
			result.append(WindowInfo(windowID: id, pid: pid, name: name, owner: owner, bounds: bounds, layer: layer))
		}
		return result
	}

	static func findWindow(titleRegex: String) throws -> WindowInfo {
		let windows = listWindows().filter { $0.layer == 0 && $0.bounds.width >= 200 && $0.bounds.height >= 200 }
		guard !windows.isEmpty else { throw WindowCaptureError.noWindows }

		guard let regex = try? NSRegularExpression(pattern: titleRegex, options: [.caseInsensitive]) else {
			throw WindowCaptureError.notFound("invalid regex \(titleRegex)")
		}

		func matches(_ s: String) -> Bool {
			let range = NSRange(s.startIndex..<s.endIndex, in: s)
			return regex.firstMatch(in: s, options: [], range: range) != nil
		}

		let hit = windows
			.filter { matches($0.name) || matches($0.owner) }
			.sorted { ($0.bounds.width * $0.bounds.height) > ($1.bounds.width * $1.bounds.height) }
			.first

		if let hit { return hit }
		throw WindowCaptureError.notFound(titleRegex)
	}

	/// Capture full window. Try multiple option combos (games clients differ).
	static func captureWindow(id: CGWindowID) throws -> CGImage {
		let attempts: [CGWindowImageOption] = [
			[.boundsIgnoreFraming, .bestResolution],
			[.boundsIgnoreFraming],
			[.bestResolution],
			[],
		]
		for opt in attempts {
			if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, opt) {
				if image.width > 10, image.height > 10 {
					return image
				}
			}
		}
		throw WindowCaptureError.captureFailed
	}

	/// Rasterize whole image (or region) to RGBA top-left origin for fast scans.
	static func makeBuffer(_ image: CGImage) -> PixelBuffer? {
		let w = image.width
		let h = image.height
		guard w > 0, h > 0 else { return nil }
		var rgba = [UInt8](repeating: 0, count: w * h * 4)
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		guard let ctx = CGContext(
			data: &rgba,
			width: w,
			height: h,
			bitsPerComponent: 8,
			bytesPerRow: w * 4,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			return nil
		}
		// Flip to top-left origin
		ctx.translateBy(x: 0, y: CGFloat(h))
		ctx.scaleBy(x: 1, y: -1)
		ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
		return PixelBuffer(width: w, height: h, rgba: rgba)
	}

	/// Sample median pixel of a cell in top-left grid (from CGImage).
	static func sampleCell(
		image: CGImage,
		slot: Int,
		cellSize: Int,
		originX: Int = 0,
		originY: Int = 0
	) throws -> PixelRGB {
		guard let buf = makeBuffer(image) else { throw WindowCaptureError.invalidImage }
		return try sampleCell(buffer: buf, slot: slot, cellSize: cellSize, originX: originX, originY: originY)
	}

	static func sampleCell(
		buffer: PixelBuffer,
		slot: Int,
		cellSize: Int,
		originX: Int,
		originY: Int
	) throws -> PixelRGB {
		let cx = originX + slot * cellSize + max(0, cellSize / 2)
		let cy = originY + max(0, cellSize / 2)
		guard cx >= 0, cy >= 0, cx < buffer.width, cy < buffer.height else {
			throw WindowCaptureError.invalidImage
		}
		let radius = max(0, (cellSize - 1) / 2)
		var samples: [PixelRGB] = []
		for dy in -radius...radius {
			for dx in -radius...radius {
				if let p = buffer.pixel(x: cx + dx, y: cy + dy) {
					samples.append(p)
				}
			}
		}
		guard !samples.isEmpty else { throw WindowCaptureError.invalidImage }
		return medianPixel(samples)
	}

	/// Find pixels matching target color in a search band (fast).
	static func findColorMatches(
		buffer: PixelBuffer,
		target: PixelRGB,
		tolerance: Int,
		maxX: Int,
		maxY: Int,
		step: Int = 1
	) -> [(x: Int, y: Int, dist: Int)] {
		let xLimit = min(maxX, buffer.width - 1)
		let yLimit = min(maxY, buffer.height - 1)
		var hits: [(Int, Int, Int)] = []
		let s = max(1, step)
		var y = 0
		while y <= yLimit {
			var x = 0
			while x <= xLimit {
				if let p = buffer.pixel(x: x, y: y) {
					let d = p.distance(to: target)
					// per-channel-ish: total L1 distance
					if abs(p.r - target.r) <= tolerance,
					   abs(p.g - target.g) <= tolerance,
					   abs(p.b - target.b) <= tolerance {
						hits.append((x, y, d))
					}
				}
				x += s
			}
			y += s
		}
		// Prefer top-left
		hits.sort {
			if $0.2 != $1.2 { return $0.2 < $1.2 }
			if $0.1 != $1.1 { return $0.1 < $1.1 }
			return $0.0 < $1.0
		}
		return hits.map { (x: $0.0, y: $0.1, dist: $0.2) }
	}

	private static func medianPixel(_ samples: [PixelRGB]) -> PixelRGB {
		let rs = samples.map(\.r).sorted()
		let gs = samples.map(\.g).sorted()
		let bs = samples.map(\.b).sorted()
		let mid = samples.count / 2
		return PixelRGB(r: rs[mid], g: gs[mid], b: bs[mid])
	}
}
