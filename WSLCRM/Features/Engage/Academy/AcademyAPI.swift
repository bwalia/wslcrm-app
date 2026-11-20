import Foundation

/// Academy endpoints (`lapis/routes/academy.lua`, `academy-billing.lua`, `academy-admin.lua`).
///
/// The academy routes read form bodies (the dashboard sends `toFormData`), so writes go as
/// `application/x-www-form-urlencoded`; lists and objects travel as JSON text inside a field.
struct AcademyAPI: Sendable {
    let client: APIClient

    static let base = "/api/v2/academy"

    // MARK: Courses

    struct CourseQuery: Hashable, Sendable {
        var search = ""
        var level: AcademyCourseLevel?
        var status: AcademyCourseStatus?
    }

    static let perPage = 20

    func courses(_ query: CourseQuery, page: Int) async throws -> Page<AcademyCourse> {
        var q = QueryBuilder()
        q.add("page", page)
        q.add("perPage", Self.perPage)
        q.add("search", query.search.trimmedOrNil)
        q.add("level", query.level?.rawValue)
        q.add("status", query.status?.rawValue)
        let result: AcademyCoursePage = try await client.send(.get("\(Self.base)/courses", query: q.items))
        return result.asPage
    }

    func course(_ uuid: String) async throws -> AcademyCourseWithLessons {
        try await data(.get("\(Self.base)/courses/\(uuid)"))
    }

    func categories() async throws -> [String] {
        struct Answer: Decodable { let categories: LossyArray<String>? }
        let answer: Answer = try await data(.get("\(Self.base)/categories"))
        return answer.categories?.elements ?? []
    }

    @discardableResult
    func createCourse(_ fields: [(String, String)]) async throws -> AcademyCourse {
        try await data(Endpoint(.post, "\(Self.base)/courses").withForm(fields))
    }

    @discardableResult
    func updateCourse(_ uuid: String, _ fields: [(String, String)]) async throws -> AcademyCourse {
        try await data(Endpoint(.put, "\(Self.base)/courses/\(uuid)").withForm(fields))
    }

    func deleteCourse(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/courses/\(uuid)"))
    }

    // MARK: Review (platform admin or workspace owner)

    func pendingCourses() async throws -> [AcademyCourse] {
        // `{success, data: {data: [...], total, page, perPage}}`.
        let (data, _) = try await client.sendRaw(.get("\(Self.base)/pending-courses"))
        return try Self.courses(fromPending: data)
    }

    static func courses(fromPending data: Data) throws -> [AcademyCourse] {
        struct Inner: Decodable { let data: LossyArray<AcademyCourse>? }
        struct Outer: Decodable { let data: Inner? }
        if let outer = try? JSONDecoder.opsAPI().decode(Outer.self, from: data), let rows = outer.data?.data {
            return rows.elements
        }
        struct Flat: Decodable { let data: LossyArray<AcademyCourse> }
        return try JSONDecoder.opsAPI().decode(Flat.self, from: data).data.elements
    }

    @discardableResult
    func approve(_ uuid: String) async throws -> AcademyCourse {
        try await data(Endpoint(.post, "\(Self.base)/courses/\(uuid)/approve"))
    }

    @discardableResult
    func reject(_ uuid: String) async throws -> AcademyCourse {
        try await data(Endpoint(.post, "\(Self.base)/courses/\(uuid)/reject"))
    }

    // MARK: Lessons

    func lesson(_ uuid: String) async throws -> AcademyLesson {
        try await data(.get("\(Self.base)/lessons/\(uuid)"))
    }

    @discardableResult
    func createLesson(course: String, _ fields: [(String, String)]) async throws -> AcademyLesson {
        try await data(Endpoint(.post, "\(Self.base)/courses/\(course)/lessons").withForm(fields))
    }

    @discardableResult
    func updateLesson(_ uuid: String, _ fields: [(String, String)]) async throws -> AcademyLesson {
        try await data(Endpoint(.put, "\(Self.base)/lessons/\(uuid)").withForm(fields))
    }

    func deleteLesson(_ uuid: String) async throws {
        try await client.sendDiscardingBody(.delete("\(Self.base)/lessons/\(uuid)"))
    }

    // MARK: Instructors

    func instructorStatus() async throws -> AcademyInstructorStatus {
        try await data(.get("\(Self.base)/instructor/status").academyNoNamespace)
    }

    func registerInstructor() async throws -> AcademyInstructorStatus {
        try await data(Endpoint(.post, "\(Self.base)/instructor/register").academyNoNamespace)
    }

    func profile() async throws -> AcademyProfile {
        try await client.send(.get("\(Self.base)/creator/profile"))
    }

    @discardableResult
    func saveProfile(_ fields: [(String, String)]) async throws -> AcademyProfile {
        try await client.send(Endpoint(.put, "\(Self.base)/creator/profile").withForm(fields))
    }

    // MARK: Creator money

    func creatorAccount() async throws -> AcademyCreatorAccount {
        try await client.send(.get("\(Self.base)/creator/account"))
    }

    /// Returns whether the details are now complete enough to be paid.
    func saveBank(_ values: [String: String]) async throws -> Bool {
        struct Answer: Decodable { let bankDetailsComplete: FlexibleBool? }
        let fields = AcademyBank.keys.map { ($0, values[$0] ?? "") }
        let answer: Answer = try await client.send(Endpoint(.put, "\(Self.base)/creator/account").withForm(fields))
        return answer.bankDetailsComplete?.value ?? false
    }

    @discardableResult
    func savePlan(tier: Int, amountMinor: Int, interval: String) async throws -> AcademyPlan {
        let fields = [("tier", String(tier)), ("amount", String(amountMinor)), ("interval", interval)]
        return try await client.send(Endpoint(.put, "\(Self.base)/creator/subscription-plan").withForm(fields))
    }

    // MARK: Platform admin (payouts and the platform's cut)

    func defaultFeePct() async throws -> Double {
        struct Answer: Decodable { let defaultFeePct: FlexibleDecimal? }
        let answer: Answer = try await client.send(.get("\(Self.base)/admin/settings").academyNoNamespace)
        return answer.defaultFeePct?.doubleValue ?? 0
    }

    func setDefaultFeePct(_ pct: Double) async throws {
        try await client.sendDiscardingBody(Endpoint(.put, "\(Self.base)/admin/settings").academyNoNamespace
            .withForm([("default_fee_pct", AcademyAPI.number(pct))]))
    }

    /// nil clears the instructor's own cut (they go back to the default).
    func setFeeOverride(user: String, pct: Double?) async throws {
        try await client.sendDiscardingBody(Endpoint(.put, "\(Self.base)/admin/instructors/\(user)/fee").academyNoNamespace
            .withForm([("fee_pct", pct.map(AcademyAPI.number) ?? "")]))
    }

    func payouts() async throws -> [AcademyPayout] {
        struct Answer: Decodable { let payouts: LossyArray<AcademyPayout>? }
        let answer: Answer = try await client.send(.get("\(Self.base)/admin/payouts").academyNoNamespace)
        return answer.payouts?.elements ?? []
    }

    struct PaidAnswer: Decodable, Sendable {
        let amount: FlexibleInt?
        let currency: String?
    }

    func markPaid(user: String, reference: String) async throws -> PaidAnswer {
        try await client.send(Endpoint(.post, "\(Self.base)/admin/payouts/\(user)/mark-paid").academyNoNamespace
            .withForm([("reference", reference)]))
    }

    // MARK: Learning (the learner's side; the academy workspace by its slug)

    static func publicBase(_ namespace: String) -> String {
        "/api/v2/public/academy/\(namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace)"
    }

    func learning(namespace: String) async throws -> AcademyLearning {
        try await client.send(.get("\(Self.publicBase(namespace))/me/learning").academyNoNamespace)
    }

    func catalogue(namespace: String) async throws -> [AcademyLearnerCourse] {
        struct Answer: Decodable { let courses: LossyArray<AcademyLearnerCourse>? }
        let answer: Answer = try await client.send(.get("\(Self.publicBase(namespace))/courses").academyNoNamespace)
        return answer.courses?.elements ?? []
    }

    func publicCourse(namespace: String, slug: String) async throws -> AcademyLearnerCourse {
        try await client.send(.get("\(Self.publicBase(namespace))/courses/\(slug)").academyNoNamespace)
    }

    func enrol(namespace: String, slug: String) async throws {
        try await client.sendDiscardingBody(Endpoint(.post, "\(Self.publicBase(namespace))/courses/\(slug)/enroll")
            .academyNoNamespace.withForm([]))
    }

    func courseProgress(namespace: String, slug: String) async throws -> AcademyCourseProgress {
        try await client.send(.get("\(Self.publicBase(namespace))/courses/\(slug)/progress").academyNoNamespace)
    }

    func hasAccess(namespace: String, slug: String) async throws -> Bool {
        struct Answer: Decodable { let enrolled: FlexibleBool? }
        let answer: Answer = try await client.send(.get("\(Self.publicBase(namespace))/courses/\(slug)/enrollment")
            .academyNoNamespace)
        return answer.enrolled?.value ?? false
    }

    struct ProgressAnswer: Decodable, Sendable {
        let completed: FlexibleBool?
        let completedCount: FlexibleInt?
        let total: FlexibleInt?
    }

    func setCompleted(namespace: String, lesson: String, completed: Bool) async throws -> ProgressAnswer {
        try await client.send(Endpoint(.post, "\(Self.publicBase(namespace))/lessons/\(lesson)/progress")
            .academyNoNamespace.withForm([("completed", completed ? "true" : "false")]))
    }

    /// A signed address (valid for an hour) to stream a lesson's video.
    func streamURL(namespace: String, lesson: String) async throws -> URL {
        struct Inner: Decodable { let url: String }
        let inner: Inner = try await data(.get("\(Self.publicBase(namespace))/lessons/\(lesson)/stream-url").academyNoNamespace)
        guard let url = URL(string: inner.url) else {
            throw ResourceService.problem(404, "The video’s address couldn’t be read.")
        }
        return url
    }

    // MARK: Helpers

    /// Decodes `{success, data}` (or a bare value).
    private func data<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let (raw, _) = try await client.sendRaw(endpoint)
        return try Self.decodeData(T.self, from: raw, endpoint: endpoint.summary)
    }

    static func decodeData<T: Decodable>(_ type: T.Type, from raw: Data, endpoint: String = "academy") throws -> T {
        let decoder = JSONDecoder.opsAPI()
        if let wrapped = try? decoder.decode(AcademyDataEnvelope<T>.self, from: raw) { return wrapped.data }
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            throw APIError.decoding(endpoint: endpoint, description: String(describing: error),
                                    body: String(decoding: raw.prefix(500), as: UTF8.self))
        }
    }

    /// 12.5 → "12.5", 20 → "20".
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// `{success, data}`.
struct AcademyDataEnvelope<T: Decodable>: Decodable {
    let data: T
}

extension Endpoint {
    /// Academy instructor and learner routes look the academy workspace up themselves.
    var academyNoNamespace: Endpoint {
        var copy = self
        copy.requiresNamespace = false
        return copy
    }
}

extension Services {
    var academy: AcademyAPI { AcademyAPI(client: client) }
}
