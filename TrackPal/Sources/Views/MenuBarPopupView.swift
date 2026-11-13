import SwiftUI
import TrackPalSystem

/// 選單列彈出視窗：主頁（開關與區域示意圖）與設定頁。
struct MenuBarPopupView: View {
    @Environment(AppRuntime.self) private var runtime

    @State private var isSettingsOpen: Bool
    @State private var isSettingsAnimating = false

    init(initiallyShowingSettings: Bool = false) {
        _isSettingsOpen = State(initialValue: initiallyShowingSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            headerSection

            Divider()

            if isSettingsOpen {
                SettingsView(settings: runtime.settings, onQuit: runtime.quit)
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
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isSettingsOpen ? "Settings" : "TrackPal")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .contentTransition(.numericText())

                if !isSettingsOpen {
                    Text("Trackpad Zone Scrolling")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }

            Spacer()

            settingsToggleButton
        }
    }

    /// 齒輪 ↔ 叉叉。動畫進行中不接受第二次點擊，避免連點造成頁面狀態錯亂。
    private var settingsToggleButton: some View {
        Button {
            guard !isSettingsAnimating else { return }
            isSettingsAnimating = true
            withAnimation(DesignTokens.Animation.pageTransition) {
                isSettingsOpen.toggle()
            }
            Task {
                try? await Task.sleep(for: .seconds(0.4))
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
        .accessibilityLabel(Text("Settings"))
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            enableToggleSection

            diagramSection

            Divider()

            footerSection
        }
    }

    private var enableToggleSection: some View {
        SettingsToggleRow(
            icon: runtime.isRunning ? "hand.draw.fill" : "hand.draw",
            iconColor: runtime.isRunning
                ? DesignTokens.Colors.accentPrimary
                : DesignTokens.Colors.textSecondary,
            title: "Enable Zone Scrolling",
            isOn: Binding(
                get: { runtime.isRunning },
                set: { runtime.setEnabled($0) }
            )
        )
    }

    private var diagramSection: some View {
        let settings = runtime.settings
        return VStack(spacing: DesignTokens.Spacing.sm) {
            TrackpadDiagramView(
                edgeWidth: settings.edgeZoneWidth,
                bottomHeight: settings.bottomZoneHeight,
                edgeMode: settings.verticalEdgeMode,
                horizontalPosition: settings.horizontalPosition,
                middleClickEnabled: settings.middleClickEnabled,
                cornerTriggerEnabled: settings.cornerTriggerEnabled,
                cornerTriggerZoneSize: settings.cornerTriggerZoneSize
            )
            TrackpadLegendView(
                middleClickEnabled: settings.middleClickEnabled,
                cornerTriggerEnabled: settings.cornerTriggerEnabled
            )
        }
    }

    private var footerSection: some View {
        HStack {
            Text("Accessibility Permission Required")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Spacer()

            Button("Quit", action: runtime.quit)
                .glassButtonStyle()
        }
    }
}
