// TrackPal/Views/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @Binding var launchAtLogin: Bool
    @Binding var edgeMode: TrackpadZoneScroller.VerticalEdgeMode
    @Binding var horizontalPosition: TrackpadZoneScroller.HorizontalPosition
    @Binding var edgeWidth: Double
    @Binding var bottomHeight: Double
    @Binding var sensitivity: Double
    @Binding var accelerationCurve: TrackpadZoneScroller.AccelerationCurveType
    @Binding var middleClickEnabled: Bool
    @Binding var cornerTriggerEnabled: Bool
    @Binding var cornerTriggerZoneSize: Double
    @Binding var cornerActionTopLeft: TrackpadZoneScroller.CornerAction
    @Binding var cornerActionTopRight: TrackpadZoneScroller.CornerAction
    @Binding var cornerActionBottomLeft: TrackpadZoneScroller.CornerAction
    @Binding var cornerActionBottomRight: TrackpadZoneScroller.CornerAction

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                // 一般
                generalSection

                // 捲動區域
                scrollZoneSection

                // 捲動行為
                scrollBehaviorSection

                // 中鍵點擊
                middleClickSection

                // 角落觸發
                cornerTriggerSection

                // Footer
                footerSection
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
        }
    }

    // MARK: - 一般

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "General")

            SettingsToggleRow(
                icon: "power.circle",
                iconColor: launchAtLogin ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary,
                title: "Launch at Login",
                isOn: $launchAtLogin
            )
            .onChange(of: launchAtLogin) { _, newValue in
                Settings.shared.launchAtLogin = newValue
            }
        }
    }

    // MARK: - 捲動區域

    private var scrollZoneSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Scroll Zones")

            SettingsPickerRow(
                icon: "arrow.up.arrow.down",
                iconColor: DesignTokens.Colors.accentPrimary,
                title: "Vertical Scroll",
                selection: $edgeMode,
                pickerWidth: 150
            )
            .onChange(of: edgeMode) { _, newValue in
                Settings.shared.verticalEdgeMode = newValue
                TrackpadZoneScroller.shared.verticalEdgeMode = newValue
            }

            SettingsPickerRow(
                icon: "arrow.left.arrow.right",
                iconColor: DesignTokens.Colors.accentPrimary,
                title: "Horizontal Scroll",
                selection: $horizontalPosition,
                pickerWidth: 100
            )
            .onChange(of: horizontalPosition) { _, newValue in
                Settings.shared.horizontalPosition = newValue
                TrackpadZoneScroller.shared.horizontalPosition = newValue
            }

            SettingsSliderRow(
                title: "Edge Width",
                value: $edgeWidth,
                range: 0.05...0.30,
                format: { "\(Int($0 * 100))%" },
                icon: "ruler"
            )
            .onChange(of: edgeWidth) { _, newValue in
                Settings.shared.edgeZoneWidth = CGFloat(newValue)
                TrackpadZoneScroller.shared.edgeZoneWidth = CGFloat(newValue)
            }

            SettingsSliderRow(
                title: "Horizontal Height",
                value: $bottomHeight,
                range: 0.10...0.40,
                format: { "\(Int($0 * 100))%" },
                icon: "rectangle.bottomhalf.filled"
            )
            .onChange(of: bottomHeight) { _, newValue in
                Settings.shared.bottomZoneHeight = CGFloat(newValue)
                TrackpadZoneScroller.shared.bottomZoneHeight = CGFloat(newValue)
            }
        }
    }

    // MARK: - 捲動行為

    private var scrollBehaviorSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Scroll Behavior")

            SettingsSliderRow(
                title: "Scroll Sensitivity",
                value: $sensitivity,
                range: 1.0...10.0,
                format: { String(format: "%.1fx", $0) },
                icon: "gauge.with.dots.needle.33percent"
            )
            .onChange(of: sensitivity) { _, newValue in
                Settings.shared.scrollMultiplier = CGFloat(newValue)
                TrackpadZoneScroller.shared.scrollMultiplier = CGFloat(newValue)
            }

            SettingsPickerRow(
                icon: "chart.line.uptrend.xyaxis",
                iconColor: DesignTokens.Colors.accentPrimary,
                title: "Acceleration Curve",
                selection: $accelerationCurve,
                pickerWidth: 140
            )
            .onChange(of: accelerationCurve) { _, newValue in
                Settings.shared.accelerationCurveType = newValue
                TrackpadZoneScroller.shared.accelerationCurveType = newValue
            }
        }
    }

    // MARK: - 中鍵點擊

    private var middleClickSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Middle Click")

            SettingsToggleRow(
                icon: "hand.tap",
                iconColor: middleClickEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary,
                title: "Enable Middle Click",
                isOn: $middleClickEnabled
            )
            .onChange(of: middleClickEnabled) { _, newValue in
                Settings.shared.middleClickEnabled = newValue
                TrackpadZoneScroller.shared.middleClickEnabled = newValue
            }
        }
    }

    // MARK: - 角落觸發

    private var cornerTriggerSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Corner Triggers")

            SettingsToggleRow(
                icon: "rectangle.dashed.badge.record",
                iconColor: cornerTriggerEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary,
                title: "Enable Corner Triggers",
                isOn: $cornerTriggerEnabled
            )
            .onChange(of: cornerTriggerEnabled) { _, newValue in
                Settings.shared.cornerTriggerEnabled = newValue
                TrackpadZoneScroller.shared.cornerTriggerEnabled = newValue
            }

            if cornerTriggerEnabled {
                SettingsSliderRow(
                    title: "Corner Zone Size",
                    value: $cornerTriggerZoneSize,
                    range: 0.05...0.25,
                    format: { "\(Int($0 * 100))%" },
                    icon: "square.dashed"
                )
                .onChange(of: cornerTriggerZoneSize) { _, newValue in
                    Settings.shared.cornerTriggerZoneSize = CGFloat(newValue)
                    TrackpadZoneScroller.shared.cornerTriggerZoneSize = CGFloat(newValue)
                }

                cornerActionRow(title: "Top Left", icon: "arrow.up.left", selection: $cornerActionTopLeft) { newValue in
                    Settings.shared.cornerActionTopLeft = newValue
                    TrackpadZoneScroller.shared.cornerActions[.topLeftCorner] = newValue
                }

                cornerActionRow(title: "Top Right", icon: "arrow.up.right", selection: $cornerActionTopRight) { newValue in
                    Settings.shared.cornerActionTopRight = newValue
                    TrackpadZoneScroller.shared.cornerActions[.topRightCorner] = newValue
                }

                cornerActionRow(title: "Bottom Left", icon: "arrow.down.left", selection: $cornerActionBottomLeft) { newValue in
                    Settings.shared.cornerActionBottomLeft = newValue
                    TrackpadZoneScroller.shared.cornerActions[.bottomLeftCorner] = newValue
                }

                cornerActionRow(title: "Bottom Right", icon: "arrow.down.right", selection: $cornerActionBottomRight) { newValue in
                    Settings.shared.cornerActionBottomRight = newValue
                    TrackpadZoneScroller.shared.cornerActions[.bottomRightCorner] = newValue
                }
            }
        }
    }

    private func cornerActionRow(
        title: LocalizedStringKey,
        icon: String,
        selection: Binding<TrackpadZoneScroller.CornerAction>,
        onChange: @escaping (TrackpadZoneScroller.CornerAction) -> Void
    ) -> some View {
        SettingsPickerRow(
            icon: icon,
            iconColor: DesignTokens.Colors.accentPrimary,
            title: title,
            selection: selection,
            style: .menu,
            pickerWidth: 140
        )
        .onChange(of: selection.wrappedValue) { _, newValue in
            onChange(newValue)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("v1.1")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .glassButtonStyle()
        }
        .padding(.top, DesignTokens.Spacing.xs)
    }
}
