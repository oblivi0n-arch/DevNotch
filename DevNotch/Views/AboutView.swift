import SwiftUI
import Combine

struct Contributor: Identifiable, Codable {
    let id: Int
    let login: String
    let avatarUrl: String
    let contributions: Int
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case id, login, contributions
        case avatarUrl = "avatar_url"
        case htmlUrl = "html_url"
    }
}

@MainActor
final class ContributorsStore: ObservableObject {
    @Published var contributors: [Contributor] = []
    @Published var isLoading = false

    func load(owner: String, repo: String) async {
        isLoading = true
        defer { isLoading = false }
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contributors?per_page=100") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            contributors = try JSONDecoder()
                .decode([Contributor].self, from: data)
                .sorted { $0.contributions > $1.contributions }
        } catch {
            print("Failed to fetch contributors: \(error)")
        }
    }
}

struct AboutView: View {
    @StateObject private var store = ContributorsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Bundle.main.appName)
                        .font(.system(size: 15, weight: .semibold))
                    Text("Version \(Bundle.main.appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Contributors")
                .font(.system(size: 13, weight: .semibold))

            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if store.contributors.isEmpty {
                Text("Failed to load contributors")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 12) {
                    ForEach(store.contributors) { c in
                        Link(destination: URL(string: c.htmlUrl)!) {
                            VStack(spacing: 4) {
                                AsyncImage(url: URL(string: c.avatarUrl)) { $0.resizable() }
                                    placeholder: { Circle().fill(Color.secondary.opacity(0.2)) }
                                    .frame(width: 40, height: 40)
                                    .clipShape(Circle())
                                Text(c.login)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 340)
        .task { await store.load(owner: "oblivi0n-arch", repo: "DevNotch") }
    }
}

extension Bundle {
    var appName: String { object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App" }
    var appVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var buildNumber: String { object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
}
