import Foundation
import WidgetBuilder
import WidgetEngine

/// A ready-made widget that ships in the app: a folder in `Templates/` holding `widget.json` (and `assets/`,
/// like any widget source) and `template.json`, which says where it sits in the gallery and which blanks a person
/// fills before adding it.
struct Template: Identifiable, Sendable {
    /// A word the template asks for, such as the pet's name. `{{key}}` in the document stands for it.
    struct Blank: Decodable, Identifiable, Sendable, Equatable {
        let key: String
        let label: String
        /// Used when the field is left empty, so every template adds as it looks in the gallery.
        let placeholder: String
        /// The most UTF-16 units a value keeps, the unit of the engine's member names; a character takes at least
        /// one, so the count also bounds the widget's name. Few enough that the filled name and sample fit the
        /// engine's limits and the face fits the value as one word of wide letters, which an app test checks by
        /// building every template with each blank this long.
        let maxLength: Int
        var id: String { key }

        /// The characters of `text` that fit in `maxLength` UTF-16 units, never splitting one.
        func clamped(_ text: String) -> String {
            var units = 0
            return String(
                text.prefix { character in
                    units += character.utf16.count
                    return units <= maxLength
                })
        }
    }

    /// The gallery's shelves, in the order its category row shows them.
    enum Category: String, Decodable, CaseIterable, Sendable {
        case forTwo = "for-two"
        case home, habits, goals
    }

    /// The folder's name.
    let id: String
    let name: String
    let line: String
    let category: Category
    /// Its place in the gallery, lowest first.
    let order: Int
    /// The size the gallery shows it in.
    let family: Family
    /// What Widgie says first when the template opens: what to try on it.
    let hint: String
    let blanks: [Blank]
    let folder: URL

    private struct Info: Decodable {
        let name: String
        let line: String
        let category: Category
        let order: Int
        let family: Family
        let hint: String
        let blanks: [Blank]
    }

    /// Every template in `root`, in gallery order. A folder whose `template.json` does not read is left out, and an
    /// app test checks that none is.
    static func catalog(in root: URL? = Bundle.main.url(forResource: "Templates", withExtension: nil)) -> [Template] {
        guard let root,
            let folders = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "template.json")),
                let info = try? JSONDecoder().decode(Info.self, from: data)
            else { return nil }
            return Template(
                id: folder.lastPathComponent, name: info.name, line: info.line, category: info.category,
                order: info.order, family: info.family, hint: info.hint, blanks: info.blanks, folder: folder)
        }
        .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// The template's source with each blank filled: a trimmed value cut to the blank's length, or the blank's
    /// placeholder when it is empty.
    func source(filling values: [String: String] = [:]) throws -> WidgetSource {
        var source = try WidgetSource(directory: folder)
        let filled = Dictionary(
            uniqueKeysWithValues: blanks.map { blank in
                let typed = values[blank.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let value = blank.clamped(typed).trimmingCharacters(in: .whitespacesAndNewlines)
                return (blank.key, value.isEmpty ? blank.placeholder : value)
            })
        source.json = try Self.fill(source.json, with: filled)
        return source
    }

    /// Fills `{{key}}` in every string of the decoded document, never in the raw text. In `look`, which is code, a
    /// blank becomes a whole quoted string literal, so templates write `const PET = {{pet}};` and no value can end
    /// the string early or add code. Everywhere else it becomes the plain value.
    static func fill(_ json: Data, with values: [String: String]) throws(Unreadable) -> Data {
        guard var document = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw Unreadable(line: "the template's widget.json is not a JSON object")
        }
        for (key, value) in document {
            document[key] = replace(in: value, values, code: key == "look")
        }
        do {
            return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        } catch {
            throw Unreadable(line: "the filled template could not be written as JSON")
        }
    }

    private static func replace(in value: Any, _ values: [String: String], code: Bool) -> Any {
        switch value {
        case let text as String:
            // One pass over the original text, so a value that holds another blank's `{{key}}` stays as typed.
            return text.replacing(/\{\{([^{}]+)\}\}/) { match in
                guard let value = values[String(match.output.1)] else { return String(match.output.0) }
                return code ? literal(value) : value
            }
        case let list as [Any]:
            return list.map { replace(in: $0, values, code: code) }
        case let object as [String: Any]:
            return object.mapValues { replace(in: $0, values, code: code) }
        default:
            return value
        }
    }

    /// `value` as a JSON string literal, which is also a JavaScript string literal. The two line separators that
    /// JSON allows raw are escaped too, for engines older than ES2019.
    static func literal(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// A template whose document is not a JSON object, which only a broken bundle can cause.
    struct Unreadable: Error {
        let line: String
    }
}
