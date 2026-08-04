import SwiftUI

struct NotchContentView: View {
    @StateObject private var gitService = GitStatusService()
    @State private var isHovered = false

    private let hitAreaWidth: CGFloat = 280

    private let notchWidth: CGFloat
    private let notchHeight: CGFloat

    private let collapsedDotOverhang: CGFloat = 28

    private var collapsedWidth: CGFloat {
        notchWidth > 0 ? notchWidth + collapsedDotOverhang : 60
    }

    private var expandedHeight: CGFloat {
        notchHeight > 0 ? max(70, notchHeight + 55) : 70
    }

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
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
            gitService.start()
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

                Text("\(gitService.status.uncommittedChanges) niescommitowanych zmian")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Text("tag: \(gitService.status.lastTag)")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            } else {
                Text("Brak repo w aktywnym terminalu / Xcode")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .padding(.top, notchHeight)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
