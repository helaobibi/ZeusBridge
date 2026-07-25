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
	/// Macro_AI: decoded from slot3 when state==5 (G≈TNum, B≈ANum).
	var aiTNum: Int?
	var aiANum: Int?

	static let empty = DTCFrame(
		dataNum: 0, state: 0, key1: "", key2: "", anchorOK: false,
		pixels: [], sendkey: "", aiTNum: nil, aiANum: nil
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

		let anchorOK = ColorCodec.isAnchor(pixels[4], tolerance: max(tolerance, 5))
		let dataNum = ColorCodec.decodeInteger(pixels[0], tolerance: tolerance)
		let state = ColorCodec.decodeState(pixels[1], tolerance: max(tolerance, 4))

		var key1 = ""
		var key2 = ""
		var aiT: Int? = nil
		var aiA: Int? = nil

		if state == 5 {
			// AI channel: key2 texture is {0, TNum/255, ANum/255} → sample G/B ≈ TNum/ANum
			aiT = ColorCodec.decodeChannel(pixels[3].g, tolerance: tolerance)
			aiA = ColorCodec.decodeChannel(pixels[3].b, tolerance: tolerance)
			key2 = String(format: "ai:T=%d,A=%d", aiT ?? -1, aiA ?? -1)
		} else {
			if !isNearBlack(pixels[2], tolerance: tolerance) {
				key1 = ColorCodec.colorToString(pixels[2], tolerance: tolerance)
			}
			if !isNearBlack(pixels[3], tolerance: tolerance) {
				key2 = ColorCodec.colorToString(pixels[3], tolerance: tolerance)
			}
		}

		let sendkey: String
		if state == 5 {
			sendkey = key2
		} else {
			sendkey = KeyMap.joinFragments(key1: key1, key2: key2)
		}

		return DTCFrame(
			dataNum: dataNum,
			state: state,
			key1: key1,
			key2: key2,
			anchorOK: anchorOK,
			pixels: pixels,
			sendkey: sendkey,
			aiTNum: aiT,
			aiANum: aiA
		)
	}

	/// Try origin offsets and multiple cell sizes until anchor matches.
	static func readWithCalibrate(
		image: CGImage,
		preferredCellSize: Int,
		tolerance: Int = 3,
		searchAlternateCellSizes: Bool = true
	) throws -> (frame: DTCFrame, originX: Int, originY: Int, cellSize: Int) {
		// Prefer configured size first, then common Retina multiples of DTC_SIZE=3.
		var cellSizes = [preferredCellSize]
		if searchAlternateCellSizes {
			cellSizes.append(contentsOf: [3, 6, 2, 4, 5, 8, 9])
		}
		var seen = Set<Int>()
		cellSizes = cellSizes.filter { seen.insert($0).inserted }

		var last = DTCFrame.empty
		var lastCell = preferredCellSize

		for cell in cellSizes {
			let maxX = min(40, max(0, image.width - cell * slotCount))
			let maxY = min(28, max(0, image.height - cell))

			// Phase 1: coarse grid (fast)
			for oy in stride(from: 0, through: maxY, by: 2) {
				for ox in stride(from: 0, through: maxX, by: 2) {
					let frame = try read(
						image: image,
						cellSize: cell,
						originX: ox,
						originY: oy,
						tolerance: tolerance
					)
					last = frame
					lastCell = cell
					if frame.anchorOK {
						// Phase 2: refine ±1 around hit
						return try refineAnchor(
							image: image,
							cell: cell,
							nearX: ox,
							nearY: oy,
							tolerance: tolerance
						)
					}
				}
			}
			// Phase 1b: remaining odd offsets if needed (only small region)
			for oy in 0...min(8, maxY) {
				for ox in 0...min(12, maxX) {
					if ox % 2 == 0 && oy % 2 == 0 { continue }
					let frame = try read(
						image: image,
						cellSize: cell,
						originX: ox,
						originY: oy,
						tolerance: tolerance
					)
					last = frame
					lastCell = cell
					if frame.anchorOK {
						return (frame, ox, oy, cell)
					}
				}
			}
		}
		return (last, 0, 0, lastCell)
	}

	private static func refineAnchor(
		image: CGImage,
		cell: Int,
		nearX: Int,
		nearY: Int,
		tolerance: Int
	) throws -> (frame: DTCFrame, originX: Int, originY: Int, cellSize: Int) {
		var best: DTCFrame?
		var bestX = nearX
		var bestY = nearY
		for dy in -1...1 {
			for dx in -1...1 {
				let ox = max(0, nearX + dx)
				let oy = max(0, nearY + dy)
				if ox + cell * slotCount > image.width { continue }
				if oy + cell > image.height { continue }
				let frame = try read(
					image: image,
					cellSize: cell,
					originX: ox,
					originY: oy,
					tolerance: tolerance
				)
				if frame.anchorOK {
					// Prefer closer to (0,0) among valid anchors
					if best == nil || ox + oy < bestX + bestY {
						best = frame
						bestX = ox
						bestY = oy
					}
				}
			}
		}
		if let best {
			return (best, bestX, bestY, cell)
		}
		let fallback = try read(
			image: image,
			cellSize: cell,
			originX: nearX,
			originY: nearY,
			tolerance: tolerance
		)
		return (fallback, nearX, nearY, cell)
	}

	private static func isNearBlack(_ p: PixelRGB, tolerance: Int) -> Bool {
		p.r <= tolerance && p.g <= tolerance && p.b <= tolerance
	}
}

/// Edge-triggered key dispatcher with hold + Macro_AI support.
final class DTCBridgeLoop {
	struct Config {
		var titleRegex: String = "World of Warcraft|WoW|Classic"
		var intervalMs: Int = 40
		var cellSize: Int = 3
		var dryRun: Bool = false
		var verbose: Bool = false
		var tolerance: Int = 3
		var fixedOriginX: Int? = nil
		var fixedOriginY: Int? = nil
		/// Map right modifiers to left (helps some Mac WoW builds).
		var unifyLeftModifiers: Bool = false
		/// Auto-search cell size on calibrate (default true).
		var autoCellSize: Bool = true
		var aiGapMs: Int = 25
		var aiHoldMs: Int = 25
		var tapHoldMs: Int = 30
	}

	private let config: Config
	private var lastSendkey: String = ""
	private var lastState: Int = -1
	private var lastAIToken: String = ""
	private var originX: Int = 0
	private var originY: Int = 0
	private var cellSize: Int
	private var calibrated: Bool = false
	private var windowID: CGWindowID = 0
	private var missAnchorCount: Int = 0

	/// Currently held stroke for state=3 (nil when not holding).
	private var heldStroke: KeyStroke? = nil
	private var heldSendkey: String = ""

	init(config: Config) {
		self.config = config
		self.cellSize = config.cellSize
	}

	func run() throws {
		log("ZeusBridge starting (dryRun=\(config.dryRun) interval=\(config.intervalMs)ms cell=\(config.cellSize) unifyL=\(config.unifyLeftModifiers))")
		if !config.dryRun {
			let trusted = KeySynthesizer.isAccessibilityTrusted(prompt: true)
			if !trusted {
				log("WARN: Accessibility not granted — key injection will fail. System Settings → Privacy → Accessibility")
			}
		}

		try attachWindow()

		if let x = config.fixedOriginX { originX = x; calibrated = true }
		if let y = config.fixedOriginY { originY = y; calibrated = true }
		if config.fixedOriginX != nil || config.fixedOriginY != nil {
			cellSize = config.cellSize
		}

		while true {
			autoreleasepool {
				do {
					try tick()
				} catch {
					log("ERR: \(error)")
					releaseHeld(reason: "error")
					try? attachWindow()
					if config.fixedOriginX == nil {
						calibrated = false
					}
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
				cellSize: cellSize,
				originX: originX,
				originY: originY,
				tolerance: config.tolerance
			)
			if !frame.anchorOK {
				missAnchorCount += 1
				if missAnchorCount >= 15 {
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
				preferredCellSize: config.cellSize,
				tolerance: config.tolerance,
				searchAlternateCellSizes: config.autoCellSize
			)
			frame = result.frame
			if frame.anchorOK {
				originX = result.originX
				originY = result.originY
				cellSize = result.cellSize
				calibrated = true
				log("calibrated origin=(\(originX),\(originY)) cell=\(cellSize) anchor OK")
			}
		}

		if config.verbose {
			let px = frame.pixels.map { $0.description }.joined(separator: " ")
			log("state=\(frame.state) key1=\(frame.key1) key2=\(frame.key2) send=\(frame.sendkey) anchor=\(frame.anchorOK) cell=\(cellSize) \(px)")
		}

		guard frame.anchorOK else {
			releaseHeld(reason: "no-anchor")
			if config.verbose { log("skip: no anchor") }
			return
		}

		// state 0: keyboard focus — do not press; release any hold
		if frame.state == 0 {
			releaseHeld(reason: "focus")
			lastSendkey = ""
			lastState = 0
			lastAIToken = ""
			return
		}

		// state 5: Macro_AI — four RALT+NUMPAD taps encoding TNum/ANum
		if frame.state == 5 {
			releaseHeld(reason: "ai")
			try handleAI(frame)
			lastState = 5
			lastSendkey = ""
			return
		}

		let send = frame.sendkey
		if send.isEmpty {
			// Keys cleared after PIXEL_INTERVAL — end hold + reset edge
			releaseHeld(reason: "clear")
			lastSendkey = ""
			lastState = frame.state
			lastAIToken = ""
			return
		}

		// state 3: hold while pixels stay active
		if frame.state == 3 {
			try handleHold(send: send)
			lastSendkey = send
			lastState = 3
			return
		}

		// state 1 (and any other): edge-triggered tap
		// If we were holding something else, release first.
		if heldStroke != nil {
			releaseHeld(reason: "tap")
		}

		if send == lastSendkey && frame.state == lastState {
			return
		}
		lastSendkey = send
		lastState = frame.state
		lastAIToken = ""

		do {
			var stroke = try KeyMap.parse(send)
			if config.unifyLeftModifiers {
				stroke = stroke.unifiedLeftModifiers()
			}
			if config.dryRun {
				log("[dry-run] \(send) → \(stroke.label)")
			} else {
				KeySynthesizer.tap(stroke, holdMs: config.tapHoldMs)
				log("[ok] \(send) → \(stroke.label)")
			}
		} catch {
			log("[map-fail] \(send): \(error)")
		}
	}

	private func handleHold(send: String) throws {
		if heldStroke != nil, heldSendkey == send {
			// already holding the same key
			return
		}
		// switch hold target
		releaseHeld(reason: "switch")
		var stroke = try KeyMap.parse(send)
		if config.unifyLeftModifiers {
			stroke = stroke.unifiedLeftModifiers()
		}
		if config.dryRun {
			log("[dry-run hold-down] \(send) → \(stroke.label)")
			heldStroke = stroke
			heldSendkey = send
			return
		}
		KeySynthesizer.keyDown(stroke)
		heldStroke = stroke
		heldSendkey = send
		log("[hold-down] \(send) → \(stroke.label)")
	}

	private func releaseHeld(reason: String) {
		guard let stroke = heldStroke else { return }
		if config.dryRun {
			log("[dry-run hold-up] \(heldSendkey) (\(reason))")
		} else {
			KeySynthesizer.keyUp(stroke)
			log("[hold-up] \(heldSendkey) (\(reason))")
		}
		heldStroke = nil
		heldSendkey = ""
	}

	private func handleAI(_ frame: DTCFrame) throws {
		guard let t = frame.aiTNum, let a = frame.aiANum else {
			if config.verbose { log("[ai] missing T/A channels") }
			return
		}
		let token = "\(t):\(a)"
		// Edge: only fire once per AI paint window
		if token == lastAIToken {
			return
		}
		// Also require non-zero-ish paint (ANum at least 1 for a real skill slot usually)
		// Allow TNum=1 (empty unit) + ANum>=1
		if t == 0 && a == 0 {
			return
		}

		var strokes = try KeyMap.aiSequence(tNum: t, aNum: a)
		if config.unifyLeftModifiers {
			// RALT → LALT for each digit
			strokes = strokes.map { $0.unifiedLeftModifiers() }
		}
		let label = strokes.map(\.label).joined(separator: " ")
		lastAIToken = token

		if config.dryRun {
			log("[dry-run ai] T=\(t) A=\(a) → \(label)")
		} else {
			KeySynthesizer.tapSequence(strokes, gapMs: config.aiGapMs, holdMs: config.aiHoldMs)
			log("[ok ai] T=\(t) A=\(a) → \(label)")
		}
	}

	private func log(_ msg: String) {
		let ts = ISO8601DateFormatter().string(from: Date())
		print("\(ts) \(msg)")
		fflush(stdout)
	}
}
