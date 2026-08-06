import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: String
    var content: String
}
