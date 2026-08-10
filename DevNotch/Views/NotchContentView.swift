import SwiftUI

private struct PulseKey: Equatable {
    let branch: String
    let lastCommitSubject: String
    let aheadCount: Int
    let behindCount: Int
    let operation: GitOperation
    let collisions: String
}

struct NotchContentView: View {
    @ObservedObject private var appModeService: AppModeService
    @ObservedObject private var gitService: GitStatusService
    @StateObject private var pointer = PointerTracker()
    
    @State private var isHoverExpanded = false
    @State private var isPulsing = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var pulseTask: Task<Void, Never>?
    @State private var showSplash = true
    
    private let style: NotchStyle
    private let metrics: ScreenMetrics
    private let position: AppearanceSettings.Position
    private let hideOutsideDevApps: Bool
    private let windowFrame: NSRect
    
    private let expandedWidth: CGFloat = 300
    private let collapsedHeight: CGFloat = 32
    private let collapsedDotOverhang: CGFloat = 28
    private let edgeInset: CGFloat = 16
    private let remoteDisplayLimit = 3
    private let remoteRowHeight: CGFloat = 14
    private let remoteRowSpacing: CGFloat = 4
    
    private let pulseDuration: Duration = .seconds(2)
    private let hoverOpenDelay: Duration = .milliseconds(120)
    private let hoverCloseDelay: Duration = .milliseconds(180)
    
    private let collapsedHoverPadding: CGFloat = 18
    private let expandedHoverPadding: CGFloat = 14
    
    init(
        style: NotchStyle,
        metrics: ScreenMetrics,
        position: AppearanceSettings.Position,
        hideOutsideDevApps: Bool,
        windowFrame: NSRect,
        appModeService: AppModeService,
        gitService: GitStatusService
    ) {
        self.style = style
        self.metrics = metrics
        self.position = position
        self.hideOutsideDevApps = hideOutsideDevApps
        self.windowFrame = windowFrame
        self.appModeService = appModeService
        self.gitService = gitService
    }
    
    // MARK: - Derived state
    
    private var status: GitStatus { gitService.status }
    
    private var isIdle: Bool { !status.isValidRepo }
    
    private var isHidden: Bool {
        hideOutsideDevApps && appModeService.mode == .neutral
    }
    
    private var isExpanded: Bool { !isHidden && (isHoverExpanded || isPulsing) }
    
    private var pulseKey: PulseKey {
        PulseKey(
            branch: status.branch,
            lastCommitSubject: status.lastCommitSubject,
            aheadCount: status.aheadCount,
            behindCount: status.behindCount,
            operation: status.operation,
            collisions: status.collisions.map { "\($0.branch):\($0.files.count)" }.joined(separator: ",")
        )
    }
    
    private var visibleRemoteBranches: [RemoteBranchInfo] {
        Array(status.remoteBranches.prefix(remoteDisplayLimit))
    }
    
    private var collisionSummary: String? {
        guard let first = status.collisions.first else { return nil }
        
        let noun = first.files.count == 1 ? "file" : "files"
        var text = "\(first.files.count) \(noun) also on \(displayName(for: first.branch))"
        
        if status.collisions.count > 1 {
            text += " +\(status.collisions.count - 1)"
        }
        
        return text
    }
    
    private var collisionSectionHeight: CGFloat {
        collisionSummary == nil ? 0 : remoteRowHeight + 7
    }
    
    private var remoteSectionHeight: CGFloat {
        let count = visibleRemoteBranches.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * remoteRowHeight
        + CGFloat(count - 1) * remoteRowSpacing
        + 7
    }
    
    // MARK: - Style geometry
    
    private var effectivePosition: AppearanceSettings.Position {
        style == .notch ? .center : position
    }
    
    private var outerAlignment: Alignment {
        switch effectivePosition {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
    
    private var collapsedWidth: CGFloat {
        switch style {
        case .notch:
            let base = metrics.notchWidth > 0 ? metrics.notchWidth : 44
            return isIdle ? base : base + collapsedDotOverhang
        case .island:
            return isIdle ? 46 : 78
        }
    }
    
    private var expandedHeight: CGFloat {
        let base: CGFloat
        switch style {
        case .notch: base = max(118, metrics.notchHeight + 108)
        case .island: base = 118
        }
        return base + collisionSectionHeight + remoteSectionHeight
    }
    
    private var collapsedCornerRadius: CGFloat {
        style == .island ? collapsedHeight / 2 : 10
    }
    
    private var expandedCornerRadius: CGFloat { 18 }
    
    private var contentTopPadding: CGFloat {
        style == .island ? 12 : metrics.notchHeight + 18
    }
    
    private var shadowOpacity: Double {
        style == .island ? 0.35 : 0
    }
    
    private var hoverAreaWidth: CGFloat {
        isExpanded ? expandedWidth + expandedHoverPadding : collapsedWidth + collapsedHoverPadding
    }
    
    private var hoverAreaHeight: CGFloat {
        isExpanded ? expandedHeight + expandedHoverPadding : collapsedHeight + 6
    }
    
    private var horizontalInset: CGFloat {
        effectivePosition == .center ? 0 : edgeInset
    }
    
    private var trackingFrame: NSRect {
        guard !isHidden, !windowFrame.isEmpty else { return .zero }
        
        let centerX: CGFloat
        switch effectivePosition {
        case .leading:
            centerX = windowFrame.minX + horizontalInset + hoverAreaWidth / 2
        case .center:
            centerX = windowFrame.midX
        case .trailing:
            centerX = windowFrame.maxX - horizontalInset - hoverAreaWidth / 2
        }
        
        return NSRect(
            x: centerX - hoverAreaWidth / 2,
            y: windowFrame.maxY - hoverAreaHeight,
            width: hoverAreaWidth,
            height: hoverAreaHeight
        )
    }
    
    // MARK: - Colors
    
    private var workingTreeColor: Color {
        if status.conflictedCount > 0 || status.operation != .none { return .red }
        if status.isDirty { return .orange }
        return .green
    }
    
    private var remoteStatusColor: Color {
        if !status.collisions.isEmpty { return .yellow }
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
            if showSplash {
                ZStack(alignment: outerAlignment) {
                    Color.clear
                    SplashView(
                        isActive: $showSplash,
                        expandedWidth: expandedWidth,
                        expandedHeight: expandedHeight,
                        expandedCornerRadius: expandedCornerRadius
                    )
                    .padding(.horizontal, horizontalInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: outerAlignment)
            } else {
                ZStack(alignment: outerAlignment) {
                    Color.clear

                    if !isHidden {
                        capsule
                            .padding(.horizontal, horizontalInset)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: outerAlignment)
                .animation(.easeInOut(duration: 0.2), value: isHidden)
                .onAppear {
                    pointer.start()
                    pointer.updateTrackingFrame(trackingFrame)
                }
                .onDisappear {
                    pointer.stop()
                    hoverTask?.cancel()
                    pulseTask?.cancel()
                }
                .onChange(of: trackingFrame) { _, frame in
                    pointer.updateTrackingFrame(frame)
                }
                .onChange(of: pointer.isInside) { _, inside in
                    scheduleHoverChange(to: inside)
                }
                .onChange(of: isHidden) { _, hidden in
                    if hidden {
                        hoverTask?.cancel()
                        isHoverExpanded = false
                        isPulsing = false
                    }
                }
                .onChange(of: pulseKey) { oldValue, newValue in
                    guard !isHidden else { return }
                    guard !oldValue.branch.isEmpty || !newValue.branch.isEmpty else { return }
                    triggerPulse()
                }
            }
        }
    
    private var capsule: some View {
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
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? expandedCornerRadius : collapsedCornerRadius))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowOpacity > 0 ? 14 : 0, y: 4)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isExpanded)
        .allowsHitTesting(false)
    }
    
    private func scheduleHoverChange(to hovering: Bool) {
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
                    .padding(.leading, style == .island ? 12 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                
                if status.hasUpstream || !status.collisions.isEmpty {
                    Circle()
                        .fill(remoteStatusColor)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, style == .island ? 12 : 8)
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
                collisionRow
                remoteActivitySection
                Spacer(minLength: 0)
                tagRow
            } else {
                Text("No repo detected in active Terminal / Xcode")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
                    .padding(.top, contentTopPadding)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
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
        .padding(.top, contentTopPadding)
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
    
    @ViewBuilder
    private var collisionRow: some View {
        if let summary = collisionSummary {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                
                Text(summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer(minLength: 0)
            }
            .frame(height: remoteRowHeight)
        }
    }
    
    @ViewBuilder
    private var remoteActivitySection: some View {
        if !visibleRemoteBranches.isEmpty {
            VStack(alignment: .leading, spacing: remoteRowSpacing) {
                ForEach(visibleRemoteBranches) { branch in
                    remoteBranchRow(branch)
                }
            }
        }
    }
    
    private func remoteBranchRow(_ branch: RemoteBranchInfo) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8))
                .foregroundStyle(.gray)
            
            Text(displayName(for: branch.name))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer(minLength: 4)
            
            Text(firstName(of: branch.author))
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .lineLimit(1)
            
            Text(branch.relativeDate)
                .font(.system(size: 9))
                .foregroundStyle(.gray.opacity(0.7))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: remoteRowHeight)
    }
    
    private func displayName(for ref: String) -> String {
        guard let slash = ref.firstIndex(of: "/") else { return ref }
        return String(ref[ref.index(after: slash)...])
    }
    
    private func firstName(of author: String) -> String {
        author.split(separator: " ").first.map(String.init) ?? author
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
