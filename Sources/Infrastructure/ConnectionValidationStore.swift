import Domain
import Foundation

/// Results of explicit live checks. Configuration presence is never treated as a successful check.
public struct ConnectionValidationStore: Sendable {
    public var identity: AppIdentity
    public init(identity: AppIdentity = .current) { self.identity = identity }

    public struct Report: Decodable, Sendable {
        public var checkedAt: Date
        public var results: [Result]
    }
    public struct Result: Decodable, Sendable {
        public var accountID: UUID
        public var status: String
        public var readCall: String?
        public var reason: String?
        public var queryTool: String?
        public var queryDurationMS: Int?
        public var queryLabel: String? {
            guard let queryTool else { return nil }
            return ["list_datasources": "List Grafana datasources", "list_recent_files": "List recent Drive files",
                    "gmail_list_messages": "List Gmail messages", "outlook_list_messages": "List Outlook messages",
                    "getAccessibleAtlassianResources": "List Atlassian sites", "slack_search_emojis": "Search Slack emoji",
                    "aikido_issues_list": "List Aikido issues", "read_me": "Read Excalidraw guide",
                    "describe_scene": "Read canvas scene", "whatsapp_list_chats": "List WhatsApp chats",
                    "whatsapp_list_documents": "List WhatsApp documents", "whatsapp_status": "Check WhatsApp link",
                    "whatsapp_read_document": "Read WhatsApp document"][queryTool] ?? queryTool
        }
    }

    public func report(for connection: IntegrationConnection) -> Report? {
        let file = identity.dataDirectory.appendingPathComponent("connection-checks/\(connection.id.uuidString).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file), let report = try? decoder.decode(Report.self, from: data),
              report.checkedAt >= (connection.lastLoginAt ?? .distantPast) else { return nil }
        return report
    }
}
