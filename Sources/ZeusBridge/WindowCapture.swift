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
				let rect = CGRect(
					x: (b["X"] as? NSNumber)?.doubleValue ?? 0,
					y: (b["Y"] as? NSNumber)?.doubleValue ?? 0,
					width: (b["Width"] as? NSNumber)?.doubleValue ?? 0,
					height: (b["Height"] as? NSNumber)?.doubleValue ?? 0
				)
				bounds = rect
			}
			if id == 0 { continue }
			result.append(WindowInfo(windowID: id, pid: pid, name: name, owner: owner, bounds: bounds, layer: layer))
		}
		return result
	}

	/// Find best matching window by title/owner regex.
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

		// Prefer owner or name match; larger area wins
		let hit = windows
			.filter { matches($0.name) || matches($0.owner) }
			.sorted { ($0.bounds.width * $0.bounds.height) > ($1.bounds.width * $1.bounds.height) }
			.first

		if let hit { return hit }
		throw WindowCaptureError.notFound(titleRegex)
	}

	/// Capture full window image (window-local pixels, retina-aware buffer).
	static func captureWindow(id: CGWindowID) throws -> CGImage {
		let image = CGWindowListCreateImage(
			.null,
			.optionIncludingWindow,
			id,
			[.boundsIgnoreFraming, .nominalResolution]
		)
		// .nominalResolution: prefer native backing pixels when possible
		// Fallback without nominal if nil
		if let image { return image }
		guard let fallback = CGWindowListCreateImage(
			.null,
			.optionIncludingWindow,
			id,
			[.boundsIgnoreFraming]
		) else {
			throw WindowCaptureError.captureFailed
		}
		return fallback
	}

	/// Sample average-ish center pixel of a cell in top-left grid.
	/// - Parameters:
	///   - image: window capture
	///   - slot: 0..n-1 horizontal index
	///   - cellSize: DTC_SIZE (default 3)
	///   - originX/Y: top-left of grid in image pixels
	static func sampleCell(
		image: CGImage,
		slot: Int,
		cellSize: Int,
		originX: Int = 0,
		originY: Int = 0
	) throws -> PixelRGB {
		let w = image.width
		let h = image.height
		let cx = originX + slot * cellSize + cellSize / 2
		let cy = originY + cellSize / 2
		guard cx >= 0, cy >= 0, cx < w, cy < h else {
			throw WindowCaptureError.invalidImage
		}

		// Read a small neighborhood and take median-ish average for stability
		let radius = max(0, cellSize / 2)
		var samples: [PixelRGB] = []
		for dy in -radius...radius {
			for dx in -radius...radius {
				let x = cx + dx
				let y = cy + dy
				if x >= 0, y >= 0, x < w, y < h {
					if let p = readPixel(image: image, x: x, y: y) {
						samples.append(p)
					}
				}
			}
		}
		guard !samples.isEmpty else { throw WindowCaptureError.invalidImage }
		return medianPixel(samples)
	}

	// MARK: - Pixel read

	private static func readPixel(image: CGImage, x: Int, y: Int) -> PixelRGB? {
		// Crop 1x1 — simple and safe across bitmap layouts
		guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
			return nil
		}
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		var rgba: [UInt8] = [0, 0, 0, 0]
		guard let ctx = CGContext(
			data: &rgba,
			width: 1,
			height: 1,
			bitsPerComponent: 8,
			bytesPerRow: 4,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			return nil
		}
		ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
		// Un-premultiply if needed
		let a = Int(rgba[3])
		if a == 0 {
			return PixelRGB(r: 0, g: 0, b: 0)
		}
		if a < 255 {
			let r = min(255, Int(rgba[0]) * 255 / a)
			let g = min(255, Int(rgba[1]) * 255 / a)
			let b = min(255, Int(rgba[2]) * 255 / a)
			return PixelRGB(r: r, g: g, b: b)
		}
		return PixelRGB(r: Int(rgba[0]), g: Int(rgba[1]), b: Int(rgba[2]))
	}

	private static func medianPixel(_ samples: [PixelRGB]) -> PixelRGB {
		let rs = samples.map(\.r).sorted()
		let gs = samples.map(\.g).sorted()
		let bs = samples.map(\.b).sorted()
		let mid = samples.count / 2
		return PixelRGB(r: rs[mid], g: gs[mid], b: bs[mid])
	}
}
