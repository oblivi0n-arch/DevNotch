import SwiftUI

struct SplashView: View {
    @Binding var isActive: Bool

    var expandedWidth: CGFloat = 220
    var expandedHeight: CGFloat = 40
    var expandedCornerRadius: CGFloat = 14

    @State private var isExpanded = false
    @State private var opacity: Double = 1.0

    private var collapsedWidth: CGFloat { expandedWidth * 0.55 }
    private var collapsedHeight: CGFloat { expandedHeight * 0.8 }
    private var collapsedCornerRadius: CGFloat { collapsedHeight / 2 }

    var body: some View {
        RoundedRectangle(
            cornerRadius: isExpanded ? expandedCornerRadius : collapsedCornerRadius,
            style: .continuous
        )
        .fill(Color.black)
        .frame(
            width: isExpanded ? expandedWidth : collapsedWidth,
            height: isExpanded ? expandedHeight : collapsedHeight
        )
        .overlay(
            Text("DevNotch")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .opacity(isExpanded ? 1 : 0)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isExpanded)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                isExpanded = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.easeOut(duration: 0.5)) {
                    opacity = 0
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isActive = false
                }
            }
        }
    }
}
