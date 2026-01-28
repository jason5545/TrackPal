// TrackPal/Views/Settings/SettingsPickerRow.swift
import SwiftUI

enum PickerRowStyle {
    case segmented
    case menu
}

struct SettingsPickerRow<T: Hashable & CaseIterable & RawRepresentable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var selection: T
    var style: PickerRowStyle = .segmented
    var pickerWidth: CGFloat = 150

    var body: some View {
        SettingsRowView(
            icon: icon,
            iconColor: iconColor,
            title: title
        ) {
            Group {
                switch style {
                case .segmented:
                    Picker("", selection: $selection) {
                        ForEach(T.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                case .menu:
                    Picker("", selection: $selection) {
                        ForEach(T.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .labelsHidden()
            .frame(width: pickerWidth)
        }
    }
}
