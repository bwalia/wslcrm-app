import Compression
import SwiftUI

/// A web terminal session's screen recording (§11): the terminal uploads its output as gzipped asciicast
/// parts. They're fetched only when someone opens the replay, unzipped here and played back on a small
/// terminal screen drawn natively (output only: what was typed — passwords — was never recorded).
struct AITerminalReplayView: View {
    let uuid: String
    let parts: [Int]
    @Environment(\.services) private var services
    @State private var state: LoadState<AICast> = .idle
    @State private var player = AICastPlayer()
    /// The terminal's text grows with the person's text size (it scrolls both ways).
    @ScaledMetric(relativeTo: .caption2) private var terminalTextSize: CGFloat = 11

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading the recording…").font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                AILoadFailure(error: error) { Task { await load() } }
            case .loaded(let cast):
                screen(cast)
            }
        }
        .navigationTitle("Screen replay")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player.pause() }
    }

    private func screen(_ cast: AICast) -> some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                Text(player.screen)
                    .font(.system(size: terminalTextSize, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .padding(10)
                    .fixedSize()
                    .textSelection(.enabled)
                    .accessibilityLabel("Terminal screen")
            }
            .background(Color(white: 0.1))
            VStack(spacing: 8) {
                Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(cast.duration, 0.1))
                    .accessibilityLabel("Position in the recording")
                HStack {
                    Button {
                        player.playing ? player.pause() : player.play()
                    } label: {
                        Label(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill")
                    }
                    .accessibilityIdentifier("airunner.replay.play")
                    Spacer()
                    Text("\(AIFormat.elapsed(player.time)) of \(AIFormat.elapsed(cast.duration))")
                        .font(.wsFootnote.monospacedDigit())
                    Spacer()
                    Menu {
                        ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { speed in
                            Button("\(Int(speed))×") { player.speed = speed }
                        }
                    } label: {
                        Label("\(Int(player.speed))×", systemImage: "speedometer")
                    }
                    .accessibilityLabel("Speed")
                }
                Text("Pauses longer than 2 seconds are shortened.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            .padding()
            .background(.bar)
        }
    }

    private func load() async {
        state = .loading
        do {
            let api = AIRunnerAPI(client: services.client)
            var text = ""
            for part in parts {
                let data = try await api.recordingPart(uuid, part: part)
                guard let plain = AIGzip.decompress(data) ?? (String(data: data, encoding: .utf8).map { Data($0.utf8) }) else {
                    throw ResourceService.problem(422, "This recording couldn't be read.")
                }
                let chunk = String(decoding: plain, as: UTF8.self)
                text += chunk.hasSuffix("\n") ? chunk : chunk + "\n"
            }
            let cast = AICast.parse(text)
            player.load(cast)
            state = .loaded(cast)
            player.play()
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

// MARK: - gzip

enum AIGzip {
    /// The contents of a gzip file (RFC 1952), or nil when it isn't one.
    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var at = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard bytes.count > at + 2 else { return nil }
            at += 2 + Int(bytes[at]) + Int(bytes[at + 1]) << 8
        }
        if flags & 0x08 != 0 { while at < bytes.count, bytes[at] != 0 { at += 1 }; at += 1 }  // FNAME
        if flags & 0x10 != 0 { while at < bytes.count, bytes[at] != 0 { at += 1 }; at += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { at += 2 }  // FHCRC
        guard at < bytes.count - 8 else { return nil }
        let size = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8 | Int(bytes[bytes.count - 2]) << 16
            | Int(bytes[bytes.count - 1]) << 24
        let deflated = Array(bytes[at..<(bytes.count - 8)])
        // ISIZE is the size modulo 2³²; grow the buffer if it was more.
        var capacity = max(size, deflated.count * 4, 1024)
        for _ in 0..<6 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = compression_decode_buffer(&out, capacity, deflated, deflated.count, nil, COMPRESSION_ZLIB)
            if written > 0 && written < capacity { return Data(out[0..<written]) }
            if written == capacity { capacity *= 4; continue }
            return written == 0 ? nil : Data(out[0..<written])
        }
        return nil
    }
}

// MARK: - asciicast

/// An asciicast recording (v2: absolute times; v3: times since the previous event): the screen size and
/// the output, with pauses longer than 2 seconds shortened as the web player does.
struct AICast: Sendable {
    var width = 80
    var height = 24
    /// (time, output), in order.
    var frames: [(time: Double, text: String)] = []
    var duration: Double { frames.last?.time ?? 0 }

    static let idleLimit = 2.0

    static func parse(_ text: String) -> AICast {
        var cast = AICast()
        var version = 2
        var sawHeader = false
        var clock = 0.0, last = 0.0, shown = 0.0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            switch json {
            case .object(let header):
                guard !sawHeader else { continue }  // a later part's own header
                sawHeader = true
                version = Int(header["version"]?.stringValue ?? "2") ?? 2
                let term = header["term"]
                cast.width = Int(header["width"]?.stringValue ?? term?["cols"]?.stringValue ?? "80") ?? 80
                cast.height = Int(header["height"]?.stringValue ?? term?["rows"]?.stringValue ?? "24") ?? 24
            case .array(let event):
                guard event.count >= 3, case .number(let t) = event[0], event[1].stringValue == "o",
                      case .string(let output) = event[2] else { continue }
                clock = version >= 3 ? clock + t : t
                shown += min(max(clock - last, 0), idleLimit)
                last = clock
                cast.frames.append((shown, output))
            default:
                continue
            }
        }
        cast.width = min(max(cast.width, 20), 400)
        cast.height = min(max(cast.height, 5), 200)
        return cast
    }
}

/// Plays a cast: the screen at the current time, play / pause / seek / speed.
@MainActor
@Observable
final class AICastPlayer {
    private(set) var screen = ""
    private(set) var time = 0.0
    private(set) var playing = false
    var speed = 1.0
    private var cast = AICast()
    private var terminal = AITerminalScreen(width: 80, height: 24)
    private var next = 0
    private var ticker: Task<Void, Never>?

    func load(_ cast: AICast) {
        self.cast = cast
        rewind()
    }

    func play() {
        guard !playing else { return }
        if time >= cast.duration { rewind() }
        playing = true
        ticker = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let now = Date()
                self.advance(to: self.time + now.timeIntervalSince(last) * self.speed)
                last = now
                if self.time >= self.cast.duration { self.pause(); return }
            }
        }
    }

    func pause() {
        playing = false
        ticker?.cancel()
        ticker = nil
    }

    func seek(to target: Double) {
        if target < time { rewind() }
        advance(to: target)
    }

    private func rewind() {
        terminal = AITerminalScreen(width: cast.width, height: cast.height)
        next = 0
        time = 0
        screen = terminal.text
    }

    private func advance(to target: Double) {
        while next < cast.frames.count, cast.frames[next].time <= target {
            terminal.feed(cast.frames[next].text)
            next += 1
        }
        time = min(target, cast.duration)
        screen = terminal.text
    }
}

/// A small terminal: enough of VT100/xterm (cursor moves, erasing, scrolling, the alternate screen) to show
/// what a shell or a coding agent drew. Colours and styles are left out.
struct AITerminalScreen {
    let width: Int
    let height: Int
    private var main: [[Character]]
    private var alternate: [[Character]]?
    private var row = 0
    private var col = 0
    private var saved = (row: 0, col: 0)
    private var top = 0
    private var bottom: Int
    private var pending: [Character] = []

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        main = Array(repeating: Array(repeating: " ", count: width), count: height)
        bottom = height - 1
    }

    private var grid: [[Character]] {
        get { alternate ?? main }
        set { if alternate != nil { alternate = newValue } else { main = newValue } }
    }

    /// The screen as lines, trailing spaces trimmed.
    var text: String {
        grid.map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    mutating func feed(_ output: String) {
        var chars = pending
        chars.append(contentsOf: output)
        pending = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}" {
                guard let used = escape(chars, from: i) else {
                    pending = Array(chars[i...])  // the sequence continues in the next chunk
                    return
                }
                i += used
                continue
            }
            switch c {
            case "\r": col = 0
            case "\n", "\u{0B}", "\u{0C}": lineFeed()
            case "\r\n": col = 0; lineFeed()
            case "\u{08}": col = max(0, col - 1)
            case "\t": col = min(width - 1, (col / 8 + 1) * 8)
            case "\u{07}", "\u{00}", "\u{0E}", "\u{0F}": break
            default: put(c)
            }
            i += 1
        }
    }

    private mutating func put(_ c: Character) {
        if col >= width {
            col = 0
            lineFeed()
        }
        // In place: this runs for every character drawn.
        if alternate != nil { alternate![row][col] = c } else { main[row][col] = c }
        col += 1
    }

    private mutating func lineFeed() {
        if row == bottom { scrollUp(1) } else { row = min(height - 1, row + 1) }
    }

    private mutating func scrollUp(_ n: Int) {
        var g = grid
        for _ in 0..<max(n, 0) {
            g.remove(at: top)
            g.insert(Array(repeating: " ", count: width), at: bottom)
        }
        grid = g
    }

    private mutating func scrollDown(_ n: Int) {
        var g = grid
        for _ in 0..<max(n, 0) {
            g.remove(at: bottom)
            g.insert(Array(repeating: " ", count: width), at: top)
        }
        grid = g
    }

    /// Handles the escape sequence at `start`; returns how many characters it used, or nil when incomplete.
    private mutating func escape(_ chars: [Character], from start: Int) -> Int? {
        guard start + 1 < chars.count else { return nil }
        let kind = chars[start + 1]
        switch kind {
        case "[":
            var j = start + 2
            var body = ""
            while j < chars.count {
                let c = chars[j]
                if let scalar = c.unicodeScalars.first, (0x40...0x7E).contains(scalar.value), c.unicodeScalars.count == 1 {
                    csi(body, final: c)
                    return j - start + 1
                }
                body.append(c)
                j += 1
                if body.count > 64 { return j - start }  // not a real sequence: skip it
            }
            return nil
        case "]", "P", "_", "^":  // OSC / DCS / APC / PM: up to BEL or ESC \
            var j = start + 2
            while j < chars.count {
                if chars[j] == "\u{07}" { return j - start + 1 }
                if chars[j] == "\u{1B}", j + 1 < chars.count, chars[j + 1] == "\\" { return j - start + 2 }
                if chars[j] == "\u{1B}", j + 1 >= chars.count { return nil }
                j += 1
            }
            return nil
        case "(", ")", "*", "+", "#", "%":  // character sets: one more character
            return start + 2 < chars.count ? 3 : nil
        case "7": saved = (row, col); return 2
        case "8": row = saved.row; col = saved.col; return 2
        case "M": if row == top { scrollDown(1) } else { row = max(0, row - 1) }; return 2
        case "D": lineFeed(); return 2
        case "E": col = 0; lineFeed(); return 2
        case "c": self = AITerminalScreen(width: width, height: height); return 2
        default: return 2
        }
    }

    private mutating func csi(_ body: String, final: Character) {
        let isPrivate = body.hasPrefix("?") || body.hasPrefix(">") || body.hasPrefix("=")
        let params = body.trimmingCharacters(in: CharacterSet(charactersIn: "?>=! ")).split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.split(separator: ":").first ?? "") ?? 0 }
        func p(_ index: Int, _ fallback: Int) -> Int {
            index < params.count && params[index] != 0 ? params[index] : fallback
        }
        switch final {
        case "A": row = max(top, row - p(0, 1))
        case "B": row = min(bottom, row + p(0, 1))
        case "C": col = min(width - 1, col + p(0, 1))
        case "D": col = max(0, col - p(0, 1))
        case "E": row = min(bottom, row + p(0, 1)); col = 0
        case "F": row = max(top, row - p(0, 1)); col = 0
        case "G", "`": col = min(width - 1, max(0, p(0, 1) - 1))
        case "d": row = min(height - 1, max(0, p(0, 1) - 1))
        case "H", "f":
            row = min(height - 1, max(0, p(0, 1) - 1))
            col = min(width - 1, max(0, p(1, 1) - 1))
        case "J": eraseDisplay(params.first ?? 0)
        case "K": eraseLine(params.first ?? 0)
        case "X":
            var g = grid
            for c in col..<min(width, col + p(0, 1)) { g[row][c] = " " }
            grid = g
        case "P":
            var g = grid
            let n = min(p(0, 1), width - col)
            g[row].removeSubrange(col..<(col + n))
            g[row].append(contentsOf: Array(repeating: " ", count: n))
            grid = g
        case "@":
            var g = grid
            let n = min(p(0, 1), width - col)
            g[row].insert(contentsOf: Array(repeating: " ", count: n), at: col)
            g[row].removeLast(n)
            grid = g
        case "L":
            guard row >= top, row <= bottom else { break }
            var g = grid
            for _ in 0..<min(p(0, 1), bottom - row + 1) {
                g.remove(at: bottom)
                g.insert(Array(repeating: " ", count: width), at: row)
            }
            grid = g
        case "M":
            guard row >= top, row <= bottom else { break }
            var g = grid
            for _ in 0..<min(p(0, 1), bottom - row + 1) {
                g.remove(at: row)
                g.insert(Array(repeating: " ", count: width), at: bottom)
            }
            grid = g
        case "S": scrollUp(p(0, 1))
        case "T": if !isPrivate { scrollDown(p(0, 1)) }
        case "r":
            if !isPrivate {
                let newTop = max(0, p(0, 1) - 1), newBottom = min(height - 1, p(1, height) - 1)
                if newTop < newBottom { top = newTop; bottom = newBottom; row = 0; col = 0 }
            }
        case "s": if !isPrivate { saved = (row, col) }
        case "u": if !isPrivate { row = saved.row; col = saved.col }
        case "h", "l":
            if isPrivate, params.contains(where: { [47, 1047, 1049].contains($0) }) {
                if final == "h", alternate == nil {
                    if params.contains(1049) { saved = (row, col) }
                    alternate = Array(repeating: Array(repeating: " ", count: width), count: height)
                } else if final == "l", alternate != nil {
                    alternate = nil
                    if params.contains(1049) { row = saved.row; col = saved.col }
                }
            }
        default:
            break  // colours (m) and anything else that doesn't change the text
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        var g = grid
        let blank = Array(repeating: Character(" "), count: width)
        switch mode {
        case 0:
            for c in col..<width { g[row][c] = " " }
            for r in (row + 1)..<height { g[r] = blank }
        case 1:
            for r in 0..<row { g[r] = blank }
            for c in 0...min(col, width - 1) { g[row][c] = " " }
        default:
            g = Array(repeating: blank, count: height)
        }
        grid = g
    }

    private mutating func eraseLine(_ mode: Int) {
        var g = grid
        switch mode {
        case 0: for c in col..<width { g[row][c] = " " }
        case 1: for c in 0...min(col, width - 1) { g[row][c] = " " }
        default: g[row] = Array(repeating: " ", count: width)
        }
        grid = g
    }
}
