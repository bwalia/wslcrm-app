import XCTest
@testable import WSLCRM

/// One test per module envelope shape — OpsAPI does not use a single envelope.
final class EnvelopeDecodingTests: XCTestCase {

    // MARK: Field service: { success, data, meta{total,page,per_page,total_pages} }

    func testFieldServiceJobListEnvelope() throws {
        let envelope = try Fixture.decode(Envelope.Standard<LossyArray<Job>>.self, from: "fs_jobs_list")
        XCTAssertEqual(envelope.success, true)
        XCTAssertEqual(envelope.meta?.total, 7)
        XCTAssertEqual(envelope.meta?.perPage, 2)
        XCTAssertEqual(envelope.meta?.totalPages, 4)

        let jobs = envelope.data.elements
        XCTAssertEqual(jobs.count, 2)
        let job = jobs[0]
        XCTAssertEqual(job.jobNumber, "JOB-0042")
        XCTAssertEqual(job.status, .scheduled)
        XCTAssertEqual(job.priority, .high)
        XCTAssertEqual(job.dueDate, CalendarDay(year: 2026, month: 9, day: 20))
        XCTAssertEqual(job.estimatedHours, 4)
        XCTAssertEqual(job.fullAddress, "St Mary's Hospital, Praed Street, London, W2 1NY")
        XCTAssertNotNil(job.updatedAt, "Microsecond timestamps must decode")
        XCTAssertEqual(job.phaseCount, 3)

        // NULL columns are omitted by the API, not sent as null.
        let draft = jobs[1]
        XCTAssertNil(draft.customerName)
        XCTAssertNil(draft.dueDate)
        XCTAssertEqual(draft.status, .draft)
    }

    func testJobDetailWithPhasesVisitsItemsAndTransitions() throws {
        let envelope = try Fixture.decode(Envelope.Standard<JobDetail>.self, from: "fs_job_detail")
        let detail = envelope.data
        XCTAssertNil(envelope.meta)
        XCTAssertEqual(detail.job.status, .inProgress)
        XCTAssertEqual(detail.allowedTransitions, [.cancelled, .completed, .onHold, .scheduled])

        XCTAssertEqual(detail.phases.count, 2)
        let diagnose = detail.sortedPhases[0]
        XCTAssertEqual(diagnose.checklist.count, 2)
        XCTAssertTrue(diagnose.checklist[0].done)
        XCTAssertNotNil(diagnose.checklist[0].doneAt)
        XCTAssertFalse(diagnose.checklist[1].done)
        XCTAssertEqual(diagnose.uncheckedCount, 1)
        let handover = detail.sortedPhases[1]
        XCTAssertTrue(handover.requiresSignoff)
        XCTAssertTrue(handover.needsSignoff)
        XCTAssertTrue(handover.checklist.isEmpty)

        XCTAssertEqual(detail.visits.first?.status, .onSite)
        XCTAssertEqual(detail.visits.first?.phaseStatus, .inProgress)
        XCTAssertEqual(detail.items.first?.approvalStatus, .pending)
        XCTAssertEqual(detail.items.first?.lineTotal, 76)
        XCTAssertEqual(detail.totals?.itemsValue, 76)
        XCTAssertEqual(detail.totals?.openVisits, 1)
        // `metadata` arrives as an object on one row and `[]` on another; neither breaks decoding.
        XCTAssertEqual(detail.activity.count, 2)
    }

    func testVisitListEnvelope() throws {
        let envelope = try Fixture.decode(Envelope.Standard<LossyArray<Visit>>.self, from: "fs_visits_list")
        let visit = try XCTUnwrap(envelope.data.elements.first)
        XCTAssertEqual(visit.status, .scheduled)
        XCTAssertEqual(visit.instructions, "Ask for estates at gate B")
        XCTAssertEqual(visit.jobNumber, "JOB-0042")
        XCTAssertNil(visit.checkedInAt)
        XCTAssertEqual(envelope.meta?.perPage, 100)
    }

    func testCheckOutResponseCarriesWarnings() throws {
        let result = try Fixture.decode(Envelope.Standard<CheckOutResult>.self, from: "fs_checkout_response").data
        XCTAssertEqual(result.visit.visit.status, .completed)
        XCTAssertEqual(result.visit.visit.labourHours, Decimal(string: "2.75"))
        XCTAssertEqual(result.visit.phase?.status, .completed)
        XCTAssertEqual(result.warnings, ["Timesheet not logged: Timesheets are not enabled"])
    }

    func testServiceRequestDetailWithEmptyMetadataArray() throws {
        let detail = try Fixture.decode(Envelope.Standard<ServiceRequestDetail>.self, from: "fs_service_request_detail").data
        XCTAssertEqual(detail.request.status, .assigned)
        XCTAssertTrue(detail.request.slaBreached)
        XCTAssertEqual(detail.jobs.first?.jobNumber, "JOB-0042")
        XCTAssertEqual(detail.allowedTransitions, [.inProgress, .onHold, .resolved, .triaged])
    }

    // MARK: CRM: { success, data, meta } with numeric relations

    func testCRMAccountListEnvelope() throws {
        let envelope = try Fixture.decode(Envelope.Standard<LossyArray<CRMAccount>>.self, from: "crm_accounts_list")
        let account = try XCTUnwrap(envelope.data.elements.first)
        XCTAssertEqual(account.id, 12)
        XCTAssertEqual(account.annualRevenue, 2_500_000)
        XCTAssertEqual(account.address, "1 High Street, London, EC1A 1AA, GB")
        XCTAssertEqual(envelope.meta?.total, 1)
    }

    func testCRMDealDetailWithMixedStageShapes() throws {
        let deal = try Fixture.decode(Envelope.Standard<CRMDeal>.self, from: "crm_deal_detail").data
        XCTAssertEqual(deal.value, Decimal(string: "24000.5"))
        XCTAssertEqual(deal.status, .open)
        XCTAssertEqual(deal.contactName, "Jane Doe")
        XCTAssertEqual(deal.expectedCloseDate, CalendarDay(year: 2026, month: 10, day: 31))
        XCTAssertEqual(deal.pipelineStages.map(\.name), ["new", "proposal", "negotiation", "won"])
    }

    func testDealsByStageMapAndEmptyArray() throws {
        let grouped = try Fixture.decode(Envelope.Standard<DealsByStage>.self, from: "crm_deals_by_stage").data.deals
        XCTAssertEqual(Set(grouped.keys), ["proposal", "new"])
        XCTAssertEqual(grouped["new"]?.first?.value, 5000)

        // An empty map is encoded by the server as `[]`.
        let empty = try Fixture.decode(Envelope.Standard<DealsByStage>.self, from: "crm_deals_by_stage_empty").data.deals
        XCTAssertTrue(empty.isEmpty)
    }

    func testPipelineStagesAreOrdered() throws {
        let pipelines = try Fixture.decode(Envelope.Standard<LossyArray<CRMPipeline>>.self, from: "crm_pipelines").data.elements
        XCTAssertEqual(pipelines[0].orderedStages.map(\.name), ["new", "proposal"])
        XCTAssertEqual(pipelines[1].orderedStages.map(\.name), ["qualify", "renew"])
        XCTAssertTrue(pipelines[0].isDefault)
    }

    // MARK: Customers / products: { data, total }

    func testCustomersDataTotalEnvelopeWithJSONStringAddresses() throws {
        let envelope = try Fixture.decode(Envelope.DataTotal<Customer>.self, from: "customers_list")
        XCTAssertEqual(envelope.total, 57)
        XCTAssertEqual(envelope.data.count, 2)
        let customer = envelope.data[0]
        XCTAssertEqual(customer.displayName, "Sam Patel")
        XCTAssertEqual(customer.addresses.first?.city, "London")
        XCTAssertEqual(customer.totalSpent, Decimal(string: "129.5"))
        // A legacy row with non-JSON address text still decodes, with no addresses.
        XCTAssertTrue(envelope.data[1].addresses.isEmpty)
        XCTAssertEqual(envelope.data[1].displayName, "legacy@example.com")
    }

    func testProductsDataTotalEnvelope() throws {
        let envelope = try Fixture.decode(Envelope.DataTotal<Product>.self, from: "products_list")
        let product = envelope.data[0]
        XCTAssertEqual(product.price, Decimal(string: "24.5"))
        XCTAssertEqual(product.images, ["https://cdn.example.com/p/501.jpg"])
        XCTAssertEqual(product.storeName, "Bean There")
        XCTAssertEqual(product.storeCurrency, "GBP")
        XCTAssertEqual(product.categoryName, "Coffee")
        XCTAssertTrue(product.isLowStock)
        // The quoted legacy default `'[]'` is not JSON; it must not break the list.
        XCTAssertEqual(envelope.data[1].images, [])
    }

    // MARK: Orders: top-level paging keys

    func testOrdersTopLevelPagingEnvelope() throws {
        let envelope = try Fixture.decode(Envelope.Orders<Order>.self, from: "orders_list")
        XCTAssertEqual(envelope.total, 2)
        XCTAssertEqual(envelope.page, 1)
        XCTAssertEqual(envelope.perPage, 25)
        XCTAssertEqual(envelope.totalPages, 1)

        let order = envelope.data[0]
        XCTAssertEqual(order.status, .pending)
        XCTAssertEqual(order.totalAmount, Decimal(string: "64.78"))
        XCTAssertEqual(order.currency, "GBP", "Quoted legacy currency defaults are cleaned")
        XCTAssertEqual(order.customer?.displayName, "John Doe")
        XCTAssertEqual(order.shippingAddress, "123 Main St, London, N1 1AA")
        XCTAssertEqual(order.storeName, "Acme Store")

        let second = envelope.data[1]
        XCTAssertEqual(second.status, .shipped)
        XCTAssertEqual(second.shippingAddress, "Unit 4, Trading Estate", "Raw address text is kept")
        XCTAssertNil(second.customer?.displayName, "A blank full_name means no customer")
    }

    // MARK: Invoices: { success, data, meta{total,page,perPage,totalPages} }

    func testInvoiceListCamelCaseMetaAndUuidInIdField() throws {
        let envelope = try Fixture.decode(Envelope.Invoices<LossyArray<Invoice>>.self, from: "invoices_list")
        XCTAssertEqual(envelope.meta?.total, 41)
        XCTAssertEqual(envelope.meta?.page, 2)
        XCTAssertEqual(envelope.meta?.perPage, 20)
        XCTAssertEqual(envelope.meta?.totalPages, 3)

        let invoice = try XCTUnwrap(envelope.data.elements.first)
        XCTAssertEqual(invoice.id, "6b3e2c1a-8d7e-4f5a-9b1c-2d3e4f5a6b7c", "List rows carry the uuid in `id`")
        XCTAssertEqual(invoice.balanceDue, 580)
    }

    func testInvoiceDetailDerivedStatusAndDiscount() throws {
        let invoice = try Fixture.decode(Envelope.Invoices<Invoice>.self, from: "invoice_detail").data
        XCTAssertEqual(invoice.lineItems.map(\.description), ["Consulting (10h)", "Call-out fee"], "Sorted by sort_order")
        XCTAssertEqual(invoice.payments.first?.referenceNumber, "BACS-0042")
        XCTAssertEqual(invoice.payments.first?.paymentDate, CalendarDay(year: 2026, month: 9, day: 10))
        XCTAssertEqual(invoice.status, .sent)
        XCTAssertEqual(invoice.displayStatus, .partiallyPaid)
        // The API reports discount_amount = 0; the real 10% line discount is derived from the totals.
        XCTAssertEqual(invoice.discountAmount, 100)
        XCTAssertTrue(invoice.canRecordPayment)
        XCTAssertFalse(invoice.canSend)
    }

    // MARK: Auth & menu (no envelope)

    func testLoginAndVerifyResponses() throws {
        let login = try Fixture.decode(LoginResponse.self, from: "auth_login")
        XCTAssertEqual(login.requires2Fa, true)
        XCTAssertNotNil(login.sessionToken)

        let verify = try Fixture.decode(VerifyTwoFactorResponse.self, from: "auth_verify")
        XCTAssertEqual(verify.user.displayName, "Sam Engineer")
        XCTAssertEqual(verify.user.platformRoles, ["buyer"])
        XCTAssertEqual(verify.namespaces.count, 2)
        XCTAssertEqual(verify.namespaces[0].internalId, 7)
        XCTAssertEqual(verify.currentNamespace?.uuid, "c0ffee00-1111-2222-3333-444455556666")
        XCTAssertNotNil(verify.refreshToken)
    }

    func testMenuPermissionsForEngineer() throws {
        let menu = try Fixture.decode(MenuResponse.self, from: "user_menu_engineer")
        let permissions = PermissionSet(menu: menu)
        XCTAssertTrue(permissions.can(.read, .fsJobs))
        XCTAssertFalse(permissions.can(.update, .fsJobs))
        XCTAssertFalse(permissions.can(.create, .invoices))
        XCTAssertTrue(permissions.shows(.jobs))
        XCTAssertFalse(permissions.shows(.invoices))
    }

    func testMenuOwnerWithEmptyPermissionsArray() throws {
        // Owners can have `"permissions": []` — they are authorised by `is_owner`.
        let menu = try Fixture.decode(MenuResponse.self, from: "user_menu_owner_empty_permissions")
        let permissions = PermissionSet(menu: menu)
        XCTAssertTrue(menu.permissions.grants.isEmpty)
        XCTAssertTrue(permissions.can(.delete, .invoices))
        XCTAssertTrue(permissions.shows(.crm))
    }

    func testPermissionGrantsAsJSONString() throws {
        let data = Data(#"{"p": "{\"fs_jobs\":[\"manage\"]}"}"#.utf8)
        struct Wrapper: Decodable { let p: PermissionGrants }
        let grants = try JSONDecoder.opsAPI().decode(Wrapper.self, from: data).p
        let set = PermissionSet(isAdmin: false, isOwner: false, grants: grants.grants, menuKeys: [])
        XCTAssertTrue(set.can(.delete, .fsJobs), "`manage` implies every action")
    }
}

/// Decodes every live capture (`Fixtures/live/live_*.json`) with the matching model.
/// Skipped until `scripts/capture-fixtures.py` has been run.
final class LiveFixtureDecodingTests: XCTestCase {
    private func decodeIfCaptured<T: Decodable>(_ name: String, as type: T.Type, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let bundle = Bundle(for: LiveFixtureDecodingTests.self)
        guard let url = bundle.url(forResource: "live_\(name)", withExtension: "json") else { return false }
        let data = try Data(contentsOf: url)
        do {
            _ = try JSONDecoder.opsAPI().decode(T.self, from: data)
        } catch {
            XCTFail("live_\(name).json failed to decode as \(T.self): \(error)", file: file, line: line)
        }
        return true
    }

    func testLiveCapturesDecode() throws {
        var decoded = 0
        let checks: [() throws -> Bool] = [
            { try self.decodeIfCaptured("auth_me", as: MeResponse.self) },
            { try self.decodeIfCaptured("user_menu", as: MenuResponse.self) },
            { try self.decodeIfCaptured("fs_jobs_list", as: Envelope.Standard<LossyArray<Job>>.self) },
            { try self.decodeIfCaptured("fs_job_detail", as: Envelope.Standard<JobDetail>.self) },
            { try self.decodeIfCaptured("fs_visits_mine", as: Envelope.Standard<LossyArray<Visit>>.self) },
            { try self.decodeIfCaptured("fs_visit_detail", as: Envelope.Standard<VisitDetail>.self) },
            { try self.decodeIfCaptured("fs_service_requests_list", as: Envelope.Standard<LossyArray<ServiceRequest>>.self) },
            { try self.decodeIfCaptured("fs_service_request_detail", as: Envelope.Standard<ServiceRequestDetail>.self) },
            { try self.decodeIfCaptured("fs_stats", as: Envelope.Standard<FieldServiceStats>.self) },
            { try self.decodeIfCaptured("crm_accounts_list", as: Envelope.Standard<LossyArray<CRMAccount>>.self) },
            { try self.decodeIfCaptured("crm_contacts_list", as: Envelope.Standard<LossyArray<CRMContact>>.self) },
            { try self.decodeIfCaptured("crm_deals_list", as: Envelope.Standard<LossyArray<CRMDeal>>.self) },
            { try self.decodeIfCaptured("crm_pipelines", as: Envelope.Standard<LossyArray<CRMPipeline>>.self) },
            { try self.decodeIfCaptured("crm_dashboard_stats", as: Envelope.Standard<CRMDashboardStats>.self) },
            { try self.decodeIfCaptured("customers_list", as: Envelope.DataTotal<Customer>.self) },
            { try self.decodeIfCaptured("products_list", as: Envelope.DataTotal<Product>.self) },
            { try self.decodeIfCaptured("orders_list", as: Envelope.Orders<Order>.self) },
            { try self.decodeIfCaptured("orders_stats", as: OrderStats.self) },
            { try self.decodeIfCaptured("invoices_list", as: Envelope.Invoices<LossyArray<Invoice>>.self) },
            { try self.decodeIfCaptured("invoice_detail", as: Envelope.Invoices<Invoice>.self) },
            { try self.decodeIfCaptured("invoices_stats", as: Envelope.Invoices<InvoiceStats>.self) },
        ]
        for check in checks where try check() { decoded += 1 }
        try XCTSkipIf(decoded == 0, "No live fixtures captured yet — run scripts/capture-fixtures.py")
    }
}
