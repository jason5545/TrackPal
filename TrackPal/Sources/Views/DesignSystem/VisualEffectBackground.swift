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
            .tracking(DesignTokens.Typography.sectionHeaderTracking)
    }

    /// Applies hoverable row background with border
    func hoverableRow() -> some View {
        self.modifier(HoverableRowModifier())
    }

    /// Applies glass button styling
    func glassButtonStyle() -> some View {
        self
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

// MARK: - Hoverable Row Modifier

struct HoverableRowModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .fill(.ultraThinMaterial)
                    .opacity(isHovered ? 1 : 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .fill(Color.white.opacity(isHovered ? 0.04 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .strokeBorder(
                        isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isHovered = hovering
                }
            }
    }
}
