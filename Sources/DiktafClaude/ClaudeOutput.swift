import Foundation

/// What the CLI said, read out of its JSON.
///
/// Only the four fields Diktaf needs are decoded, and every one of them is
/// optional in the decoding even where it is documented as present: this is
/// another program's output format, and a field that moves should cost a clear
/// error rather than a crash.
struct ClaudeOutput: Sendable, Equatable {
    let text: String
    let sessionID: String?
    let isError: Bool

    private struct Payload: Decodable {
        let result: String?
        let session_id: String?
        let is_error: Bool?
        let subtype: String?
        /// Present when the CLI itself failed rather than the model.
        let error: String?
    }

    /// Reads one JSON object.
    ///
    /// The CLI prints exactly one with `--output-format json`, but it is not the
    /// only thing that can end up on stdout — a warning from the runtime, an
    /// update notice — so the object is looked for rather than assumed to start
    /// at the first byte.
    static func parse(_ standardOutput: String) throws -> ClaudeOutput {
        guard let json = jsonObject(in: standardOutput) else {
            throw ClaudeOutputFailure.notJSON(String(standardOutput.prefix(400)))
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        } catch {
            throw ClaudeOutputFailure.notJSON(String(json.prefix(400)))
        }

        if payload.is_error == true || payload.subtype == "error" {
            let detail = payload.error ?? payload.result ?? "the agent reported an error"
            throw ClaudeOutputFailure.reportedError(detail)
        }

        return ClaudeOutput(
            text: (payload.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            sessionID: payload.session_id,
            isError: false
        )
    }

    /// The outermost brace-delimited run, found by counting braces outside
    /// strings. A JSON payload that happens to contain a `}` in a transcript is
    /// the normal case, not an edge one.
    private static func jsonObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\", inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum ClaudeOutputFailure: Error, Sendable, Equatable {
    /// Stdout was not the JSON object the CLI is supposed to print.
    case notJSON(String)
    /// The CLI printed JSON saying it had failed.
    case reportedError(String)
}
