import CoreGraphics
import Foundation

struct DTCFrame: Equatable {
	var dataNum: Int
	var state: Int
	var key1: String
	var key2: String
	var anchorOK: Bool
	var pixels: [PixelRGB] // 0..4
	var sendkey: String
	var rawKey2RGB: PixelRGB?

	static let empty = DTCFrame(
		dataNum: 0, state: 0, key1: "", key2: "", anchorOK: false,
		pixels: [], sendkey: "", rawKey2RGB: nil
	)
}

enum DTCReader {
	static let slotCount = 5

	/// Read 5 DTC cells from a window image.
	static func read(
		image: CGImage,
		cellSize: Int,
		originX: Int,
		originY: Int,
		tolerance: Int = 3
	) throws -> DTCFrame {
		var pixels: [PixelRGB] = []
		for slot in 0..<slotCount {
			let p = try WindowCapture.sampleCell(
				image: image,
				slot: slot,
				cellSize: cellSize,
				originX: originX,
				originY: originY
			)
			pixels.append(p)
		}

		let anchorOK = ColorCodec.isAnchor(pixels[4], tolerance: max(tolerance, 4))
		let dataNum = ColorCodec.decodeInteger(pixels[0], tolerance: tolerance)
		let state = ColorCodec.decodeInteger(pixels[1], tolerance: tolerance)

		var key1 = ""
		var key2 = ""
		var rawKey2: PixelRGB? = nil

		// Only decode keys when non-black-ish
		if !isNearBlack(pixels[2], tolerance: tolerance) {
			key1 = ColorCodec.colorToString(pixels[2], tolerance: tolerance)
		}
		if state == 5 {
			// AI channel: raw G/B encode TNum/ANum
			rawKey2 = pixels[3]
			key2 = String(format: "ai:g=%d,b=%d", pixels[3].g, pixels[3].b)
		} else if !isNearBlack(pixels[3], tolerance: tolerance) {
			key2 = ColorCodec.colorToString(pixels[3], tolerance: tolerance)
		}

		let sendkey = KeyMap.joinFragments(key1: key1, key2: key2)

		return DTCFrame(
			dataNum: dataNum,
			state: state,
			key1: key1,
			key2: key2,
			anchorOK: anchorOK,
			pixels: pixels,
			sendkey: sendkey,
			rawKey2RGB: rawKey2
		)
	}

	/// Try a few origin offsets if default top-left misses anchor.
	static func readWithCalibrate(
		image: CGImage,
		cellSize: Int,
		tolerance: Int = 3
	) throws -> (frame: DTCFrame, originX: Int, originY: Int) {
		let candidates: [(Int, Int)] = {
			var c: [(Int, Int)] = [(0, 0)]
			for y in stride(from: 0, through: 12, by: 1) {
				for x in stride(from: 0, through: 24, by: 1) {
					if x == 0 && y == 0 { continue }
					c.append((x, y))
				}
			}
			return c
		}()

		var last = DTCFrame.empty
		for (ox, oy) in candidates {
			// Need room for 5 cells
			if ox + cellSize * slotCount > image.width { continue }
			if oy + cellSize > image.height { continue }
			let frame = try read(
				image: image,
				cellSize: cellSize,
				originX: ox,
				originY: oy,
				tolerance: tolerance
			)
			last = frame
			if frame.anchorOK {
				return (frame, ox, oy)
			}
		}
		return (last, 0, 0)
	}

	private static func isNearBlack(_ p: PixelRGB, tolerance: Int) -> Bool {
		p.r <= tolerance && p.g <= tolerance && p.b <= tolerance
	}
}

/// Edge-triggered key dispatcher.
final class DTCBridgeLoop {
	struct Config {
		var titleRegex: String = "World of Warcraft|WoW|Classic"
		var intervalMs: Int = 40
		var cellSize: Int = 3
		var dryRun: Bool = false
		var verbose: Bool = false
		var tolerance: Int = 3
		var holdDurationMs: Int = 50
		var fixedOriginX: Int? = nil
		var fixedOriginY: Int? = nil
	}

	private let config: Config
	private var lastSendkey: String = ""
	private var lastState: Int = -1
	private var originX: Int = 0
	private var originY: Int = 0
	private var calibrated: Bool = false
	private var windowID: CGWindowID = 0
	private var missAnchorCount: Int = 0

	init(config: Config) {
		self.config = config
	}

	func run() throws {
		log("ZeusBridge starting (dryRun=\(config.dryRun) interval=\(config.intervalMs)ms cell=\(config.cellSize))")
		if !config.dryRun {
			let trusted = KeySynthesizer.isAccessibilityTrusted(prompt: true)
			if !trusted {
				log("WARN: Accessibility not granted — key injection will fail. System Settings → Privacy → Accessibility")
			}
		}

		// Resolve window once; re-find on capture failure
		try attachWindow()

		if let x = config.fixedOriginX { originX = x; calibrated = true }
		if let y = config.fixedOriginY { originY = y; calibrated = true }

		while true {
			autoreleasepool {
				do {
					try tick()
				} catch {
					log("ERR: \(error)")
					// Re-attach after errors
					try? attachWindow()
					calibrated = config.fixedOriginX != nil
				}
			}
			usleep(useconds_t(max(10, config.intervalMs) * 1000))
		}
	}

	private func attachWindow() throws {
		let w = try WindowCapture.findWindow(titleRegex: config.titleRegex)
		windowID = w.windowID
		log("attached \(w)")
	}

	private func tick() throws {
		let image = try WindowCapture.captureWindow(id: windowID)
		let frame: DTCFrame

		if calibrated {
			frame = try DTCReader.read(
				image: image,
				cellSize: config.cellSize,
				originX: originX,
				originY: originY,
				tolerance: config.tolerance
			)
			if !frame.anchorOK {
				missAnchorCount += 1
				if missAnchorCount >= 15 {
					// Re-calibrate
					calibrated = false
					missAnchorCount = 0
					if config.verbose { log("anchor lost → recalibrate") }
				}
			} else {
				missAnchorCount = 0
			}
		} else {
			let result = try DTCReader.readWithCalibrate(
				image: image,
				cellSize: config.cellSize,
				tolerance: config.tolerance
			)
			frame = result.frame
			if frame.anchorOK {
				originX = result.originX
				originY = result.originY
				calibrated = true
				log("calibrated origin=(\(originX),\(originY)) anchor OK")
			}
		}

		if config.verbose {
			let px = frame.pixels.map { $0.description }.joined(separator: " ")
			log("state=\(frame.state) key1=\(frame.key1) key2=\(frame.key2) send=\(frame.sendkey) anchor=\(frame.anchorOK) \(px)")
		}

		guard frame.anchorOK else {
			if config.verbose { log("skip: no anchor") }
			return
		}

		// state 0: keyboard focus — do not press
		if frame.state == 0 {
			lastSendkey = ""
			lastState = 0
			return
		}

		// state 5: AI channel — log only in v1
		if frame.state == 5 {
			if config.verbose || config.dryRun {
				log("[ai] \(frame.key2) (not injected in v1)")
			}
			return
		}

		let send = frame.sendkey
		if send.isEmpty {
			// Keys cleared after PIXEL_INTERVAL — reset edge detector
			lastSendkey = ""
			lastState = frame.state
			return
		}

		// Edge trigger: new sendkey or re-assert after clear
		if send == lastSendkey && frame.state == lastState {
			return
		}
		lastSendkey = send
		lastState = frame.state

		do {
			let stroke = try KeyMap.parse(send)
			if config.dryRun {
				log("[dry-run] \(send) → \(stroke.label)")
			} else {
				if frame.state == 3 {
					KeySynthesizer.hold(stroke, durationMs: config.holdDurationMs)
				} else {
					KeySynthesizer.tap(stroke)
				}
				log("[ok] \(send) → \(stroke.label)")
			}
		} catch {
			log("[map-fail] \(send): \(error)")
		}
	}

	private func log(_ msg: String) {
		let ts = ISO8601DateFormatter().string(from: Date())
		print("\(ts) \(msg)")
		fflush(stdout)
	}
}
