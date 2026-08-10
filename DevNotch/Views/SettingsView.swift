import SwiftUI

struct SettingsView: View {
    @ObservedObject var appearance: AppearanceSettings

    let detectedNotch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Appearance")
                    .font(.system(size: 13, weight: .semibold))
                Text(detectedNotch
                     ? "This display has a notch."
                     : "This display has no notch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Array(AppearanceSettings.Preference.allCases.enumerated()), id: \.element.id) { index, option in
                    Button {
                        appearance.preference = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: appearance.preference == option
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(appearance.preference == option ? Color.accentColor : Color.secondary)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(option.label)
                                        .font(.system(size: 12, weight: .medium))
                                    if option == .auto {
                                        Text(detectedNotch ? "notch" : "island")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15), in: Capsule())
                                    }
                                }
                                Text(option.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < AppearanceSettings.Preference.allCases.count - 1 {
                        Divider().padding(.leading, 38)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .padding(.horizontal, 20)

            Text("Changes apply immediately.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .frame(width: 420)
    }
}
