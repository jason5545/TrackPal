// TrackPal/Views/Components/TrackpadDiagramView.swift
import SwiftUI

/// Visual diagram showing trackpad zones
struct TrackpadDiagramView: View {
    let edgeWidth: CGFloat
    let bottomHeight: CGFloat
    let edgeMode: TrackpadZoneScroller.VerticalEdgeMode
    let horizontalPosition: TrackpadZoneScroller.HorizontalPosition
    let middleClickEnabled: Bool

    private var showLeftEdge: Bool {
        edgeMode == .left || edgeMode == .both
    }

    private var showRightEdge: Bool {
        edgeMode == .right || edgeMode == .both
    }

    private let middleClickZoneWidth: CGFloat = 0.30
    private let middleClickZoneHeight: CGFloat = 0.15

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let edgePixels = width * edgeWidth
            let horizontalZonePixels = height * bottomHeight
            let middleClickWidth = width * middleClickZoneWidth
            let middleClickHeight = height * middleClickZoneHeight

            ZStack {
                // Trackpad outline
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )

                // Left edge zone
                if showLeftEdge {
                    Rectangle()
                        .fill(DesignTokens.Colors.verticalZone)
                        .frame(width: edgePixels)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(2)
                }

                // Right edge zone
                if showRightEdge {
                    Rectangle()
                        .fill(DesignTokens.Colors.verticalZone)
                        .frame(width: edgePixels)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(2)
                }

                // Horizontal scrolling zone (bottom or top based on position)
                Rectangle()
                    .fill(DesignTokens.Colors.horizontalZone)
                    .frame(height: horizontalZonePixels)
                    .frame(maxHeight: .infinity, alignment: horizontalPosition == .bottom ? .bottom : .top)
                    .padding(.horizontal, (showLeftEdge ? edgePixels : 0) + 2)
                    .padding(.trailing, (showRightEdge ? edgePixels : 0))
                    .padding(2)

                // Middle click zone (opposite of horizontal position)
                if middleClickEnabled {
                    Rectangle()
                        .fill(DesignTokens.Colors.middleClickZone)
                        .frame(width: middleClickWidth, height: middleClickHeight)
                        .frame(maxHeight: .infinity, alignment: horizontalPosition == .bottom ? .top : .bottom)
                        .padding(2)
                }

                // Labels
                VStack {
                    // Top label
                    if horizontalPosition == .top {
                        Text("↔")
                            .font(.system(size: 14))
                            .padding(.top, 4)
                    } else if middleClickEnabled {
                        Text("🖱")
                            .font(.system(size: 10))
                            .padding(.top, 4)
                    }

                    Spacer()

                    // Side labels
                    HStack {
                        if showLeftEdge {
                            Text("↕")
                                .font(.system(size: 14))
                                .frame(width: edgePixels)
                        } else {
                            Spacer().frame(width: edgePixels)
                        }
                        Spacer()
                        if showRightEdge {
                            Text("↕")
                                .font(.system(size: 14))
                                .frame(width: edgePixels)
                        } else {
                            Spacer().frame(width: edgePixels)
                        }
                    }

                    Spacer()

                    // Bottom label
                    if horizontalPosition == .bottom {
                        Text("↔")
                            .font(.system(size: 14))
                            .padding(.bottom, 4)
                    } else if middleClickEnabled {
                        Text("🖱")
                            .font(.system(size: 10))
                            .padding(.bottom, 4)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(height: DesignTokens.Dimensions.trackpadDiagramHeight)
    }
}

/// Legend for trackpad zones
struct TrackpadLegendView: View {
    let middleClickEnabled: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Rectangle()
                    .fill(DesignTokens.Colors.verticalZone)
                    .frame(width: 12, height: 12)
                    .cornerRadius(2)
                Text("上下捲動")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Rectangle()
                    .fill(DesignTokens.Colors.horizontalZone)
                    .frame(width: 12, height: 12)
                    .cornerRadius(2)
                Text("水平捲動")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            if middleClickEnabled {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Rectangle()
                        .fill(DesignTokens.Colors.middleClickZone)
                        .frame(width: 12, height: 12)
                        .cornerRadius(2)
                    Text("中鍵")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        TrackpadDiagramView(
            edgeWidth: 0.15,
            bottomHeight: 0.20,
            edgeMode: .right,
            horizontalPosition: .bottom,
            middleClickEnabled: true
        )
        TrackpadLegendView(middleClickEnabled: true)
    }
    .padding()
    .frame(width: 300)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
