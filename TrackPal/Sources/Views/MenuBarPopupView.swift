// TrackPal/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @State private var isEnabled: Bool = TrackpadZoneScroller.shared.isEnabled
    @State private var launchAtLogin: Bool = Settings.shared.launchAtLogin
    @State private var edgeWidth: Double = Double(Settings.shared.edgeZoneWidth)
    @State private var bottomHeight: Double = Double(Settings.shared.bottomZoneHeight)
    @State private var sensitivity: Double = Double(Settings.shared.scrollMultiplier)
    @State private var edgeMode: TrackpadZoneScroller.VerticalEdgeMode = Settings.shared.verticalEdgeMode
    @State private var horizontalPosition: TrackpadZoneScroller.HorizontalPosition = Settings.shared.horizontalPosition
    @State private var middleClickEnabled: Bool = Settings.shared.middleClickEnabled
    @State private var accelerationCurve: TrackpadZoneScroller.AccelerationCurveType = Settings.shared.accelerationCurveType
    @State private var cornerTriggerEnabled: Bool = Settings.shared.cornerTriggerEnabled
    @State private var cornerTriggerZoneSize: Double = Double(Settings.shared.cornerTriggerZoneSize)
    @State private var cornerActionTopLeft: TrackpadZoneScroller.CornerAction = Settings.shared.cornerActionTopLeft
    @State private var cornerActionTopRight: TrackpadZoneScroller.CornerAction = Settings.shared.cornerActionTopRight
    @State private var cornerActionBottomLeft: TrackpadZoneScroller.CornerAction = Settings.shared.cornerActionBottomLeft
    @State private var cornerActionBottomRight: TrackpadZoneScroller.CornerAction = Settings.shared.cornerActionBottomRight

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // Header
            headerSection

            Divider()

            // Enable toggle
            enableToggleSection

            // Trackpad diagram
            diagramSection

            Divider()

            // Settings sliders
            settingsSection

            Divider()

            // Footer
            footerSection
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: DesignTokens.Dimensions.popupWidth)
        .darkGlassBackground()
        .environment(\.colorScheme, .dark)
        .onAppear {
            // Sync with actual scroller state
            isEnabled = TrackpadZoneScroller.shared.isEnabled
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TrackPal")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text("觸控板區域捲動")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            Spacer()
        }
    }

    private var enableToggleSection: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Toggle(isOn: $isEnabled) {
                HStack {
                    Image(systemName: isEnabled ? "hand.draw.fill" : "hand.draw")
                        .foregroundStyle(isEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                    Text("啟用區域捲動")
                        .font(DesignTokens.Typography.body)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: isEnabled) { _, newValue in
                Settings.shared.isEnabled = newValue
                if newValue {
                    TrackpadZoneScroller.shared.start()
                } else {
                    TrackpadZoneScroller.shared.stop()
                }
            }

            Toggle(isOn: $launchAtLogin) {
                HStack {
                    Image(systemName: launchAtLogin ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(launchAtLogin ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                    Text("開機時自動啟動")
                        .font(DesignTokens.Typography.body)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: launchAtLogin) { _, newValue in
                Settings.shared.launchAtLogin = newValue
            }
        }
    }

    private var diagramSection: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            TrackpadDiagramView(
                edgeWidth: CGFloat(edgeWidth),
                bottomHeight: CGFloat(bottomHeight),
                edgeMode: edgeMode,
                horizontalPosition: horizontalPosition,
                middleClickEnabled: middleClickEnabled,
                cornerTriggerEnabled: cornerTriggerEnabled,
                cornerTriggerZoneSize: CGFloat(cornerTriggerZoneSize)
            )
            TrackpadLegendView(middleClickEnabled: middleClickEnabled, cornerTriggerEnabled: cornerTriggerEnabled)
        }
    }

    private var settingsSection: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("設定")
                .sectionHeaderStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

            // Edge mode picker
            HStack {
                Text("上下捲動區域")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                Picker("", selection: $edgeMode) {
                    ForEach(TrackpadZoneScroller.VerticalEdgeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .onChange(of: edgeMode) { _, newValue in
                    Settings.shared.verticalEdgeMode = newValue
                    TrackpadZoneScroller.shared.verticalEdgeMode = newValue
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xs)

            // Horizontal position picker
            HStack {
                Text("水平捲動位置")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                Picker("", selection: $horizontalPosition) {
                    ForEach(TrackpadZoneScroller.HorizontalPosition.allCases, id: \.self) { pos in
                        Text(pos.rawValue).tag(pos)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .onChange(of: horizontalPosition) { _, newValue in
                    Settings.shared.horizontalPosition = newValue
                    TrackpadZoneScroller.shared.horizontalPosition = newValue
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xs)

            // Middle click toggle
            Toggle(isOn: $middleClickEnabled) {
                HStack {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(middleClickEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                    Text("啟用中鍵點擊")
                        .font(DesignTokens.Typography.body)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: middleClickEnabled) { _, newValue in
                Settings.shared.middleClickEnabled = newValue
                TrackpadZoneScroller.shared.middleClickEnabled = newValue
            }
            .padding(.vertical, DesignTokens.Spacing.xs)

            SettingsSliderRow(
                title: "邊緣寬度",
                value: $edgeWidth,
                range: 0.05...0.30,
                format: { "\(Int($0 * 100))%" }
            )
            .onChange(of: edgeWidth) { _, newValue in
                Settings.shared.edgeZoneWidth = CGFloat(newValue)
                TrackpadZoneScroller.shared.edgeZoneWidth = CGFloat(newValue)
            }

            SettingsSliderRow(
                title: "水平區域高度",
                value: $bottomHeight,
                range: 0.10...0.40,
                format: { "\(Int($0 * 100))%" }
            )
            .onChange(of: bottomHeight) { _, newValue in
                Settings.shared.bottomZoneHeight = CGFloat(newValue)
                TrackpadZoneScroller.shared.bottomZoneHeight = CGFloat(newValue)
            }

            SettingsSliderRow(
                title: "捲動靈敏度",
                value: $sensitivity,
                range: 1.0...10.0,
                format: { String(format: "%.1fx", $0) }
            )
            .onChange(of: sensitivity) { _, newValue in
                Settings.shared.scrollMultiplier = CGFloat(newValue)
                TrackpadZoneScroller.shared.scrollMultiplier = CGFloat(newValue)
            }

            // Acceleration curve picker
            HStack {
                Text("捲動加速曲線")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                Picker("", selection: $accelerationCurve) {
                    ForEach(TrackpadZoneScroller.AccelerationCurveType.allCases, id: \.self) { curve in
                        Text(curve.rawValue).tag(curve)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: accelerationCurve) { _, newValue in
                    Settings.shared.accelerationCurveType = newValue
                    TrackpadZoneScroller.shared.accelerationCurveType = newValue
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xs)

            Divider()

            // Corner triggers section
            cornerTriggersSection
        }
    }

    private var cornerTriggersSection: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("角落觸發")
                .sectionHeaderStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

            // Enable toggle
            Toggle(isOn: $cornerTriggerEnabled) {
                HStack {
                    Image(systemName: "rectangle.dashed.badge.record")
                        .foregroundStyle(cornerTriggerEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                    Text("啟用角落觸發")
                        .font(DesignTokens.Typography.body)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: cornerTriggerEnabled) { _, newValue in
                Settings.shared.cornerTriggerEnabled = newValue
                TrackpadZoneScroller.shared.cornerTriggerEnabled = newValue
            }

            if cornerTriggerEnabled {
                // Corner zone size slider
                SettingsSliderRow(
                    title: "角落區域大小",
                    value: $cornerTriggerZoneSize,
                    range: 0.05...0.25,
                    format: { "\(Int($0 * 100))%" }
                )
                .onChange(of: cornerTriggerZoneSize) { _, newValue in
                    Settings.shared.cornerTriggerZoneSize = CGFloat(newValue)
                    TrackpadZoneScroller.shared.cornerTriggerZoneSize = CGFloat(newValue)
                }

                // Corner action pickers
                cornerActionPicker(title: "左上角", selection: $cornerActionTopLeft) { newValue in
                    Settings.shared.cornerActionTopLeft = newValue
                    TrackpadZoneScroller.shared.cornerActions[.topLeftCorner] = newValue
                }

                cornerActionPicker(title: "右上角", selection: $cornerActionTopRight) { newValue in
                    Settings.shared.cornerActionTopRight = newValue
                    TrackpadZoneScroller.shared.cornerActions[.topRightCorner] = newValue
                }

                cornerActionPicker(title: "左下角", selection: $cornerActionBottomLeft) { newValue in
                    Settings.shared.cornerActionBottomLeft = newValue
                    TrackpadZoneScroller.shared.cornerActions[.bottomLeftCorner] = newValue
                }

                cornerActionPicker(title: "右下角", selection: $cornerActionBottomRight) { newValue in
                    Settings.shared.cornerActionBottomRight = newValue
                    TrackpadZoneScroller.shared.cornerActions[.bottomRightCorner] = newValue
                }
            }
        }
    }

    private func cornerActionPicker(
        title: String,
        selection: Binding<TrackpadZoneScroller.CornerAction>,
        onChange: @escaping (TrackpadZoneScroller.CornerAction) -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(TrackpadZoneScroller.CornerAction.allCases, id: \.self) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .onChange(of: selection.wrappedValue) { _, newValue in
                onChange(newValue)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private var footerSection: some View {
        HStack {
            Text("需要輔助功能權限")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Spacer()

            Button("結束") {
                NSApplication.shared.terminate(nil)
            }
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
            )
        }
    }
}

#Preview {
    MenuBarPopupView()
}
