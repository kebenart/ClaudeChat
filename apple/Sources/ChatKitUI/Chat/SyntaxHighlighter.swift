import ChatKit
import SwiftUI

// MARK: - SyntaxHighlighter
//
// Minimal, regex-based syntax highlighter. No external dependencies. Covers
// the languages Claude responses commonly contain: Swift, JS/TS, Python,
// Rust, Go, Bash/sh, JSON, YAML, HTML/XML, CSS. Unknown languages fall back
// to plain (uncoloured) monospaced text.
//
// The highlighter returns an `AttributedString` ready for `Text(_:)`.
// Per-token foreground colours are applied via `AttributedString` runs.

public enum SyntaxHighlighter {

    public static func highlight(_ source: String, language: String?) -> AttributedString {
        var attr = AttributedString(source)
        attr.foregroundColor = SyntaxColors.plain   // base colour

        guard let lang = language?.lowercased(),
              let spec = languageSpec(for: lang) else {
            return attr
        }

        applyTokens(in: &attr, source: source, spec: spec)
        return attr
    }

    // MARK: - Token application

    private static func applyTokens(in attr: inout AttributedString,
                                    source: String,
                                    spec: LanguageSpec) {
        // Order matters: comments / strings first so they "shadow" keywords / numbers
        // that happen to live inside them.
        applyPattern(spec.commentPatterns, color: SyntaxColors.comment, in: &attr, source: source)
        applyPattern(spec.stringPatterns,  color: SyntaxColors.string,  in: &attr, source: source)
        applyPattern(spec.numberPatterns,  color: SyntaxColors.number,  in: &attr, source: source)
        if !spec.keywords.isEmpty {
            applyKeywords(spec.keywords, color: SyntaxColors.keyword, in: &attr, source: source)
        }
        if !spec.builtins.isEmpty {
            applyKeywords(spec.builtins, color: SyntaxColors.builtin, in: &attr, source: source)
        }
    }

    private static func applyPattern(_ patterns: [String], color: Color,
                                     in attr: inout AttributedString,
                                     source: String) {
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: []) else { continue }
            let ns = NSRange(source.startIndex..., in: source)
            for m in regex.matches(in: source, range: ns) {
                if let r = Range(m.range, in: source),
                   let attrRange = Range(r, in: attr) {
                    attr[attrRange].foregroundColor = color
                }
            }
        }
    }

    private static func applyKeywords(_ words: Set<String>, color: Color,
                                      in attr: inout AttributedString,
                                      source: String) {
        // Build one combined regex: \b(word1|word2|...)\b
        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }
        let joined = escaped.joined(separator: "|")
        let pattern = "\\b(?:\(joined))\\b"
        applyPattern([pattern], color: color, in: &attr, source: source)
    }

    // MARK: - Language specs

    struct LanguageSpec {
        let keywords: Set<String>
        let builtins: Set<String>
        let commentPatterns: [String]
        let stringPatterns: [String]
        let numberPatterns: [String]
    }

    private static func languageSpec(for lang: String) -> LanguageSpec? {
        switch lang {
        case "swift":
            return LanguageSpec(
                keywords: ["import", "let", "var", "func", "class", "struct", "enum",
                           "protocol", "extension", "if", "else", "guard", "switch",
                           "case", "default", "return", "for", "in", "while", "do",
                           "try", "throw", "throws", "catch", "self", "Self", "init",
                           "deinit", "public", "private", "internal", "fileprivate",
                           "static", "final", "async", "await", "actor", "nil", "true",
                           "false", "where", "as", "is", "typealias", "associatedtype",
                           "some", "any", "@escaping", "@Sendable", "@MainActor",
                           "@Observable", "@Model", "@State", "@Binding", "@Environment"],
                builtins: ["Int", "String", "Double", "Float", "Bool", "Array", "Dictionary",
                           "Set", "Optional", "Result", "Void", "Date", "URL", "UUID",
                           "Task", "Actor", "Sendable", "Codable", "Decodable", "Encodable"],
                commentPatterns: ["//[^\\n]*", "/\\*[\\s\\S]*?\\*/"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\"", "\"\"\"[\\s\\S]*?\"\"\""],
                numberPatterns: ["\\b[0-9]+(?:\\.[0-9]+)?\\b"]
            )
        case "js", "javascript", "ts", "typescript", "tsx", "jsx":
            return LanguageSpec(
                keywords: ["const", "let", "var", "function", "return", "if", "else",
                           "for", "while", "do", "switch", "case", "break", "continue",
                           "new", "class", "extends", "import", "export", "from", "as",
                           "default", "async", "await", "try", "catch", "finally",
                           "throw", "typeof", "instanceof", "in", "of", "this", "super",
                           "null", "undefined", "true", "false", "void", "delete",
                           "yield", "interface", "type", "enum", "implements", "public",
                           "private", "protected", "readonly", "static"],
                builtins: ["console", "window", "document", "Array", "Object", "String",
                           "Number", "Boolean", "Promise", "Math", "JSON", "Date",
                           "RegExp", "Map", "Set", "Symbol", "Error"],
                commentPatterns: ["//[^\\n]*", "/\\*[\\s\\S]*?\\*/"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\"", "'(?:[^'\\\\]|\\\\.)*'",
                                 "`(?:[^`\\\\]|\\\\.)*`"],
                numberPatterns: ["\\b[0-9]+(?:\\.[0-9]+)?\\b"]
            )
        case "python", "py":
            return LanguageSpec(
                keywords: ["def", "class", "return", "if", "elif", "else", "for", "while",
                           "in", "not", "and", "or", "is", "import", "from", "as",
                           "True", "False", "None", "try", "except", "finally", "raise",
                           "with", "yield", "lambda", "pass", "break", "continue", "global",
                           "nonlocal", "async", "await", "self", "cls"],
                builtins: ["print", "len", "range", "list", "dict", "set", "tuple", "str",
                           "int", "float", "bool", "type", "isinstance", "map", "filter",
                           "zip", "enumerate", "sorted", "reversed", "sum", "min", "max",
                           "open", "input"],
                commentPatterns: ["#[^\\n]*"],
                stringPatterns: ["\"\"\"[\\s\\S]*?\"\"\"", "'''[\\s\\S]*?'''",
                                 "\"(?:[^\"\\\\]|\\\\.)*\"", "'(?:[^'\\\\]|\\\\.)*'"],
                numberPatterns: ["\\b[0-9]+(?:\\.[0-9]+)?\\b"]
            )
        case "rust", "rs":
            return LanguageSpec(
                keywords: ["fn", "let", "mut", "const", "static", "pub", "use", "mod",
                           "struct", "enum", "trait", "impl", "for", "where", "if", "else",
                           "match", "return", "while", "loop", "in", "break", "continue",
                           "as", "ref", "self", "Self", "Box", "true", "false", "async",
                           "await", "move", "dyn", "type", "crate", "super", "extern",
                           "unsafe", "Result", "Option", "Some", "None", "Ok", "Err"],
                builtins: ["String", "Vec", "Box", "Rc", "Arc", "Mutex", "i32", "i64",
                           "u32", "u64", "f32", "f64", "bool", "char", "str", "usize", "isize"],
                commentPatterns: ["//[^\\n]*", "/\\*[\\s\\S]*?\\*/"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\""],
                numberPatterns: ["\\b[0-9]+(?:\\.[0-9]+)?\\b"]
            )
        case "go", "golang":
            return LanguageSpec(
                keywords: ["func", "var", "const", "type", "struct", "interface", "import",
                           "package", "return", "if", "else", "for", "range", "switch",
                           "case", "default", "break", "continue", "go", "defer", "chan",
                           "map", "select", "true", "false", "nil"],
                builtins: ["string", "int", "int32", "int64", "uint", "uint32", "uint64",
                           "float32", "float64", "bool", "byte", "rune", "error",
                           "make", "new", "len", "cap", "append", "copy", "delete",
                           "print", "println", "panic", "recover"],
                commentPatterns: ["//[^\\n]*", "/\\*[\\s\\S]*?\\*/"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\"", "`[^`]*`"],
                numberPatterns: ["\\b[0-9]+(?:\\.[0-9]+)?\\b"]
            )
        case "bash", "sh", "zsh", "shell":
            return LanguageSpec(
                keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done",
                           "while", "case", "esac", "function", "return", "exit", "echo",
                           "export", "source", "alias", "unset", "local", "readonly"],
                builtins: ["cd", "ls", "cat", "grep", "sed", "awk", "find", "git", "npm",
                           "node", "python", "swift", "curl", "wget", "rm", "mv", "cp",
                           "mkdir", "touch"],
                commentPatterns: ["#[^\\n]*"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\"", "'[^']*'"],
                numberPatterns: ["\\b[0-9]+\\b"]
            )
        case "json":
            return LanguageSpec(
                keywords: ["true", "false", "null"],
                builtins: [],
                commentPatterns: [],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\""],
                numberPatterns: ["-?\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b"]
            )
        case "yaml", "yml":
            return LanguageSpec(
                keywords: ["true", "false", "null", "yes", "no"],
                builtins: [],
                commentPatterns: ["#[^\\n]*"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\"", "'[^']*'"],
                numberPatterns: ["\\b[0-9]+(?:\\.[0-9]+)?\\b"]
            )
        case "html", "xml", "svg":
            return LanguageSpec(
                keywords: [],
                builtins: [],
                commentPatterns: ["<!--[\\s\\S]*?-->"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\"", "'[^']*'"],
                numberPatterns: []
            )
        case "css", "scss", "sass":
            return LanguageSpec(
                keywords: [],
                builtins: ["color", "background", "margin", "padding", "border",
                           "font", "display", "position", "width", "height"],
                commentPatterns: ["/\\*[\\s\\S]*?\\*/"],
                stringPatterns: ["\"(?:[^\"\\\\]|\\\\.)*\"", "'[^']*'"],
                numberPatterns: ["\\b[0-9]+(?:\\.[0-9]+)?(?:px|em|rem|%|vh|vw)?\\b"]
            )
        default:
            return nil
        }
    }
}

// MARK: - Colours
// Dynamic: tuned for the light code card in light mode, and brightened to the
// VSCode-dark family in dark mode so syntax stays legible on the dark card.

private enum SyntaxColors {
    static let plain   = syntax(light: "#1a1a1f", dark: "#d4d4d4")   // near-black / off-white
    static let comment = syntax(light: "#668c73", dark: "#6a9955")   // muted green
    static let keyword = syntax(light: "#a61a73", dark: "#c586c0")   // magenta
    static let builtin = syntax(light: "#4d4dbf", dark: "#569cd6")   // indigo / blue
    static let string  = syntax(light: "#1a668c", dark: "#ce9178")   // teal / salmon
    static let number  = syntax(light: "#bf4d1a", dark: "#b5cea8")   // orange / green
}

#if canImport(AppKit)
import AppKit
/// A syntax color that resolves light/dark from the code card's appearance.
private func syntax(light: String, dark: String) -> Color {
    let l = NSColor(hex: light), d = NSColor(hex: dark)
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
    })
}
#else
private func syntax(light: String, dark: String) -> Color { Color(hex: light) }
#endif
