import Foundation
import Testing
@testable import MacScopeCore

@Test func appVolumeIsFiniteAndClamped() {
    #expect(UtilitySupport.sanitizedAppVolume(-1) == 0)
    #expect(UtilitySupport.sanitizedAppVolume(0.42) == 0.42)
    #expect(UtilitySupport.sanitizedAppVolume(4) == 2)
    #expect(UtilitySupport.sanitizedAppVolume(.nan) == 1)
    #expect(UtilitySupport.isUnityVolume(1.004))
    #expect(!UtilitySupport.isUnityVolume(1.02))
    #expect(!UtilitySupport.requiresAudioTap(volume: 1, hasCustomOutput: false))
    #expect(UtilitySupport.requiresAudioTap(volume: 1, hasCustomOutput: true))
    #expect(UtilitySupport.requiresAudioTap(volume: 0.75, hasCustomOutput: false))
}

@Test func commandBarArithmeticUsesNormalPrecedenceAndRejectsInvalidInput() {
    #expect(UtilitySupport.arithmeticResult("2 + 3 * 4") == 14)
    #expect(UtilitySupport.arithmeticResult("(2 + 3) * -4") == -20)
    #expect(UtilitySupport.arithmeticResult("1 / 0") == nil)
    #expect(UtilitySupport.arithmeticResult("2 + hello") == nil)
}

@Test func commandBarUnitConversionsCoverPhysicalAndDigitalUnits() {
    let miles = UtilitySupport.unitConversion("10 km to mi")
    #expect(miles?.unit == "mi")
    #expect(abs((miles?.value ?? 0) - 6.213_711_922) < 0.000_001)

    #expect(UtilitySupport.unitConversion("72 F to C") == .init(value: 22.222_222_222_222_22, unit: "°C"))
    #expect(UtilitySupport.unitConversion("1 GiB to MiB") == .init(value: 1_024, unit: "mib"))
    #expect(UtilitySupport.unitConversion("2 hours in minutes") == .init(value: 120, unit: "min"))
    #expect(UtilitySupport.unitConversion("10 kg to nonsense") == nil)
}

@Test func commandBarDateCalculationsAreDeterministicAndBounded() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(UtilitySupport.dateCalculation("tomorrow", now: now, calendar: calendar)?.date == now.addingTimeInterval(86_400))
    #expect(UtilitySupport.dateCalculation("in 2 weeks", now: now, calendar: calendar)?.date == now.addingTimeInterval(14 * 86_400))
    #expect(UtilitySupport.dateCalculation("3 hours ago", now: now, calendar: calendar)?.date == now.addingTimeInterval(-10_800))
    #expect(UtilitySupport.dateCalculation("unix 0", now: now, calendar: calendar)?.date == Date(timeIntervalSince1970: 0))
    #expect(UtilitySupport.dateCalculation("not a date", now: now, calendar: calendar) == nil)
}

@Test func screenshotFilenameIsStableAndFilesystemSafe() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 28, hour: 9, minute: 7, second: 3
    ))!
    #expect(UtilitySupport.screenshotFilename(at: date, calendar: calendar) == "MacScope-2026-08-28-090703.png")
    #expect(UtilitySupport.screenshotFilename(at: date, prefix: "Client / Demo", calendar: calendar) == "Client---Demo-2026-08-28-090703.png")
    #expect(UtilitySupport.screenshotFilename(at: date, prefix: "***", calendar: calendar) == "MacScope-2026-08-28-090703.png")
}

@Test func colorStringsAreClampedAndReadyToPaste() {
    let color = UtilitySupport.colorStrings(red: 1.2, green: 0.5, blue: -.nan)
    #expect(color.hex == "#FF8000")
    #expect(color.rgb == "rgb(255, 128, 0)")
    #expect(color.hsl == "hsl(30°, 100%, 50%)")
    #expect(color.swiftUI == "Color(red: 1.000, green: 0.500, blue: 0.000)")
}

@Test func windowPlacementsStayInsideTheAvailableScreen() {
    let screen = UtilitySupport.WindowFrame(x: 100, y: 40, width: 1200, height: 800)
    #expect(UtilitySupport.windowFrame(for: .leftHalf, in: screen) == .init(x: 100, y: 40, width: 600, height: 800))
    #expect(UtilitySupport.windowFrame(for: .rightHalf, in: screen) == .init(x: 700, y: 40, width: 600, height: 800))
    #expect(UtilitySupport.windowFrame(for: .centerThird, in: screen) == .init(x: 500, y: 40, width: 400, height: 800))
    #expect(UtilitySupport.windowFrame(for: .bottomHalf, in: screen) == .init(x: 100, y: 440, width: 1200, height: 400))
    #expect(UtilitySupport.windowFrame(for: .bottomRight, in: screen) == .init(x: 700, y: 440, width: 600, height: 400))
    #expect(UtilitySupport.windowFrame(for: .centered, in: screen) == .init(x: 220, y: 120, width: 960, height: 640))
}

@Test func trackingURLCleanerPreservesMeaningfulParameters() {
    let source = "https://example.com/article?q=swift&utm_source=newsletter&fbclid=abc#part"
    #expect(UtilitySupport.cleanedTrackingURL(source) == "https://example.com/article?q=swift#part")
    #expect(UtilitySupport.cleanedTrackingURL("not a url") == nil)
}

@Test func trackingURLCleanerSupportsCustomParameters() {
    let source = "https://example.com/?campaign=summer&item=42"
    #expect(UtilitySupport.cleanedTrackingURL(source, additionalParameters: ["campaign"]) == "https://example.com/?item=42")
}

@Test func snippetTitlesUseTheFirstUsefulLineAndStayBounded() {
    #expect(UtilitySupport.snippetTitle(for: "\n  Deploy checklist  \nsecond") == "Deploy checklist")
    #expect(UtilitySupport.snippetTitle(for: "123456789", maximumLength: 5) == "12345…")
    #expect(UtilitySupport.snippetTitle(for: "\n \n") == "Untitled snippet")
}

@Test func snippetTemplatesSupportClipboardAndCustomDateFormats() {
    let date = Date(timeIntervalSince1970: 1_725_151_845)
    let expanded = UtilitySupport.expandedSnippetTemplate(
        "{clipboard} · {date:yyyy-MM-dd} · {time:HH:mm}",
        at: date,
        clipboard: "Copied",
        localeIdentifier: "en_US_POSIX",
        timeZoneIdentifier: "UTC"
    )
    #expect(expanded == "Copied · 2024-09-01 · 00:50")
}
