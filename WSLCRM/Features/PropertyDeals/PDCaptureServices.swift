import AVFoundation
import CoreLocation
import Foundation
import Observation
import Speech

// MARK: - Address from GPS

/// Where the phone is, as an address, worked out on the phone (CoreLocation + reverse geocoding).
struct PDPlace: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var addressLine1: String?
    var town: String?
    var postcode: String?
}

@MainActor
struct PDPlaceFinder {
    func currentPlace() async -> PDPlace? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.uiTestArgument) {
            return PDPlace(latitude: 53.9576, longitude: -1.0827, addressLine1: "7 Mill Lane", town: "York", postcode: "YO1 7AA")
        }
        #endif
        guard let fix = await LocationProvider().currentCoordinates(timeout: .seconds(10)) else { return nil }
        var place = PDPlace(latitude: fix.latitude, longitude: fix.longitude)
        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        if let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            place.addressLine1 = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                .nilIfEmpty ?? mark.name
            place.town = mark.locality ?? mark.subAdministrativeArea
            place.postcode = mark.postalCode
        }
        return place
    }

    #if DEBUG
    /// `-UITestPlace`: a fixed location and address (the simulator has no GPS fix to give).
    static let uiTestArgument = "-UITestPlace"
    #endif
}

// MARK: - Voice note

/// Dictation that stays on the phone: speech is recognised on the device, and only the text is
/// kept. Where the device can't recognise speech offline, dictation is off (typing still works);
/// audio is never sent to a server.
@MainActor
@Observable
final class PDDictation {
    enum State: Equatable { case idle, listening, unavailable(String) }

    private(set) var state: State = .idle
    private(set) var transcript = ""

    @ObservationIgnored private var session: SpeechSession?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer()

    var isListening: Bool { state == .listening }

    func toggle() async {
        if isListening { stop() } else { await start() }
    }

    func start() async {
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Dictation isn't available on this phone right now. Type the note instead.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            state = .unavailable("This phone can't turn speech into text offline, and voice notes never leave the phone. Type the note instead.")
            return
        }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized, await AVAudioApplication.requestRecordPermission() else {
            state = .unavailable("Allow the microphone and speech recognition in Settings to dictate.")
            return
        }
        transcript = ""
        let session = SpeechSession(recognizer: recognizer) { [weak self] text, finished in
            Task { @MainActor in
                guard let self else { return }
                self.transcript = text
                if finished { self.stop() }
            }
        }
        do {
            try session.start()
            self.session = session
            state = .listening
        } catch {
            state = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        session?.stop()
        session = nil
        if state == .listening { state = .idle }
    }
}

/// The audio engine and recognition task. They run off the main thread and aren't Sendable, so
/// they live here and only text crosses back.
private final class SpeechSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let recognizer: SFSpeechRecognizer
    private let onText: @Sendable (String, Bool) -> Void
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer, onText: @escaping @Sendable (String, Bool) -> Void) {
        self.recognizer = recognizer
        self.onText = onText
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
    }

    func start() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        let onText = onText
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result { onText(result.bestTranscription.formattedString, result.isFinal) }
            if error != nil { onText(result?.bestTranscription.formattedString ?? "", true) }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
