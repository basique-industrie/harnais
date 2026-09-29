import AppKit
import Darwin
import Domain
import Foundation
import PDFKit
import Vision

/// Reads downloaded bytes locally. Office packages are never unpacked to disk or executed.
public enum DriveContentReader {
    public static let xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    public static func read(_ data: Data, mime: String) throws -> String {
        guard data.count <= 16 * 1024 * 1024 else { throw failure("File exceeds the 16 MB reader limit.") }
        if mime.hasPrefix("text/") || ["application/json", "application/xml", "application/javascript"].contains(mime) {
            guard let text = String(data: data, encoding: .utf8) else { throw failure("This text file is not UTF-8. Download the original to inspect its encoding.") }
            return text
        }
        if mime == "application/pdf" {
            guard let pdf = PDFDocument(data: data) else { throw failure("Could not decode this PDF.") }
            var pages: [String] = []
            for index in 0..<min(pdf.pageCount, 100) {
                guard let page = pdf.page(at: index) else { continue }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { pages.append("[Page \(index + 1)]\n" + text) }
                else if index < 30, let image = page.thumbnail(of: NSSize(width: 1600, height: 2200), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    pages.append("[Page \(index + 1), OCR]\n" + (try recognize(image)))
                } else { pages.append("[Page \(index + 1): no selectable text; OCR page limit reached]") }
            }
            if pdf.pageCount > 100 { pages.append("[Truncated after 100 pages]") }
            return pages.joined(separator: "\n\n")
        }
        if mime.hasPrefix("image/") {
            guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw failure("Could not decode this image.") }
            return "[Image text, OCR; visual layout and non-text content are not described]\n" + (try recognize(image))
        }
        if mime == "application/msword" || mime == "application/rtf" {
            return try withFile(data) { file in
                String(decoding: try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", "-format", mime == "application/msword" ? "doc" : "rtf", file.path]), as: UTF8.self)
            }
        }
        let supported = [xlsx, "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/vnd.oasis.opendocument.spreadsheet", "application/vnd.oasis.opendocument.presentation", "application/vnd.oasis.opendocument.text", "application/x-vnd.oasis.opendocument.text"]
        guard supported.contains(mime) else { throw failure("Text extraction is unavailable for this type. Use download_file_content for the original file.") }
        return try withFile(data) { file in
            let names = String(decoding: try run("/usr/bin/unzip", ["-Z1", file.path]), as: UTF8.self).split(separator: "\n").map(String.init)
            guard names.count <= 10_000, Set(names).count == names.count else { throw failure("Office package has too many or duplicate members.") }
            var total = 0
            func xml(_ name: String) throws -> XMLNodeValue {
                guard names.contains(name), !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.contains(where: { "*?[]\\".contains($0) }) else { throw failure("Invalid Office package member.") }
                let content = try run("/usr/bin/unzip", ["-p", file.path, name])
                total += content.count
                guard total <= 32 * 1024 * 1024 else { throw failure("Office package exceeds the expanded reader limit.") }
                return try parseXML(content)
            }
            if mime == xlsx {
                let workbook = try xml("xl/workbook.xml")
                let relationships = try xml("xl/_rels/workbook.xml.rels").descendants("Relationship")
                let strings = names.contains("xl/sharedStrings.xml") ? try xml("xl/sharedStrings.xml").descendants("si").map { $0.descendants("t").map(\.text).joined() } : []
                var output: [String] = []
                for sheet in workbook.descendants("sheet") {
                    guard let relation = relationships.first(where: { $0.attributes["Id"] == sheet.attributes["r:id"] }), relation.attributes["TargetMode"] != "External", let target = relation.attributes["Target"] else { continue }
                    let path = target.hasPrefix("/") ? String(target.dropFirst()) : URL(fileURLWithPath: "/xl/" + target).standardizedFileURL.path.dropFirst().description
                    let document = try xml(path)
                    output.append("[Sheet: \(sheet.attributes["name"] ?? "Untitled")\(sheet.attributes["state"].map { ", " + $0 } ?? "")]")
                    for cell in document.descendants("c") {
                        let raw = cell.children.first { $0.name == "v" }?.text ?? ""
                        let type = cell.attributes["t"] ?? ""
                        var value = type == "inlineStr" ? cell.descendants("t").map(\.text).joined() : raw
                        if type == "s", let index = Int(raw), strings.indices.contains(index) { value = strings[index] }
                        if type == "b" { value = raw == "1" ? "TRUE" : "FALSE" }
                        if let formula = cell.children.first(where: { $0.name == "f" }) {
                            value += " [formula: =\(formula.text)\(formula.attributes["t"] == "shared" ? "; shared formula group \(formula.attributes["si"] ?? "")" : "")]"
                        }
                        if !value.isEmpty { output.append("\(cell.attributes["r"] ?? "cell"): \(value)") }
                        if output.count >= 50_000 { output.append("[Truncated after 50,000 cells]"); return output.joined(separator: "\n") }
                    }
                }
                return output.joined(separator: "\n")
            }
            if mime.contains("wordprocessingml") {
                let files = names.filter { $0 == "word/document.xml" || $0.range(of: #"^word/(header[0-9]+|footer[0-9]+|footnotes|endnotes)\.xml$"#, options: .regularExpression) != nil }.sorted()
                return try files.map { name in
                    "[\(name)]\n" + (try xml(name)).descendants("p").map { $0.descendants("t").map(\.text).joined() }.joined(separator: "\n")
                }.joined(separator: "\n\n")
            }
            if mime.contains("presentationml") {
                let files = names.filter { $0.range(of: #"^ppt/(slides/slide|notesSlides/notesSlide)[0-9]+\.xml$"#, options: .regularExpression) != nil }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                return try files.map { name in "[\(name)]\n" + (try xml(name)).descendants("p").map { $0.descendants("t").map(\.text).joined() }.joined(separator: "\n") }.joined(separator: "\n\n")
            }
            let document = try xml("content.xml")
            if mime.contains("spreadsheet") {
                var lines: [String] = []
                for table in document.descendants("table") {
                    lines.append("[Sheet: \(table.attributes["table:name"] ?? "Untitled")]")
                    for (index, row) in table.descendants("table-row").enumerated() {
                        let cells = row.children.filter { $0.name == "table-cell" }.map { cell in
                            let paragraphs = cell.descendants("p").map(\.allText).joined(separator: " ")
                            let value = paragraphs.isEmpty ? cell.attributes["office:value"] ?? cell.attributes["office:date-value"] ?? "" : paragraphs
                            return value + (cell.attributes["table:formula"].map { " [formula: \($0)]" } ?? "") + (cell.attributes["table:number-columns-repeated"].map { " [repeated columns: \($0)]" } ?? "")
                        }
                        lines.append("Row \(index + 1)\(row.attributes["table:number-rows-repeated"].map { " [repeated rows: \($0)]" } ?? ""): " + cells.joined(separator: " | "))
                    }
                }
                return lines.joined(separator: "\n")
            }
            return document.descendants("p").map(\.allText).joined(separator: "\n")
        }
    }

    private static func recognize(_ image: CGImage) throws -> String {
        guard image.width <= 20_000, image.height <= 20_000, image.width * image.height <= 60_000_000 else { throw failure("Image dimensions exceed the OCR limit.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? "No text recognized."
    }
    private static func failure(_ text: String) -> HarnaisError { .processFailed(text) }
    private static func withFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("harnais-drive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("content")
        try data.write(to: file)
        return try body(file)
    }
    // Drain while running; cap output and time so compressed files cannot exhaust memory.
    private static func run(_ executable: String, _ args: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        try process.run()
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var result = Data(); let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            var fd = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&fd, 1, 100) > 0 {
                let part = pipe.fileHandleForReading.availableData
                if part.isEmpty {
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw failure("Could not decode this document package.") }
                    return result
                }
                result.append(part)
                guard result.count <= 8 * 1024 * 1024 else { throw failure("Document member exceeds the 8 MB reader limit.") }
            }
        }
        throw failure("Document conversion timed out.")
    }
    private static func parseXML(_ data: Data) throws -> XMLNodeValue {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data); parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard !String(decoding: data, as: UTF8.self).contains("<!DOCTYPE"), parser.parse(), let root = builder.root else { throw failure("Invalid Office XML.") }
        return root
    }
}

private final class XMLNodeValue {
    let name: String
    let attributes: [String: String]
    var text = ""
    var allText = ""
    var children: [XMLNodeValue] = []
    init(_ name: String, _ attributes: [String: String]) { self.name = name.split(separator: ":").last.map(String.init) ?? name; self.attributes = attributes }
    func descendants(_ name: String) -> [XMLNodeValue] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
}
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNodeValue?
    var stack: [XMLNodeValue] = []
    var count = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 100, count <= 200_000 else { parser.abortParsing(); return }
        let node = XMLNodeValue(elementName, attributes)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string; for node in stack { node.allText += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
}
