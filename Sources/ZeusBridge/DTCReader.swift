import CoreGraphics
import Foundation

struct DTCFrame: Equatable {
	var dataNum: Int
	var state: Int
	var key1: String
	var key2: String
	var anchorOK: Bool
	/// Full multi-slot validation (not just teal-ish slot4).
	var gridOK: Bool
	var pixels: [PixelRGB]
	var sendkey: String
	var aiTNum: Int?
	var aiANum: Int?
	/// Lower is better (used during calibrate).
	var qualityScore: Int

	static let empty = DTCFrame(
		dataNum: 0, state: 0, key1: "", key2: "", anchorOK: false, gridOK: false,
		pixels: [], sendkey: "", aiTNum: nil, aiANum: nil, qualityScore: 999_999
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
		// Flatness of each cell (solid UI color vs photo noise)
		var flatness = 0
		for slot in 0..<slotCount {
			flatness += cellVariance(
				buffer: buffer,
				slot: slot,
				cellSize: cellSize,
				originX: originX,
				originY: originY
			)
		}
		return decodePixels(pixels, flatnessPenalty: flatness, tolerance: tolerance)
	}

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

	private static func decodePixels(_ pixels: [PixelRGB], flatnessPenalty: Int, tolerance: Int) -> DTCFrame {
		let anchorTarget = ColorCodec.integerToColor(ColorCodec.anchorInteger)
		let anchorDist = pixels[4].distance(to: anchorTarget)
		// Tighter than before for "looks like anchor", but still allow mild shift.
		let anchorTol = max(tolerance, 14)
		let anchorOK = ColorCodec.isAnchor(pixels[4], tolerance: anchorTol)

		let dataNum = ColorCodec.decodeInteger(pixels[0], tolerance: tolerance)
		// For validation use strict known-state check (do not accept huge junk).
		let stateStrict = strictState(pixels[1])
		let state = stateStrict ?? ColorCodec.decodeState(pixels[1], tolerance: max(tolerance, 6))

		var key1 = ""
		var key2 = ""
		var aiT: Int? = nil
		var aiA: Int? = nil

		if state == 5 {
			aiT = ColorCodec.decodeChannel(pixels[3].g, tolerance: tolerance)
			aiA = ColorCodec.decodeChannel(pixels[3].b, tolerance: tolerance)
			key2 = String(format: "ai:T=%d,A=%d", aiT ?? -1, aiA ?? -1)
		} else {
			if !isNearBlack(pixels[2], tolerance: max(tolerance, 8)) {
				key1 = ColorCodec.colorToString(pixels[2], tolerance: tolerance)
			}
			if !isNearBlack(pixels[3], tolerance: max(tolerance, 8)) {
				key2 = ColorCodec.colorToString(pixels[3], tolerance: tolerance)
			}
		}

		let sendkey: String
		if state == 5 {
			sendkey = key2
		} else {
			sendkey = KeyMap.joinFragments(key1: key1, key2: key2)
		}

		// --- Grid validation (reject scenery false positives) ---
		// Real DTC idle: slot1≈state tiny (0,0,1), slot2/3 black, slot4 teal solid.
		let stateOK = stateStrict != nil
		// Slot1 should be dark-ish for states 0/1/3 (only blue/green small), state5 still dark R
		let slot1Dark = pixels[1].r <= 40 && pixels[1].g <= 40
		// Keys idle → near black
		let keysIdleDark = isNearBlack(pixels[2], tolerance: 20) && isNearBlack(pixels[3], tolerance: 20)
		// Or actively sending keys / AI: keys not required dark
		let keysActive = !keysIdleDark || state == 5 || state == 3
		// Flat cells (photo noise has high variance)
		let flatOK = flatnessPenalty <= 80 * slotCount  // avg variance per cell <= 80

		// Score: lower better
		var score = 0
		score += anchorDist * 3
		score += flatnessPenalty
		if !stateOK { score += 5000 }
		if !slot1Dark && state != 5 { score += 2000 }
		// Prefer idle-looking grid or active with known state
		if stateOK && keysIdleDark { score -= 50 }
		if stateOK && keysActive && !keysIdleDark { score -= 20 }
		// Prefer solid teal closer to exact
		if anchorDist > 40 { score += 1000 }

		// Accept grid only if multi-signal OK
		let gridOK = anchorOK
			&& stateOK
			&& flatOK
			&& (slot1Dark || state == 5)
			&& anchorDist <= 45

		return DTCFrame(
			dataNum: dataNum,
			state: state,
			key1: key1,
			key2: key2,
			anchorOK: anchorOK,
			gridOK: gridOK,
			pixels: pixels,
			sendkey: sendkey,
			aiTNum: aiT,
			aiANum: aiA,
			qualityScore: score
		)
	}

	/// Only accept exact known states with pixels near IntegerToColor(state).
	private static func strictState(_ pixel: PixelRGB) -> Int? {
		let targetTol = 22
		var best: Int? = nil
		var bestD = Int.max
		for s in ColorCodec.knownStates {
			let t = ColorCodec.integerToColor(s)
			let d = pixel.distance(to: t)
			if d < bestD {
				bestD = d
				best = s
			}
		}
		// state 1 is (0,0,1) — nearly black; allow slightly higher
		if let best, bestD <= targetTol {
			return best
		}
		// Also accept nearly black as state 0/1 (focus/idle) if very dark
		if pixel.r <= 8 && pixel.g <= 8 && pixel.b <= 12 {
			return pixel.b <= 2 ? 0 : 1
		}
		return nil
	}

	/// Sum of max-min channel ranges inside a cell (0 = perfectly flat).
	private static func cellVariance(
		buffer: PixelBuffer,
		slot: Int,
		cellSize: Int,
		originX: Int,
		originY: Int
	) -> Int {
		let x0 = originX + slot * cellSize
		let y0 = originY
		var minR = 255, minG = 255, minB = 255
		var maxR = 0, maxG = 0, maxB = 0
		var n = 0
		for y in y0..<(y0 + cellSize) {
			for x in x0..<(x0 + cellSize) {
				guard let p = buffer.pixel(x: x, y: y) else { continue }
				minR = min(minR, p.r); maxR = max(maxR, p.r)
				minG = min(minG, p.g); maxG = max(maxG, p.g)
				minB = min(minB, p.b); maxB = max(maxB, p.b)
				n += 1
			}
		}
		if n == 0 { return 999 }
		return (maxR - minR) + (maxG - minG) + (maxB - minB)
	}

	/// Calibrate: find best-scoring valid DTC grid near top-left.
	static func readWithCalibrate(
		image: CGImage,
		preferredCellSize: Int,
		tolerance: Int = 3,
		searchAlternateCellSizes: Bool = true
	) throws -> (frame: DTCFrame, originX: Int, originY: Int, cellSize: Int, diag: String) {
		guard let buffer = WindowCapture.makeBuffer(image) else {
			throw WindowCaptureError.invalidImage
		}

		let anchorTarget = ColorCodec.integerToColor(ColorCodec.anchorInteger)
		var cellSizes = [preferredCellSize]
		if searchAlternateCellSizes {
			cellSizes.append(contentsOf: [3, 6, 2, 4, 5, 8, 9, 12, 1, 7, 10])
		}
		var seen = Set<Int>()
		cellSizes = cellSizes.filter { seen.insert($0).inserted }

		// Prefer TOP of screen (UIParent TOPLEFT). Scenery mid-screen often has false teal.
		// Search full width of top strip, modest height (title bar + UI scale).
		let searchMaxY = min(buffer.height - 1, 180)
		let searchMaxX = min(buffer.width - 1, max(80, buffer.width / 2))
		let colorTol = 16

		let hits = WindowCapture.findColorMatches(
			buffer: buffer,
			target: anchorTarget,
			tolerance: colorTol,
			maxX: searchMaxX,
			maxY: searchMaxY,
			step: 1
		)

		struct Cand {
			var frame: DTCFrame
			var ox: Int
			var oy: Int
			var cell: Int
			var score: Int
			var hit: String
		}
		var best: Cand? = nil

		func consider(frame: DTCFrame, ox: Int, oy: Int, cell: Int, hit: String) {
			guard frame.gridOK else { return }
			// Prefer top-left strongly
			let posPenalty = ox * 2 + oy * 8
			let total = frame.qualityScore + posPenalty
			if best == nil || total < best!.score {
				best = Cand(frame: frame, ox: ox, oy: oy, cell: cell, score: total, hit: hit)
			}
		}

		// Phase A: from color hits
		for hit in hits.prefix(120) {
			for cell in cellSizes {
				let baseOx = hit.x - 4 * cell - cell / 2
				let baseOy = hit.y - cell / 2
				for dyo in -3...3 {
					for dxo in -3...3 {
						let originX = baseOx + dxo
						let originY = baseOy + dyo
						if originX < 0 || originY < 0 { continue }
						if originX + cell * slotCount > buffer.width { continue }
						if originY + cell > buffer.height { continue }
						// Real DTC is a tiny strip near UI top-left; reject deep mid-screen origins
						if originX > 400 || originY > 200 { continue }
						let frame = try read(
							buffer: buffer,
							cellSize: cell,
							originX: originX,
							originY: originY,
							tolerance: tolerance
						)
						consider(
							frame: frame,
							ox: originX,
							oy: originY,
							cell: cell,
							hit: "hit=(\(hit.x),\(hit.y))"
						)
					}
				}
			}
		}

		// Phase B: brute force only top-left corner (true DTC location)
		if best == nil {
			for cell in cellSizes {
				let maxX = min(80, max(0, buffer.width - cell * slotCount))
				let maxY = min(100, max(0, buffer.height - cell))
				for oy in stride(from: 0, through: maxY, by: 1) {
					for ox in stride(from: 0, through: maxX, by: 1) {
						let frame = try read(
							buffer: buffer,
							cellSize: cell,
							originX: ox,
							originY: oy,
							tolerance: tolerance
						)
						consider(frame: frame, ox: ox, oy: oy, cell: cell, hit: "grid")
					}
				}
			}
		}

		if let best {
			let refined = try refine(
				buffer: buffer,
				cell: best.cell,
				nearX: best.ox,
				nearY: best.oy,
				tolerance: tolerance
			)
			let diag = "OK score=\(best.score) \(best.hit) img=\(buffer.width)x\(buffer.height) state=\(refined.frame.state) anchorDist=\(refined.frame.pixels[4].distance(to: anchorTarget))"
			return (refined.frame, refined.ox, refined.oy, refined.cell, diag)
		}

		// Fail diagnostics
		let corner = sampleCorners(buffer)
		var nearTopLeftSample = DTCFrame.empty
		if let f = try? read(buffer: buffer, cellSize: 3, originX: 0, originY: 0, tolerance: tolerance) {
			nearTopLeftSample = f
		}
		let diag = """
		FAIL img=\(buffer.width)x\(buffer.height) anchorTarget=\(anchorTarget) colorHits=\(hits.count) \
		searchTop=\(searchMaxX)x\(searchMaxY) cornerTL=\(corner.tl) \
		@0,0 cells=\(nearTopLeftSample.pixels.map(\.description).joined(separator: " ")) \
		hint: need solid teal + dark state cell; scenery teal rejected
		"""
		return (nearTopLeftSample, 0, 0, preferredCellSize, diag.replacingOccurrences(of: "\n", with: " "))
	}

	private static func refine(
		buffer: PixelBuffer,
		cell: Int,
		nearX: Int,
		nearY: Int,
		tolerance: Int
	) throws -> (frame: DTCFrame, ox: Int, oy: Int, cell: Int) {
		var bestFrame: DTCFrame?
		var bestX = nearX
		var bestY = nearY
		var bestScore = Int.max
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
				guard frame.gridOK else { continue }
				let s = frame.qualityScore + ox + oy * 3
				if s < bestScore {
					bestScore = s
					bestFrame = frame
					bestX = ox
					bestY = oy
				}
			}
		}
		if let bestFrame {
			return (bestFrame, bestX, bestY, cell)
		}
		let fallback = try read(
			buffer: buffer,
			cellSize: cell,
			originX: nearX,
			originY: nearY,
			tolerance: tolerance
		)
		return (fallback, nearX, nearY, cell)
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
		log("expect anchor RGB \(ColorCodec.integerToColor(ColorCodec.anchorInteger)) + dark state cell (0/1/3/5)")
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
			// Require full grid validation, not just teal slot4
			if !frame.gridOK {
				missAnchorCount += 1
				if missAnchorCount >= 25 {
					calibrated = false
					missAnchorCount = 0
					log("grid lost → recalibrate (img=\(lastImageSize))")
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
			if frame.gridOK {
				originX = result.originX
				originY = result.originY
				cellSize = result.cellSize
				calibrated = true
				log("calibrated origin=(\(originX),\(originY)) cell=\(cellSize) img=\(lastImageSize) \(result.diag)")
			} else {
				failLogCounter += 1
				if failLogCounter <= 3 || failLogCounter % 5 == 0 {
					log("no-grid \(result.diag)")
				}
			}
		}

		if config.verbose {
			let px = frame.pixels.map(\.description).joined(separator: " ")
			log("state=\(frame.state) key1=\(frame.key1) key2=\(frame.key2) send=\(frame.sendkey) grid=\(frame.gridOK) cell=\(cellSize) o=(\(originX),\(originY)) \(px)")
		}

		guard frame.gridOK else {
			releaseHeld(reason: "no-grid")
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
