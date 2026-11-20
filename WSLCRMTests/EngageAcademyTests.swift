import XCTest
import UIKit
@testable import WSLCRM

/// The academy, built natively: response shapes from `lapis/routes/academy*.lua`, the form bodies
/// the routes read, the lesson content editor (HTML ⇄ blocks ⇄ styled text) and the menu key.
final class EngageAcademyTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.opsAPI().decode(T.self, from: Data(json.utf8))
    }

    private func fields(_ pairs: [(String, String)]) -> [String: String] {
        Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }

    // MARK: Courses

    /// `GET /api/v2/academy/courses`: `{success, data, pagination: {page, perPage, total}}`, tags as an array.
    func testTheCourseListAndItsPaging() throws {
        let page = try decode(AcademyCoursePage.self, """
        {"success":true,"data":[{"id":7,"uuid":"c-1","namespace_id":3,"title":"Intro to Swift","slug":"intro-to-swift",
          "description":"Learn Swift","instructor":"Ann","thumbnail_url":"https://x/t.jpg","category":"coding",
          "tags":["swift","ios"],"level":"beginner","is_free":false,"price":999,"currency":"GBP","tier":2,
          "rating":0,"rating_count":0,"duration_minutes":125,"lesson_count":4,"status":"pending_review",
          "owner_user_uuid":"u-1","created_at":"2026-11-01 10:00:00","updated_at":"2026-11-02 10:00:00"}],
         "pagination":{"page":1,"perPage":20,"total":41}}
        """)
        XCTAssertEqual(page.total, 41)
        XCTAssertTrue(page.asPage.hasMore)
        let course = try XCTUnwrap(page.data.first)
        XCTAssertEqual(course.uuid, "c-1")
        XCTAssertEqual(course.tags, ["swift", "ios"])
        XCTAssertEqual(course.statusValue, .pendingReview)
        XCTAssertEqual(course.statusValue.label, "Waiting for review")
        XCTAssertFalse(course.isFree)
        XCTAssertEqual(course.price, 999)
        XCTAssertEqual(course.tier, 2)
        XCTAssertEqual(course.durationText, "2h 5m")
        XCTAssertTrue(course.priceText.contains("9.99"), course.priceText)
    }

    /// `GET /pending-courses` wraps CourseQueries.list's own `{data, total…}`, and tags are the raw jsonb text.
    func testThePendingQueueShape() throws {
        let courses = try AcademyAPI.courses(fromPending: Data("""
        {"success":true,"data":{"data":[{"uuid":"p-1","title":"Waiting","slug":"waiting","tags":"[\\"a\\",\\"b\\"]",
          "level":"advanced","is_free":"t","price":"0","currency":"USD","status":"pending_review","lesson_count":"3"}],
          "total":1,"page":1,"perPage":200}}
        """.utf8))
        XCTAssertEqual(courses.map(\.uuid), ["p-1"])
        XCTAssertEqual(courses[0].tags, ["a", "b"])
        XCTAssertTrue(courses[0].isFree, "Postgres booleans arrive as \"t\"")
        XCTAssertEqual(courses[0].lessonCount, 3)
        XCTAssertEqual(courses[0].levelValue, .advanced)
    }

    /// `GET /courses/:uuid`: `{success, data: {course, lessons}}`; an empty list is lua-cjson's `{}`.
    func testACourseWithItsLessonsInOrder() throws {
        let raw = Data("""
        {"success":true,"data":{"course":{"uuid":"c-1","title":"T","slug":"t","tags":{},"level":"beginner",
          "is_free":true,"price":0,"currency":"USD","status":"draft"},
         "lessons":[{"uuid":"l-2","title":"Second","position":2,"duration_seconds":95,"is_preview":false,"status":"published",
                     "s3_key":"courses/t/2.mp4","content_html":"<p>Hi</p>"},
                    {"uuid":"l-1","title":"First","position":1,"duration_seconds":0,"is_preview":true,"status":"draft"}]}}
        """.utf8)
        let result = try AcademyAPI.decodeData(AcademyCourseWithLessons.self, from: raw)
        XCTAssertEqual(result.course.tags, [])
        XCTAssertEqual(result.lessons.map(\.uuid), ["l-1", "l-2"])
        XCTAssertEqual(result.lessons[1].durationText, "1:35")
        XCTAssertTrue(result.lessons[1].hasVideo)
        XCTAssertTrue(result.lessons[0].isPreview)
        XCTAssertEqual(result.lessons[0].statusValue, .draft)
    }

    /// The course form sends what `POST/PUT /courses` reads: minor units, tags as one JSON field.
    func testTheCourseFormBody() {
        var draft = AcademyCourseDraft(instructor: "Ann Smith")
        draft.title = "  Pottery  "
        XCTAssertNil(draft.problem)
        var body = fields(draft.formFields)
        XCTAssertEqual(body["title"], "Pottery")
        XCTAssertEqual(body["is_free"], "true")
        XCTAssertEqual(body["price"], "0")
        XCTAssertEqual(body["tags"], "[]", "an empty list clears the tags on the server")
        XCTAssertEqual(body["instructor"], "Ann Smith")
        XCTAssertNil(body["slug"], "no slug: the server makes one from the title")

        draft.isFree = false
        XCTAssertEqual(draft.problem, "A paid course needs a price above 0, for example 9.99.")
        draft.price = "£12.50"
        draft.slug = "pottery-basics"
        draft.addTag("Clay")
        draft.addTag("clay")
        draft.addTag(String(repeating: "x", count: 60))
        draft.status = .published
        body = fields(draft.formFields)
        XCTAssertNil(draft.problem)
        XCTAssertEqual(body["price"], "1250")
        XCTAssertEqual(body["is_free"], "false")
        XCTAssertEqual(body["slug"], "pottery-basics")
        XCTAssertEqual(body["status"], "published")
        XCTAssertEqual(draft.tags.count, 2, "no repeats, whatever the case")
        XCTAssertEqual(draft.tags[1].count, 40, "tags are cut to 40 characters")
        XCTAssertEqual(body["tags"], #"["Clay","\#(String(repeating: "x", count: 40))"]"#)

        draft.title = ""
        XCTAssertEqual(draft.problem, "Give the course a title.")
    }

    func testEditingACourseStartsFromItsValues() {
        let course = AcademyCourse(uuid: "c", title: "T", slug: "t", tags: ["a"], level: "intermediate", isFree: false,
                                   price: 999, currency: "gbp", tier: 3, status: "archived")
        let draft = AcademyCourseDraft(course)
        XCTAssertEqual(draft.price, "9.99")
        XCTAssertEqual(draft.currency, "GBP")
        XCTAssertEqual(draft.level, .intermediate)
        XCTAssertEqual(draft.status, .archived)
        XCTAssertEqual(draft.tier, 3)
    }

    func testMoneyTypedInEitherStyle() {
        XCTAssertEqual(AcademyMoney.minor(fromTyped: "9.99"), 999)
        XCTAssertEqual(AcademyMoney.minor(fromTyped: "9,99"), 999)
        XCTAssertEqual(AcademyMoney.minor(fromTyped: "£1,234.50"), 123_450)
        XCTAssertEqual(AcademyMoney.minor(fromTyped: "10"), 1000)
        XCTAssertNil(AcademyMoney.minor(fromTyped: "free"))
        XCTAssertEqual(AcademyMoney.major(1250), "12.50")
    }

    // MARK: Lessons

    func testTheLessonFormBody() {
        var draft = AcademyLessonDraft()
        XCTAssertEqual(draft.problem, "Give the lesson a title.")
        draft.title = "Welcome"
        draft.minutes = 3
        draft.seconds = 5
        draft.isPreview = true
        draft.contentHTML = "<p>Hello</p>"
        let body = fields(draft.formFields)
        XCTAssertEqual(body["duration_seconds"], "185")
        XCTAssertEqual(body["is_preview"], "true")
        XCTAssertEqual(body["status"], "draft")
        XCTAssertEqual(body["content_html"], "<p>Hello</p>")
        XCTAssertEqual(body["content_json"], "", "the HTML is the content; the web editor rebuilds its own copy")
        let lesson = AcademyLesson(uuid: "l", title: "T", durationSeconds: 185, status: "published")
        XCTAssertEqual(AcademyLessonDraft(lesson).minutes, 3)
        XCTAssertEqual(AcademyLessonDraft(lesson).seconds, 5)
    }

    func testReorderingSendsOnlyTheMovedLessons() {
        let a = AcademyLesson(uuid: "a", title: "A", position: 1)
        let b = AcademyLesson(uuid: "b", title: "B", position: 2)
        let c = AcademyLesson(uuid: "c", title: "C", position: 3)
        let changes = AcademyLessonOrder.changes(before: [a, b, c], after: [a, c, b])
        XCTAssertEqual(changes.map(\.0), ["c", "b"])
        XCTAssertEqual(changes.map(\.1), [2, 3])
    }

    // MARK: Lesson content: HTML ⇄ blocks

    /// What the web's editor (TipTap) saves, read into blocks and written back unchanged.
    static let tiptap = """
    <h2 style="text-align: center">Welcome</h2><p>Hello <strong>there</strong>, see \
    <a target="_blank" rel="noopener noreferrer nofollow" href="https://example.com">this</a>.</p>\
    <ul><li><p>One</p></li><li><p><em>Two</em></p></li></ul><ol><li><p>First</p></li></ol>\
    <blockquote><p>Wise words</p></blockquote><pre><code class="language-swift">let a = 1 &lt; 2</code></pre><hr>\
    <img src="https://example.com/a.png" alt="A chart" class="academy-img">\
    <div class="academy-video"><iframe src="https://www.youtube.com/embed/abcdef123" frameborder="0"></iframe></div>\
    <table style="min-width: 50px"><colgroup><col><col></colgroup><tbody><tr><th colspan="1" rowspan="1"><p>Name</p></th>\
    <th colspan="1" rowspan="1"><p>Age</p></th></tr><tr><td colspan="1" rowspan="1"><p>Ann</p></td>\
    <td colspan="1" rowspan="1"><p>30</p></td></tr></tbody></table><p><mark data-color="#fef08a" \
    style="background-color: #fef08a; color: inherit">Note</mark> <span style="color: #dc2626">red</span> H<sub>2</sub>O</p>
    """

    func testTheWebEditorsHTMLBecomesBlocks() {
        let content = AcademyContent.parse(Self.tiptap)
        let kinds = content.blocks.map(\.kindName)
        XCTAssertEqual(kinds, ["Heading 2", "Text", "Bullet list", "Numbered list", "Quote", "Code", "Divider", "Picture",
                               "Video", "Table", "Text"])
        guard case .text(.h2, let heading, .center) = content.blocks[0].kind else { return XCTFail("\(content.blocks[0])") }
        XCTAssertEqual(heading, "Welcome")
        guard case .list(false, let items) = content.blocks[2].kind else { return XCTFail() }
        XCTAssertEqual(items, ["One", "<em>Two</em>"])
        guard case .code(let code, "swift") = content.blocks[5].kind else { return XCTFail("\(content.blocks[5])") }
        XCTAssertEqual(code, "let a = 1 < 2")
        guard case .image("https://example.com/a.png", "A chart") = content.blocks[7].kind else { return XCTFail() }
        guard case .video("https://www.youtube.com/embed/abcdef123") = content.blocks[8].kind else { return XCTFail() }
        guard case .table(let rows, true) = content.blocks[9].kind else { return XCTFail("\(content.blocks[9])") }
        XCTAssertEqual(rows, [["Name", "Age"], ["Ann", "30"]])
        XCTAssertEqual(content.html, Self.tiptap, "nothing changed: written back exactly as read")
    }

    func testWhatTheBlocksCantHoldStaysAsHTML() {
        let html = #"<div class="callout"><p>Careful</p></div><ul><li><p>Outer</p><ul><li><p>Inner</p></li></ul></li></ul>"#
            + #"<p class="lead">Styled</p><h5>Small</h5>"#
        let content = AcademyContent.parse(html)
        XCTAssertEqual(content.blocks.map(\.kindName), ["HTML", "HTML", "HTML", "HTML"])
        XCTAssertEqual(content.html, html)
    }

    func testAChangedBlockIsWrittenFresh() {
        var content = AcademyContent.parse(#"<p style="text-align: right">Old</p><hr>"#)
        content.blocks[0].kind = .text(.h3, html: "New <strong>title</strong>", align: .none)
        content.blocks[0].source = nil
        content.blocks.append(AcademyBlock(.list(ordered: true, items: ["a", "b"])))
        content.blocks.append(AcademyBlock(.video(src: "https://player.vimeo.com/video/42")))
        content.blocks.append(AcademyBlock(.table(rows: [["x", "<y>"]], header: false)))
        content.blocks.append(AcademyBlock(.image(src: "https://e.com/p.png", alt: "A \"quoted\" picture")))
        XCTAssertEqual(content.html, "<h3>New <strong>title</strong></h3><hr><ol><li><p>a</p></li><li><p>b</p></li></ol>"
            + #"<div class="academy-video"><iframe src="https://player.vimeo.com/video/42" title="Lesson video" "#
            + #"frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; "#
            + #"picture-in-picture" allowfullscreen="true"></iframe></div>"#
            + "<table><tbody><tr><td><p>x</p></td><td><p>&lt;y&gt;</p></td></tr></tbody></table>"
            + #"<img src="https://e.com/p.png" alt="A &quot;quoted&quot; picture" class="academy-img">"#)
        // And it reads back as the same blocks.
        let reread = AcademyContent.parse(content.html)
        XCTAssertEqual(reread.blocks.map(\.kind), content.blocks.map(\.kind))
    }

    func testLooseTextAndAnEmptyLesson() {
        XCTAssertTrue(AcademyContent.parse("").blocks.isEmpty)
        let loose = AcademyContent.parse("Just words with <b>bold</b>")
        guard case .text(.paragraph, let html, .none) = loose.blocks.first?.kind else { return XCTFail() }
        XCTAssertEqual(html, "Just words with <b>bold</b>")
    }

    // MARK: Lesson content: styled text

    func testInlineHTMLToStyledTextAndBack() {
        let html = #"Hi <strong>bold <em>both</em></strong> <a target="_blank" rel="noopener noreferrer nofollow" "#
            + #"href="https://x.com">link</a><br><span style="color: #dc2626">red</span> <mark>mark</mark> x<sup>2</sup>"#
        XCTAssertTrue(AcademyInline.isSupported(html))
        let text = AcademyInline.attributed(html)
        XCTAssertEqual(text.string, "Hi bold both link\nred mark x2")
        let both = AcademyInline.style(at: text.attributes(at: 8, effectiveRange: nil))
        XCTAssertEqual(both.marks, [.bold, .italic])
        let link = AcademyInline.style(at: text.attributes(at: 13, effectiveRange: nil))
        XCTAssertEqual(link.href, "https://x.com")
        let red = AcademyInline.style(at: text.attributes(at: 18, effectiveRange: nil))
        XCTAssertEqual(red.colour, "#dc2626")
        XCTAssertEqual(AcademyInline.html(from: text),
                       #"Hi <strong>bold </strong><strong><em>both</em></strong> "#
                       + #"<a target="_blank" rel="noopener noreferrer nofollow" href="https://x.com">link</a><br>"#
                       + #"<span style="color: #dc2626">red</span> <mark>mark</mark> x<sup>2</sup>"#)
        // Written HTML reads back to the same text and formatting.
        let again = AcademyInline.attributed(AcademyInline.html(from: text))
        XCTAssertEqual(again.string, text.string)
        XCTAssertEqual(AcademyInline.html(from: again), AcademyInline.html(from: text))
    }

    func testOnlyKnownFormattingIsEditedAsText() {
        XCTAssertFalse(AcademyInline.isSupported(#"<span class="x">a</span>"#))
        XCTAssertFalse(AcademyInline.isSupported(#"<img src="a.png">"#))
        XCTAssertFalse(AcademyInline.isSupported(#"<span style="font-size: 20px">a</span>"#))
        XCTAssertTrue(AcademyInline.isSupported(##"<mark data-color="#bbf7d0" style="background-color: #bbf7d0; color: inherit">a</mark>"##))
    }

    @MainActor
    func testFormattingTheSelectedWords() {
        let controller = AcademyInlineController()
        let view = UITextView()
        view.attributedText = AcademyInline.attributed("Hello world")
        controller.focus(view)
        view.selectedRange = NSRange(location: 6, length: 5)
        controller.refresh()
        controller.toggle(.bold)
        XCTAssertEqual(AcademyInline.html(from: view.attributedText), "Hello <strong>world</strong>")
        controller.toggle(.bold)
        XCTAssertEqual(AcademyInline.html(from: view.attributedText), "Hello world")
        controller.setLink("https://example.com")
        controller.setColour("#2563eb")
        XCTAssertEqual(AcademyInline.html(from: view.attributedText),
                       #"Hello <a target="_blank" rel="noopener noreferrer nofollow" href="https://example.com">"#
                       + #"<span style="color: #2563eb">world</span></a>"#)
        controller.clearFormatting()
        XCTAssertEqual(AcademyInline.html(from: view.attributedText), "Hello world")
    }

    func testVideoLinksBecomeEmbeds() {
        XCTAssertEqual(AcademyVideo.embedURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                       "https://www.youtube.com/embed/dQw4w9WgXcQ")
        XCTAssertEqual(AcademyVideo.embedURL("https://youtu.be/dQw4w9WgXcQ?t=3"), "https://www.youtube.com/embed/dQw4w9WgXcQ")
        XCTAssertEqual(AcademyVideo.embedURL("https://vimeo.com/76979871"), "https://player.vimeo.com/video/76979871")
        XCTAssertNil(AcademyVideo.embedURL("https://example.com/video.mp4"))
        XCTAssertEqual(AcademyVideo.watchURL("https://www.youtube.com/embed/dQw4w9WgXcQ")?.absoluteString,
                       "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(AcademyVideo.provider("https://player.vimeo.com/video/1"), "Vimeo")
    }

    // MARK: Instructors and money

    func testInstructorStatusAndProfile() throws {
        let status = try AcademyAPI.decodeData(AcademyInstructorStatus.self, from: Data("""
        {"success":true,"data":{"is_instructor":false,"is_owner":true,"namespace":{"id":9,"uuid":"ns-1","slug":"academy","name":"Academy"}}}
        """.utf8))
        XCTAssertTrue(status.isOwner)
        XCTAssertEqual(status.namespace?.slug, "academy")

        // A profile nobody saved yet: lua-cjson sends empty lists and objects as {}.
        let empty = try decode(AcademyProfile.self, #"{"socials":{},"achievements":{},"education":{},"skills":{},"exists":false}"#)
        XCTAssertTrue(empty.achievements.isEmpty)
        XCTAssertFalse(empty.exists)

        var profile = try decode(AcademyProfile.self, """
        {"headline":"Teacher","bio":"Hi","avatar_url":"https://a/p.jpg","location":"Leeds","website":"https://ann.dev",
         "socials":{"twitter":"https://twitter.com/ann"},"achievements":[{"title":"AWS","issuer":"Amazon","year":"2024"}],
         "education":[{"degree":"BSc","institution":"Leeds","year":"2010"}],"skills":["Swift","Go"],"exists":true}
        """)
        XCTAssertEqual(profile.socials["twitter"], "https://twitter.com/ann")
        XCTAssertEqual(profile.achievements.first?.issuer, "Amazon")
        profile.achievements.append(AcademyAchievement())
        let body = fields(profile.formFields(skillsText: "Swift, Go , ,Rust"))
        XCTAssertEqual(body["skills"], #"["Swift","Go","Rust"]"#)
        XCTAssertEqual(body["achievements"], #"[{"issuer":"Amazon","title":"AWS","year":"2024"}]"#, "empty rows are dropped")
        XCTAssertEqual(body["socials"], #"{"twitter":"https://twitter.com/ann"}"#)
        XCTAssertEqual(body["avatar_url"], "https://a/p.jpg")
    }

    func testTheCreatorsAccount() throws {
        let account = try decode(AcademyCreatorAccount.self, """
        {"bank":{"account_holder_name":"Ann","iban":"GB00X","sort_code":""},"bank_details_complete":true,"fee_pct":20,
         "plan":{"tier":1,"amount":999,"currency":"usd","interval":"month"},
         "plans":[{"tier":2,"amount":1999,"currency":"usd","interval":"year"},{"tier":1,"amount":999,"currency":"usd","interval":"month"}],
         "earnings":{"total_net":5000,"owed":1200,"paid":3800,"currency":"gbp","sales":7}}
        """)
        XCTAssertEqual(account.bank["account_holder_name"], "Ann")
        XCTAssertEqual(account.bank["sort_code"], "", "blank values are treated as not given")
        XCTAssertEqual(account.plans.map(\.tier), [1, 2])
        XCTAssertEqual(account.feePct, 20)
        XCTAssertEqual(account.earnings.owed, 1200)
        XCTAssertTrue(account.plans[1].priceText.hasSuffix("a year"))

        let legacy = try decode(AcademyCreatorAccount.self, """
        {"bank":{},"bank_details_complete":false,"fee_pct":"12.5","plan":{"tier":1,"amount":500,"currency":"usd","interval":"month"},
         "earnings":{"total_net":0,"owed":0,"paid":0,"currency":"usd","sales":0}}
        """)
        XCTAssertEqual(legacy.plans.count, 1, "a server before multi-tier memberships sends only `plan`")
        XCTAssertEqual(legacy.feePct, 12.5)

        XCTAssertEqual(AcademyBank.problem([:]), "Enter the account holder’s name.")
        XCTAssertEqual(AcademyBank.problem(["account_holder_name": "Ann"]), "Enter an account number or an IBAN.")
        XCTAssertNil(AcademyBank.problem(["account_holder_name": "Ann", "iban": "GB00"]))
    }

    func testPayoutsOwed() throws {
        struct Answer: Decodable { let payouts: [AcademyPayout] }
        let answer = try decode(Answer.self, """
        {"payouts":[{"user_uuid":"u-1","instructor_name":"Ann Smith","instructor_email":"ann@x.com","owed":"4200",
          "currency":"gbp","sales":"3","bank":{"account_holder_name":"Ann","account_number":"123","sort_code":"12-34-56",
          "complete":true}},{"user_uuid":"u-2","instructor_name":"Bob","owed":100,"currency":"usd","sales":1}]}
        """)
        XCTAssertEqual(answer.payouts.map(\.owed), [4200, 100])
        XCTAssertTrue(answer.payouts[0].canBePaid)
        XCTAssertEqual(answer.payouts[0].bank?.summary, "Ann · 123 · 12-34-56")
        XCTAssertFalse(answer.payouts[1].canBePaid, "no bank details: can't be marked paid")
        XCTAssertEqual(AcademyAPI.number(20), "20")
        XCTAssertEqual(AcademyAPI.number(12.5), "12.5")
    }

    // MARK: Learning

    func testMyLearningAndAPublicCourse() throws {
        let learning = try decode(AcademyLearning.self, """
        {"courses":[{"id":"c-1","slug":"intro","title":"Intro","instructor":"Ann","instructor_name":"Ann Smith",
          "level":"beginner","is_free":true,"price":0,"currency":"USD","tier":1,"lessons":[],
          "progress":{"completed":2,"total":4,"percent":50,"next_lesson_id":"l-3"}}],
         "count":1,"stats":{"lessons_completed":2,"minutes_completed":15,"courses_started":1,"courses_enrolled":1,"courses_completed":0}}
        """)
        XCTAssertEqual(learning.courses.first?.course.uuid, "c-1", "public shapes call the uuid `id`")
        XCTAssertEqual(learning.courses.first?.progress?.percent, 50)
        XCTAssertEqual(learning.minutesCompleted, 15)

        let course = try decode(AcademyLearnerCourse.self, """
        {"id":"c-1","slug":"intro","title":"Intro","is_free":false,"price":1500,"currency":"GBP","level":"intermediate",
         "lessons":[{"id":"l-2","title":"Two","position":2,"has_video":true,"is_preview":false},
                    {"id":"l-1","title":"One","position":1,"has_video":false,"is_preview":true,"content_html":"<p>Free</p>"}]}
        """)
        XCTAssertEqual(course.lessons.map(\.uuid), ["l-1", "l-2"])
        XCTAssertTrue(course.lessons[1].hasVideo, "the video key stays private; the flag says there is one")
        XCTAssertNil(course.lessons[1].contentHtml, "withheld until the learner has access")
        XCTAssertEqual(course.lessons[0].statusValue, .published)

        let progress = try decode(AcademyCourseProgress.self,
                                  #"{"completed_lesson_ids":{},"completed":0,"total":2,"next_lesson_id":"l-1"}"#)
        XCTAssertTrue(progress.completedLessonIds.isEmpty)
        XCTAssertEqual(progress.nextLessonId, "l-1")
    }

    // MARK: Menu

    @MainActor
    func testTheAcademyMenuKeyOpensItsNativeScreen() {
        XCTAssertEqual(ModuleCatalog.screenKeys["academy"], AcademyScreens.home)
        guard case .native(let route)? = NativeModules.destination(forKey: "academy") else {
            return XCTFail("academy has no native screen")
        }
        XCTAssertEqual(route.id, AcademyScreens.home)
        XCTAssertNotNil(ModuleCatalog.screen(AcademyScreens.home))
        XCTAssertNotNil(ModuleCatalog.screen(AcademyScreens.learning))
        XCTAssertNotNil(ModuleCatalog.screen(EngageArea.route(AcademyScreens.course, "c-1").id))
        XCTAssertNil(ModuleCatalog.screen("academy.nothing"))
        XCTAssertFalse(NativeModules.notYetNative.contains("academy"))
    }
}
