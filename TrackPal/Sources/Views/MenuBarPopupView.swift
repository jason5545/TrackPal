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

    @State private var isSettingsOpen = false
    @State private var isSettingsAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // Header
            headerSection

            Divider()

            // Page content
            if isSettingsOpen {
                SettingsView(
                    launchAtLogin: $launchAtLogin,
                    edgeMode: $edgeMode,
                    horizontalPosition: $horizontalPosition,
                    edgeWidth: $edgeWidth,
                    bottomHeight: $bottomHeight,
                    sensitivity: $sensitivity,
                    accelerationCurve: $accelerationCurve,
                    middleClickEnabled: $middleClickEnabled,
                    cornerTriggerEnabled: $cornerTriggerEnabled,
                    cornerTriggerZoneSize: $cornerTriggerZoneSize,
                    cornerActionTopLeft: $cornerActionTopLeft,
                    cornerActionTopRight: $cornerActionTopRight,
                    cornerActionBottomLeft: $cornerActionBottomLeft,
                    cornerActionBottomRight: $cornerActionBottomRight
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                mainContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: DesignTokens.Dimensions.popupWidth)
        .darkGlassBackground()
        .environment(\.colorScheme, .dark)
        .onAppear {
            isEnabled = TrackpadZoneScroller.shared.isEnabled
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isSettingsOpen ? "設定" : "TrackPal")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .contentTransition(.numericText())

                if !isSettingsOpen {
                    Text("觸控板區域捲動")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }

            Spacer()

            // Gear / X toggle button
            Button {
                guard !isSettingsAnimating else { return }
                isSettingsAnimating = true
                withAnimation(DesignTokens.Animation.pageTransition) {
                    isSettingsOpen.toggle()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isSettingsAnimating = false
                }
            } label: {
                ZStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .opacity(isSettingsOpen ? 0 : 1)
                        .rotationEffect(.degrees(isSettingsOpen ? 90 : 0))

                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .opacity(isSettingsOpen ? 1 : 0)
                        .rotationEffect(.degrees(isSettingsOpen ? 0 : -90))
                }
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // Enable toggle
            enableToggleSection

            // Trackpad diagram
            diagramSection

            Divider()

            // Footer
            footerSection
        }
    }

    private var enableToggleSection: some View {
        SettingsToggleRow(
            icon: isEnabled ? "hand.draw.fill" : "hand.draw",
            iconColor: isEnabled ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary,
            title: "啟用區域捲動",
            isOn: $isEnabled
        )
        .onChange(of: isEnabled) { _, newValue in
            Settings.shared.isEnabled = newValue
            if newValue {
                TrackpadZoneScroller.shared.start()
            } else {
                TrackpadZoneScroller.shared.stop()
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

    private var footerSection: some View {
        HStack {
            Text("需要輔助功能權限")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Spacer()

            Button("結束") {
                NSApplication.shared.terminate(nil)
            }
            .glassButtonStyle()
        }
    }
}

#Preview {
    MenuBarPopupView()
}
