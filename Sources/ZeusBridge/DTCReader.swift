import CoreGraphics
import Foundation

struct DTCFrame: Equatable {
	var dataNum: Int
	var state: Int
	var key1: String
	var key2: String
	var anchorOK: Bool
	var pixels: [PixelRGB]
	var sendkey: String
	var aiTNum: Int?
	var aiANum: Int?

	static let empty = DTCFrame(
		dataNum: 0, state: 0, key1: "", key2: "", anchorOK: false,
		pixels: [], sendkey: "", aiTNum: nil, aiANum: nil
	)
}

enum DTCReader {
	static let slotCount = 5

	/// Read 5 DTC cells from a raster buffer.
	static func read(
		buffer: PixelBuffer,
		cellSize: Int,
		originX: Int,
		originY: Int,
		tolerance: Int = 3
	) throws -> DTCFrame {
		var pixels: [PixelRGB] = []
		for slot in 0..<slotCount {
			let p = try WindowCapture.sampleCell(
				buffer: buffer,
				slot: slot,
				cellSize: cellSize,
				originX: originX,
				originY: originY
			)
			pixels.append(p)
		}
		return decodePixels(pixels, tolerance: tolerance)
	}

	/// Convenience from CGImage.
	static func read(
		image: CGImage,
		cellSize: Int,
		originX: Int,
		originY: Int,
		tolerance: Int = 3
	) throws -> DTCFrame {
		guard let buf = WindowCapture.makeBuffer(image) else {
			throw WindowCaptureError.invalidImage
		}
		return try read(buffer: buf, cellSize: cellSize, originX: originX, originY: originY, tolerance: tolerance)
	}

	private static func decodePixels(_ pixels: [PixelRGB], tolerance: Int) -> DTCFrame {
		// Looser anchor match: Mac display color can shift DTC teal.
		let anchorTol = max(tolerance, 18)
		let anchorOK = ColorCodec.isAnchor(pixels[4], tolerance: anchorTol)
		let dataNum = ColorCodec.decodeInteger(pixels[0], tolerance: tolerance)
		let state = ColorCodec.decodeState(pixels[1], tolerance: max(tolerance, 6))

		var key1 = ""
		var key2 = ""
		var aiT: Int? = nil
		var aiA: Int? = nil

		if state == 5 {
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

	/// Calibrate: scan for anchor teal (30,132,129), then fit 5-cell grid.
	static func readWithCalibrate(
		image: CGImage,
		preferredCellSize: Int,
		tolerance: Int = 3,
		searchAlternateCellSizes: Bool = true
	) throws -> (frame: DTCFrame, originX: Int, originY: Int, cellSize: Int, diag: String) {
		guard let buffer = WindowCapture.makeBuffer(image) else {
			throw WindowCaptureError.invalidImage
		}

		let anchorTarget = ColorCodec.integerToColor(ColorCodec.anchorInteger) // (30,132,129)
		var cellSizes = [preferredCellSize]
		if searchAlternateCellSizes {
			// DTC_SIZE=3; Retina often 6; also try larger if UI scale upscales frames
			cellSizes.append(contentsOf: [3, 6, 2, 4, 5, 8, 9, 12, 1, 7, 10])
		}
		var seen = Set<Int>()
		cellSizes = cellSizes.filter { seen.insert($0).inserted }

		// --- Phase A: color-first search (handles title-bar / offset UI) ---
		// Search top band + left band of the full capture.
		let searchMaxY = min(buffer.height - 1, max(120, buffer.height / 4))
		let searchMaxX = min(buffer.width - 1, max(200, buffer.width / 3))
		let colorTol = max(18, tolerance + 12)

		let hits = WindowCapture.findColorMatches(
			buffer: buffer,
			target: anchorTarget,
			tolerance: colorTol,
			maxX: searchMaxX,
			maxY: searchMaxY,
			step: 1
		)

		// Limit candidates for speed
		let candidates = Array(hits.prefix(80))

		for hit in candidates {
			// hit is a pixel inside slot4; try each cell size → origin
			for cell in cellSizes {
				// Assume hit near center of slot4
				let ox = hit.x - 4 * cell - cell / 2
				let oy = hit.y - cell / 2
				for dyo in -2...2 {
					for dxo in -2...2 {
						let originX = ox + dxo
						let originY = oy + dyo
						if originX < 0 || originY < 0 { continue }
						if originX + cell * slotCount > buffer.width { continue }
						if originY + cell > buffer.height { continue }
						let frame = try read(
							buffer: buffer,
							cellSize: cell,
							originX: originX,
							originY: originY,
							tolerance: tolerance
						)
						if frame.anchorOK {
							let diag = "color-scan hit=(\(hit.x),\(hit.y)) img=\(buffer.width)x\(buffer.height) anchorTarget=\(anchorTarget)"
							return try refine(
								buffer: buffer,
								cell: cell,
								nearX: originX,
								nearY: originY,
								tolerance: tolerance,
								diag: diag
							)
						}
					}
				}
			}
		}

		// --- Phase B: brute force wider grid (fallback) ---
		var last = DTCFrame.empty
		var lastCell = preferredCellSize
		for cell in cellSizes {
			let maxX = min(160, max(0, buffer.width - cell * slotCount))
			let maxY = min(120, max(0, buffer.height - cell))
			for oy in stride(from: 0, through: maxY, by: 2) {
				for ox in stride(from: 0, through: maxX, by: 2) {
					let frame = try read(
						buffer: buffer,
						cellSize: cell,
						originX: ox,
						originY: oy,
						tolerance: tolerance
					)
					last = frame
					lastCell = cell
					if frame.anchorOK {
						let diag = "grid-scan img=\(buffer.width)x\(buffer.height)"
						return try refine(
							buffer: buffer,
							cell: cell,
							nearX: ox,
							nearY: oy,
							tolerance: tolerance,
							diag: diag
						)
					}
				}
			}
		}

		// Diagnostics when failed
		let corner = sampleCorners(buffer)
		let hitCount = hits.count
		let diag = """
		FAIL img=\(buffer.width)x\(buffer.height) anchorTarget=\(anchorTarget) colorHits=\(hitCount) search=\(searchMaxX)x\(searchMaxY) \
		cornerTL=\(corner.tl) TR=\(corner.tr) sample5@0,0=\(last.pixels.map(\.description).joined(separator: " "))
		hint: if colorHits=0, capture may miss UI overlay OR color shifted; if colorHits>0 but no grid, cell size mismatch
		"""
		return (last, 0, 0, lastCell, diag.replacingOccurrences(of: "\n", with: " "))
	}

	private static func refine(
		buffer: PixelBuffer,
		cell: Int,
		nearX: Int,
		nearY: Int,
		tolerance: Int,
		diag: String
	) throws -> (frame: DTCFrame, originX: Int, originY: Int, cellSize: Int, diag: String) {
		var best: DTCFrame?
		var bestX = nearX
		var bestY = nearY
		for dy in -2...2 {
			for dx in -2...2 {
				let ox = max(0, nearX + dx)
				let oy = max(0, nearY + dy)
				if ox + cell * slotCount > buffer.width { continue }
				if oy + cell > buffer.height { continue }
				let frame = try read(
					buffer: buffer,
					cellSize: cell,
					originX: ox,
					originY: oy,
					tolerance: tolerance
				)
				if frame.anchorOK {
					if best == nil || ox + oy < bestX + bestY {
						best = frame
						bestX = ox
						bestY = oy
					}
				}
			}
		}
		if let best {
			return (best, bestX, bestY, cell, diag)
		}
		let fallback = try read(
			buffer: buffer,
			cellSize: cell,
			originX: nearX,
			originY: nearY,
			tolerance: tolerance
		)
		return (fallback, nearX, nearY, cell, diag)
	}

	private static func sampleCorners(_ buffer: PixelBuffer) -> (tl: PixelRGB, tr: PixelRGB) {
		let tl = buffer.pixel(x: 0, y: 0) ?? PixelRGB(r: 0, g: 0, b: 0)
		let tr = buffer.pixel(x: max(0, buffer.width - 1), y: 0) ?? PixelRGB(r: 0, g: 0, b: 0)
		return (tl, tr)
	}

	private static func isNearBlack(_ p: PixelRGB, tolerance: Int) -> Bool {
		p.r <= tolerance && p.g <= tolerance && p.b <= tolerance
	}
}

/// Edge-triggered key dispatcher with hold + Macro_AI support.
final class DTCBridgeLoop {
	struct Config {
		var titleRegex: String = "Wow|魔兽|Warcraft|Classic|World of Warcraft"
		var intervalMs: Int = 40
		var cellSize: Int = 3
		var dryRun: Bool = false
		var verbose: Bool = false
		var tolerance: Int = 3
		var fixedOriginX: Int? = nil
		var fixedOriginY: Int? = nil
		var unifyLeftModifiers: Bool = false
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
	private var failLogCounter: Int = 0
	private var lastImageSize: String = ""

	private var heldStroke: KeyStroke? = nil
	private var heldSendkey: String = ""

	init(config: Config) {
		self.config = config
		self.cellSize = config.cellSize
	}

	func run() throws {
		log("ZeusBridge starting (dryRun=\(config.dryRun) interval=\(config.intervalMs)ms cell=\(config.cellSize) unifyL=\(config.unifyLeftModifiers))")
		log("expect anchor RGB \(ColorCodec.integerToColor(ColorCodec.anchorInteger)) from plugin slot4")
		if !config.dryRun {
			let trusted = KeySynthesizer.isAccessibilityTrusted(prompt: true)
			if !trusted {
				log("WARN: Accessibility not granted — System Settings → Privacy → Accessibility")
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
		lastImageSize = "\(image.width)x\(image.height)"
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
				if missAnchorCount >= 20 {
					calibrated = false
					missAnchorCount = 0
					log("anchor lost → recalibrate (img=\(lastImageSize))")
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
				log("calibrated origin=(\(originX),\(originY)) cell=\(cellSize) img=\(lastImageSize) \(result.diag)")
			} else {
				failLogCounter += 1
				// Log diagnostic every attempt while failing (throttled every 2nd to reduce spam a bit)
				if failLogCounter <= 3 || failLogCounter % 5 == 0 {
					log("no-anchor \(result.diag)")
					if !frame.pixels.isEmpty {
						let px = frame.pixels.map(\.description).joined(separator: " ")
						log("sample@origin0 cells: \(px)")
					}
				}
			}
		}

		if config.verbose, calibrated || frame.anchorOK {
			let px = frame.pixels.map(\.description).joined(separator: " ")
			log("state=\(frame.state) key1=\(frame.key1) key2=\(frame.key2) send=\(frame.sendkey) anchor=\(frame.anchorOK) cell=\(cellSize) \(px)")
		}

		guard frame.anchorOK else {
			releaseHeld(reason: "no-anchor")
			return
		}

		if frame.state == 0 {
			releaseHeld(reason: "focus")
			lastSendkey = ""
			lastState = 0
			lastAIToken = ""
			return
		}

		if frame.state == 5 {
			releaseHeld(reason: "ai")
			try handleAI(frame)
			lastState = 5
			lastSendkey = ""
			return
		}

		let send = frame.sendkey
		if send.isEmpty {
			releaseHeld(reason: "clear")
			lastSendkey = ""
			lastState = frame.state
			lastAIToken = ""
			return
		}

		if frame.state == 3 {
			try handleHold(send: send)
			lastSendkey = send
			lastState = 3
			return
		}

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
		if heldStroke != nil, heldSendkey == send { return }
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
		guard let t = frame.aiTNum, let a = frame.aiANum else { return }
		let token = "\(t):\(a)"
		if token == lastAIToken { return }
		if t == 0 && a == 0 { return }

		var strokes = try KeyMap.aiSequence(tNum: t, aNum: a)
		if config.unifyLeftModifiers {
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
