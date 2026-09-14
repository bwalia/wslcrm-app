import XCTest
@testable import WSLCRM

/// Error bodies: the catalogued, plain and `{error,reason}` shapes were captured from
/// int-opsapi.workstation.co.uk; the others mirror the Lua handlers that emit them.
final class ServerErrorTests: XCTestCase {
    func testCataloguedErrorEnvelope() throws {
        let body = try Fixture.data("error_catalogued_validation")
        let error = ServerError.parse(status: 400, data: body)
        XCTAssertEqual(error.code, "VALIDATION_400")
        XCTAssertEqual(error.title, "Check your details")
        XCTAssertEqual(error.message, "Some of the details you entered don't look right. Please review and try again.")
        XCTAssertEqual(error.correlationId, "bab41934-a706-fb8e-4bb5-a01af8b26c82")
        XCTAssertEqual(error.occurrenceUuid, "7652b611-a92b-3fc2-5a0e-b0e54427e349")
        XCTAssertEqual(error.fieldErrors["identifier"], "required")
    }

    func testPlainStringError() {
        let error = ServerError.parse(status: 401, data: Data(#"{"error":"Invalid or expired 2FA session. Please login again."}"#.utf8))
        XCTAssertEqual(error.message, "Invalid or expired 2FA session. Please login again.")
        XCTAssertNil(error.code)
        XCTAssertNil(error.correlationId)
    }

    func testStringErrorWithReason() {
        let error = ServerError.parse(status: 401, data: Data(#"{"error":"Invalid or expired token","reason":"invalid jwt string"}"#.utf8))
        XCTAssertEqual(error.message, "Invalid or expired token")
        XCTAssertEqual(error.reason, "invalid jwt string")
    }

    func testSuccessFalseEnvelope() {
        let error = ServerError.parse(status: 422, data: Data(#"{"success":false,"error":"Job has 2 unfinished phase(s) and 1 open visit(s) — finish them or pass force=true"}"#.utf8))
        XCTAssertEqual(error.message, "Job has 2 unfinished phase(s) and 1 open visit(s) — finish them or pass force=true")
        XCTAssertTrue(error.suggestsForce)
    }

    func testForbiddenWithRequiredPermission() {
        let body = #"{"error":"Permission denied","required":{"module":"fs_jobs","action":"update"}}"#
        let apiError = APIError.from(status: 403, data: Data(body.utf8), headers: [:])
        guard case .forbidden(let server) = apiError else { return XCTFail("Expected forbidden, got \(apiError)") }
        XCTAssertEqual(server.requiredPermission, .init(module: "fs_jobs", action: "update"))
        XCTAssertEqual(apiError.localizedDescription, "You don't have permission to update service jobs.")
    }

    func testCorrelationIdHeaderIsUsedWhenBodyHasNone() {
        let error = ServerError.parse(status: 500, data: Data(#"{"error":"boom"}"#.utf8),
                                      headers: ["X-Correlation-Id": "abc-123"])
        XCTAssertEqual(error.correlationId, "abc-123")
    }

    @MainActor
    func testForcePromptMessageIsHumanised() {
        XCTAssertEqual(JobDetailViewModel.ForcePrompt.humanize("Job has 2 unfinished phase(s) and 1 open visit(s) — finish them or pass force=true"),
                       "Job has 2 unfinished phase(s) and 1 open visit(s).")
        XCTAssertEqual(JobDetailViewModel.ForcePrompt.humanize("Something else — entirely"), "Something else — entirely")
    }

    func testSignoffRequiredIsNotAForcePrompt() {
        let error = ServerError.parse(status: 422, data: Data(#"{"success":false,"error":"This phase requires customer sign-off — provide signoff_name"}"#.utf8))
        XCTAssertFalse(error.suggestsForce, "force never bypasses sign-off")
    }

    func testRateLimitBodyRetryAfter() {
        let apiError = APIError.from(status: 429, data: Data(#"{"error":"Too many requests. Please try again later.","retry_after":42}"#.utf8), headers: [:])
        guard case .rateLimited(_, let retry) = apiError else { return XCTFail("Expected rateLimited") }
        XCTAssertEqual(retry, 42)
    }

    func testSystem500ObjectEnvelopeUsesRequestIdHeader() {
        let body = #"{"error":{"code":"SYSTEM_500","message":"Something went wrong on our side.","category":"error"}}"#
        let error = ServerError.parse(status: 500, data: Data(body.utf8), headers: ["X-Request-ID": "req-99"])
        XCTAssertEqual(error.code, "SYSTEM_500")
        XCTAssertEqual(error.correlationId, "req-99")
    }

    func testNonJSONBodyFallsBackToStatusText() {
        let error = ServerError.parse(status: 502, data: Data("<html>Bad gateway</html>".utf8))
        XCTAssertEqual(error.status, 502)
        XCTAssertFalse(error.message.contains("<html>"))
    }

    func testStatusMapping() {
        XCTAssertTrue({ if case .validation = APIError.from(status: 422, data: Data(), headers: [:]) { return true }; return false }())
        XCTAssertTrue({ if case .notFound = APIError.from(status: 404, data: Data(), headers: [:]) { return true }; return false }())
        XCTAssertTrue({ if case .server = APIError.from(status: 503, data: Data(), headers: [:]) { return true }; return false }())
        XCTAssertTrue({ if case .rateLimited(_, let retry) = APIError.from(status: 429, data: Data(), headers: ["Retry-After": "30"]) { return retry == 30 }; return false }())
    }

    func testUnauthorizedMessages() {
        let credentials = APIError.from(status: 401, data: try! Fixture.data("error_catalogued_validation"), headers: [:])
        XCTAssertEqual(credentials.localizedDescription, "Some of the details you entered don't look right. Please review and try again.")
        let otp = APIError.from(status: 401, data: Data(#"{"error":"Invalid code. 3 attempt(s) remaining."}"#.utf8), headers: [:])
        XCTAssertEqual(otp.localizedDescription, "Invalid code. 3 attempt(s) remaining.")
        let token = APIError.from(status: 401, data: Data(#"{"error":"Invalid or expired token","reason":"jwt expired"}"#.utf8), headers: [:])
        XCTAssertEqual(token.localizedDescription, "Your session has expired. Please sign in again.")
    }

    func testURLErrorMapping() {
        XCTAssertTrue(APIError.from(urlError: URLError(.notConnectedToInternet)).isConnectivityProblem)
        XCTAssertTrue(APIError.from(urlError: URLError(.timedOut)).isConnectivityProblem)
        XCTAssertFalse(APIError.from(urlError: URLError(.serverCertificateUntrusted)).isConnectivityProblem)
    }
}
