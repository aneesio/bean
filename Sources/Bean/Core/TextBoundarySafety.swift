import Foundation

/// Structural text guard shared by replacement surfaces. It compares only line
/// boundary kinds and order; it never stores or logs the surrounding text.
enum TextBoundarySafety {
    private enum Boundary: Equatable {
        case carriageReturn
        case lineFeed
        case carriageReturnLineFeed
        case unicodeLineSeparator
        case unicodeParagraphSeparator
    }

    static func isSingleLine(_ text: String) -> Bool {
        signature(of: text).isEmpty
    }

    static func preservesLineBreakStructure(from original: String,
                                            to replacement: String) -> Bool {
        signature(of: original) == signature(of: replacement)
    }

    private static func signature(of text: String) -> [Boundary] {
        let values = text.unicodeScalars.map(\.value)
        var result: [Boundary] = []
        var index = 0
        while index < values.count {
            switch values[index] {
            case 0x0D where index + 1 < values.count && values[index + 1] == 0x0A:
                result.append(.carriageReturnLineFeed)
                index += 2
            case 0x0D:
                result.append(.carriageReturn)
                index += 1
            case 0x0A:
                result.append(.lineFeed)
                index += 1
            case 0x2028:
                result.append(.unicodeLineSeparator)
                index += 1
            case 0x2029:
                result.append(.unicodeParagraphSeparator)
                index += 1
            default:
                index += 1
            }
        }
        return result
    }
}
