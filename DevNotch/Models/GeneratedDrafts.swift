import Foundation

enum CommitType: String, Codable, CaseIterable {
    case feat, fix, docs, style, refactor, perf, test, chore, build, ci, revert
}

struct CommitDraft: Decodable {
    let type: CommitType
    let scope: String
    let summary: String
    let body: String
    let breakingChange: String

    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "type": ["type": "string", "enum": CommitType.allCases.map(\.rawValue)],
            "scope": ["type": "string"],
            "summary": ["type": "string"],
            "body": ["type": "string"],
            "breakingChange": ["type": "string"]
        ],
        "required": ["type", "scope", "summary", "body", "breakingChange"]
    ]

    var subjectLine: String {
        renderedMessage.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    var renderedMessage: String {
        var header = type.rawValue

        let cleanScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanScope.isEmpty {
            header += "(\(cleanScope))"
        }

        var subject = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        while subject.count > 1 && subject.hasSuffix(".") {
            subject.removeLast()
        }
        if let first = subject.first, first.isUppercase {
            subject.replaceSubrange(subject.startIndex...subject.startIndex, with: first.lowercased())
        }
        header += ": \(subject)"

        var parts = [header]

        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanBody.isEmpty {
            parts.append(cleanBody)
        }

        let breaking = breakingChange.trimmingCharacters(in: .whitespacesAndNewlines)
        if !breaking.isEmpty {
            parts.append("BREAKING CHANGE: \(breaking)")
        }

        return parts.joined(separator: "\n\n")
    }
}

enum VersionBump: String, CaseIterable, Hashable {
    case major
    case minor
    case patch
}

/// A commit subject decomposed according to the Conventional Commits grammar.
/// The prefix already encodes the classification, so nothing about it needs to
/// be inferred by a language model.
struct ParsedCommit: Equatable {
    let subject: String
    let type: CommitType?
    let scope: String?
    let description: String
    let isBreaking: Bool

    private static let grammar: NSRegularExpression = {
        // <type>[(<scope>)][!]: <description>
        try! NSRegularExpression(pattern: #"^([a-zA-Z]+)(?:\(([^)]*)\))?(!)?:\s*(.+)$"#)
    }()

    static func parse(subject: String, body: String = "") -> ParsedCommit {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let breakingFooter = body.contains("BREAKING CHANGE")

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = Self.grammar.firstMatch(in: trimmed, range: range) else {
            return ParsedCommit(
                subject: trimmed,
                type: nil,
                scope: nil,
                description: trimmed,
                isBreaking: breakingFooter
            )
        }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: trimmed) else { return nil }
            return String(trimmed[range])
        }

        return ParsedCommit(
            subject: trimmed,
            type: group(1).map { $0.lowercased() }.flatMap(CommitType.init(rawValue:)),
            scope: group(2),
            description: group(4) ?? trimmed,
            isBreaking: group(3) != nil || breakingFooter
        )
    }
}

enum ChangelogCategory: String, CaseIterable {
    case added = "Added"
    case fixed = "Fixed"
    case performance = "Performance"
    case changed = "Changed"
    case other = "Other"

    static func category(for type: CommitType?) -> ChangelogCategory {
        switch type {
        case .feat: return .added
        case .fix: return .fixed
        case .perf: return .performance
        case .refactor, .style, .docs, .build, .ci, .chore: return .changed
        case .revert, .test, .none: return .other
        }
    }
}

struct ChangelogSection: Equatable, Identifiable {
    let category: ChangelogCategory
    let entries: [String]

    var id: String { category.rawValue }
    var title: String { category.rawValue }
}

/// What the model is asked for: one readable sentence per commit, nothing else.
struct ReleaseNotesDraft: Decodable {
    let entries: [String]

    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "entries": ["type": "array", "items": ["type": "string"]]
        ],
        "required": ["entries"]
    ]
}

struct ReleaseNotes: Equatable {
    let sections: [ChangelogSection]

    var markdown: String {
        guard !sections.isEmpty else { return "No user-facing changes in this release." }

        return sections
            .map { section in
                (["### \(section.title)"] + section.entries.map { "- \($0)" }).joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    /// Groups rewritten entries by the type parsed from each commit. Falls back to the
    /// raw commit descriptions when the model returns a different number of entries
    /// than there are commits, which small models occasionally do.
    static func build(commits: [ParsedCommit], rewritten: [String]) -> ReleaseNotes {
        let texts = rewritten.count == commits.count
            ? rewritten
            : commits.map(\.description)

        var buckets: [ChangelogCategory: [String]] = [:]

        for (commit, text) in zip(commits, texts) {
            let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            buckets[ChangelogCategory.category(for: commit.type), default: []].append(entry)
        }

        let sections = ChangelogCategory.allCases.compactMap { category -> ChangelogSection? in
            guard let entries = buckets[category], !entries.isEmpty else { return nil }
            return ChangelogSection(category: category, entries: entries)
        }

        return ReleaseNotes(sections: sections)
    }

    static func bump(for commits: [ParsedCommit]) -> VersionBump {
        if commits.contains(where: \.isBreaking) { return .major }
        if commits.contains(where: { $0.type == .feat }) { return .minor }
        return .patch
    }
}

struct SemanticVersion: Equatable {
    var major: Int
    var minor: Int
    var patch: Int

    var tagName: String { "v\(major).\(minor).\(patch)" }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(tag: String) {
        let withoutPrefix = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let core = withoutPrefix.split(separator: "-", maxSplits: 1).first.map(String.init) ?? withoutPrefix
        let parts = core.split(separator: ".")

        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }

        self.init(major: major, minor: minor, patch: patch)
    }

    func bumped(_ bump: VersionBump) -> SemanticVersion {
        switch bump {
        case .major:
            return SemanticVersion(major: major + 1, minor: 0, patch: 0)
        case .minor:
            return SemanticVersion(major: major, minor: minor + 1, patch: 0)
        case .patch:
            return SemanticVersion(major: major, minor: minor, patch: patch + 1)
        }
    }

    static func next(after lastTag: String?, bump: VersionBump) -> SemanticVersion {
        guard let lastTag, let current = SemanticVersion(tag: lastTag) else {
            return SemanticVersion(major: 0, minor: 1, patch: 0)
        }
        return current.bumped(bump)
    }
}
