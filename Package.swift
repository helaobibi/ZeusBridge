// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "ZeusBridge",
	platforms: [
		.macOS(.v13)
	],
	products: [
		.executable(name: "ZeusBridge", targets: ["ZeusBridge"])
	],
	targets: [
		.executableTarget(
			name: "ZeusBridge",
			path: "Sources/ZeusBridge"
		)
	]
)
