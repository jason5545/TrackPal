import SwiftUI
import TrackPalCore
import TrackPalSystem

/// 設定頁。每一列直接綁 `SettingsStore` 的屬性：寫入時 store 會存檔並把新設定
/// 交給狀態機，這裡不需要另外同步。
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let onQuit: () -> Void

    private var accent: Color { DesignTokens.Colors.accentPrimary }

    private func stateColor(_ isOn: Bool) -> Color {
        isOn ? accent : DesignTokens.Colors.textSecondary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                generalSection
                scrollZoneSection
                scrollBehaviorSection
                middleClickSection
                cornerTriggerSection
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
                iconColor: stateColor(settings.launchAtLogin),
                title: "Launch at Login",
                isOn: $settings.launchAtLogin
            )
        }
    }

    // MARK: - 捲動區域

    private var scrollZoneSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Scroll Zones")

            SettingsPickerRow(
                icon: "arrow.up.arrow.down",
                iconColor: accent,
                title: "Vertical Scroll",
                selection: $settings.verticalEdgeMode,
                pickerWidth: 150
            )

            SettingsPickerRow(
                icon: "arrow.left.arrow.right",
                iconColor: accent,
                title: "Horizontal Scroll",
                selection: $settings.horizontalPosition,
                pickerWidth: 100
            )

            SettingsSliderRow(
                title: "Edge Width",
                value: $settings.edgeZoneWidth,
                range: 0.05...0.30,
                format: Self.percent,
                icon: "ruler"
            )

            SettingsSliderRow(
                title: "Horizontal Height",
                value: $settings.bottomZoneHeight,
                range: 0.10...0.40,
                format: Self.percent,
                icon: "rectangle.bottomhalf.filled"
            )
        }
    }

    // MARK: - 捲動行為

    private var scrollBehaviorSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Scroll Behavior")

            SettingsSliderRow(
                title: "Scroll Sensitivity",
                value: $settings.scrollMultiplier,
                range: 1.0...10.0,
                format: { String(format: "%.1fx", $0) },
                icon: "gauge.with.dots.needle.33percent"
            )

            SettingsPickerRow(
                icon: "chart.line.uptrend.xyaxis",
                iconColor: accent,
                title: "Acceleration Curve",
                selection: $settings.accelerationCurveType,
                // 四個選項用一般大小會超出面板右緣，最後一個被切掉。
                pickerWidth: 170,
                controlSize: .small
            )
        }
    }

    // MARK: - 中鍵點擊

    private var middleClickSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Force Middle Click")

            SettingsToggleRow(
                icon: "hand.tap",
                iconColor: stateColor(settings.middleClickEnabled),
                title: "Enable Force Middle Click",
                isOn: $settings.middleClickEnabled
            )
        }
    }

    // MARK: - 角落觸發

    private var cornerTriggerSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Force Corner Triggers")

            SettingsToggleRow(
                icon: "rectangle.dashed.badge.record",
                iconColor: stateColor(settings.cornerTriggerEnabled),
                title: "Enable Force Corner Triggers",
                isOn: $settings.cornerTriggerEnabled
            )

            if settings.cornerTriggerEnabled {
                SettingsSliderRow(
                    title: "Corner Zone Size",
                    value: $settings.cornerTriggerZoneSize,
                    range: 0.05...0.25,
                    format: Self.percent,
                    icon: "square.dashed"
                )

                cornerActionRow("Top Left", "arrow.up.left", $settings.cornerActionTopLeft)
                cornerActionRow("Top Right", "arrow.up.right", $settings.cornerActionTopRight)
                cornerActionRow("Bottom Left", "arrow.down.left", $settings.cornerActionBottomLeft)
                cornerActionRow("Bottom Right", "arrow.down.right", $settings.cornerActionBottomRight)
            }
        }
    }

    private func cornerActionRow(
        _ title: LocalizedStringKey,
        _ icon: String,
        _ selection: Binding<CornerAction>
    ) -> some View {
        SettingsPickerRow(
            icon: icon,
            iconColor: accent,
            title: title,
            selection: selection,
            style: .menu,
            pickerWidth: 140
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text(verbatim: Self.versionLabel)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            Spacer()

            Button("Quit", action: onQuit)
                .glassButtonStyle()
        }
        .padding(.top, DesignTokens.Spacing.xs)
    }

    private static let percent: (Double) -> String = { "\(Int($0 * 100))%" }

    /// 版本號讀 bundle，跟 build 設定一致。
    private static let versionLabel: String = {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "?")"
    }()
}
