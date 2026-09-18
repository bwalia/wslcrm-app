import XCTest

/// What the video tour says, and the markers that put each line against the right second of
/// footage.
///
/// `scripts/record-dbs-video.sh` records the Simulator while `DBSLimitedTourUITests` runs, then
/// reads these markers back out of the result bundle and hands them to `scripts/tour-video.swift`,
/// which captions the recording. Every line is stamped at the moment the screen it describes had
/// settled, so nothing has to be lined up by hand afterwards.
///
/// The captions describe the seeded DBS demo data by name, not by reference number: job and
/// request numbers are sequential and change every time the workspace is re-seeded.
enum TourNarration {
    /// One line per screenshot the tour takes, keyed by its name. A screenshot with no line here
    /// is still captured; the video simply keeps the previous caption up.
    static let captions: [String: String] = [
        // Signing in
        "eng-00-sign-in": "The app is white-labelled as DBS Ltd — their mark on the sign-in screen, their icon on the home screen, their letterhead on every PDF it produces.",
        "eng-01-sign-in-filled": "Tom Fletcher signs in with his own account. The badge under the fields names the server this build is talking to.",
        "eng-01b-two-factor": "Every sign-in is two-factor. Roles and permissions come back with the session, so the app only ever shows what this person is allowed to see.",

        // Engineer — Tom Fletcher
        "eng-02-my-work": "My Work opens on the job he is on now: a cold room sitting at 11°C at The Olive Tree in Covent Garden, with today's numbers beside it.",
        "eng-03-my-work-coming-up": "Underneath, the rest of today and tomorrow's first call — the shape of his day without ringing the office.",
        "eng-04-notifications": "Notifications are the things addressed to him: a job assigned, a part approved, a visit moved.",
        "eng-05-guided-visit-on-site": "Tapping through opens the guided visit. It knows he is on site and offers the next thing to do rather than a form to fill in.",
        "eng-06-guided-visit-checklist": "The checklist for this type of work. Each tick is saved as he goes, and the customer's paperwork is built from it.",
        "eng-07-guided-visit-sheet-and-fgas": "Labour, materials and hire land on the sheet as he works. The F-Gas record — refrigerant, cylinder, charge, leak check — is captured here instead of on a paper log.",
        "eng-08-stock-list": "Materials come from DBS's own stock list, with the part number and the price already attached.",
        "eng-09-part-proposal": "A replacement is proposed, not quietly logged: the part, the reason, and a photo of the fault. That photo is what the manager approves it on.",
        "eng-10-upcoming-visit": "Tomorrow's first job — high head pressure alarms on a CRAC unit at Brightwell's data centre — is ready before he sets off.",
        "eng-11-upcoming-visit-site-access": "Site access travels with the visit: where to park, who to ask for, what the permit needs.",
        "eng-12-field-service": "The Field Service tab is the rest of the business, filtered to what an engineer may see.",
        "eng-13-jobs": "His jobs board, with the filter across the top.",
        "eng-14-job-on-hold": "A vaccine fridge job on hold for a part. The reason sits on the job, so nobody has to chase it.",
        "eng-15-job-phases-visits": "Below that, the phases and every visit made so far, each with its own notes, photos and sign-off.",

        // Service manager — Claire Donnelly
        "mgr-01-field-service-hub": "Claire Donnelly runs reactive service. Her hub counts open jobs, today's visits, who is on site and what has gone overdue.",
        "mgr-02-service-requests": "Service requests as they arrive, each showing its priority and how long it has been waiting.",
        "mgr-03-service-requests-more": "They stay here until they are converted, rejected or closed, so nothing falls between a phone call and a job.",
        "mgr-04-request-sla-breached": "A hotel guest complaint that has already missed its response time. The breach is on the request itself, not buried in a report.",
        "mgr-05-convert-to-job": "Converting makes a job out of the request without retyping it: customer, site, fault and history all come across.",
        "mgr-06-pick-engineer": "She can assign an engineer now or leave it until the morning run.",
        "mgr-07-jobs-open": "The jobs board for the whole workspace.",
        "mgr-08-installation-job": "An installation in progress across three floors, with its value and where it has got to.",
        "mgr-09-installation-phases": "Larger jobs are split into phases, so progress is measured floor by floor rather than job by job.",
        "mgr-10-installation-visits": "Every visit booked against the job, whoever made it.",
        "mgr-11-installation-parts-and-hire": "Materials and plant hire are costed against the job as they are used — this is what the final account is built from.",
        "mgr-12-emergency-job": "Back on the emergency call-out Tom is working.",
        "mgr-13-emergency-items-pending-approval": "The refrigerant and filter drier he logged are waiting on her approval, with his photo attached. Approved here, they reach the invoice.",
        "mgr-14-quote-job": "A quotation to replace end-of-life R22 cassettes, still sitting as a draft job.",
        "mgr-15-quotation": "The quote is built from the job — labour, materials, and the terms DBS quote on.",
        "mgr-16-quotation-lines": "It renders as the PDF the customer receives, on DBS's letterhead.",
        "mgr-17-completed-ppm": "A planned maintenance visit finished earlier today.",
        "mgr-18-completed-ppm-fgas": "…with its F-Gas record attached, which is what makes the visit compliant as well as complete.",
        "mgr-19-invoice-preview": "Invoicing is one step from the job: the lines are already there, approved and priced.",
        "mgr-20-invoices": "The invoice list — draft, sent, overdue and paid.",
        "mgr-21-invoice-overdue": "An overdue invoice, with how far past due it has gone.",
        "mgr-22-invoice-lines": "Every line traces back to the visit that earned it.",
        "mgr-23-sites": "Sites, with their addresses and access details.",
        "mgr-24-assets": "And the plant DBS maintain at them.",

        // Service desk — Aisha Rahman
        "desk-01-field-service": "Aisha Rahman is on the service desk. She sees requests and customers — not the jobs board, and not the money.",
        "desk-02-service-requests": "The morning's calls, in the order they came in.",
        "desk-03-fault-categories": "Logging a call: the fault category comes from a list the business owns, so the reporting afterwards is not guesswork.",
        "desk-04-customers": "The customer is picked from DBS's own accounts.",
        "desk-05-customer-sites": "…and then the site, because most customers have several.",
        "desk-06-request-form": "The call as the manager will receive it.",
        "desk-07-request-form-more": "Priority, how it came in, and who to keep informed.",

        // Simpro — the CRM in front of it
        "simpro-00-dbs-ltd-sign-in": "DBS run their business on Simpro. This is the same app as the CRM in front of it — the same shapes, the same screens, on the phone.",
        "simpro-01-hub": "Two more tiles for a manager: the asset register and the report pack.",
        "simpro-02-assets": "Every piece of plant DBS look after, in Simpro's shape: condition, contract, service dates and location.",
        "simpro-03-assets-service-overdue": "Filtered to what is overdue for service.",
        "simpro-04-asset-detail": "A Daikin VRV condenser at BNP Paribas on New Bond Street — condition 5, plan replacement — with the engineer's note explaining why.",
        "simpro-05-asset-fgas-and-schedule": "Its F-Gas position and service schedule: refrigerant charge, when it was last checked, when it is next due.",
        "simpro-06-asset-surveys": "Eighteen months of condition surveys on DBS's 1–6 scale, newest first.",
        "simpro-07-asset-history-pdf-share": "The asset's history exports as a PDF on DBS's letterhead, ready to send from site.",
        "simpro-08-reports": "The report pack DBS publish, in an engineer's pocket: assets, compliance, operations and performance.",
        "simpro-09-ppm-forecast": "The programmed maintenance forecast — what is due, by site and by month.",
        "simpro-10-ppm-forecast-rows": "Row by row, the way it comes out of Simpro.",
        "simpro-11-ppm-forecast-share-pdf": "Every report shares as a PDF or a CSV from the phone.",
        "simpro-12-fgas-register": "The F-Gas register: charges, recoveries and leak checks — the record the regulations ask for.",
        "simpro-13-employee-licences": "Employee licences, with the ones about to expire flagged before they lapse.",
        "simpro-14-sync-status": "And the Simpro connection itself: what was pulled, what was pushed and when. Managers read it here; the syncs run from the web dashboard.",
        "simpro-15-engineer-asset": "The same register as an engineer gets it: the plant and its condition, no report pack and no prices.",
        "simpro-16-engineer-survey-form": "He records a condition survey on site — the score, what he found, and whether it needs a remedial quote.",
        "simpro-17-engineer-survey-saved": "Saved, it is on the asset's history before he is off the roof.",

        // The rest of the platform
        "more-01-modules": "The More tab lists the modules this account can open — customers, the product catalogue, invoices, assets and reports. What the role is not granted is not shown at all.",
        "more-02-customers": "The customer accounts behind the jobs.",
        "more-03-customer": "Contacts, addresses and what has been done for them.",
        "more-04-products": "The catalogue the stock list draws on: parts, prices and what is held.",
        "more-05-product": "Each part with its code, price and stock position.",
        "more-06-settings": "Settings names the build, the server it is pointed at and the account signed in.",
        "more-07-permissions": "…and spells out what this role may do, module by module. That is the server's answer, not the app's guess.",
        "more-08-workspace": "An account can belong to more than one workspace; the app moves between them without signing out.",
        "more-09-unsynced": "Anything written without a signal waits here until it lands.",
        "more-10-sign-out": "Signing out clears the session and every cached response on the device.",

        // Offline
        "offline-01-checklist": "Plant rooms and basements have no signal. Here the connection is cut while the engineer is mid-visit.",
        "offline-02-waiting": "The tick is kept on the device and shown as waiting to sync — no error, and no lost work.",
        "offline-03-synced": "When the signal comes back the queue drains on its own, and the tick is on the server.",
    ]

    // MARK: Markers

    /// True when the run is being recorded for the video, which slows the tour down so each
    /// caption can be read.
    static var isVideoRun: Bool { ProcessInfo.processInfo.environment["TOUR_VIDEO"] == "1" }

    private nonisolated(unsafe) static var markers: [[String: Any]] = []
    private nonisolated(unsafe) static var openChapter = false

    private static func emit(_ marker: [String: Any]) {
        markers.append(marker)
        if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print("TOURMARK \(line)")
        }
    }

    /// Opens a chapter of the video, closing the one before it. Footage between chapters — the
    /// app relaunching, a sign-in being typed — is cut out.
    static func chapter(_ title: String, _ subtitle: String) {
        if openChapter { chapterEnd() }
        openChapter = true
        emit(["kind": "section", "at": Date().timeIntervalSince1970, "title": title, "subtitle": subtitle])
    }

    static func chapterEnd() {
        guard openChapter else { return }
        openChapter = false
        emit(["kind": "sectionEnd", "at": Date().timeIntervalSince1970])
    }

    /// Drops a stretch of the recording from the video: a wait the tour has to sit through, such
    /// as an outage running its course, that nobody needs to watch. The caption either side of it
    /// stays as it was.
    static func cut(from: Date, to: Date = Date()) {
        emit(["kind": "cut", "from": from.timeIntervalSince1970, "to": to.timeIntervalSince1970])
    }

    /// Marks the moment a screen described by `captions[id]` was on screen and settled.
    static func beat(_ id: String) {
        guard let text = captions[id] else { return }
        emit(["kind": "beat", "at": Date().timeIntervalSince1970, "id": id, "text": text])
    }

    /// How long to hold a screen so its caption can be read.
    static func readingSeconds(for id: String) -> TimeInterval {
        guard isVideoRun, let text = captions[id] else { return 0 }
        let words = text.split(separator: " ").count
        return min(9, max(2.6, 1.1 + Double(words) * 0.34))
    }

    /// Everything the run marked, as the recorder reads it back out of the result bundle.
    /// Attached rather than only printed: xcodebuild's log interleaves and truncates, a result
    /// bundle attachment does not.
    static func attach(to testCase: XCTestCase) {
        chapterEnd()
        guard !markers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: markers, options: [.sortedKeys])
        else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "tour-markers"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
        markers.removeAll()
    }
}
