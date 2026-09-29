import Domain
import Foundation

/// Uploads complete revised bytes without creating, converting, renaming or moving the file.
enum DriveFileReplacement {
    static let limit = 16 * 1024 * 1024
    static func call(_ args: [String: Any], metadata: [String: Any], send: (URLRequest) throws -> Data) throws -> [String: Any] {
        func fail(_ message: String) -> HarnaisError { .processFailed(message) }
        let id = try DriveMCPServer.identifier(args["fileId"])
        guard let mime = metadata["mimeType"] as? String, !mime.hasPrefix("application/vnd.google-apps.") else {
            throw fail("Use the native Sheets, Docs or Slides editing tools for Google-native files. Folders and shortcuts cannot receive replacement content.")
        }
        guard metadata["trashed"] as? Bool != true else { throw fail("Restore the file from trash before replacing its content.") }
        guard (metadata["capabilities"] as? [String: Any])?["canEdit"] as? Bool != false else { throw fail("You do not have edit permission for this file.") }
        if let expected = args["expectedVersion"] {
            guard let expected = expected as? String, expected == metadata["version"] as? String else { throw fail("The file changed since it was read. Download the current version and merge your changes before replacing it.") }
        }
        if let requested = args["contentMimeType"] {
            guard let requested = requested as? String, requested == mime else { throw fail("Replacement content must have the file's existing MIME type: \(mime). This tool does not convert files.") }
        }
        guard mime.range(of: #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#, options: .regularExpression) != nil else { throw fail("Invalid file MIME type.") }
        guard ["base64Content", "textContent", "localPath"].filter({ args[$0] != nil }).count == 1 else { throw fail("Provide exactly one of localPath, base64Content or textContent.") }
        let bytes: Data
        if let path = args["localPath"] {
            guard let path = path as? String else { throw fail("localPath must be an absolute file path on this Mac.") }
            bytes = try DriveLocalFiles.read(path)
        } else if let encoded = args["base64Content"] {
            guard let encoded = encoded as? String, encoded.utf8.count <= ((limit + 2) / 3) * 4,
                  let decoded = Data(base64Encoded: encoded), decoded.count <= limit else { throw fail("Provide valid base64 content of at most 16 MB.") }
            bytes = decoded
        } else {
            guard mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime),
                  let text = args["textContent"] as? String, text.utf8.count <= limit else { throw fail("textContent is only for text, JSON or XML files up to 16 MB. Use base64Content for Office files.") }
            bytes = Data(text.utf8)
        }
        var url = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files/" + id)!
        let resumable = bytes.count > 5 * 1024 * 1024
        url.queryItems = [URLQueryItem(name: "uploadType", value: resumable ? "resumable" : "media"), URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "fields", value: DriveMCPServer.fields)]
        var request = URLRequest(url: url.url!); request.httpMethod = "PATCH"
        if resumable {
            request.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(bytes.count), forHTTPHeaderField: "X-Upload-Content-Length")
            guard let session = try JSONSerialization.jsonObject(with: send(request)) as? [String: Any],
                  let location = session["uploadURL"] as? String, let sessionURL = URL(string: location),
                  GoogleWorkspaceTransport.isAllowed(sessionURL), sessionURL.path == url.path,
                  URLComponents(url: sessionURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "upload_id" && $0.value?.isEmpty == false }) == true else { throw fail("Google did not return a valid resumable upload session.") }
            request = URLRequest(url: sessionURL); request.httpMethod = "PUT"
        }
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = bytes
        guard let result = try JSONSerialization.jsonObject(with: send(request)) as? [String: Any], result["id"] as? String == id else { throw fail("Unexpected upload response. Check the file before retrying the replacement.") }
        return result
    }
}
