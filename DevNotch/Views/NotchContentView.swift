import SwiftUI

struct NotchContentView: View {
    @ObservedObject private var appModeService: AppModeService
    @ObservedObject private var gitService: GitStatusService
    @StateObject private var buildMonitor: BuildMonitorService
    @State private var isHovered = false
    
    private var isExpanded: Bool {
        isHovered || buildMonitor.status.isBuilding
    }

    private let hitAreaWidth: CGFloat = 280

    private let notchWidth: CGFloat
    private let notchHeight: CGFloat

    private let collapsedDotOverhang: CGFloat = 28

    private var isIdle: Bool {
        !gitService.status.isValidRepo
    }

    private var collapsedWidth: CGFloat {
        if isIdle {
            return notchWidth > 0 ? notchWidth : 40
        }
        return notchWidth > 0 ? notchWidth + collapsedDotOverhang : 60
    }

    private var expandedHeight: CGFloat {
        notchHeight > 0 ? max(100, notchHeight + 65) : 100
    }
    
    private var remoteStatusColor: Color {
        let ahead = gitService.status.aheadCount
        let behind = gitService.status.behindCount
        if behind > 0 { return .purple }
        if ahead > 0 { return .blue }
        return .green
    }

    private var remoteStatusShortLabel: String {
        let ahead = gitService.status.aheadCount
        let behind = gitService.status.behindCount
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " ")
    }

    init(notchWidth: CGFloat, notchHeight: CGFloat, appModeService: AppModeService, gitService: GitStatusService) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.appModeService = appModeService
        self.gitService = gitService
        _buildMonitor = StateObject(wrappedValue: BuildMonitorService(appModeService: appModeService))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(width: hitAreaWidth, height: expandedHeight)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }

            ZStack {
                Color.black

                if isExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                } else {
                    collapsedContent
                        .transition(.opacity)
                }
            }
            .frame(
                width: isExpanded ? 280 : collapsedWidth,
                height: isExpanded ? expandedHeight : 32
            )
            .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 16 : 10))
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isExpanded)
            .allowsHitTesting(false)
        }
        .frame(width: 320, height: 100, alignment: .top)
        .onAppear {
            buildMonitor.start()
        }
    }

    private var collapsedContent: some View {
        ZStack {
            if !isIdle {
                Circle()
                    .fill(gitService.status.uncommittedChanges > 0 ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if gitService.status.hasUpstream {
                    Circle()
                        .fill(remoteStatusColor)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if gitService.status.isValidRepo {
                HStack {
                    Circle()
                        .fill(gitService.status.uncommittedChanges > 0 ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(gitService.status.branch)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    if gitService.status.hasUpstream {
                        HStack(spacing: 4) {
                            if gitService.status.aheadCount > 0 || gitService.status.behindCount > 0 {
                                Text(remoteStatusShortLabel)
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                            }
                            Circle()
                                .fill(remoteStatusColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .padding(.top, notchHeight)
                HStack(spacing: 14) {
                    Label("\(gitService.status.uncommittedChanges)", systemImage: "pencil")
                    Label(gitService.status.lastTag, systemImage: "tag.fill")
                }
                .font(.system(size: 11))
                .foregroundColor(.gray)

                if buildMonitor.status.isBuilding, let startedAt = buildMonitor.status.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Label(formattedDuration(from: startedAt, to: context.date), systemImage: "hammer.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
            } else {
                Text("No repo detected in active Terminal / Xcode")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .padding(.top, notchHeight)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    
    private func formattedDuration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
