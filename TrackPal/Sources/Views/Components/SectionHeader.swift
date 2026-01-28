// TrackPal/Views/Components/SectionHeader.swift
import SwiftUI

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .sectionHeaderStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DesignTokens.Spacing.xs)
    }
}
