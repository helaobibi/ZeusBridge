import Foundation

// ZeusBridge — external DTC pixel → keyboard bridge for TtMan / zeus.
// Protocol: core/api/compatibility.lua DataToColor frames ZUFrame_0..4
// Note: this file is main.swift (top-level entry). Do not add @main.

struct CLIOptions {
	var listWindows = false
	var dryRun = false
	var verbose = false
	var intervalMs = 40
	var cellSize = 3
	var titleRegex = "World of Warcraft|WoW|Classic"
	var originX: Int? = nil
	var originY: Int? = nil
	var showHelp = false
}

func parseArgs(_ args: [String]) -> CLIOptions {
	var opt = CLIOptions()
	var i = 0
	while i < args.count {
		let a = args[i]
		switch a {
		case "-h", "--help":
			opt.showHelp = true
		case "--list-windows":
			opt.listWindows = true
		case "--dry-run":
			opt.dryRun = true
		case "-v", "--verbose":
			opt.verbose = true
		case "--interval-ms":
			i += 1
			if i < args.count, let v = Int(args[i]) { opt.intervalMs = v }
		case "--cell-size":
			i += 1
			if i < args.count, let v = Int(args[i]) { opt.cellSize = max(1, v) }
		case "--title-regex":
			i += 1
			if i < args.count { opt.titleRegex = args[i] }
		case "--origin-x":
			i += 1
			if i < args.count, let v = Int(args[i]) { opt.originX = v }
		case "--origin-y":
			i += 1
			if i < args.count, let v = Int(args[i]) { opt.originY = v }
		default:
			if a.hasPrefix("-") {
				fputs("unknown option: \(a)\n", stderr)
			}
		}
		i += 1
	}
	return opt
}

func printHelp() {
	let help = """
	ZeusBridge — read TtMan/zeus DTC pixels and inject key bindings

	Usage:
	  ZeusBridge [options]

	Options:
	  --list-windows          List on-screen windows and exit
	  --dry-run               Decode and print keys, do not inject
	  --interval-ms <n>       Poll interval (default 40)
	  --cell-size <n>         DTC cell size in pixels (default 3)
	  --title-regex <re>      Window title/owner regex (default: World of Warcraft|WoW|Classic)
	  --origin-x <n>          Fix grid origin X in window image pixels
	  --origin-y <n>          Fix grid origin Y in window image pixels
	  -v, --verbose           Verbose pixel dump each tick
	  -h, --help              Show this help

	Permissions (macOS):
	  1. Screen Recording  — System Settings → Privacy & Security → Screen Recording
	  2. Accessibility     — System Settings → Privacy & Security → Accessibility
	  Grant for ZeusBridge.app (or the terminal if you run the bare binary).

	Workflow:
	  1. Start WoW in windowed mode, load the addon (EpicMusicBox / zeus).
	  2. ZeusBridge --dry-run -v
	  3. Confirm anchor=true and keys like rcl-f1 when rotation fires.
	  4. Re-run without --dry-run.

	"""
	print(help)
}

let args = Array(CommandLine.arguments.dropFirst())
let opt = parseArgs(args)

if opt.showHelp {
	printHelp()
	exit(0)
}

if opt.listWindows {
	let wins = WindowCapture.listWindows()
	if wins.isEmpty {
		print("no windows (need Screen Recording permission?)")
		exit(1)
	}
	for w in wins where w.layer == 0 {
		print(w)
	}
	exit(0)
}

var cfg = DTCBridgeLoop.Config()
cfg.titleRegex = opt.titleRegex
cfg.intervalMs = opt.intervalMs
cfg.cellSize = opt.cellSize
cfg.dryRun = opt.dryRun
cfg.verbose = opt.verbose
cfg.fixedOriginX = opt.originX
cfg.fixedOriginY = opt.originY

let loop = DTCBridgeLoop(config: cfg)
do {
	try loop.run()
} catch {
	fputs("fatal: \(error)\n", stderr)
	exit(1)
}
