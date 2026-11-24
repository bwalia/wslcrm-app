import UIKit

/// The job sheet: the engineer's paper worksheet for a job — customer and site, equipment, the
/// fault, phases with their checklists, visits, the F-Gas log, labour, materials, hire, notes,
/// totals and signature lines. Drawn on the device and shared as a PDF.
@MainActor
enum JobSheetPDF {
    nonisolated static func filename(for job: Job) -> String {
        "Job-sheet-\(job.jobNumber.isEmpty ? "job" : job.jobNumber).pdf"
    }

    /// The customer's sign-off from the visit where they signed at "Finish job".
    struct CustomerSignature {
        var name: String?
        var signedAt: Date?
        var image: UIImage?
    }

    static func file(for detail: JobDetail, company: String?, customerSignature: CustomerSignature? = nil) -> URL? {
        DocumentPDF.file(named: filename(for: detail.job)) { canvas in
            draw(detail, company: company, customerSignature: customerSignature, on: canvas)
        }
    }

    /// "Signed by Jo Bloggs · 12 Nov 2026 at 14:05".
    nonisolated static func signatureCaption(name: String?, signedAt: Date?) -> String {
        ["Signed by \(name?.trimmedOrNil ?? "the customer")", Formatters.dateTime(signedAt)].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Visits that recorded refrigerant, for the F-Gas log.
    nonisolated static func fgasVisits(_ detail: JobDetail) -> [Visit] {
        detail.visits.filter(\.hasFGasRecord)
    }

    private static func draw(_ detail: JobDetail, company: String?, customerSignature: CustomerSignature?,
                             on canvas: DocumentPDF.Canvas) {
        let job = detail.job
        let small = UIFont.systemFont(ofSize: 10)
        let body = UIFont.systemFont(ofSize: 11)
        let bold = UIFont.boldSystemFont(ofSize: 11)
        let money = { (value: Decimal) in Formatters.money(value, currency: job.currency) ?? "" }
        let dash = { (text: String?) in (text?.isEmpty == false ? text! : "—") }

        func heading(_ title: String) {
            canvas.pageBreakIfNeeded(keeping: 60)
            canvas.y += 12
            canvas.y += canvas.text(title, x: 48, font: .boldSystemFont(ofSize: 13), width: 499)
            canvas.rule()
            canvas.y += 6
        }

        func row(_ label: String, _ value: String?) {
            canvas.pageBreakIfNeeded()
            canvas.text(label, x: 48, font: small, color: .darkGray, width: 130)
            canvas.y += max(canvas.text(dash(value), x: 180, font: body, width: 367), 14) + 2
        }

        /// A table: column titles, x positions and widths, then rows of cells.
        func table(_ columns: [(String, CGFloat, CGFloat)], _ rows: [[String]]) {
            canvas.pageBreakIfNeeded(keeping: 40)
            for (title, x, width) in columns { canvas.text(title, x: x, font: .boldSystemFont(ofSize: 9), width: width) }
            canvas.y += 14
            for cells in rows {
                canvas.pageBreakIfNeeded(keeping: 28)
                var height: CGFloat = 12
                for (index, cell) in cells.enumerated() where index < columns.count {
                    height = max(height, canvas.text(cell, x: columns[index].1, font: small, width: columns[index].2))
                }
                canvas.y += height + 4
            }
        }

        canvas.text("JOB SHEET", x: 48, font: .boldSystemFont(ofSize: 26))
        canvas.text(job.jobNumber, x: 287, font: .monospacedSystemFont(ofSize: 14, weight: .semibold),
                    width: 260, alignment: .right)
        canvas.y += 34
        if let company, !company.isEmpty {
            canvas.text(company, x: 287, font: small, color: .darkGray, width: 260, alignment: .right)
        }
        canvas.y += canvas.text(job.title, x: 48, font: .boldSystemFont(ofSize: 14), width: 380) + 2
        canvas.y += canvas.text("\(job.status.label) · \(job.priority.label) priority", x: 48, font: small,
                                color: .darkGray, width: 380)

        heading("Customer & site")
        row("Customer", job.customerName)
        row("Site", job.siteName)
        row("Reference / PO", job.customerReference)
        row("Phone", job.customerPhone)
        row("Email", job.customerEmail)
        row("Service address", job.fullAddress)
        row("Due date", job.dueDate.flatMap { Formatters.day($0.date()) })

        heading("Equipment")
        row("Product", job.productName)
        row("SKU", job.productSku)
        row("Unit serial / ref", job.productRef)
        row("Job type", job.jobTypeName)

        heading("Reported fault / work")
        canvas.y += canvas.text(dash(job.description), x: 48, font: body, width: 499) + 4

        heading("Phases & checklist")
        if detail.phases.isEmpty {
            canvas.y += canvas.text("No phases.", x: 48, font: body, color: .darkGray, width: 499)
        }
        for phase in detail.sortedPhases {
            canvas.pageBreakIfNeeded(keeping: 30)
            canvas.y += canvas.text("\(phase.sortOrder). \(phase.name) · \(phase.status.label)", x: 48, font: bold,
                                    width: 499) + 2
            for item in phase.checklist {
                canvas.pageBreakIfNeeded()
                canvas.y += canvas.text("\(item.done ? "☑" : "☐")  \(item.label)", x: 60, font: body, width: 487) + 2
            }
            canvas.y += 4
        }

        heading("Visits")
        if detail.visits.isEmpty {
            canvas.y += canvas.text("No visits booked.", x: 48, font: body, color: .darkGray, width: 499)
        } else {
            table([("Date", 48, 95), ("Engineer", 148, 95), ("Status", 248, 70), ("Hours", 323, 40), ("Work done", 368, 179)],
                  detail.visits.map { visit in
                      [Formatters.dateTime(visit.scheduledStart) ?? "—", dash(visit.engineerName), visit.status.label,
                       Formatters.hours(visit.labourHours) ?? "—", dash(visit.workSummary)]
                  })
        }

        let fgas = fgasVisits(detail)
        if !fgas.isEmpty {
            heading("F-Gas / refrigerant log")
            table([("Date", 48, 80), ("Gas", 133, 70), ("Charged (kg)", 208, 70), ("Recovered (kg)", 283, 75),
                   ("Leak check", 363, 90), ("Cylinder", 458, 89)],
                  fgas.map { visit in
                      [Formatters.day(visit.scheduledStart) ?? "—", dash(visit.refrigerantType),
                       visit.refrigerantAddedKg.map { "\($0)" } ?? "—", visit.refrigerantRecoveredKg.map { "\($0)" } ?? "—",
                       dash(visit.leakCheckResult), dash(visit.fgasCylinderRef)]
                  })
        }

        let labour = detail.items.filter(\.isLabour)
        heading("Labour")
        if labour.isEmpty {
            canvas.y += canvas.text("No labour logged.", x: 48, font: body, color: .darkGray, width: 499)
        } else {
            table([("Labour type", 48, 300), ("Hours", 353, 90), ("Days", 448, 99)],
                  labour.map { [$0.labourCategory?.label ?? $0.description, $0.quantity.formatted(),
                                $0.days.map { "\($0)" } ?? "—"] })
        }

        let materials = detail.items.filter(\.isMaterial)
        heading("Materials")
        if materials.isEmpty {
            canvas.y += canvas.text("No materials logged.", x: 48, font: body, color: .darkGray, width: 499)
        } else {
            table([("Part", 48, 160), ("Part number", 213, 80), ("Supplier", 298, 90), ("Qty", 393, 50),
                   ("Price per", 448, 99)],
                  materials.map { [$0.description, dash($0.partNumber), dash($0.supplier), $0.quantity.formatted(),
                                   $0.unitPrice > 0 ? money($0.unitPrice) : "—"] })
        }

        let hire = detail.items.filter(\.isHire)
        if !hire.isEmpty {
            heading("Specialist tool / access equipment hire")
            table([("Supplier", 48, 130), ("Equipment", 183, 200), ("Reference", 388, 90), ("Days", 483, 64)],
                  hire.map { [dash($0.supplier), $0.description, dash($0.partNumber), $0.days.map { "\($0)" } ?? "—"] })
        }

        let notes = detail.visits.filter { $0.workSummary != nil || $0.followUpNotes != nil }
        if !notes.isEmpty {
            heading("Engineer notes")
            for visit in notes {
                canvas.pageBreakIfNeeded()
                var line = "\(Formatters.day(visit.scheduledStart) ?? "—"): \(visit.workSummary ?? "")"
                if let follow = visit.followUpNotes { line += " — Follow-up: \(follow)" }
                canvas.y += canvas.text(line, x: 48, font: body, width: 499) + 4
            }
        }

        if let totals = detail.totals {
            heading("Totals")
            row("Labour hours", Formatters.hours(totals.labourHours))
            row("Billable hours", Formatters.hours(totals.billableHours))
            row("Labour value", money(totals.labourValue))
            row("Materials value", money(totals.itemsValue))
        }

        guard let signed = customerSignature else {
            canvas.pageBreakIfNeeded(keeping: 80)
            canvas.y += 40
            canvas.text("Engineer signature / date", x: 48, font: small, color: .darkGray, width: 230)
            canvas.text("Customer signature / date", x: 317, font: small, color: .darkGray, width: 230)
            canvas.y += 30
            canvas.rule()
            return
        }
        // Signed at "Finish job": draw the signature, who signed and when, instead of a blank line.
        canvas.pageBreakIfNeeded(keeping: 140)
        canvas.y += 40
        canvas.text("Engineer signature / date", x: 48, font: small, color: .darkGray, width: 230)
        canvas.text("Customer signature", x: 317, font: small, color: .darkGray, width: 230)
        canvas.y += 14
        if let image = signed.image, image.size.width > 0, image.size.height > 0 {
            let scale = min(230 / image.size.width, 60 / image.size.height, 1)
            image.draw(in: CGRect(x: 317, y: canvas.y, width: image.size.width * scale, height: image.size.height * scale))
        }
        canvas.y += 64
        canvas.y += canvas.text(signatureCaption(name: signed.name, signedAt: signed.signedAt), x: 317, font: small, width: 230) + 4
        canvas.rule()
    }
}
