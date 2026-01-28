// TrackPal/Views/Settings/SettingsToggleRow.swift
import SwiftUI

struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    var description: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRowView(
            icon: icon,
            iconColor: iconColor,
            title: title,
            description: description
        ) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
    }
}
