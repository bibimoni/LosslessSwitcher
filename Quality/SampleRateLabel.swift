//
//  SampleRateLabel.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI
import AppKit

struct SampleRateLabel: View {
    @EnvironmentObject private var outputDevices: OutputDevices
    var compact: Bool = false

    var body: some View {
        let parts = SampleRateText.parts(sampleRateKHz: outputDevices.currentSampleRate,
                                         bitDepth: outputDevices.currentBitDepth)
        if compact {
            Image(nsImage: Self.renderCompactStatusBarImage(rate: parts.rate, bit: parts.bit, isFlashing: outputDevices.isFlashing))
        } else {
            Image(nsImage: Self.renderStatusBarImage(rate: parts.rate, bit: parts.bit, isFlashing: outputDevices.isFlashing))
        }
    }

    /// 将采样率文本渲染为 NSImage，文字底部对齐以匹配系统状态栏其他图标
    private static func renderStatusBarImage(rate: String, bit: String?, isFlashing: Bool) -> NSImage {
        let statusBarHeight: CGFloat = 22
        let bottomPadding: CGFloat = 3

        let rateFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bitFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let attributed = NSMutableAttributedString()
        let textColor = isFlashing ? NSColor.systemGreen : NSColor.labelColor

        attributed.append(NSAttributedString(string: rate, attributes: [
            .font: rateFont,
            .foregroundColor: textColor
        ]))

        if let bit = bit {
            attributed.append(NSAttributedString(string: " ", attributes: [
                .font: rateFont,
                .foregroundColor: textColor
            ]))
            attributed.append(NSAttributedString(string: bit, attributes: [
                .font: bitFont,
                .foregroundColor: textColor
            ]))
        }

        let textSize = attributed.size()
        let imageWidth = ceil(textSize.width)

        let image = NSImage(size: NSSize(width: imageWidth, height: statusBarHeight), flipped: false) { _ in
            attributed.draw(at: NSPoint(x: 0, y: bottomPadding))
            return true
        }

        // 当不闪烁时，使用模板模式以适应黑白模式切换
        // 当闪烁时，关闭模板模式以显示真实颜色
        image.isTemplate = !isFlashing
        return image
    }

    /// 将采样率渲染为紧凑的两行 NSImage 用于状态栏显示
    private static func renderCompactStatusBarImage(rate: String, bit: String?, isFlashing: Bool) -> NSImage {
        let statusBarHeight: CGFloat = 22
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let textColor = isFlashing ? NSColor.systemGreen : NSColor.labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

        let rateAttr = NSAttributedString(string: rate, attributes: attrs)
        let rateSize = rateAttr.size()

        // Strip "/ " prefix for compact display
        let bitAttr: NSAttributedString?
        let bitSize: NSSize
        if let bit = bit {
            let cleanBit = bit.hasPrefix("/ ") ? String(bit.dropFirst(2)) : bit
            bitAttr = NSAttributedString(string: cleanBit, attributes: attrs)
            bitSize = bitAttr!.size()
        } else {
            bitAttr = nil
            bitSize = .zero
        }

        let maxWidth = ceil(max(rateSize.width, bitSize.width))

        let image = NSImage(size: NSSize(width: maxWidth, height: statusBarHeight), flipped: false) { _ in
            if let bitAttr = bitAttr {
                let totalHeight = rateSize.height + bitSize.height
                let startY = (statusBarHeight - totalHeight) / 2
                // Bottom line: bit depth
                bitAttr.draw(at: NSPoint(x: 0, y: startY))
                // Top line: sample rate
                rateAttr.draw(at: NSPoint(x: 0, y: startY + bitSize.height))
            } else {
                // Single line centered
                let startY = (statusBarHeight - rateSize.height) / 2
                rateAttr.draw(at: NSPoint(x: 0, y: startY))
            }
            return true
        }

        image.isTemplate = !isFlashing
        return image
    }
}
