import SwiftUI

struct NotchContentView: View {
    @StateObject private var appModeService = AppModeService()
    @StateObject private var gitService: GitStatusService
    @StateObject private var buildMonitor = BuildMonitorService()
    @State private var isHovered = false

    private let hitAreaWidth: CGFloat = 280

    private let notchWidth: CGFloat
    private let notchHeight: CGFloat

    private let collapsedDotOverhang: CGFloat = 28

    private var collapsedWidth: CGFloat {
        notchWidth > 0 ? notchWidth + collapsedDotOverhang : 60
    }

    private var expandedHeight: CGFloat {
        notchHeight > 0 ? max(100, notchHeight + 65) : 100
    }

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        let modeService = AppModeService()
        _appModeService = StateObject(wrappedValue: modeService)
        _gitService = StateObject(wrappedValue: GitStatusService(appModeService: modeService))
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

                if isHovered {
                    expandedContent
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                } else {
                    collapsedContent
                        .transition(.opacity)
                }
            }
            .frame(
                width: isHovered ? 280 : collapsedWidth,
                height: isHovered ? expandedHeight : 32
            )
            .clipShape(RoundedRectangle(cornerRadius: isHovered ? 16 : 10))
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovered)
            .allowsHitTesting(false)
        }
        .frame(width: 320, height: 100, alignment: .top)
        .onAppear {
            appModeService.start()
            gitService.start()
            buildMonitor.start()
        }
    }

    private var collapsedContent: some View {
        Circle()
            .fill(gitService.status.uncommittedChanges > 0 ? Color.orange : Color.green)
            .frame(width: 6, height: 6)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
