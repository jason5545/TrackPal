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
                middleClickEnabled: middleClickEnabled
            )
            TrackpadLegendView(middleClickEnabled: middleClickEnabled)
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
        }
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
