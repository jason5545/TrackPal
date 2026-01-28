// TrackPal/Views/Settings/SettingsRowView.swift
import SwiftUI

struct SettingsRowView<Control: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var description: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)

            Text(title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: DesignTokens.Spacing.xs)

            control()
        }
        .hoverableRow()
    }
}
