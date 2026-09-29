import AppKit
import Domain
import Foundation
import Infrastructure

enum DriveReaderTests {
    static func run(root: URL, expect: (Bool, String) -> Void) throws {
        func package(_ files: [String: String]) throws -> Data {
            let folder = root.appendingPathComponent("reader-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, text) in files {
                let file = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
            let archive = folder.appendingPathComponent("fixture.zip")
            let result = try ProcessRunner().run(executable: "/usr/bin/zip", arguments: ["-q", "-r", archive.path, "."], environment: ["PATH": "/usr/bin:/bin"], timeout: 10, workingDirectory: folder)
            guard result.exitCode == 0 else { throw HarnaisError.processFailed("Could not build ZIP fixture") }
            return try Data(contentsOf: archive)
        }
        let workbook = try package([
            "xl/workbook.xml": "<workbook xmlns:r='urn:r'><sheets><sheet name='First' r:id='r1'/><sheet name='Hidden data' state='hidden' r:id='r2'/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id='r1' Target='worksheets/sheet1.xml'/><Relationship Id='r2' Target='/xl/worksheets/sheet2.xml'/></Relationships>",
            "xl/sharedStrings.xml": "<sst><si><t>Revenue</t></si></sst>",
            "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row><c r='A1' t='s'><v>0</v></c><c r='B1'><f>SUM(B2:B3)</f><v>42</v></c></row></sheetData></worksheet>",
            "xl/worksheets/sheet2.xml": "<worksheet><sheetData><row><c r='C8' t='inlineStr'><is><t>Hidden fixture</t></is></c></row></sheetData></worksheet>"
        ])
        let text = try DriveContentReader.read(workbook, mime: DriveContentReader.xlsx)
        expect(text.contains("A1: Revenue") && text.contains("B1: 42 [formula: =SUM(B2:B3)]"), "Excel read preserves cell addresses, values and formulas")
        expect(text.contains("Hidden data, hidden") && text.contains("C8: Hidden fixture"), "Excel read includes all worksheets and hidden cells")
        let read = try DriveMCPServer.call("read_file_content", ["fileId": "fixture"]) { request in
            if request.url!.path.hasSuffix("/export") {
                expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == DriveContentReader.xlsx, "Google Sheets reads export XLSX instead of PDF")
                return workbook
            }
            return Data(#"{"mimeType":"application/vnd.google-apps.spreadsheet","name":"Fixture"}"#.utf8)
        }
        expect((read["content"] as? String)?.contains("Hidden fixture") == true, "Drive tools expose full workbook reader")
        let doc = try package(["word/document.xml": "<w:document xmlns:w='urn:w'><w:p><w:r><w:t>Word fixture</w:t></w:r></w:p></w:document>"])
        expect(try DriveContentReader.read(doc, mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document").contains("Word fixture"), "binary Word content is readable")
        let slides = try package(["ppt/slides/slide2.xml": "<slide xmlns:a='urn:a'><a:p><a:r><a:t>Second slide</a:t></a:r></a:p></slide>", "ppt/slides/slide10.xml": "<slide xmlns:a='urn:a'><a:p><a:r><a:t>Tenth slide</a:t></a:r></a:p></slide>"])
        let presentation = try DriveContentReader.read(slides, mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        expect(presentation.range(of: "Second slide")!.lowerBound < presentation.range(of: "Tenth slide")!.lowerBound, "PowerPoint slide numbers sort numerically")
        let openDoc = try package(["content.xml": "<office:document xmlns:office='urn:office' xmlns:text='urn:text'><text:p>Hello <text:span>OpenDocument</text:span>.</text:p></office:document>"])
        expect(try DriveContentReader.read(openDoc, mime: "application/vnd.oasis.opendocument.text") == "Hello OpenDocument.", "OpenDocument retains mixed text order")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 140, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 140).fill()
        ("HARNAIS READER FIXTURE" as NSString).draw(at: NSPoint(x: 25, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        expect(try DriveContentReader.read(png, mime: "image/png").contains("HARNAIS READER FIXTURE"), "image OCR reads local PNG text")
        let hostile = try package(["word/document.xml": "<!DOCTYPE doc [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><doc><p><t>&secret;</t></p></doc>"])
        expect((try? DriveContentReader.read(hostile, mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")) == nil, "Office XML rejects entity declarations")
        expect((try? DriveContentReader.read(Data([1,2,3]), mime: DriveContentReader.xlsx)) == nil, "invalid Office packages fail explicitly")
    }
}
