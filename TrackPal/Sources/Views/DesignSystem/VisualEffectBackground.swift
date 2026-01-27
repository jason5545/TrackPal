// TrackPal/Views/DesignSystem/VisualEffectBackground.swift
import SwiftUI
import AppKit

/// A dark frosted glass background using NSVisualEffectView
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - View Extensions

extension View {
    /// Applies a dark glass background
    func darkGlassBackground() -> some View {
        self
            .background(DesignTokens.Colors.popupOverlay)
            .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
    }

    /// Applies section header text styling
    func sectionHeaderStyle() -> some View {
        self
            .font(DesignTokens.Typography.sectionHeader)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .textCase(.uppercase)
    }
}
