import UIKit
import XCTest

/// Photo upload against the real local OPSAPI (#610 `fs_job_photos`), driven over HTTP rather
/// than through the system photo picker: what needs proving is the contract — the multipart
/// field name, the size limit, the presigned URL that comes back and the delete — not Apple's
/// picker, which the app only hands a `Data` blob.
///
/// Runs only under `scripts/run-local-fs-uitest.sh` (credentials in the environment).
final class LocalPhotoUploadTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var api: URL!
    private var namespace = ""
    private var token = ""

    override func setUp() async throws {
        try XCTSkipIf(env["WSL_PASSWORD"] == nil || env["WSL_OTP"] == nil,
                      "Local OPSAPI credentials not supplied (run scripts/run-local-fs-uitest.sh)")
        api = URL(string: env["WSL_API"] ?? "http://127.0.0.1:4011")!
        namespace = env["WSL_NAMESPACE"] ?? ""
        token = try await signIn(identifier: env["WSL_MANAGER"] ?? "")
    }

    func testPhotoUploadReturnsAPresignedURLAndCanBeDeleted() async throws {
        let jobUuid = try await latestJobUuid()
        let jpeg = try XCTUnwrap(Self.jpeg(width: 1_200, height: 900))
        XCTAssertLessThan(jpeg.count, 10 * 1024 * 1024, "the client caps photos below the server's 10MB limit")

        let uploaded = try await upload(jpeg: jpeg, toJob: jobUuid)
        let uuid = try XCTUnwrap(uploaded["uuid"] as? String)
        let urlText = try XCTUnwrap(uploaded["url"] as? String, "the server returns a URL for the stored photo")
        XCTAssertTrue(urlText.contains("X-Amz-"), "the URL is presigned, so it expires — the app must not cache it")

        let listed = try await photos(jobUuid: jobUuid)
        let stored = try XCTUnwrap(listed.first { $0["uuid"] as? String == uuid }, "the photo is listed on the job")
        XCTAssertEqual(stored["caption"] as? String, "UI test fault photo")
        XCTAssertEqual(stored["filename"] as? String, "fault.jpg")
        let listedURL = try XCTUnwrap(stored["url"] as? String)
        XCTAssertTrue(listedURL.contains("X-Amz-"), "the list re-signs the URL on every read")
        // Known gap (docs/API-NOTES.md): the server drops the part's Content-Type, so the row
        // never carries one. The app treats it as optional; this pins the behaviour.
        XCTAssertNil(stored["content_type"], "content_type is still dropped by the upload route")

        try await delete(photo: uuid)
        let after = try await photos(jobUuid: jobUuid)
        XCTAssertFalse(after.contains { $0["uuid"] as? String == uuid }, "the photo is removed")
    }

    // MARK: Requests

    private func signIn(identifier: String) async throws -> String {
        var login = URLRequest(url: api.appending(path: "auth/login"))
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [("identifier", identifier), ("password", env["WSL_PASSWORD"] ?? "")]
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
        login.httpBody = Data(form.utf8)
        let session = try await json(login)
        let sessionToken = try XCTUnwrap(session["session_token"] as? String)

        var verify = URLRequest(url: api.appending(path: "auth/2fa/verify"))
        verify.httpMethod = "POST"
        verify.setValue("application/json", forHTTPHeaderField: "Content-Type")
        verify.httpBody = try JSONSerialization.data(withJSONObject: ["session_token": sessionToken,
                                                                     "code": env["WSL_OTP"] ?? ""])
        let verified = try await json(verify)
        return try XCTUnwrap(verified["token"] as? String)
    }

    private func latestJobUuid() async throws -> String {
        let response = try await json(authorized(get(path: "api/v2/field-service/jobs", query: "per_page=1&status=all")))
        let rows = try XCTUnwrap(response["data"] as? [[String: Any]])
        return try XCTUnwrap(rows.first?["uuid"] as? String, "the happy-path test leaves a job behind")
    }

    private func photos(jobUuid: String) async throws -> [[String: Any]] {
        let request = authorized(get(path: "api/v2/field-service/jobs/\(jobUuid)/photos"))
        let response = try await json(request)
        return response["data"] as? [[String: Any]] ?? []
    }

    private func upload(jpeg: Data, toJob jobUuid: String) async throws -> [String: Any] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = authorized(URLRequest(url: api.appending(path: "api/v2/field-service/jobs/\(jobUuid)/photos")))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"caption\"\r\n\r\nUI test fault photo\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"photo\"; filename=\"fault.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let response = try await json(request)
        return try XCTUnwrap(response["data"] as? [String: Any], "upload failed: \(response)")
    }

    private func delete(photo uuid: String) async throws {
        var request = authorized(URLRequest(url: api.appending(path: "api/v2/field-service/job-photos/\(uuid)")))
        request.httpMethod = "DELETE"
        _ = try await json(request)
    }

    private func get(path: String, query: String = "") -> URLRequest {
        var components = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.query = query }
        return URLRequest(url: components.url!)
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(namespace, forHTTPHeaderField: "X-Namespace-Id")
        return request
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        XCTAssertTrue((200..<300).contains(status),
                      "\(request.httpMethod ?? "GET") \(request.url?.path ?? "") → \(status): \(body)")
        return body
    }

    /// A JPEG of roughly the size the app produces after downscaling a camera photo.
    private static func jpeg(width: Int, height: Int) -> Data? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("WSLCRM fault photo" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.white,
            ])
        }
        return image.jpegData(compressionQuality: 0.7)
    }
}
