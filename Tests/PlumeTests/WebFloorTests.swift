import XCTest
@testable import Plume

/// The scripts Plume injects must run on the oldest WebKit it supports: the
/// system WebKit of macOS 13.3, Safari 16.4. The unit tests that execute them
/// use this Mac's JavaScriptCore, which accepts everything newer, so nothing
/// else would notice a newer API slipping in, and on 13.3 a syntax error takes
/// the whole script down with it. This keeps the floor by name.
final class WebFloorTests: XCTestCase {

    /// APIs newer than Safari 16.4 (MDN browser-compat data). Everything the
    /// scripts use today, up to `findLast`, `structuredClone` and `static {}`
    /// blocks, is at or below 16.4.
    static let forbiddenJS = [
        "groupBy(",            // Object/Map.groupBy, Safari 17.4
        "withResolvers",       // Promise.withResolvers, 17.4
        "Promise.try",         // 18.2
        "RegExp.escape",       // 18.2
        ".union(", ".intersection(", ".difference(", ".symmetricDifference(",
        ".isSubsetOf(", ".isSupersetOf(", ".isDisjointFrom(",   // Set methods, 17
        "Iterator.",           // iterator helpers, 18.4
    ]

    /// CSS newer than Safari 16.4.
    static let forbiddenCSS = [
        "&",                   // nesting, 17.2
        "@scope",              // 17.4
        "@starting-style",     // 17.5
        "light-dark(",         // 17.5
    ]

    private var scripts: [(String, String)] {
        [("source", InjectedScript.source), ("deleteThreadJS", InjectedScript.deleteThreadJS)]
    }

    func testInjectedJavaScriptStaysWithinSafari16_4() {
        for (name, script) in scripts {
            let scan = JSScan.scan(script)
            // A mis-read regex or string would hide the rest of the script
            // from the checks; the helpers every script defines must be seen.
            XCTAssertTrue(scan.code.contains("plumeListRows"), "\(name): scanner lost the code")
            XCTAssertTrue(scan.code.contains("querySelectorAll"), "\(name): scanner lost the code")
            if name == "source" {   // its last part: the context-menu hook
                XCTAssertTrue(scan.code.contains("addEventListener"), "source: scanner stopped early")
            }
            for api in Self.forbiddenJS {
                XCTAssertFalse(scan.code.contains(api), "\(name) uses \(api), newer than Safari 16.4")
            }
            for flags in scan.regexFlags {
                XCTAssertFalse(flags.contains("v"), "\(name) has a regex with the v flag (Safari 17)")
            }
        }
    }

    func testInjectedCSSStaysWithinSafari16_4() {
        for (name, css) in [("densityCSS", InjectedScript.densityCSS),
                            ("cardThreadCSS", InjectedScript.cardThreadCSS)] {
            for feature in Self.forbiddenCSS {
                XCTAssertFalse(css.contains(feature), "\(name) uses \(feature), newer than Safari 16.4")
            }
        }
    }

    // The scanner itself: what it must catch, and what it must not.
    func testScannerSeesCodeOnly() {
        func code(_ s: String) -> String { JSScan.scan(s).code }
        XCTAssertTrue(code("var x = a.union(b);").contains(".union("))
        XCTAssertTrue(code("Object.groupBy(xs, f)").contains("groupBy("))
        XCTAssertTrue(code("var t = `a ${ s.union(b) } c`;").contains(".union("))
        // Strings, comments, templates and regexes are not code.
        XCTAssertFalse(code(#"var s = "x.union(y)";"#).contains(".union("))
        XCTAssertFalse(code("var s = 'a.union(b)';").contains(".union("))
        XCTAssertFalse(code("var t = `a.union(b) ${1}`;").contains(".union("))
        XCTAssertFalse(code("// the row's .union( is a comment\nvar a = 1;").contains(".union("))
        XCTAssertFalse(code("/* Meta's .union( */ var a = 1;").contains(".union("))
        XCTAssertFalse(code(#"var re = /\/t\/([^\/?#]+)\.union(/; re.exec(s);"#).contains(".union("))
        // A quote inside a regex, a slash inside a class, and division.
        XCTAssertTrue(code(#"var r = /'/; x.union(y);"#).contains(".union("))
        XCTAssertTrue(code(#"var r = /[/]/g; x.union(y);"#).contains(".union("))
        XCTAssertTrue(code("var q = a / b / c; x.union(y);").contains(".union("))
        XCTAssertTrue(code(##"var s = 'a[href^="#"]'; x.union(y);"##).contains(".union("))
        XCTAssertEqual(JSScan.scan(#"var r = /[\p{L}--[a-z]]/v;"#).regexFlags, ["v"])
        XCTAssertEqual(JSScan.scan("var r = a / b / c;").regexFlags, [])
        XCTAssertEqual(JSScan.scan("return /x/gi.test(s);").regexFlags, ["gi"])
    }
}

/// Splits JavaScript into code and the parts that are not code (strings,
/// template text, comments, regex literals), left to right, the way a
/// tokenizer would. A `/` starts a regex when the previous significant token
/// cannot end an expression.
enum JSScan {
    struct Result {
        var code = ""
        var regexFlags: [String] = []
    }

    private static let regexAfterKeywords: Set<String> = [
        "return", "typeof", "case", "do", "else", "in", "of", "new", "delete",
        "void", "throw", "instanceof", "yield", "await",
    ]

    static func scan(_ source: String) -> Result {
        let c = Array(source)
        var out = Result()
        var i = 0
        var lastSignificant: Character?
        var lastWord = ""
        var word = ""
        // Each entry is a template literal waiting for its `${…}` to close,
        // holding the brace depth inside that substitution.
        var templateBraces: [Int] = []

        func emit(_ ch: Character) {
            out.code.append(ch)
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" {
                word.append(ch)
            } else {
                if !word.isEmpty { lastWord = word; word = "" }
                if !ch.isWhitespace { lastSignificant = ch; lastWord = "" }
            }
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" { lastSignificant = ch }
        }

        /// Skips a template literal's text from just after its opening
        /// backtick (or a closing `}`), stopping after the closing backtick or
        /// just after a `${`. Returns true when it stopped at `${`.
        func skipTemplateText() -> Bool {
            while i < c.count {
                if c[i] == "\\" { i += 2; continue }
                if c[i] == "`" { i += 1; return false }
                if c[i] == "$", i + 1 < c.count, c[i + 1] == "{" { i += 2; return true }
                i += 1
            }
            return false
        }

        func enterTemplate() {
            out.code.append(" ")
            if skipTemplateText() { templateBraces.append(0) }
            lastSignificant = "`"; lastWord = ""; word = ""
        }

        while i < c.count {
            let ch = c[i]
            if ch == "'" || ch == "\"" {
                i += 1
                while i < c.count, c[i] != ch {
                    if c[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                out.code.append(" ")
                if !word.isEmpty { lastWord = ""; word = "" }
                lastSignificant = ch; lastWord = ""
                continue
            }
            if ch == "`" { i += 1; enterTemplate(); continue }
            if !templateBraces.isEmpty {
                if ch == "{" { templateBraces[templateBraces.count - 1] += 1 }
                if ch == "}" {
                    if templateBraces[templateBraces.count - 1] == 0 {
                        templateBraces.removeLast()
                        i += 1
                        out.code.append(" ")
                        if skipTemplateText() { templateBraces.append(0) }
                        lastSignificant = "`"; lastWord = ""; word = ""
                        continue
                    }
                    templateBraces[templateBraces.count - 1] -= 1
                }
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { i += 1 }
                continue
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2
                out.code.append(" ")
                continue
            }
            if ch == "/" {
                if !word.isEmpty { lastWord = word; word = "" }
                let startsRegex: Bool
                if let prev = lastSignificant {
                    let wordEnds = prev.isLetter || prev.isNumber || prev == "_" || prev == "$"
                    if wordEnds {
                        startsRegex = regexAfterKeywords.contains(lastWord)
                    } else {
                        startsRegex = !")]}`'\"".contains(prev)
                    }
                } else {
                    startsRegex = true
                }
                if startsRegex {
                    i += 1
                    var inClass = false
                    while i < c.count {
                        if c[i] == "\\" { i += 2; continue }
                        if c[i] == "[" { inClass = true }
                        else if c[i] == "]" { inClass = false }
                        else if c[i] == "/", !inClass { break }
                        else if c[i] == "\n" { break }
                        i += 1
                    }
                    i += 1
                    var flags = ""
                    while i < c.count, c[i].isLetter { flags.append(c[i]); i += 1 }
                    out.regexFlags.append(flags)
                    out.code.append(" ")
                    lastSignificant = "/"; lastWord = ""; word = ""
                    // A regex ends an expression, as a closing bracket does.
                    lastSignificant = ")"
                    continue
                }
            }
            emit(ch)
            i += 1
        }
        return out
    }
}
