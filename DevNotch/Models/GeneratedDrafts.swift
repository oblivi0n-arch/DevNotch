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

struct TagDraft: Decodable {
    enum Bump: String, Decodable {
        case major, minor, patch
    }

    let bump: Bump
    let added: [String]
    let fixed: [String]
    let performance: [String]
    let changed: [String]
    let other: [String]

    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "bump": ["type": "string", "enum": ["major", "minor", "patch"]],
            "added": ["type": "array", "items": ["type": "string"]],
            "fixed": ["type": "array", "items": ["type": "string"]],
            "performance": ["type": "array", "items": ["type": "string"]],
            "changed": ["type": "array", "items": ["type": "string"]],
            "other": ["type": "array", "items": ["type": "string"]]
        ],
        "required": ["bump", "added", "fixed", "performance", "changed", "other"]
    ]

    var changelog: String {
        let sections: [(heading: String, entries: [String])] = [
            ("### Added", added),
            ("### Fixed", fixed),
            ("### Performance", performance),
            ("### Changed", changed),
            ("### Other", other)
        ]

        let rendered = sections
            .filter { !$0.entries.isEmpty }
            .map { section in
                ([section.heading] + section.entries.map { "- \($0)" }).joined(separator: "\n")
            }

        return rendered.isEmpty
            ? "No user-facing changes in this release."
            : rendered.joined(separator: "\n\n")
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

    func bumped(_ bump: TagDraft.Bump) -> SemanticVersion {
        switch bump {
        case .major:
            return major == 0
                ? SemanticVersion(major: 0, minor: minor + 1, patch: 0)
                : SemanticVersion(major: major + 1, minor: 0, patch: 0)
        case .minor:
            return SemanticVersion(major: major, minor: minor + 1, patch: 0)
        case .patch:
            return SemanticVersion(major: major, minor: minor, patch: patch + 1)
        }
    }

    static func next(after lastTag: String?, bump: TagDraft.Bump) -> SemanticVersion {
        guard let lastTag, let current = SemanticVersion(tag: lastTag) else {
            return SemanticVersion(major: 0, minor: 1, patch: 0)
        }
        return current.bumped(bump)
    }
}
