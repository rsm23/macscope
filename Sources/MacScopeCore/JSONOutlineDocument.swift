import Foundation

/// One immutable source line in a pretty-printed JSON document.
public struct JSONOutlineLine: Identifiable, Hashable, Sendable {
    public var id: Int { lineNumber }
    public let lineNumber: Int
    public let text: String
    public let closingLineNumber: Int?
    public let collapsedText: String?

    public var isFoldable: Bool {
        closingLineNumber != nil && collapsedText != nil
    }

    public init(
        lineNumber: Int,
        text: String,
        closingLineNumber: Int? = nil,
        collapsedText: String? = nil
    ) {
        self.lineNumber = lineNumber
        self.text = text
        self.closingLineNumber = closingLineNumber
        self.collapsedText = collapsedText
    }
}

/// A source line after applying the caller's current collapsed-line set.
public struct JSONOutlineVisibleLine: Identifiable, Hashable, Sendable {
    public var id: Int { lineNumber }
    public let lineNumber: Int
    public let text: String
    public let isFoldable: Bool
    public let isCollapsed: Bool
    public let closingLineNumber: Int?
    /// Number of original source lines hidden after this line. For a collapsed
    /// range this includes the matching closing-delimiter line.
    public let hiddenLineCount: Int

    public init(
        lineNumber: Int,
        text: String,
        isFoldable: Bool,
        isCollapsed: Bool,
        closingLineNumber: Int?,
        hiddenLineCount: Int
    ) {
        self.lineNumber = lineNumber
        self.text = text
        self.isFoldable = isFoldable
        self.isCollapsed = isCollapsed
        self.closingLineNumber = closingLineNumber
        self.hiddenLineCount = hiddenLineCount
    }
}

/// Lossless line-oriented representation of pretty-printed JSON with optional
/// object and array folding. Invalid JSON intentionally produces no fold ranges.
public struct JSONOutlineDocument: Hashable, Sendable {
    public let originalText: String
    public let isValidJSON: Bool
    public let lines: [JSONOutlineLine]

    public var foldableLineNumbers: Set<Int> {
        Set(lines.lazy.filter(\.isFoldable).map(\.lineNumber))
    }

    public init(text: String) {
        originalText = text
        let sourceLines = text.components(separatedBy: "\n")
        let valid = Self.isValidJSONText(text)
        isValidJSON = valid
        let folds = valid ? (Self.findFolds(in: sourceLines) ?? [:]) : [:]
        lines = sourceLines.enumerated().map { index, text in
            let fold = folds[index]
            return JSONOutlineLine(
                lineNumber: index + 1,
                text: text,
                closingLineNumber: fold.map { $0.closingLineIndex + 1 },
                collapsedText: fold?.collapsedText
            )
        }
    }

    /// Applies collapsed ranges from top to bottom. When an outer range is
    /// collapsed, nested entries in the set are naturally hidden with it.
    public func visibleLines(collapsedLineNumbers: Set<Int>) -> [JSONOutlineVisibleLine] {
        var visible: [JSONOutlineVisibleLine] = []
        visible.reserveCapacity(lines.count)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if collapsedLineNumbers.contains(line.lineNumber),
               let closingLineNumber = line.closingLineNumber,
               let collapsedText = line.collapsedText,
               closingLineNumber > line.lineNumber,
               closingLineNumber <= lines.count {
                visible.append(JSONOutlineVisibleLine(
                    lineNumber: line.lineNumber,
                    text: collapsedText,
                    isFoldable: true,
                    isCollapsed: true,
                    closingLineNumber: closingLineNumber,
                    hiddenLineCount: closingLineNumber - line.lineNumber
                ))
                // Line numbers are one-based, so the closing line number is the
                // zero-based index of the first line after the collapsed range.
                index = closingLineNumber
            } else {
                visible.append(JSONOutlineVisibleLine(
                    lineNumber: line.lineNumber,
                    text: line.text,
                    isFoldable: line.isFoldable,
                    isCollapsed: false,
                    closingLineNumber: line.closingLineNumber,
                    hiddenLineCount: 0
                ))
                index += 1
            }
        }
        return visible
    }

    private struct StackEntry {
        let openingDelimiter: Character
        let lineIndex: Int
        let openingPrefix: String

        var closingDelimiter: Character {
            openingDelimiter == "{" ? "}" : "]"
        }
    }

    private struct Fold {
        let closingLineIndex: Int
        let collapsedText: String
    }

    private static func isValidJSONText(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return true
        } catch {
            return false
        }
    }

    /// Lexes only JSON strings and structural delimiters. Full syntax validity
    /// is checked independently with JSONSerialization before this is called.
    private static func findFolds(in lines: [String]) -> [Int: Fold]? {
        var stack: [StackEntry] = []
        var folds: [Int: Fold] = [:]
        var isInsideString = false
        var isEscaped = false

        for (lineIndex, line) in lines.enumerated() {
            var characterIndex = line.startIndex
            while characterIndex < line.endIndex {
                let character = line[characterIndex]

                if isInsideString {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "\"" {
                        isInsideString = false
                    }
                    characterIndex = line.index(after: characterIndex)
                    continue
                }

                switch character {
                case "\"":
                    isInsideString = true
                case "{", "[":
                    stack.append(StackEntry(
                        openingDelimiter: character,
                        lineIndex: lineIndex,
                        openingPrefix: String(line[...characterIndex])
                    ))
                case "}", "]":
                    guard let opener = stack.popLast(), opener.closingDelimiter == character else {
                        return nil
                    }
                    guard lineIndex > opener.lineIndex else { break }

                    let closingSuffix = String(line[characterIndex...])
                    let fold = Fold(
                        closingLineIndex: lineIndex,
                        collapsedText: opener.openingPrefix + " … " + closingSuffix
                    )
                    // Multiple openers can technically occur on one source
                    // line. Folding that line uses its outermost complete range.
                    if let existing = folds[opener.lineIndex] {
                        if fold.closingLineIndex > existing.closingLineIndex {
                            folds[opener.lineIndex] = fold
                        }
                    } else {
                        folds[opener.lineIndex] = fold
                    }
                default:
                    break
                }

                characterIndex = line.index(after: characterIndex)
            }
        }

        guard stack.isEmpty, !isInsideString, !isEscaped else { return nil }
        return folds
    }
}
