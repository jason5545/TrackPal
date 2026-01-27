// TrackPal/Views/Components/SettingsSliderRow.swift
import SwiftUI

/// A settings row with a label, slider, and value display
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
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
            title: "下方區域高度",
            value: .constant(0.20),
            range: 0.10...0.40,
            format: { "\(Int($0 * 100))%" }
        )

        SettingsSliderRow(
            title: "捲動靈敏度",
            value: .constant(3.0),
            range: 1.0...10.0,
            format: { String(format: "%.1fx", $0) }
        )
    }
    .padding()
    .frame(width: 300)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
