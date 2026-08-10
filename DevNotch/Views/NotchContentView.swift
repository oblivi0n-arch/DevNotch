import SwiftUI

private struct PulseKey: Equatable {
    let branch: String
    let lastCommitSubject: String
    let aheadCount: Int
    let behindCount: Int
    let operation: GitOperation
}

struct NotchContentView: View {
    @ObservedObject private var appModeService: AppModeService
    @ObservedObject private var gitService: GitStatusService

    @State private var isHoverExpanded = false
    @State private var isPulsing = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var pulseTask: Task<Void, Never>?

    private let notchWidth: CGFloat
    private let notchHeight: CGFloat

    private let expandedWidth: CGFloat = 300
    private let collapsedHeight: CGFloat = 32
    private let collapsedDotOverhang: CGFloat = 28

    private let pulseDuration: Duration = .seconds(2)
    private let hoverOpenDelay: Duration = .milliseconds(120)
    private let hoverCloseDelay: Duration = .milliseconds(180)

    private let collapsedHoverPadding: CGFloat = 18
    private let expandedHoverPadding: CGFloat = 14

    init(notchWidth: CGFloat, notchHeight: CGFloat, appModeService: AppModeService, gitService: GitStatusService) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.appModeService = appModeService
        self.gitService = gitService
    }

    // MARK: - Derived state

    private var status: GitStatus { gitService.status }

    private var isIdle: Bool { !status.isValidRepo }

    private var isExpanded: Bool { isHoverExpanded || isPulsing }

    private var hoverAreaWidth: CGFloat {
        isExpanded ? expandedWidth + expandedHoverPadding : collapsedWidth + collapsedHoverPadding
    }

    private var hoverAreaHeight: CGFloat {
        isExpanded ? expandedHeight + expandedHoverPadding : collapsedHeight + 6
    }

    private var pulseKey: PulseKey {
        PulseKey(
            branch: status.branch,
            lastCommitSubject: status.lastCommitSubject,
            aheadCount: status.aheadCount,
            behindCount: status.behindCount,
            operation: status.operation
        )
    }

    private var collapsedWidth: CGFloat {
        if isIdle {
            return notchWidth > 0 ? notchWidth : 40
        }
        return notchWidth > 0 ? notchWidth + collapsedDotOverhang : 60
    }

    private var expandedHeight: CGFloat {
        max(118, notchHeight + 100)
    }

    private var workingTreeColor: Color {
        if status.conflictedCount > 0 || status.operation != .none { return .red }
        if status.isDirty { return .orange }
        return .green
    }

    private var remoteStatusColor: Color {
        if status.behindCount > 0 && status.isDirty { return .orange }
        if status.behindCount > 0 { return .purple }
        if status.aheadCount > 0 { return .blue }
        return .green
    }

    private var remoteStatusShortLabel: String {
        var parts: [String] = []
        if status.aheadCount > 0 { parts.append("↑\(status.aheadCount)") }
        if status.behindCount > 0 { parts.append("↓\(status.behindCount)") }
        return parts.joined(separator: " ")
    }

    private var changeSummary: [(symbol: String, count: Int, color: Color)] {
        var parts: [(String, Int, Color)] = []
        if status.conflictedCount > 0 { parts.append(("exclamationmark.triangle.fill", status.conflictedCount, .red)) }
        if status.stagedCount > 0 { parts.append(("plus.square.fill", status.stagedCount, .green)) }
        if status.modifiedCount > 0 { parts.append(("pencil", status.modifiedCount, .orange)) }
        if status.untrackedCount > 0 { parts.append(("questionmark.square", status.untrackedCount, .gray)) }
        return parts
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(width: hoverAreaWidth, height: hoverAreaHeight)
                .contentShape(Rectangle())
                .onHover(perform: handleHover)

            ZStack {
                Color.black

                if isExpanded {
                    expandedContent
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: -6))
                                    .animation(.easeOut(duration: 0.2).delay(0.08)),
                                removal: .opacity
                                    .animation(.easeIn(duration: 0.09))
                            )
                        )
                } else {
                    collapsedContent
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                                removal: .opacity.animation(.easeIn(duration: 0.08))
                            )
                        )
                }
            }
            .frame(
                width: isExpanded ? expandedWidth : collapsedWidth,
                height: isExpanded ? expandedHeight : collapsedHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 18 : 10))
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isExpanded)
            .allowsHitTesting(false)
        }
        .frame(width: 320, height: expandedHeight, alignment: .top)
        .onChange(of: pulseKey) { oldValue, newValue in
            guard !oldValue.branch.isEmpty || !newValue.branch.isEmpty else { return }
            triggerPulse()
        }
        .onDisappear {
            hoverTask?.cancel()
            pulseTask?.cancel()
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        guard hovering != isHoverExpanded else { return }

        hoverTask = Task {
            try? await Task.sleep(for: hovering ? hoverOpenDelay : hoverCloseDelay)
            guard !Task.isCancelled else { return }
            isHoverExpanded = hovering
        }
    }

    private func triggerPulse() {
        pulseTask?.cancel()
        isPulsing = true
        pulseTask = Task {
            try? await Task.sleep(for: pulseDuration)
            guard !Task.isCancelled else { return }
            isPulsing = false
        }
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        ZStack {
            if !isIdle {
                Circle()
                    .fill(workingTreeColor)
                    .frame(width: 6, height: 6)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if status.hasUpstream {
                    Circle()
                        .fill(remoteStatusColor)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if status.isValidRepo {
                branchRow
                changesRow
                lastCommitRow
                Spacer(minLength: 0)
                tagRow
            } else {
                Text("No repo detected in active Terminal / Xcode")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
                    .padding(.top, notchHeight)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var branchRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(workingTreeColor)
                .frame(width: 8, height: 8)

            Text(status.branch)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if status.hasUpstream {
                HStack(spacing: 4) {
                    if !remoteStatusShortLabel.isEmpty {
                        Text(remoteStatusShortLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                    Circle()
                        .fill(remoteStatusColor)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.top, notchHeight)
    }

    @ViewBuilder
    private var changesRow: some View {
        if let operationLabel = status.operation.label {
            HStack(spacing: 5) {
                Text(operationLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.85), in: Capsule())

                if !status.operationProgress.isEmpty {
                    Text(status.operationProgress)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.gray)
                }

                Spacer(minLength: 0)
            }
        } else if status.isDirty {
            HStack(spacing: 12) {
                ForEach(changeSummary, id: \.symbol) { item in
                    HStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(item.color)
                        Text("\(item.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            Text("Working tree clean")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
        }
    }

    @ViewBuilder
    private var lastCommitRow: some View {
        if !status.lastCommitSubject.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(status.lastCommitSubject)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(status.lastCommitRelative)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
        }
    }

    private var tagRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "tag.fill")
                .font(.system(size: 9))
            Text(status.lastTag)
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.gray)
    }
}
