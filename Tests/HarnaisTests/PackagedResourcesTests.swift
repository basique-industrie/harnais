import Foundation
@testable import HarnaisCore

enum PackagedResourcesTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        let app = root.appendingPathComponent("Harnais.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources/Harnais_HarnaisCore.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.example.harnais-resource-test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("fixture".utf8).write(to: resources.appendingPathComponent("mark.txt"))
        guard let application = Bundle(url: app) else {
            expect(false, "packaged app fixture loads")
            return
        }
        var evaluatedFallback = false
        func fallback() -> Bundle {
            evaluatedFallback = true
            return Bundle.main
        }
        let packaged = HarnaisResourceBundle.resolve(applicationBundle: application, moduleBundle: fallback())
        expect(!evaluatedFallback, "installed app never evaluates the build-machine resource fallback")
        expect(packaged.url(forResource: "mark", withExtension: "txt") != nil, "installed app reads its packaged resources")
        let missing = root.appendingPathComponent("Missing.app/Contents")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: missing.appendingPathComponent("Info.plist"))
        guard let missingApplication = Bundle(url: missing.deletingLastPathComponent()) else {
            expect(false, "missing-resource app fixture loads")
            return
        }
        let resolvedFallback = HarnaisResourceBundle.resolve(applicationBundle: missingApplication, moduleBundle: fallback())
        expect(evaluatedFallback && resolvedFallback == Bundle.main, "development builds resolve the module only when packaged resources are absent")
    }
}
