// TrackPal/Views/DesignSystem/DesignTokens.swift
import SwiftUI

/// Design System tokens for TrackPal UI
enum DesignTokens {

    // MARK: - Colors

    enum Colors {
        // Text
        static let textPrimary: Color = .primary
        static let textSecondary: Color = .secondary
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        // Interactive
        static let interactiveDefault: Color = .primary.opacity(0.7)
        static let interactiveHover: Color = .primary.opacity(0.9)
        static let accentPrimary: Color = .accentColor

        // Zone colors
        static let verticalZone = Color.blue.opacity(0.3)
        static let horizontalZone = Color.green.opacity(0.3)
        static let middleClickZone = Color.purple.opacity(0.3)
        static let cornerTriggerZone = Color.orange.opacity(0.3)

        // Separators & Borders
        static let separator = Color(nsColor: .separatorColor)
        static let glassBorder = Color(nsColor: .separatorColor).opacity(0.3)
        static let glassBorderHover = Color(nsColor: .separatorColor).opacity(0.5)

        // Slider
        static let sliderTrack: Color = .primary.opacity(0.15)
        static let sliderFill: Color = .accentColor

        // Glass Effects
        static let popupOverlay: Color = .black.opacity(0.4)
    }

    // MARK: - Typography

    enum Typography {
        static let title = Font.system(size: 16, weight: .semibold)
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let caption = Font.system(size: 11, weight: .regular)
        static let percentage = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let sectionHeaderTracking: CGFloat = 1.2
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Dimensions

    enum Dimensions {
        static let popupWidth: CGFloat = 320
        static let cornerRadius: CGFloat = 12
        static let rowRadius: CGFloat = 8
        static let buttonRadius: CGFloat = 6
        static let sliderHeight: CGFloat = 4
        static let iconSize: CGFloat = 20
        static let settingsIconWidth: CGFloat = 20
        static let minTouchTarget: CGFloat = 24
        static let trackpadDiagramHeight: CGFloat = 100
    }

    // MARK: - Animation

    enum Animation {
        static let quick = SwiftUI.Animation.spring(response: 0.2, dampingFraction: 0.85)
        static let hover = SwiftUI.Animation.easeOut(duration: 0.12)
        static let standard = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let pageTransition = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.88)
    }
}
