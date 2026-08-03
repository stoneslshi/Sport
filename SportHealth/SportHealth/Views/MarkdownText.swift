import SwiftUI

/// 轻量 Markdown 渲染器：支持标题(#/##/###)、无序列表(-/*)、有序列表(1.)、
/// 引用(>)、分隔线(---)、行内加粗(**)/斜体(*)/行内代码(`)。
/// 用于渲染大模型返回的 Markdown 文本，避免直接显示源码。
struct MarkdownText: View {
    let markdown: String

    private var blocks: [MDBlock] { MDParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block.kind {
                case .h1:
                    inline(block.text).font(.title2.bold()).padding(.top, 4)
                case .h2:
                    inline(block.text).font(.title3.bold()).padding(.top, 2)
                case .h3:
                    inline(block.text).font(.headline)
                case .bullet:
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.orange).bold()
                        inline(block.text)
                    }
                case .ordered:
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(block.order).").foregroundStyle(.orange).bold()
                            .monospacedDigit()
                        inline(block.text)
                    }
                case .quote:
                    HStack(spacing: 8) {
                        Rectangle().fill(.orange.opacity(0.6)).frame(width: 3)
                        inline(block.text).foregroundStyle(.secondary).italic()
                    }
                case .divider:
                    Divider().padding(.vertical, 2)
                case .paragraph:
                    inline(block.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 行内样式：优先用系统 Markdown 解析器处理 **/*/`
    private func inline(_ text: String) -> Text {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(text)
    }
}

// MARK: - 解析

enum MDBlockKind {
    case h1, h2, h3, bullet, ordered, quote, divider, paragraph
}

struct MDBlock: Identifiable {
    let id = UUID()
    let kind: MDBlockKind
    let text: String
    var order: Int = 0
}

enum MDParser {
    static func parse(_ raw: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line == "---" || line == "***" || line == "___" {
                blocks.append(MDBlock(kind: .divider, text: ""))
            } else if line.hasPrefix("### ") {
                blocks.append(MDBlock(kind: .h3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                blocks.append(MDBlock(kind: .h2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                blocks.append(MDBlock(kind: .h1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") {
                blocks.append(MDBlock(kind: .quote, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(MDBlock(kind: .bullet, text: String(line.dropFirst(2))))
            } else if let m = orderedPrefix(line) {
                blocks.append(MDBlock(kind: .ordered, text: m.rest, order: m.num))
            } else {
                blocks.append(MDBlock(kind: .paragraph, text: line))
            }
        }
        return blocks
    }

    /// 匹配 "1. xxx" 形式，返回序号与剩余文本
    private static func orderedPrefix(_ line: String) -> (num: Int, rest: String)? {
        guard let dotRange = line.range(of: ". ") else { return nil }
        let numPart = line[line.startIndex..<dotRange.lowerBound]
        guard let num = Int(numPart) else { return nil }
        return (num, String(line[dotRange.upperBound...]))
    }
}
