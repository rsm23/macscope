import Foundation

public enum UtilitySupport {
    public static let maximumAppVolume = 2.0

    public static func sanitizedAppVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), maximumAppVolume)
    }

    public static func isUnityVolume(_ value: Double) -> Bool {
        abs(sanitizedAppVolume(value) - 1) < 0.005
    }

    public static func requiresAudioTap(volume: Double, hasCustomOutput: Bool) -> Bool {
        !isUnityVolume(volume) || hasCustomOutput
    }

    public static func arithmeticResult(_ expression: String) -> Double? {
        var parser = ArithmeticParser(expression)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return value
    }

    public struct UnitConversionResult: Equatable, Sendable {
        public let value: Double
        public let unit: String

        public init(value: Double, unit: String) {
            self.value = value
            self.unit = unit
        }
    }

    public struct DateCalculationResult: Equatable, Sendable {
        public let date: Date
        public let description: String

        public init(date: Date, description: String) {
            self.date = date
            self.description = description
        }
    }

    public static func dateCalculation(
        _ expression: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DateCalculationResult? {
        let normalized = expression.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "today", "date today": return .init(date: now, description: "Today")
        case "tomorrow", "date tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: now).map { .init(date: $0, description: "Tomorrow") }
        case "yesterday", "date yesterday":
            return calendar.date(byAdding: .day, value: -1, to: now).map { .init(date: $0, description: "Yesterday") }
        default: break
        }
        if normalized.hasPrefix("unix "),
           let seconds = TimeInterval(normalized.dropFirst(5).trimmingCharacters(in: .whitespaces)),
           seconds.isFinite {
            return .init(date: Date(timeIntervalSince1970: seconds), description: "Unix timestamp")
        }
        let future = #"^(?:in\s+)?(\d+)\s+(minute|minutes|hour|hours|day|days|week|weeks)(?:\s+from\s+now)?$"#
        let past = #"^(\d+)\s+(minute|minutes|hour|hours|day|days|week|weeks)\s+ago$"#
        if let match = relativeDateMatch(future, in: normalized),
           let date = calendar.date(byAdding: match.component, value: match.value, to: now) {
            return .init(date: date, description: "\(match.value) \(match.unit) from now")
        }
        if let match = relativeDateMatch(past, in: normalized),
           let date = calendar.date(byAdding: match.component, value: -match.value, to: now) {
            return .init(date: date, description: "\(match.value) \(match.unit) ago")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: expression.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .init(date: date, description: "Parsed date")
            }
        }
        return nil
    }

    public static func unitConversion(_ expression: String) -> UnitConversionResult? {
        let pattern = #"^\s*([+-]?(?:\d+(?:[\.,]\d*)?|[\.,]\d+))\s*([A-Za-z°]+)\s+(?:to|in)\s+([A-Za-z°]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        guard let match = regex.firstMatch(in: expression, range: range), match.range == range,
              let numberRange = Range(match.range(at: 1), in: expression),
              let sourceRange = Range(match.range(at: 2), in: expression),
              let destinationRange = Range(match.range(at: 3), in: expression),
              let number = Double(expression[numberRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let source = normalizedUnit(String(expression[sourceRange]))
        let destination = normalizedUnit(String(expression[destinationRange]))

        if let sourceTemperature = temperatureUnit(source),
           let destinationTemperature = temperatureUnit(destination) {
            let celsius: Double
            switch sourceTemperature {
            case "c": celsius = number
            case "f": celsius = (number - 32) * 5 / 9
            default: celsius = number - 273.15
            }
            let result: Double
            switch destinationTemperature {
            case "c": result = celsius
            case "f": result = celsius * 9 / 5 + 32
            default: result = celsius + 273.15
            }
            return result.isFinite ? UnitConversionResult(value: result, unit: displayUnit(destinationTemperature)) : nil
        }

        for family in conversionFamilies {
            guard let sourceFactor = family[source], let destinationFactor = family[destination] else { continue }
            let result = number * sourceFactor / destinationFactor
            return result.isFinite ? UnitConversionResult(value: result, unit: displayUnit(destination)) : nil
        }
        return nil
    }

    public static func screenshotFilename(
        at date: Date,
        prefix: String = "MacScope",
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let normalizedPrefix = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
                    ? character : "-"
            }
        let safePrefix = String(normalizedPrefix.prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(
            format: "%@-%04d-%02d-%02d-%02d%02d%02d.png",
            safePrefix.isEmpty ? "MacScope" : safePrefix,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    public static func colorStrings(red: Double, green: Double, blue: Double) -> (
        hex: String, rgb: String, hsl: String, swiftUI: String
    ) {
        let red = min(max(red.isFinite ? red : 0, 0), 1)
        let green = min(max(green.isFinite ? green : 0, 0), 1)
        let blue = min(max(blue.isFinite ? blue : 0, 0), 1)
        let redByte = Int((red * 255).rounded())
        let greenByte = Int((green * 255).rounded())
        let blueByte = Int((blue * 255).rounded())
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        let rawHue: Double
        if delta == 0 { rawHue = 0 }
        else if maximum == red { rawHue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if maximum == green { rawHue = 60 * ((blue - red) / delta + 2) }
        else { rawHue = 60 * ((red - green) / delta + 4) }
        let hue = rawHue < 0 ? rawHue + 360 : rawHue
        return (
            String(format: "#%02X%02X%02X", redByte, greenByte, blueByte),
            "rgb(\(redByte), \(greenByte), \(blueByte))",
            "hsl(\(Int(hue.rounded()))°, \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)",
            String(
                format: "Color(red: %.3f, green: %.3f, blue: %.3f)",
                red, green, blue
            )
        )
    }

    public enum WindowPlacement: String, CaseIterable, Sendable {
        case leftHalf
        case rightHalf
        case leftThird
        case centerThird
        case rightThird
        case topHalf
        case bottomHalf
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
        case maximize
        case centered
    }

    public struct WindowFrame: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public static func windowFrame(
        for placement: WindowPlacement,
        in available: WindowFrame
    ) -> WindowFrame {
        switch placement {
        case .leftHalf:
            WindowFrame(x: available.x, y: available.y, width: available.width / 2, height: available.height)
        case .rightHalf:
            WindowFrame(x: available.x + available.width / 2, y: available.y, width: available.width / 2, height: available.height)
        case .leftThird:
            WindowFrame(x: available.x, y: available.y, width: available.width / 3, height: available.height)
        case .centerThird:
            WindowFrame(x: available.x + available.width / 3, y: available.y, width: available.width / 3, height: available.height)
        case .rightThird:
            WindowFrame(x: available.x + available.width * 2 / 3, y: available.y, width: available.width / 3, height: available.height)
        case .topHalf:
            WindowFrame(x: available.x, y: available.y, width: available.width, height: available.height / 2)
        case .bottomHalf:
            WindowFrame(x: available.x, y: available.y + available.height / 2, width: available.width, height: available.height / 2)
        case .topLeft:
            WindowFrame(x: available.x, y: available.y, width: available.width / 2, height: available.height / 2)
        case .topRight:
            WindowFrame(x: available.x + available.width / 2, y: available.y, width: available.width / 2, height: available.height / 2)
        case .bottomLeft:
            WindowFrame(x: available.x, y: available.y + available.height / 2, width: available.width / 2, height: available.height / 2)
        case .bottomRight:
            WindowFrame(x: available.x + available.width / 2, y: available.y + available.height / 2, width: available.width / 2, height: available.height / 2)
        case .maximize:
            available
        case .centered:
            WindowFrame(
                x: available.x + available.width * 0.1,
                y: available.y + available.height * 0.1,
                width: available.width * 0.8,
                height: available.height * 0.8
            )
        }
    }

    public static func cleanedTrackingURL(
        _ value: String,
        additionalParameters: Set<String> = []
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }

        let blocked = defaultTrackingParameters.union(
            additionalParameters.map { $0.lowercased() }
        )
        let filtered = components.queryItems?.filter { item in
            let key = item.name.lowercased()
            return !blocked.contains(key)
                && !key.hasPrefix("utm_")
                && !key.hasPrefix("mc_")
        }
        components.queryItems = filtered?.isEmpty == true ? nil : filtered
        return components.string
    }

    public static func snippetTitle(for text: String, maximumLength: Int = 48) -> String {
        let firstMeaningfulLine = text
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Untitled snippet"
        guard firstMeaningfulLine.count > maximumLength else { return firstMeaningfulLine }
        return String(firstMeaningfulLine.prefix(maximumLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func expandedSnippetTemplate(
        _ template: String,
        at date: Date = Date(),
        clipboard: String = "",
        localeIdentifier: String = Locale.current.identifier,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) -> String {
        var result = template
        for token in ["date", "time"] {
            let pattern = #"\{"# + token + #":([^{}]{1,64})\}"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let formatRange = Range(match.range(at: 1), in: result) else { continue }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: localeIdentifier)
                formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
                formatter.dateFormat = String(result[formatRange])
                result.replaceSubrange(fullRange, with: formatter.string(from: date))
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: localeIdentifier)
        dateFormatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: localeIdentifier)
        timeFormatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return result
            .replacingOccurrences(of: "{clipboard}", with: clipboard)
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
    }

    private static let defaultTrackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "igshid", "twclid",
        "ref_src", "ref_url", "mkt_tok", "vero_conv", "vero_id",
        "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid"
    ]

    private static func relativeDateMatch(
        _ pattern: String,
        in value: String
    ) -> (value: Int, component: Calendar.Component, unit: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let amountRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let amount = Int(value[amountRange]) else { return nil }
        let rawUnit = String(value[unitRange])
        let component: Calendar.Component
        let unit: String
        if rawUnit.hasPrefix("minute") { component = .minute; unit = amount == 1 ? "minute" : "minutes" }
        else if rawUnit.hasPrefix("hour") { component = .hour; unit = amount == 1 ? "hour" : "hours" }
        else if rawUnit.hasPrefix("week") { component = .weekOfYear; unit = amount == 1 ? "week" : "weeks" }
        else { component = .day; unit = amount == 1 ? "day" : "days" }
        return (min(amount, 1_000_000), component, unit)
    }

    private static let conversionFamilies: [[String: Double]] = [
        ["mm": 0.001, "cm": 0.01, "m": 1, "km": 1_000, "in": 0.0254, "ft": 0.3048, "yd": 0.9144, "mi": 1_609.344],
        ["mg": 0.000_001, "g": 0.001, "kg": 1, "oz": 0.028_349_523_125, "lb": 0.453_592_37],
        ["ms": 0.001, "s": 1, "min": 60, "h": 3_600, "d": 86_400],
        ["b": 1, "kb": 1_000, "mb": 1_000_000, "gb": 1_000_000_000, "tb": 1_000_000_000_000,
         "kib": 1_024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
    ]

    private static func normalizedUnit(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "°", with: "")
        return [
            "meter": "m", "meters": "m", "metre": "m", "metres": "m",
            "kilometer": "km", "kilometers": "km", "kilometre": "km", "kilometres": "km",
            "mile": "mi", "miles": "mi", "inch": "in", "inches": "in",
            "foot": "ft", "feet": "ft", "yard": "yd", "yards": "yd",
            "gram": "g", "grams": "g", "kilogram": "kg", "kilograms": "kg",
            "pound": "lb", "pounds": "lb", "lbs": "lb", "ounce": "oz", "ounces": "oz",
            "sec": "s", "second": "s", "seconds": "s", "minute": "min", "minutes": "min",
            "hr": "h", "hour": "h", "hours": "h", "day": "d", "days": "d",
            "byte": "b", "bytes": "b", "celsius": "c", "fahrenheit": "f", "kelvin": "k"
        ][normalized] ?? normalized
    }

    private static func temperatureUnit(_ unit: String) -> String? {
        ["c", "f", "k"].contains(unit) ? unit : nil
    }

    private static func displayUnit(_ unit: String) -> String {
        switch unit {
        case "c": "°C"
        case "f": "°F"
        case "k": "K"
        default: unit
        }
    }
}

private struct ArithmeticParser {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) { characters = Array(source) }

    mutating func parse() -> Double? {
        guard let result = expression() else { return nil }
        skipWhitespace()
        return index == characters.count ? result : nil
    }

    private mutating func expression() -> Double? {
        guard var value = term() else { return nil }
        while true {
            skipWhitespace()
            if consume("+") { guard let rhs = term() else { return nil }; value += rhs }
            else if consume("-") { guard let rhs = term() else { return nil }; value -= rhs }
            else { return value }
        }
    }

    private mutating func term() -> Double? {
        guard var value = factor() else { return nil }
        while true {
            skipWhitespace()
            if consume("*") { guard let rhs = factor() else { return nil }; value *= rhs }
            else if consume("/") {
                guard let rhs = factor(), rhs != 0 else { return nil }
                value /= rhs
            } else { return value }
        }
    }

    private mutating func factor() -> Double? {
        skipWhitespace()
        if consume("+") { return factor() }
        if consume("-") { return factor().map(-) }
        if consume("(") {
            guard let value = expression() else { return nil }
            skipWhitespace()
            return consume(")") ? value : nil
        }
        let start = index
        var sawDigit = false
        var sawPoint = false
        while index < characters.count {
            let character = characters[index]
            if character.isNumber { sawDigit = true; index += 1 }
            else if character == ".", !sawPoint { sawPoint = true; index += 1 }
            else { break }
        }
        guard sawDigit else { index = start; return nil }
        return Double(String(characters[start..<index]))
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }

    private mutating func consume(_ expected: Character) -> Bool {
        guard index < characters.count, characters[index] == expected else { return false }
        index += 1
        return true
    }
}
