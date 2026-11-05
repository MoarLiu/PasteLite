// PasteLiteTheme.swift
// PasteLite 设计令牌（由设计稿导出）。UI 颜色优先使用系统语义色，以便自动适配浅色 / 深色与无障碍设置；
// 下方十六进制值用于品牌元素与强调色。

import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum PL {
    /// 语义色：直接映射到 macOS 系统颜色
    enum Semantic {
        static let label = Color(nsColor: .labelColor)
        static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
        static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
        static let separator = Color(nsColor: .separatorColor)
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let control = Color(nsColor: .controlColor)
        static let danger = Color(nsColor: .systemRed)
    }

    /// 设置 › 外观 › 强调色
    enum Accent: String, CaseIterable, Identifiable {
        case blue
        case purple
        case pink
        case red
        case orange
        case yellow
        case green
        case graphite
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .blue: return Color(hex: 0x0A7CFF)
            case .purple: return Color(hex: 0xA550F0)
            case .pink: return Color(hex: 0xF0428A)
            case .red: return Color(hex: 0xF2464B)
            case .orange: return Color(hex: 0xF5860A)
            case .yellow: return Color(hex: 0xE8B100)
            case .green: return Color(hex: 0x2BB24C)
            case .graphite: return Color(hex: 0x8A8A90)
            }
        }
    }

    /// 功能色
    enum Functional {
        static let success = Color(hex: 0x30C158)
        static let warning = Color(hex: 0xF59E0B)
        static let typeCode = Color(hex: 0x9B5CF6)
        static let typeLink = Color(hex: 0x0A7CFF)
        static let typeConcealed = Color(hex: 0xD97706)
    }

    /// 品牌色（方向 A · 叠纸）
    enum Brand {
        static let coral = Color(hex: 0xFF9466)
        static let pasteRed = Color(hex: 0xF0384D)
        static let deepClip = Color(hex: 0xC41F3A)
        static let ink = Color(hex: 0x1C1B22)
        static let gradient = LinearGradient(colors: [coral, pasteRed], startPoint: .top, endPoint: .bottom)
    }

    enum Radius {
        static let panel: CGFloat = 18
        static let window: CGFloat = 12
        static let menu: CGFloat = 12
        static let group: CGFloat = 10
        static let row: CGFloat = 9
        static let buttonLg: CGFloat = 8
        static let button: CGFloat = 7
        static let buttonSm: CGFloat = 6
        static let kbd: CGFloat = 5
    }

    enum Size {
        static let panel = CGSize(width: 880, height: 560)
        static let panelCompact = CGSize(width: 520, height: 560)
        static let listColumnWidth: CGFloat = 336
        static let searchBarHeight: CGFloat = 58
        static let footerHeight: CGFloat = 50
        static let menuWidth: CGFloat = 312
        static let settingsWidth: CGFloat = 600
    }

    enum Font {
        static let search = SwiftUI.Font.system(size: 19)
        static let titleLarge = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let bodyLarge = SwiftUI.Font.system(size: 14)
        static let body = SwiftUI.Font.system(size: 13)
        static let button = SwiftUI.Font.system(size: 12.5, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let meta = SwiftUI.Font.system(size: 11.5)
        static let micro = SwiftUI.Font.system(size: 11, weight: .semibold)
    }

    enum Motion {
        static let popIn = Animation.timingCurve(0.2, 0.9, 0.3, 1.2, duration: 0.14)
        static let panelIn = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.22)
        static let fade = Animation.easeOut(duration: 0.16)
        static let hudVisible: TimeInterval = 1.7
        static let undoWindow: TimeInterval = 5
    }
}
