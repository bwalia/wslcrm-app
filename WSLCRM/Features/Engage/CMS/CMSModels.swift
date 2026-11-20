import SwiftUI

// Website content (the headless CMS, `lapis/routes/cms-*.lua`, RBAC module `cms`): blog posts,
// pages, the media library, categories, tags and "website updates" (webhooks).
// Everything is read from the server's JSON (`Record`), so fields this build doesn't know survive.

enum CMS {
    static let base = "/api/v2/cms"
    /// The RBAC module every CMS route checks (`requirePermission("cms", …)`).
    static let module = "cms"

    enum Screen {
        static let home = "cms.home"
        static let posts = "cms.posts"
        static let pages = "cms.pages"
        static let media = "cms.media"
        static let webhooks = "cms.webhooks"
    }
}

// MARK: - Status

enum CMSPostStatus: String, CaseIterable, Identifiable, Sendable {
    case draft, published, scheduled, archived
    var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: "Draft"
        case .published: "Published"
        case .scheduled: "Scheduled"
        case .archived: "Archived"
        }
    }

    /// Statuses a page can have (pages are never scheduled: `PAGE_STATUS` in cms-pages.lua).
    static let pageCases: [CMSPostStatus] = [.draft, .published, .archived]

    static let style = StatusStyle(tones: ["published": .success, "scheduled": .info, "draft": .warning,
                                           "archived": .neutral],
                                   symbols: ["published": "checkmark.circle", "scheduled": "calendar",
                                             "draft": "pencil", "archived": "archivebox"])
}

enum CMSVisibility: String, CaseIterable, Identifiable, Sendable {
    case `public`, `private`
    var id: String { rawValue }
    var label: String { self == .public ? "Public: anyone can read it" : "Private: hidden from the website" }
}

// MARK: - Slugs

enum CMSSlug {
    /// The web editor's `slugify`: lower case, words joined by hyphens, nothing else.
    static func make(_ text: String) -> String {
        clean(text, keepTrailingHyphen: false)
    }

    /// While typing in the slug field: a trailing hyphen stays so "my-post" can be typed.
    static func typing(_ text: String) -> String {
        clean(text, keepTrailingHyphen: true)
    }

    private static func clean(_ text: String, keepTrailingHyphen: Bool) -> String {
        var out = text.lowercased()
        // ASCII only, like the web's JavaScript `\w`: "café" → "caf".
        out = out.replacingOccurrences(of: #"[^A-Za-z0-9_\s-]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        out = out.replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
        while out.hasPrefix("-") { out.removeFirst() }
        if !keepTrailingHyphen { while out.hasSuffix("-") { out.removeLast() } }
        return out
    }
}

// MARK: - Post and page drafts (what the editor changes)

/// A post or page being edited. `body` builds exactly what `cms-posts.lua` / `cms-pages.lua` read.
struct CMSDraft: Equatable {
    enum Kind: Equatable { case post, page }

    let kind: Kind
    var title = ""
    var slug = ""
    /// The slug follows the title until the person edits it (a saved one never moves).
    var slugTouched = false
    var excerpt = ""
    var contentHTML = ""
    var status: CMSPostStatus = .draft
    // Posts
    var visibility: CMSVisibility = .public
    var isFeatured = false
    var categoryUUIDs: [String] = []
    var tags: [String] = []
    var authorName = ""
    var scheduledAt: Date?
    // Pages
    var template = "default"
    var menuOrder = 0
    var showInNav = false
    // Both
    var featuredImageURL = ""
    var seoTitle = ""
    var seoDescription = ""
    var seoKeywords = ""

    init(kind: Kind) {
        self.kind = kind
    }

    init(kind: Kind, record: Record) {
        self.kind = kind
        title = record.string("title") ?? ""
        slug = record.string("slug") ?? ""
        slugTouched = true
        excerpt = record.string("excerpt") ?? ""
        contentHTML = record["content_html"]?.stringValue ?? ""
        status = CMSPostStatus(rawValue: record.string("status") ?? "") ?? .draft
        visibility = CMSVisibility(rawValue: record.string("visibility") ?? "") ?? .public
        isFeatured = record.bool("is_featured") ?? false
        let categories = record.records("categories").compactMap { $0.string("uuid") }
        categoryUUIDs = categories.isEmpty ? [record.string("category.uuid")].compactMap { $0 } : categories
        tags = record.records("tags").compactMap { $0.string("name") }
        authorName = record.string("author_name") ?? ""
        scheduledAt = record.date("scheduled_at")
        template = record.string("template") ?? "default"
        menuOrder = record.int("menu_order") ?? 0
        showInNav = record.bool("show_in_nav") ?? false
        featuredImageURL = record.string("featured_image_url") ?? ""
        seoTitle = record.string("seo_title") ?? ""
        seoDescription = record.string("seo_description") ?? ""
        seoKeywords = record.string("seo_keywords") ?? ""
    }

    mutating func setTitle(_ value: String) {
        title = value
        if !slugTouched { slug = CMSSlug.make(value) }
    }

    mutating func setSlug(_ value: String) {
        slugTouched = true
        slug = CMSSlug.typing(value)
    }

    /// Adds a tag unless it's already there (any case), as the web's tag box does.
    mutating func addTag(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !tags.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        tags.append(name)
    }

    /// What must be fixed before saving, in plain words (nil = fine).
    func problem(saving status: CMSPostStatus) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give it a title first." }
        if kind == .post, status == .scheduled, scheduledAt == nil { return "Choose when it should be published." }
        return nil
    }

    /// The request body. `isNew`: blanks are left out (the server fills them in); when editing, a blank
    /// clears the field. `contentChanged`: the stored editor JSON no longer matches, so it is cleared
    /// (the web's HTML-source mode does the same).
    func body(status override: CMSPostStatus? = nil, isNew: Bool, contentChanged: Bool) -> JSONValue {
        var body: [String: JSONValue] = [:]
        func text(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body[key] = .string(trimmed) } else if !isNew { body[key] = .string("") }
        }
        body["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines))
        let cleanSlug = CMSSlug.make(slug)
        if !cleanSlug.isEmpty { body["slug"] = .string(cleanSlug) }
        text("excerpt", excerpt)
        if isNew || contentChanged {
            body["content_html"] = .string(contentHTML)
            if contentChanged || isNew { body["content_json"] = .string("") }
        }
        text("featured_image_url", featuredImageURL)
        let effective = override ?? status
        body["status"] = .string(effective.rawValue)
        text("seo_title", seoTitle)
        text("seo_description", seoDescription)
        text("seo_keywords", seoKeywords)
        switch kind {
        case .post:
            body["visibility"] = .string(visibility.rawValue)
            body["is_featured"] = .bool(isFeatured)
            body["category_uuids"] = .array(categoryUUIDs.map { .string($0) })
            body["tags"] = .array(tags.map { .string($0) })
            let author = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty { body["author_name"] = .string(author) }
            if effective == .scheduled, let scheduledAt { body["scheduled_at"] = .string(APIDate.string(from: scheduledAt)) }
        case .page:
            let layout = template.trimmingCharacters(in: .whitespacesAndNewlines)
            body["template"] = .string(layout.isEmpty ? "default" : layout)
            body["menu_order"] = .number(Double(menuOrder))
            body["show_in_nav"] = .bool(showInNav)
        }
        return .object(body)
    }
}

// MARK: - Media

enum CMSMedia {
    /// The library's size limit (`M.MAX_BYTES`, lib/media-library.lua).
    static let maxBytes = 8 * 1024 * 1024
    /// Photos are made no bigger than this on their longest side before upload (as the web does).
    static let maxEdge: CGFloat = 2560

    static let types: [Choice] = [
        Choice("jpeg", "JPEG photos"), Choice("png", "PNG"), Choice("webp", "WebP"), Choice("gif", "GIF"),
        Choice("svg", "SVG"),
    ]

    static let sorts: [Choice] = [
        Choice("newest", "Newest first"), Choice("oldest", "Oldest first"), Choice("name", "Name"),
        Choice("largest", "Largest files"),
    ]

    static let notSetUp = "Uploading is switched off: this server has no image storage set up yet. Ask your "
        + "administrator to set up file storage. You can still use images already in the library."

    /// An address the app can load: full addresses as they are; site paths (`/img/x.jpg`) on the public website.
    static func displayURL(_ raw: String?, siteURL: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") { return URL(string: raw) }
        if raw.hasPrefix("/"), !raw.hasPrefix("//"), let site = siteURL?.trimmedOrNil {
            var trimmed = site
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            return URL(string: trimmed + raw)
        }
        return nil
    }

    static func bytes(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return "\(Int((Double(count) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }

    /// "JPEG · 240 KB · 1200 × 630 px".
    static func facts(_ asset: Record) -> String {
        var parts: [String] = []
        if let mime = asset.string("mime_type") {
            parts.append(mime.replacingOccurrences(of: "image/", with: "").replacingOccurrences(of: "+xml", with: "")
                .uppercased())
        }
        if let size = bytes(asset.int("size_bytes")) { parts.append(size) }
        if let w = asset.int("width"), let h = asset.int("height"), w > 0, h > 0 { parts.append("\(w) × \(h) px") }
        return parts.joined(separator: " · ")
    }

    static func name(_ asset: Record) -> String {
        asset.string("title") ?? asset.string("filename") ?? "Image"
    }

    /// The question asked before deleting, naming where the image is used (as the web does).
    static func deleteMessage(_ asset: Record) -> (title: String, message: String, button: String) {
        let used = asset.records("used_in")
        let isLink = asset.string("storage") == "link"
        var whereUsed = ""
        if !used.isEmpty {
            let names = used.prefix(3).map { "“\($0.string("title") ?? "Untitled")”" }.joined(separator: ", ")
            whereUsed = "It is used in \(used.count) \(used.count == 1 ? "post or page" : "posts and pages") "
                + "(\(names)\(used.count > 3 ? ", …" : "")). "
        }
        if isLink {
            return ("Remove this image from the library?",
                    whereUsed + "The file stays where it is, so nothing that shows it changes. Only the library entry is removed.",
                    "Remove from library")
        }
        return ("Delete this image?",
                whereUsed + (used.isEmpty ? "" : "They will show a broken image. ")
                    + "The file is removed for good. This can’t be undone.",
                "Delete image")
    }
}

// MARK: - Website updates (webhooks)

enum CMSWebhookText {
    static let secretEnv = "OPSAPI_WEBHOOK_SECRET"

    /// What a delivery result means, for someone who isn't a developer (the web's `explainDelivery`).
    static func explain(status: Int?, error: String? = nil) -> (ok: Bool, text: String) {
        if let status, (200..<300).contains(status) { return (true, "Your website received the update.") }
        if status == 401 || status == 403 {
            return (false, "Your website refused it (HTTP \(status ?? 0)). The secret key saved on your website doesn’t "
                + "match this one: copy it again from the setup guide.")
        }
        if status == 404 { return (false, "Nothing was found at that address (HTTP 404). Check the website address with your developer.") }
        if status == 405 { return (false, "That address doesn’t accept updates (HTTP 405). Check the address with your developer.") }
        if let status, status >= 500 {
            return (false, "Your website had an error while updating (HTTP \(status)). Try again; if it keeps happening, tell your developer.")
        }
        if let status, status >= 400 { return (false, "Your website refused it (HTTP \(status)). Ask your developer to check its logs.") }
        if let error, error.range(of: "public|private|internal|not allowed", options: [.regularExpression, .caseInsensitive]) != nil {
            return (false, "That address can’t be used: it must be a public website address (https://…).")
        }
        return (false, "Couldn’t reach your website. Check the address and that the site is online.")
    }

    /// The card's one-line status.
    static func lastDelivery(_ hook: Record) -> (ok: Bool?, text: String) {
        guard let when = hook.string("last_triggered_at") else {
            return (nil, "Not sent yet: send a test from the setup guide")
        }
        let result = explain(status: hook.int("last_status"))
        let date = Formatters.dateTime(APIDate.parse(when)) ?? when
        return result.ok ? (true, "Last update worked · \(date)") : (false, "Last update failed · \(date). \(result.text)")
    }

    /// A save error in plain words (`url must be public…` → "That address can't be used…").
    static func saveError(_ message: String) -> String {
        message.hasPrefix("url ") ? "That address can’t be used: it must be a public website address (https://…)." : message
    }

    static func looksLikeAddress(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^https?://\S+$"#, options: .regularExpression) != nil
    }

    static let steps: [(icon: String, title: String, text: String)] = [
        ("link", "Get your website’s update address",
         "Your developer gives you one, or your host does: Vercel, Netlify and Cloudflare Pages call it a “Deploy Hook”."),
        ("globe", "Add it here", "Press “Add website”. OpsAPI creates a secret key for it."),
        ("key", "Put the secret key on your website",
         "Your developer saves it where the website runs, as \(secretEnv). It proves the update really came from you. "
            + "A host’s Deploy Hook doesn’t need it."),
        ("paperplane", "Publish, then update",
         "After you publish a post, you’re asked whether to update your website now. Nothing is sent by itself, so "
            + "you can finish several edits first."),
    ]

    static let sampleBody = """
    {
      "event": "post.published",
      "namespace_id": 12,
      "data": { "uuid": "…", "slug": "my-first-post", "status": "published" },
      "timestamp": "2026-10-16T09:30:00Z"
    }
    """

    /// Everything a developer needs except the key, which should travel separately.
    static func developerMessage(url: String) -> String {
        """
        Hi, please connect our website to OpsAPI so it refreshes when we publish content.

        1. When we press "Update website", OpsAPI sends a POST request to:
           \(url)
        2. The body is JSON, for example:
        \(sampleBody)
        3. Each request has the header X-Opsapi-Signature-256: "sha256=" followed by the HMAC-SHA256 (hex) of the raw request body, made with a secret key. I'll send you the key separately. Please save it as the environment variable \(secretEnv) where the website runs.
        4. Please reject a request whose signature doesn't match (answer 401), and one whose "timestamp" is more than 5 minutes old.
        5. Then refresh the content (rebuild, or revalidate the blog pages; "data.slug" is the post that changed) and answer with any 2xx status.

        Code samples for Next.js, Express and Flask are in OpsAPI under Content → Website updates → Setup guide.
        """
    }

    static let codeSamples: [(label: String, code: String)] = [
        ("Next.js", """
        // app/api/opsapi-update/route.ts
        import crypto from 'crypto';
        import { revalidatePath } from 'next/cache';

        export async function POST(req: Request) {
          const body = await req.text(); // the raw body, before JSON.parse
          const expected = 'sha256=' + crypto
            .createHmac('sha256', process.env.\(secretEnv)!)
            .update(body)
            .digest('hex');
          const given = req.headers.get('x-opsapi-signature-256') ?? '';
          if (given.length !== expected.length ||
              !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) {
            return new Response('Invalid signature', { status: 401 });
          }
          const { data, timestamp } = JSON.parse(body);
          if (Math.abs(Date.now() - Date.parse(timestamp)) > 5 * 60 * 1000) {
            return new Response('Too old', { status: 401 }); // a replayed request
          }
          revalidatePath('/blog');
          if (data?.slug) revalidatePath('/blog/' + data.slug);
          return Response.json({ ok: true });
        }
        """),
        ("Node.js (Express)", """
        const crypto = require('crypto');

        app.post('/opsapi-update', express.raw({ type: 'application/json' }), (req, res) => {
          const expected = 'sha256=' + crypto
            .createHmac('sha256', process.env.\(secretEnv))
            .update(req.body) // the raw body
            .digest('hex');
          const given = req.get('X-Opsapi-Signature-256') || '';
          if (given.length !== expected.length ||
              !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) {
            return res.status(401).send('Invalid signature');
          }
          const { data, timestamp } = JSON.parse(req.body);
          if (Math.abs(Date.now() - Date.parse(timestamp)) > 5 * 60 * 1000) return res.status(401).send('Too old');
          // rebuild or refresh the pages for data.slug here
          res.json({ ok: true });
        });
        """),
        ("Python (Flask)", """
        import hmac, hashlib, os, json
        from datetime import datetime, timezone

        @app.post("/opsapi-update")
        def opsapi_update():
            body = request.get_data()  # the raw body
            expected = "sha256=" + hmac.new(os.environ["\(secretEnv)"].encode(), body, hashlib.sha256).hexdigest()
            if not hmac.compare_digest(expected, request.headers.get("X-Opsapi-Signature-256", "")):
                return "Invalid signature", 401
            payload = json.loads(body)
            sent = datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00"))
            if abs((datetime.now(timezone.utc) - sent).total_seconds()) > 300:
                return "Too old", 401
            # rebuild or refresh the pages for payload["data"]["slug"] here
            return {"ok": True}
        """),
    ]
}

// MARK: - Video embeds

enum CMSVideo {
    /// A pasted YouTube or Vimeo address as its embeddable form (the web editor's `toEmbedUrl`), or nil.
    static func embedURL(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let id = firstMatch(#"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([\w-]{6,})"#, in: url) {
            return "https://www.youtube.com/embed/\(id)"
        }
        if let id = firstMatch(#"vimeo\.com/(?:video/)?(\d+)"#, in: url) {
            return "https://player.vimeo.com/video/\(id)"
        }
        return isTrustedHost(url) ? url : nil
    }

    static func isTrustedHost(_ url: String) -> Bool {
        url.range(of: #"^(https:)?//(www\.)?(youtube\.com|youtube-nocookie\.com|player\.vimeo\.com)/"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Errors

extension APIError {
    /// The server's own words for an error (the CMS answers `{success:false, error:"…"}`).
    var cmsMessage: String {
        serverError?.message.trimmedOrNil ?? localizedDescription
    }
}
