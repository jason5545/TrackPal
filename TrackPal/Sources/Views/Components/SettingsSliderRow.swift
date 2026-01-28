// TrackPal/Views/Components/SettingsSliderRow.swift
import SwiftUI

/// A settings row with a label, slider, and value display
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var icon: String? = nil
    var iconColor: Color = DesignTokens.Colors.accentPrimary

    var body: some View {
        if let icon {
            SettingsRowView(
                icon: icon,
                iconColor: iconColor,
                title: title
            ) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Slider(value: $value, in: range)
                        .tint(DesignTokens.Colors.accentPrimary)
                        .frame(width: 70)

                    Text(format(value))
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        } else {
            sliderContent
        }
    }

    private var sliderContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                Text(format(value))
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 50, alignment: .trailing)
            }

            Slider(value: $value, in: range)
                .tint(DesignTokens.Colors.accentPrimary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

#Preview {
    VStack(spacing: 16) {
        SettingsSliderRow(
            title: "左右邊緣寬度",
            value: .constant(0.15),
            range: 0.05...0.30,
            format: { "\(Int($0 * 100))%" }
        )

        SettingsSliderRow(
            title: "邊緣寬度",
            value: .constant(0.15),
            range: 0.05...0.30,
            format: { "\(Int($0 * 100))%" },
            icon: "ruler"
        )
    }
    .padding()
    .frame(width: 300)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
