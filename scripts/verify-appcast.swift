#!/usr/bin/env swift
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Verify with the public key embedded in the tagged source, without CI secrets.
enum Invalid: Error { case feed(String) }
func require(_ valid: Bool, _ message: String) throws {
    if !valid { throw Invalid.feed(message) }
}
do {
    guard CommandLine.arguments.count == 4 else { throw Invalid.feed("Expected feed, archive and Info.plist paths.") }
    let feed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let archive = try Data(contentsOf: archiveURL)
    let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])), format: nil) as! [String: Any]
    guard let keyText = info["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: keyText),
          let version = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String,
          let marker = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
          let end = feed.range(of: Data("-->".utf8), in: marker.upperBound..<feed.endIndex),
          let block = String(data: feed[marker.upperBound..<end.lowerBound], encoding: .utf8)
    else { throw Invalid.feed("Missing signing information.") }
    let fields = block.split(separator: "\n").reduce(into: [String: String]()) { fields, line in
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    let content = Data(feed[..<marker.lowerBound])
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard let signature = fields["edSignature"].flatMap({ Data(base64Encoded: $0) }) else {
        throw Invalid.feed("Missing feed signature.")
    }
    try require(Int(fields["length"] ?? "") == content.count, "Feed length differs.")
    try require(key.isValidSignature(signature, for: content), "Feed signature is invalid.")
    let xml = try XMLDocument(data: content, options: [.nodeLoadExternalEntitiesNever])
    let items = try xml.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Expected exactly one release in the feed.")
    guard let item = items.first as? XMLElement,
          let enclosure = item.elements(forName: "enclosure").first,
          let archiveSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) })
    else { throw Invalid.feed("Missing signed update enclosure.") }
    try require(item.elements(forName: "sparkle:version").first?.stringValue == build, "Wrong update build.")
    try require(item.elements(forName: "sparkle:shortVersionString").first?.stringValue == version, "Wrong update version.")
    try require(enclosure.attribute(forName: "url")?.stringValue == "https://github.com/basique-industrie/harnais/releases/download/v\(version)/\(archiveURL.lastPathComponent)", "Unexpected download URL.")
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "Archive length differs.")
    try require(key.isValidSignature(archiveSignature, for: archive), "Archive signature is invalid.")
    print("Verified signed appcast and archive for Harnais \(version) (\(build)).")
} catch {
    fputs("Update verification failed: \(error)\n", stderr)
    exit(1)
}
