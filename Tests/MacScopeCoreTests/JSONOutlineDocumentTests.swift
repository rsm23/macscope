import Foundation
import Testing
@testable import MacScopeCore

@Suite("JSON outline document")
struct JSONOutlineDocumentTests {
    @Test("Nested objects and arrays expose stable fold ranges")
    func nestedFoldRanges() {
        let document = JSONOutlineDocument(text: nestedJSON)

        #expect(document.isValidJSON)
        #expect(document.lines.map(\.lineNumber) == Array(1...11))
        #expect(document.foldableLineNumbers == Set([1, 3, 4, 7]))
        #expect(document.lines[0].closingLineNumber == 11)
        #expect(document.lines[2].closingLineNumber == 10)
        #expect(document.lines[3].closingLineNumber == 6)
        #expect(document.lines[6].closingLineNumber == 9)
    }

    @Test("Expanded lines preserve every original line exactly")
    func expandedTextIsLossless() {
        let document = JSONOutlineDocument(text: nestedJSON)
        let visible = document.visibleLines(collapsedLineNumbers: [])

        #expect(visible.map(\.lineNumber) == Array(1...11))
        #expect(visible.allSatisfy { !$0.isCollapsed && $0.hiddenLineCount == 0 })
        #expect(visible.map(\.text).joined(separator: "\n") == nestedJSON)
    }

    @Test("Collapsing a nested object hides its descendants and closing line")
    func collapseNestedObject() throws {
        let document = JSONOutlineDocument(text: nestedJSON)
        let visible = document.visibleLines(collapsedLineNumbers: [4])
        let folded = try #require(visible.first { $0.lineNumber == 4 })

        #expect(visible.map(\.lineNumber) == [1, 2, 3, 4, 7, 8, 9, 10, 11])
        #expect(folded.text == "    { … },")
        #expect(folded.isFoldable)
        #expect(folded.isCollapsed)
        #expect(folded.closingLineNumber == 6)
        #expect(folded.hiddenLineCount == 2)
    }

    @Test("An outer collapse wins over nested collapsed ranges")
    func nestedCollapsedRanges() throws {
        let document = JSONOutlineDocument(text: nestedJSON)
        let arrayVisible = document.visibleLines(collapsedLineNumbers: [3, 4, 7])
        let arrayFold = try #require(arrayVisible.first { $0.lineNumber == 3 })

        #expect(arrayVisible.map(\.lineNumber) == [1, 2, 3, 11])
        #expect(arrayFold.text == "  \"items\": [ … ]")
        #expect(arrayFold.hiddenLineCount == 7)

        let rootVisible = document.visibleLines(collapsedLineNumbers: [1, 3, 4])
        let rootFold = try #require(rootVisible.first)
        #expect(rootVisible.count == 1)
        #expect(rootFold.lineNumber == 1)
        #expect(rootFold.text == "{ … }")
        #expect(rootFold.hiddenLineCount == 10)
    }

    @Test("Structural characters and escaped quotes inside strings are ignored")
    func stringsDoNotCreateFalseFolds() {
        let text = #"""
        {
          "message": "braces { } and brackets [ ]",
          "quote": "escaped \" } [ still text",
          "slash": "backslash \\ and quote \" { still text",
          "items": [
            "value ] }",
            "escaped quote: \" ["
          ]
        }
        """#
        let document = JSONOutlineDocument(text: text)

        #expect(document.isValidJSON)
        #expect(document.foldableLineNumbers == Set([1, 5]))
        #expect(document.lines[0].closingLineNumber == 9)
        #expect(document.lines[4].closingLineNumber == 8)
    }

    @Test("Balanced but invalid JSON remains fully visible")
    func invalidBalancedTextDoesNotFold() {
        let text = """
        {
          unquoted: [
            1
          ]
        }
        """
        let document = JSONOutlineDocument(text: text)

        #expect(!document.isValidJSON)
        #expect(document.foldableLineNumbers.isEmpty)
        #expect(document.visibleLines(collapsedLineNumbers: [1, 2]).map(\.text).joined(separator: "\n") == text)
    }

    @Test("Unbalanced JSON remains fully visible and never indexes outside the source")
    func unbalancedTextDoesNotFold() {
        let text = """
        {
          "items": [
            1
        }
        """
        let document = JSONOutlineDocument(text: text)
        let visible = document.visibleLines(collapsedLineNumbers: [1, 2, 999])

        #expect(!document.isValidJSON)
        #expect(document.foldableLineNumbers.isEmpty)
        #expect(visible.map(\.lineNumber) == [1, 2, 3, 4])
        #expect(visible.map(\.text).joined(separator: "\n") == text)
    }
}

private let nestedJSON = """
{
  "name": "MacScope",
  "items": [
    {
      "value": 1
    },
    {
      "value": 2
    }
  ]
}
"""
