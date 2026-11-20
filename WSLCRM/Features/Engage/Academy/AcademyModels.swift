import Foundation

// Academy (the LMS): courses, lessons, instructors, creator earnings and payouts.
// Field names follow `lapis/routes/academy*.lua` and `opsapi-dashboard/services/academy.service.ts`.

/// The RBAC module that guards the academy (`requirePermission("courses", …)`).
enum AcademyRBAC {
    static let module = "courses"
}

// MARK: - Courses

enum AcademyCourseLevel: String, CaseIterable, Identifiable, Sendable {
    case beginner, intermediate, advanced
    var id: String { rawValue }
    var label: String { rawValue.capitalizedFirst }
}

/// `pending_review` is the approval gate: an instructor asking to publish lands there until an
/// admin (platform admin or the workspace owner) approves it.
enum AcademyCourseStatus: String, CaseIterable, Identifiable, Sendable {
    case draft, pendingReview = "pending_review", published, archived
    var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: "Draft"
        case .pendingReview: "Waiting for review"
        case .published: "Published"
        case .archived: "Archived"
        }
    }

    var tone: Tone {
        switch self {
        case .draft: .info
        case .pendingReview: .warning
        case .published: .success
        case .archived: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "pencil.circle"
        case .pendingReview: "hourglass"
        case .published: "checkmark.circle"
        case .archived: "archivebox"
        }
    }
}

enum AcademyLessonStatus: String, CaseIterable, Identifiable, Sendable {
    case draft, published
    var id: String { rawValue }
    var label: String { self == .draft ? "Draft" : "Published" }
}

struct AcademyCourse: Decodable, Identifiable, Hashable, Sendable {
    let uuid: String
    var title: String
    var slug: String
    var description: String?
    var instructor: String?
    var thumbnailUrl: String?
    var category: String?
    var tags: [String]
    var level: String
    var isFree: Bool
    /// Minor units (999 = 9.99).
    var price: Int
    var currency: String
    var tier: Int
    var durationMinutes: Int?
    var lessonCount: Int?
    var status: String
    var ownerUserUuid: String?
    var createdAt: String?
    var updatedAt: String?

    var id: String { uuid }
    var statusValue: AcademyCourseStatus { AcademyCourseStatus(rawValue: status) ?? .draft }
    var levelValue: AcademyCourseLevel { AcademyCourseLevel(rawValue: level) ?? .beginner }

    init(uuid: String, title: String, slug: String = "", description: String? = nil, instructor: String? = nil,
         thumbnailUrl: String? = nil, category: String? = nil, tags: [String] = [], level: String = "beginner",
         isFree: Bool = true, price: Int = 0, currency: String = "USD", tier: Int = 1, durationMinutes: Int? = nil,
         lessonCount: Int? = nil, status: String = "draft", ownerUserUuid: String? = nil, createdAt: String? = nil,
         updatedAt: String? = nil) {
        self.uuid = uuid
        self.title = title
        self.slug = slug
        self.description = description
        self.instructor = instructor
        self.thumbnailUrl = thumbnailUrl
        self.category = category
        self.tags = tags
        self.level = level
        self.isFree = isFree
        self.price = price
        self.currency = currency
        self.tier = tier
        self.durationMinutes = durationMinutes
        self.lessonCount = lessonCount
        self.status = status
        self.ownerUserUuid = ownerUserUuid
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The public shapes call the uuid `id`.
        uuid = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) ?? ""
        title = c.decodeFlexibleString(forKey: .title) ?? "Untitled course"
        slug = c.decodeFlexibleString(forKey: .slug) ?? ""
        description = c.decodeFlexibleString(forKey: .description)?.trimmedOrNil
        instructor = c.decodeFlexibleString(forKey: .instructor)?.trimmedOrNil
        thumbnailUrl = c.decodeFlexibleString(forKey: .thumbnailUrl)?.trimmedOrNil
        category = c.decodeFlexibleString(forKey: .category)?.trimmedOrNil
        tags = AcademyCourse.decodeTags(c)
        level = c.decodeFlexibleString(forKey: .level) ?? "beginner"
        isFree = c.decodeFlexibleBool(forKey: .isFree) ?? true
        price = c.decodeFlexibleInt(forKey: .price) ?? 0
        currency = c.decodeFlexibleString(forKey: .currency)?.trimmedOrNil ?? "USD"
        tier = max(1, c.decodeFlexibleInt(forKey: .tier) ?? 1)
        durationMinutes = c.decodeFlexibleInt(forKey: .durationMinutes)
        lessonCount = c.decodeFlexibleInt(forKey: .lessonCount)
        status = c.decodeFlexibleString(forKey: .status) ?? "published"
        ownerUserUuid = c.decodeFlexibleString(forKey: .ownerUserUuid)
        createdAt = c.decodeFlexibleString(forKey: .createdAt)
        updatedAt = c.decodeFlexibleString(forKey: .updatedAt)
    }

    /// `tags` arrives as an array, lua-cjson's `{}` when empty, or (straight from a jsonb column) its text.
    private static func decodeTags(_ c: KeyedDecodingContainer<CodingKeys>) -> [String] {
        if let list = try? c.decodeIfPresent([String].self, forKey: .tags) { return list }
        if let text = try? c.decodeIfPresent(String.self, forKey: .tags), let data = text.data(using: .utf8),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            return list
        }
        return []
    }

    enum CodingKeys: String, CodingKey {
        case uuid, id, title, slug, description, instructor, thumbnailUrl, category, tags, level, isFree, price
        case currency, tier, durationMinutes, lessonCount, status, ownerUserUuid, createdAt, updatedAt
    }

    /// "Free", or the price in its currency.
    var priceText: String {
        isFree ? "Free" : AcademyMoney.text(minor: price, currency: currency)
    }

    /// "2h 5m", or nil when nothing is timed yet.
    var durationText: String? { AcademyDuration.minutes(durationMinutes) }
}

struct AcademyLesson: Decodable, Identifiable, Hashable, Sendable {
    let uuid: String
    var title: String
    var description: String?
    var position: Int?
    var durationSeconds: Int
    var isPreview: Bool
    var s3Key: String?
    /// Whether the lesson has a video (public shapes say so without giving the key away).
    var hasVideo: Bool
    var contentHtml: String?
    var status: String
    var createdAt: String?
    var updatedAt: String?

    var id: String { uuid }
    var statusValue: AcademyLessonStatus { AcademyLessonStatus(rawValue: status) ?? .draft }

    init(uuid: String, title: String, description: String? = nil, position: Int? = nil, durationSeconds: Int = 0,
         isPreview: Bool = false, s3Key: String? = nil, contentHtml: String? = nil, status: String = "draft") {
        self.uuid = uuid
        self.title = title
        self.description = description
        self.position = position
        self.durationSeconds = durationSeconds
        self.isPreview = isPreview
        self.s3Key = s3Key
        hasVideo = s3Key?.trimmedOrNil != nil
        self.contentHtml = contentHtml
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = c.decodeFlexibleString(forKey: .uuid) ?? c.decodeFlexibleString(forKey: .id) ?? ""
        title = c.decodeFlexibleString(forKey: .title) ?? "Untitled lesson"
        description = c.decodeFlexibleString(forKey: .description)?.trimmedOrNil
        position = c.decodeFlexibleInt(forKey: .position)
        durationSeconds = c.decodeFlexibleInt(forKey: .durationSeconds) ?? 0
        isPreview = c.decodeFlexibleBool(forKey: .isPreview) ?? false
        s3Key = c.decodeFlexibleString(forKey: .s3Key)?.trimmedOrNil
        hasVideo = c.decodeFlexibleBool(forKey: .hasVideo) ?? (s3Key != nil)
        contentHtml = c.decodeFlexibleString(forKey: .contentHtml)
        // Public shapes only ever list published lessons and leave the status out.
        status = c.decodeFlexibleString(forKey: .status) ?? "published"
        createdAt = c.decodeFlexibleString(forKey: .createdAt)
        updatedAt = c.decodeFlexibleString(forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case uuid, id, title, description, position, durationSeconds, isPreview, s3Key, hasVideo, contentHtml, status
        case createdAt, updatedAt
    }

    var durationText: String? { AcademyDuration.seconds(durationSeconds) }
}

struct AcademyCourseWithLessons: Decodable, Sendable {
    var course: AcademyCourse
    var lessons: [AcademyLesson]

    init(course: AcademyCourse, lessons: [AcademyLesson]) {
        self.course = course
        self.lessons = lessons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        course = try c.decode(AcademyCourse.self, forKey: .course)
        lessons = c.decodeLossyArray(AcademyLesson.self, forKey: .lessons)
            .sorted { ($0.position ?? .max) < ($1.position ?? .max) }
    }

    enum CodingKeys: String, CodingKey { case course, lessons }
}

/// `GET /api/v2/academy/courses`: `{success, data: [...], pagination: {page, perPage, total}}`.
struct AcademyCoursePage: Decodable, Sendable {
    var data: [AcademyCourse]
    var page: Int
    var perPage: Int
    var total: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = c.decodeLossyArray(AcademyCourse.self, forKey: .data)
        let paging = try? c.nestedContainer(keyedBy: PagingKeys.self, forKey: .pagination)
        page = paging?.decodeFlexibleInt(forKey: .page) ?? 1
        perPage = paging?.decodeFlexibleInt(forKey: .perPage) ?? max(data.count, 1)
        total = paging?.decodeFlexibleInt(forKey: .total) ?? data.count
    }

    enum CodingKeys: String, CodingKey { case data, pagination }
    enum PagingKeys: String, CodingKey { case page, perPage, total }

    var asPage: Page<AcademyCourse> { Page(items: data, page: page, perPage: perPage, total: total) }
}

// MARK: - Instructors

struct AcademyNamespace: Decodable, Hashable, Sendable {
    var id: Int?
    var uuid: String
    var slug: String
    var name: String

    init(id: Int? = nil, uuid: String, slug: String, name: String) {
        self.id = id
        self.uuid = uuid
        self.slug = slug
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleInt(forKey: .id)
        uuid = c.decodeFlexibleString(forKey: .uuid) ?? ""
        slug = c.decodeFlexibleString(forKey: .slug) ?? "academy"
        name = c.decodeFlexibleString(forKey: .name) ?? "Academy"
    }

    enum CodingKeys: String, CodingKey { case id, uuid, slug, name }
}

/// `GET /api/v2/academy/instructor/status` (and the answer to `POST …/instructor/register`).
struct AcademyInstructorStatus: Decodable, Hashable, Sendable {
    var isInstructor: Bool
    var isOwner: Bool
    var namespace: AcademyNamespace?

    init(isInstructor: Bool, isOwner: Bool, namespace: AcademyNamespace?) {
        self.isInstructor = isInstructor
        self.isOwner = isOwner
        self.namespace = namespace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isInstructor = c.decodeFlexibleBool(forKey: .isInstructor) ?? false
        isOwner = c.decodeFlexibleBool(forKey: .isOwner) ?? false
        namespace = try? c.decodeIfPresent(AcademyNamespace.self, forKey: .namespace)
    }

    enum CodingKeys: String, CodingKey { case isInstructor, isOwner, namespace }
}

struct AcademyAchievement: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var title: String
    var issuer: String
    var year: String

    init(title: String = "", issuer: String = "", year: String = "") {
        self.title = title
        self.issuer = issuer
        self.year = year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.decodeFlexibleString(forKey: .title) ?? ""
        issuer = c.decodeFlexibleString(forKey: .issuer) ?? ""
        year = c.decodeFlexibleString(forKey: .year) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(issuer, forKey: .issuer)
        try c.encode(year, forKey: .year)
    }

    enum CodingKeys: String, CodingKey { case title, issuer, year }
}

struct AcademyEducation: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var degree: String
    var institution: String
    var year: String

    init(degree: String = "", institution: String = "", year: String = "") {
        self.degree = degree
        self.institution = institution
        self.year = year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        degree = c.decodeFlexibleString(forKey: .degree) ?? ""
        institution = c.decodeFlexibleString(forKey: .institution) ?? ""
        year = c.decodeFlexibleString(forKey: .year) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(degree, forKey: .degree)
        try c.encode(institution, forKey: .institution)
        try c.encode(year, forKey: .year)
    }

    enum CodingKeys: String, CodingKey { case degree, institution, year }
}

/// `GET /api/v2/academy/creator/profile` (flat, no envelope).
struct AcademyProfile: Decodable, Hashable, Sendable {
    static let socialKeys = ["twitter", "linkedin", "github", "youtube"]

    var headline = ""
    var bio = ""
    var avatarUrl = ""
    var location = ""
    var website = ""
    var socials: [String: String] = [:]
    var achievements: [AcademyAchievement] = []
    var education: [AcademyEducation] = []
    var skills: [String] = []
    var exists = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = c.decodeFlexibleString(forKey: .headline) ?? ""
        bio = c.decodeFlexibleString(forKey: .bio) ?? ""
        avatarUrl = c.decodeFlexibleString(forKey: .avatarUrl) ?? ""
        location = c.decodeFlexibleString(forKey: .location) ?? ""
        website = c.decodeFlexibleString(forKey: .website) ?? ""
        // `{}` when empty (lua-cjson), an object of links otherwise.
        socials = (try? c.decodeIfPresent([String: String].self, forKey: .socials)) ?? [:]
        achievements = c.decodeLossyArray(AcademyAchievement.self, forKey: .achievements)
        education = c.decodeLossyArray(AcademyEducation.self, forKey: .education)
        skills = c.decodeLossyArray(String.self, forKey: .skills)
        exists = c.decodeFlexibleBool(forKey: .exists) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case headline, bio, avatarUrl, location, website, socials, achievements, education, skills, exists
    }

    /// The form body `PUT /api/v2/academy/creator/profile` reads: lists and objects as JSON text
    /// (the web does the same), empty rows dropped.
    func formFields(skillsText: String) -> [(String, String)] {
        let skills = skillsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let kept = achievements.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        let schooling = education.filter { !$0.degree.trimmingCharacters(in: .whitespaces).isEmpty }
        let links = socials.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        return [
            ("headline", headline), ("bio", bio), ("avatar_url", avatarUrl), ("location", location),
            ("website", website), ("socials", AcademyJSON.text(links)), ("achievements", AcademyJSON.text(kept)),
            ("education", AcademyJSON.text(schooling)), ("skills", AcademyJSON.text(skills)),
        ]
    }
}

// MARK: - Creator money

struct AcademyBank: Decodable, Hashable, Sendable {
    static let keys = ["account_holder_name", "bank_name", "account_number", "routing_number", "sort_code", "iban",
                       "swift_bic", "bank_country", "payout_email"]

    var values: [String: String] = [:]
    /// On the admin payouts list: whether the instructor gave enough to be paid.
    var complete: Bool?

    init(values: [String: String] = [:], complete: Bool? = nil) {
        self.values = values
        self.complete = complete
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AcademyAnyKey.self)
        for key in Self.keys {
            // The app's decoder turns `account_holder_name` into `accountHolderName`.
            if let k = AcademyAnyKey(stringValue: JSONValue.camelCased(key)),
               let value = c.decodeFlexibleString(forKey: k)?.trimmedOrNil {
                values[key] = value
            }
        }
        complete = AcademyAnyKey(stringValue: "complete").flatMap { c.decodeFlexibleBool(forKey: $0) }
    }

    subscript(key: String) -> String { values[key] ?? "" }

    /// "Ann Smith · GB12… · 12-34-56" for the payouts list.
    var summary: String {
        let account = values["iban"] ?? values["account_number"] ?? "—"
        let extra = values["sort_code"] ?? values["swift_bic"] ?? values["routing_number"]
        return [values["account_holder_name"] ?? "—", account, extra].compactMap { $0 }.joined(separator: " · ")
    }

    /// What the server needs before it marks the details complete (holder + account or IBAN), in words.
    static func problem(_ values: [String: String]) -> String? {
        if (values["account_holder_name"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the account holder’s name."
        }
        if (values["account_number"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
           (values["iban"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter an account number or an IBAN."
        }
        return nil
    }
}

/// Keys read by name at run time (bank details).
struct AcademyAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct AcademyPlan: Decodable, Hashable, Sendable, Identifiable {
    var tier: Int
    /// Minor units.
    var amount: Int
    var currency: String
    var interval: String
    var id: Int { tier }

    init(tier: Int, amount: Int, currency: String, interval: String) {
        self.tier = tier
        self.amount = amount
        self.currency = currency
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = max(1, c.decodeFlexibleInt(forKey: .tier) ?? 1)
        amount = c.decodeFlexibleInt(forKey: .amount) ?? 0
        currency = c.decodeFlexibleString(forKey: .currency) ?? "usd"
        interval = c.decodeFlexibleString(forKey: .interval) ?? "month"
    }

    enum CodingKeys: String, CodingKey { case tier, amount, currency, interval }

    var priceText: String {
        "\(AcademyMoney.text(minor: amount, currency: currency)) a \(interval == "year" ? "year" : "month")"
    }
}

struct AcademyEarnings: Decodable, Hashable, Sendable {
    var totalNet = 0
    var owed = 0
    var paid = 0
    var currency = "usd"
    var sales = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalNet = c.decodeFlexibleInt(forKey: .totalNet) ?? 0
        owed = c.decodeFlexibleInt(forKey: .owed) ?? 0
        paid = c.decodeFlexibleInt(forKey: .paid) ?? 0
        currency = c.decodeFlexibleString(forKey: .currency) ?? "usd"
        sales = c.decodeFlexibleInt(forKey: .sales) ?? 0
    }

    enum CodingKeys: String, CodingKey { case totalNet, owed, paid, currency, sales }
}

/// `GET /api/v2/academy/creator/account` (flat, no envelope).
struct AcademyCreatorAccount: Decodable, Hashable, Sendable {
    var bank: AcademyBank
    var bankDetailsComplete: Bool
    var feePct: Double
    var plans: [AcademyPlan]
    var earnings: AcademyEarnings

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bank = (try? c.decodeIfPresent(AcademyBank.self, forKey: .bank)) ?? AcademyBank()
        bankDetailsComplete = c.decodeFlexibleBool(forKey: .bankDetailsComplete) ?? false
        feePct = c.decodeFlexibleDecimal(forKey: .feePct).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        var plans = c.decodeLossyArray(AcademyPlan.self, forKey: .plans)
        // A server before multi-tier memberships sends only `plan`.
        if plans.isEmpty, let single = try? c.decodeIfPresent(AcademyPlan.self, forKey: .plan) { plans = [single] }
        self.plans = plans.sorted { $0.tier < $1.tier }
        earnings = (try? c.decodeIfPresent(AcademyEarnings.self, forKey: .earnings)) ?? AcademyEarnings()
    }

    enum CodingKeys: String, CodingKey { case bank, bankDetailsComplete, feePct, plan, plans, earnings }
}

/// One instructor on the admin payouts list (`GET /api/v2/academy/admin/payouts` → `payouts`).
struct AcademyPayout: Decodable, Hashable, Sendable, Identifiable {
    var userUuid: String
    var instructorName: String
    var instructorEmail: String?
    var owed: Int
    var currency: String
    var sales: Int
    var bank: AcademyBank?
    var id: String { userUuid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userUuid = c.decodeFlexibleString(forKey: .userUuid) ?? ""
        instructorName = c.decodeFlexibleString(forKey: .instructorName)?.trimmedOrNil ?? "Instructor"
        instructorEmail = c.decodeFlexibleString(forKey: .instructorEmail)?.trimmedOrNil
        owed = c.decodeFlexibleInt(forKey: .owed) ?? 0
        currency = c.decodeFlexibleString(forKey: .currency) ?? "usd"
        sales = c.decodeFlexibleInt(forKey: .sales) ?? 0
        bank = try? c.decodeIfPresent(AcademyBank.self, forKey: .bank)
    }

    enum CodingKeys: String, CodingKey { case userUuid, instructorName, instructorEmail, owed, currency, sales, bank }

    var canBePaid: Bool { bank?.complete == true }
}

// MARK: - Learning (the learner's side)

struct AcademyProgress: Decodable, Hashable, Sendable {
    var completed: Int
    var total: Int
    var percent: Int
    var nextLessonId: String?
    var lastActivityAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completed = c.decodeFlexibleInt(forKey: .completed) ?? 0
        total = c.decodeFlexibleInt(forKey: .total) ?? 0
        percent = c.decodeFlexibleInt(forKey: .percent) ?? (total > 0 ? completed * 100 / total : 0)
        nextLessonId = c.decodeFlexibleString(forKey: .nextLessonId)
        lastActivityAt = c.decodeFlexibleString(forKey: .lastActivityAt)
    }

    enum CodingKeys: String, CodingKey { case completed, total, percent, nextLessonId, lastActivityAt }
}

/// A course on the learner's side: the public shape, with its lessons and (on "My learning") progress.
struct AcademyLearnerCourse: Decodable, Identifiable, Hashable, Sendable {
    var course: AcademyCourse
    var lessons: [AcademyLesson]
    var progress: AcademyProgress?
    var instructorName: String?
    var id: String { course.uuid }

    init(from decoder: Decoder) throws {
        course = try AcademyCourse(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lessons = c.decodeLossyArray(AcademyLesson.self, forKey: .lessons)
            .sorted { ($0.position ?? .max) < ($1.position ?? .max) }
        progress = try? c.decodeIfPresent(AcademyProgress.self, forKey: .progress)
        instructorName = c.decodeFlexibleString(forKey: .instructorName)
    }

    enum CodingKeys: String, CodingKey { case lessons, progress, instructorName }
}

/// `GET /api/v2/public/academy/:ns/me/learning`.
struct AcademyLearning: Decodable, Sendable {
    var courses: [AcademyLearnerCourse]
    var lessonsCompleted: Int
    var minutesCompleted: Int
    var coursesStarted: Int
    var coursesEnrolled: Int
    var coursesCompleted: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        courses = c.decodeLossyArray(AcademyLearnerCourse.self, forKey: .courses)
        let stats = try? c.nestedContainer(keyedBy: StatsKeys.self, forKey: .stats)
        lessonsCompleted = stats?.decodeFlexibleInt(forKey: .lessonsCompleted) ?? 0
        minutesCompleted = stats?.decodeFlexibleInt(forKey: .minutesCompleted) ?? 0
        coursesStarted = stats?.decodeFlexibleInt(forKey: .coursesStarted) ?? 0
        coursesEnrolled = stats?.decodeFlexibleInt(forKey: .coursesEnrolled) ?? courses.count
        coursesCompleted = stats?.decodeFlexibleInt(forKey: .coursesCompleted) ?? 0
    }

    enum CodingKeys: String, CodingKey { case courses, stats }
    enum StatsKeys: String, CodingKey {
        case lessonsCompleted, minutesCompleted, coursesStarted, coursesEnrolled, coursesCompleted
    }
}

/// `GET /api/v2/public/academy/:ns/courses/:slug/progress`.
struct AcademyCourseProgress: Decodable, Hashable, Sendable {
    var completedLessonIds: [String]
    var completed: Int
    var total: Int
    var nextLessonId: String?

    init(completedLessonIds: [String] = [], completed: Int = 0, total: Int = 0, nextLessonId: String? = nil) {
        self.completedLessonIds = completedLessonIds
        self.completed = completed
        self.total = total
        self.nextLessonId = nextLessonId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completedLessonIds = c.decodeLossyArray(String.self, forKey: .completedLessonIds)
        completed = c.decodeFlexibleInt(forKey: .completed) ?? completedLessonIds.count
        total = c.decodeFlexibleInt(forKey: .total) ?? 0
        nextLessonId = c.decodeFlexibleString(forKey: .nextLessonId)
    }

    enum CodingKeys: String, CodingKey { case completedLessonIds, completed, total, nextLessonId }
}

// MARK: - Formatting

enum AcademyMoney {
    /// 999 GBP → "£9.99".
    static func text(minor: Int, currency: String) -> String {
        Formatters.money(Decimal(minor) / 100, currency: currency.uppercased()) ?? "\(minor)"
    }

    /// What a person typed ("9.99", "£9.99", "9,99") in minor units, or nil.
    static func minor(fromTyped text: String) -> Int? {
        var cleaned = text.trimmingCharacters(in: .whitespaces).filter { $0.isNumber || $0 == "." || $0 == "," }
        // "1,234.50": commas group thousands; "9,99": a comma is the decimal point.
        cleaned = cleaned.contains(".") ? cleaned.replacingOccurrences(of: ",", with: "")
                                        : cleaned.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: value * 100).rounding(accordingToBehavior: nil).intValue
    }

    /// 999 → "9.99" (for editing).
    static func major(_ minor: Int) -> String {
        (Decimal(minor) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }

    /// The currencies the server can charge in (`academy-billing.lua` SUPPORTED_CURRENCIES).
    static let currencies = ["USD", "GBP", "EUR", "INR", "AUD", "CAD", "SGD", "AED", "JPY", "NZD"]
}

enum AcademyDuration {
    /// 125 → "2h 5m"; 0/nil → nil.
    static func minutes(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60, rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }

    /// 95 → "1:35"; 0 → nil.
    static func seconds(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

enum AcademyJSON {
    /// A value as compact JSON text (lists and objects travel as text inside form bodies).
    static func text(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
