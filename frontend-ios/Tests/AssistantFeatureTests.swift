import XCTest

@testable import CalCo

private actor FakeAssistantService: AssistantServicing {
    private var statusResult: Result<AssistantStatus, Error> =
        .success(AssistantStatus(enabled: true, supportsImages: false))
    private var turnResults: [Result<AssistantDraftTurn, Error>] = []
    private var statusCalls = 0
    private var requests: [(AssistantDraftPurpose, AssistantConversation)] = []
    private var firstDelayNanoseconds: UInt64 = 0

    func setStatus(_ result: Result<AssistantStatus, Error>) {
        statusResult = result
    }

    func enqueueTurn(_ result: Result<AssistantDraftTurn, Error>) {
        turnResults.append(result)
    }

    func enqueueTurn(_ turn: AssistantDraftTurn) {
        turnResults.append(.success(turn))
    }

    func enqueueTurn(_ error: AssistantServiceError) {
        turnResults.append(.failure(error))
    }

    func setFirstDelay(_ value: UInt64) {
        firstDelayNanoseconds = value
    }

    func recordedStatusCalls() -> Int { statusCalls }
    func recordedRequests() -> [(AssistantDraftPurpose, AssistantConversation)] { requests }

    func assistantStatus() async throws -> AssistantStatus {
        statusCalls += 1
        return try statusResult.get()
    }

    func requestDraft(
        purpose: AssistantDraftPurpose,
        conversation: AssistantConversation
    ) async throws -> AssistantDraftTurn {
        requests.append((purpose, conversation))
        if requests.count == 1, firstDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: firstDelayNanoseconds)
        }
        guard !turnResults.isEmpty else { throw AssistantServiceError.invalidResponse }
        return try turnResults.removeFirst().get()
    }
}

private final class AssistantURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?

        init(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data(),
            error: Error? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }
    }

    private static let lock = NSLock()
    private static var storedHandler: (URLRequest) -> Stub = { _ in Stub(statusCode: 500) }
    private static var storedRequests: [URLRequest] = []

    static func setUp(handler: @escaping (URLRequest) -> Stub) {
        lock.lock()
        storedHandler = handler
        storedRequests = []
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        AssistantURLProtocol.lock.lock()
        let handler = AssistantURLProtocol.storedHandler
        AssistantURLProtocol.storedRequests.append(request)
        AssistantURLProtocol.lock.unlock()

        let stub = handler(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://localhost")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class AssistantFeatureTests: XCTestCase {
    private let coreNutrients: [AssistantDraftNutrient] = [
        AssistantDraftNutrient(code: NutrientCodes.energyKcal, amountPer100g: "120"),
        AssistantDraftNutrient(code: NutrientCodes.proteinG, amountPer100g: "6"),
        AssistantDraftNutrient(code: NutrientCodes.carbsG, amountPer100g: "18"),
        AssistantDraftNutrient(code: NutrientCodes.fatG, amountPer100g: "3"),
    ]

    private let unitsByCode = [
        NutrientCodes.energyKcal: "kcal",
        NutrientCodes.proteinG: "g",
        NutrientCodes.carbsG: "g",
        NutrientCodes.fatG: "g",
    ]

    private func payload(
        name: String = "Dal",
        brand: String? = "Homemade",
        categories: [String] = ["lentils"],
        defaultQuantity: String? = "1",
        defaultUnit: String? = "bowl",
        nutrients: [AssistantDraftNutrient]? = nil,
        servings: [AssistantDraftServing] = [
            AssistantDraftServing(unit: "bowl", gramsPerUnit: "250")
        ]
    ) -> AssistantFoodDraftPayload {
        AssistantFoodDraftPayload(
            name: name,
            brand: brand,
            categories: categories,
            defaultQuantity: defaultQuantity,
            defaultUnit: defaultUnit,
            nutrients: nutrients ?? coreNutrients,
            servings: servings
        )
    }

    private func readyTurn(
        payload: AssistantFoodDraftPayload? = nil,
        suggestedLog: AssistantSuggestedLog? = nil,
        warnings: [String] = ["Estimated from a typical recipe."]
    ) -> AssistantDraftTurn {
        .draftReady(
            assistantMessage: "Here is an estimate. Review it before saving.",
            draft: payload ?? self.payload(),
            suggestedLog: suggestedLog,
            warnings: warnings
        )
    }

    private func makeViewModel(
        service: FakeAssistantService,
        purpose: AssistantDraftPurpose = .customFood,
        barcode: String? = nil,
        onAccept: @escaping (AssistantReviewedDraft) -> Void = { _ in },
        onExpired: @escaping () -> Void = {}
    ) -> AssistantViewModel {
        AssistantViewModel(
            purpose: purpose,
            initialBarcode: barcode,
            service: service,
            onAcceptDraft: onAccept,
            onSessionExpired: onExpired
        )
    }

    private func enable(_ viewModel: AssistantViewModel, service: FakeAssistantService) async {
        await service.setStatus(.success(AssistantStatus(enabled: true, supportsImages: false)))
        await viewModel.loadStatus()
    }

    // MARK: - Status gate

    func testDisabledStatusBlocksComposerAndDraftRequests() async {
        let service = FakeAssistantService()
        await service.setStatus(.success(AssistantStatus(enabled: false, supportsImages: true)))
        let viewModel = makeViewModel(service: service)

        await viewModel.loadStatus()

        XCTAssertEqual(viewModel.statusState, .disabled)
        XCTAssertFalse(viewModel.isEnabled)
        viewModel.composerChanged("Dal")
        viewModel.send()
        let requests = await service.recordedRequests()
        XCTAssertEqual(requests.count, 0, "Disabled assistant must not receive drafts")
    }

    func testStatusFailureCanBeRetriedWithoutLosingTheGate() async {
        let service = FakeAssistantService()
        await service.setStatus(.failure(AssistantServiceError.networkUnavailable))
        let viewModel = makeViewModel(service: service)

        await viewModel.loadStatus()
        XCTAssertEqual(
            viewModel.statusState,
            .failed(.networkUnavailable)
        )

        await service.setStatus(.success(AssistantStatus(enabled: true, supportsImages: true)))
        await viewModel.loadStatus()
        guard case .enabled(let status) = viewModel.statusState else {
            return XCTFail("Expected enabled status")
        }
        XCTAssertTrue(status.supportsImages)
    }

    func testUnauthorizedStatusNotifiesSession() async {
        let service = FakeAssistantService()
        await service.setStatus(.failure(AssistantServiceError.sessionExpired))
        var expired = 0
        let viewModel = makeViewModel(service: service, onExpired: { expired += 1 })

        await viewModel.loadStatus()

        XCTAssertEqual(expired, 1)
        XCTAssertEqual(viewModel.statusState, .failed(.sessionExpired))
    }

    // MARK: - Conversation and review

    func testCustomFoodDraftIsReviewedAndOnlyAcceptedExplicitly() async throws {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(service: service)
        await enable(viewModel, service: service)
        await service.enqueueTurn(readyTurn())
        var accepted: [AssistantReviewedDraft] = []
        let accepting = makeViewModel(service: service, onAccept: { accepted.append($0) })
        await enable(accepting, service: service)
        await service.enqueueTurn(readyTurn())

        await viewModel.performSend("A bowl of dal")
        XCTAssertEqual(viewModel.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(viewModel.draft?.name, "Dal")
        XCTAssertEqual(viewModel.draft?.warnings, ["Estimated from a typical recipe."])
        XCTAssertEqual(viewModel.draft?.purpose, .customFood)
        XCTAssertTrue(viewModel.draft?.hasCoreNutrients == true)

        await accepting.performSend("A bowl of dal")
        XCTAssertEqual(accepted.count, 0, "Drafting must not accept or write automatically")
        accepting.acceptDraft()
        XCTAssertEqual(accepted.count, 1)
        accepting.acceptDraft()
        XCTAssertEqual(accepted.count, 1, "The review callback is delivered once")

        let requests = await service.recordedRequests()
        let lastRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(lastRequest.0, .customFood)
        XCTAssertEqual(lastRequest.1.turns.map(\.role), [.user])
        XCTAssertEqual(lastRequest.1.turns.first?.text, "A bowl of dal")
        XCTAssertTrue(accepting.isDraftAccepted)
    }

    func testClarificationKeepsTheConversationForAFollowUp() async throws {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(service: service)
        await enable(viewModel, service: service)
        await service.enqueueTurn(.needsClarification(assistantMessage: "How much dal?"))
        await service.enqueueTurn(readyTurn())

        await viewModel.performSend("Dal")
        XCTAssertNil(viewModel.draft)
        XCTAssertEqual(viewModel.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(viewModel.messages.last?.text, "How much dal?")

        await viewModel.performSend("One bowl")
        let requests = await service.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[1].1.turns.map(\.role),
            [.user, .assistant, .user]
        )
        XCTAssertEqual(requests[1].1.turns.map(\.text), ["Dal", "How much dal?", "One bowl"])
        XCTAssertEqual(viewModel.messages.count, 4)
    }

    func testAdHocDraftCarriesSuggestedLogAndScaledAbsoluteNutrients() async throws {
        let service = FakeAssistantService()
        let suggested = AssistantSuggestedLog(
            amount: "1",
            unit: "bowl",
            totalWeightGrams: "250"
        )
        let viewModel = makeViewModel(service: service, purpose: .adHocLog)
        await enable(viewModel, service: service)
        await service.enqueueTurn(readyTurn(suggestedLog: suggested))

        await viewModel.performSend("One bowl of dal")

        let draft = try XCTUnwrap(viewModel.draft)
        XCTAssertEqual(draft.purpose, .adHocLog)
        XCTAssertEqual(draft.suggestedLogQuantity, NutritionQuantity(amount: "1", unit: "bowl"))
        let scaled = try XCTUnwrap(draft.scaledNutrientsForSuggestedLog(unitsByCode: unitsByCode))
        XCTAssertEqual(
            scaled.first(where: { $0.code == NutrientCodes.energyKcal })?.amount,
            "300"
        )
        XCTAssertEqual(
            scaled.first(where: { $0.code == NutrientCodes.proteinG })?.amount,
            "15"
        )
    }

    func testBarcodeIsAttachedOnlyToCustomFoodDrafts() async throws {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(
            service: service,
            purpose: .customFood,
            barcode: "0001234"
        )
        await enable(viewModel, service: service)
        await service.enqueueTurn(readyTurn())
        await viewModel.performSend("Oats")
        XCTAssertEqual(viewModel.draft?.barcode, "0001234")

        let adHoc = makeViewModel(
            service: service,
            purpose: .adHocLog,
            barcode: "0001234"
        )
        await enable(adHoc, service: service)
        await service.enqueueTurn(
            readyTurn(
                suggestedLog: AssistantSuggestedLog(
                    amount: "1",
                    unit: "bowl",
                    totalWeightGrams: "250"
                )
            )
        )
        await adHoc.performSend("Oats")
        XCTAssertNil(adHoc.draft?.barcode)
    }

    // MARK: - Validation

    func testReviewedDraftRejectsMissingCoreNutrientsAndDuplicates() {
        let missing = Array(coreNutrients.dropLast())
        XCTAssertThrowsError(
            try AssistantReviewedDraft(
                purpose: .customFood,
                assistantMessage: "Estimate",
                draft: payload(nutrients: missing),
                suggestedLog: nil,
                warnings: []
            )
        ) {
            XCTAssertEqual($0 as? AssistantDraftValidationError, .missingCoreNutrients)
        }

        let duplicate = coreNutrients + [
            AssistantDraftNutrient(code: NutrientCodes.proteinG, amountPer100g: "1")
        ]
        XCTAssertThrowsError(
            try AssistantReviewedDraft(
                purpose: .customFood,
                assistantMessage: "Estimate",
                draft: payload(nutrients: duplicate),
                suggestedLog: nil,
                warnings: []
            )
        ) {
            XCTAssertEqual($0 as? AssistantDraftValidationError, .duplicateNutrient)
        }
    }

    func testReviewedDraftValidatesPortionsAndSuggestedWeight() {
        XCTAssertThrowsError(
            try AssistantReviewedDraft(
                purpose: .customFood,
                assistantMessage: "Estimate",
                draft: payload(
                    defaultQuantity: "1",
                    defaultUnit: "cup",
                    servings: [AssistantDraftServing(unit: "bowl", gramsPerUnit: "250")]
                ),
                suggestedLog: nil,
                warnings: []
            )
        ) {
            XCTAssertEqual($0 as? AssistantDraftValidationError, .invalidDefaultPortion)
        }

        XCTAssertThrowsError(
            try AssistantReviewedDraft(
                purpose: .adHocLog,
                assistantMessage: "Estimate",
                draft: payload(),
                suggestedLog: nil,
                warnings: []
            )
        ) {
            XCTAssertEqual($0 as? AssistantDraftValidationError, .missingSuggestedLog)
        }

        XCTAssertThrowsError(
            try AssistantReviewedDraft(
                purpose: .adHocLog,
                assistantMessage: "Estimate",
                draft: payload(),
                suggestedLog: AssistantSuggestedLog(
                    amount: "1",
                    unit: "bowl",
                    totalWeightGrams: "999"
                ),
                warnings: []
            )
        ) {
            XCTAssertEqual($0 as? AssistantDraftValidationError, .invalidSuggestedLog)
        }
    }

    func testConversationBoundsMatchTheServerContract() throws {
        XCTAssertThrowsError(try AssistantConversation(turns: [])) {
            XCTAssertEqual($0 as? AssistantConversationError, .empty)
        }
        XCTAssertThrowsError(
            try AssistantConversationTurn(role: .user, text: "   ")
        ) {
            XCTAssertEqual($0 as? AssistantConversationError, .emptyMessage)
        }
        XCTAssertThrowsError(
            try AssistantConversationTurn(
                role: .user,
                text: String(repeating: "x", count: 4_001)
            )
        ) {
            XCTAssertEqual($0 as? AssistantConversationError, .messageTooLong)
        }
        let turns = try (0..<21).map {
            try AssistantConversationTurn(role: .user, text: "Turn \($0)")
        }
        XCTAssertThrowsError(try AssistantConversation(turns: turns)) {
            XCTAssertEqual($0 as? AssistantConversationError, .tooManyTurns)
        }
    }

    // MARK: - Failure and cancellation

    func testRateLimitPreservesUserTurnAndRetryDoesNotDuplicateIt() async throws {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(service: service)
        await enable(viewModel, service: service)
        await service.enqueueTurn(.failure(AssistantServiceError.rateLimited(retryAfterSeconds: 30)))
        await service.enqueueTurn(.needsClarification(assistantMessage: "How much?"))

        await viewModel.performSend("Dal")
        XCTAssertEqual(viewModel.messages.map(\.role), [.user])
        XCTAssertEqual(
            viewModel.requestState,
            .failed(.rateLimited(retryAfterSeconds: 30))
        )
        XCTAssertTrue(viewModel.canRetryRequest)

        viewModel.retryRequest()
        await waitUntil { !viewModel.isSending && viewModel.messages.count == 2 }
        XCTAssertEqual(viewModel.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(viewModel.requestState, .idle)

        let requests = await service.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].1.turns.count, 1)
        XCTAssertEqual(requests[1].1.turns.count, 1, "Retry reuses the transcript without adding a turn")
    }

    func testCancelRestoresComposerAndRemovesPendingTurn() async {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(service: service)
        await enable(viewModel, service: service)
        await service.enqueueTurn(readyTurn())
        await service.setFirstDelay(300_000_000)

        let request = Task { await viewModel.performSend("Dal with rice") }
        await waitUntil { viewModel.isSending }
        viewModel.cancelRequest()
        await request.value

        XCTAssertEqual(viewModel.requestState, .idle)
        XCTAssertEqual(viewModel.messages, [])
        XCTAssertEqual(viewModel.composerText, "Dal with rice")
        XCTAssertNil(viewModel.draft)
    }

    func testEmptyAndTooLongMessagesDoNotCallTheAssistant() async {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(service: service)
        await enable(viewModel, service: service)

        viewModel.send()
        XCTAssertEqual(viewModel.composerError, AssistantConversationError.empty.message)

        viewModel.composerChanged(String(repeating: "x", count: 4_001))
        viewModel.send()
        XCTAssertEqual(viewModel.composerError, AssistantConversationError.messageTooLong.message)

        let requests = await service.recordedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testStartOverRequiresConfirmationAndKeepsStatus() async {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(service: service)
        await enable(viewModel, service: service)
        await service.enqueueTurn(.needsClarification(assistantMessage: "How much?"))

        await viewModel.performSend("Dal")
        viewModel.requestStartOver()
        XCTAssertTrue(viewModel.isStartOverConfirmationPresented)
        viewModel.cancelStartOver()
        XCTAssertEqual(viewModel.messages.count, 2)

        viewModel.requestStartOver()
        viewModel.confirmStartOver()
        XCTAssertEqual(viewModel.messages, [])
        XCTAssertEqual(viewModel.composerText, "")
        XCTAssertFalse(viewModel.isStartOverConfirmationPresented)
        XCTAssertTrue(viewModel.isEnabled)
    }

    func testBeginChangesKeepsTranscriptAndClearsDraft() async {
        let service = FakeAssistantService()
        let viewModel = makeViewModel(service: service)
        await enable(viewModel, service: service)
        await service.enqueueTurn(readyTurn())

        await viewModel.performSend("Dal")
        XCTAssertNotNil(viewModel.draft)
        viewModel.beginChanges()
        XCTAssertNil(viewModel.draft)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.requestState, .idle)
    }

    // MARK: - Adapter contract

    private func makeClient() -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantURLProtocol.self]
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func errorJSON(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    private func draftReadyJSON(
        purpose: AssistantDraftPurpose,
        withSuggestedLog: Bool
    ) -> Data {
        let suggested = withSuggestedLog
            ? #", "suggested_log": {"amount": "1", "unit": "bowl", "total_weight_grams": "250"}"#
            : ""
        return Data(
            """
            {
              "assistant_message": "Review this estimate.",
              "status": "draft_ready",
              "draft": {
                "name": "Dal",
                "brand": "Homemade",
                "categories": ["lentils"],
                "default_quantity": "1",
                "default_unit": "bowl",
                "nutrients": [
                  {"code": "ENERGY_KCAL", "amount_per_100g": "120"},
                  {"code": "PROTEIN_G", "amount_per_100g": "6"},
                  {"code": "CARBS_G", "amount_per_100g": "18"},
                  {"code": "FAT_G", "amount_per_100g": "3"}
                ],
                "servings": [{"unit": "bowl", "grams_per_unit": "250"}]
              }\(suggested),
              "warnings": ["Estimated from a typical recipe."]
            }
            """.utf8
        )
    }

    func testAdapterStatusGateDecodesImageSupport() async throws {
        AssistantURLProtocol.setUp { _ in
            .init(body: Data(#"{"enabled":true,"supports_images":true}"#.utf8))
        }
        let status = try await CalCoAssistantServiceAdapter(client: makeClient())
            .assistantStatus()

        XCTAssertTrue(status.enabled)
        XCTAssertTrue(status.supportsImages)
        let request = try XCTUnwrap(AssistantURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/ai/food-assistant/status")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAdapterSendsTextOnlyMultipartConversation() async throws {
        let recorder = AssistantRequestRecorder()
        AssistantURLProtocol.setUp { request in
            recorder.record(request)
            return .init(body: self.draftReadyJSON(purpose: .customFood, withSuggestedLog: false))
        }
        let conversation = try AssistantConversation(
            turns: [
                try AssistantConversationTurn(role: .user, text: "A bowl of dal"),
                try AssistantConversationTurn(role: .assistant, text: "How much?"),
                try AssistantConversationTurn(role: .user, text: "One bowl"),
            ]
        )

        let turn = try await CalCoAssistantServiceAdapter(client: makeClient())
            .requestDraft(purpose: .customFood, conversation: conversation)

        guard case .draftReady(let message, let draft, let suggested, let warnings) = turn else {
            return XCTFail("Expected a ready draft")
        }
        XCTAssertEqual(message, "Review this estimate.")
        XCTAssertEqual(draft.nutrients.first?.amountPer100g, "120")
        XCTAssertNil(suggested)
        XCTAssertEqual(warnings, ["Estimated from a typical recipe."])

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/ai/custom-food/draft")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try XCTUnwrap(bodyData(from: request))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"conversation\""))
        XCTAssertFalse(text.contains("name=\"photos\""))
        XCTAssertFalse(text.contains("filename="))
        XCTAssertTrue(text.contains(#""purpose":"custom_food""#))
        XCTAssertTrue(text.contains(#""role":"user""#))
        XCTAssertTrue(text.contains("One bowl"))
        XCTAssertTrue(text.hasSuffix("--\r\n"))
    }

    func testAdapterDecodesAdHocSuggestedLogDecimalStrings() async throws {
        AssistantURLProtocol.setUp { _ in
            .init(body: self.draftReadyJSON(purpose: .adHocLog, withSuggestedLog: true))
        }
        let conversation = try AssistantConversation(
            turns: [try AssistantConversationTurn(role: .user, text: "One bowl of dal")]
        )

        let turn = try await CalCoAssistantServiceAdapter(client: makeClient())
            .requestDraft(purpose: .adHocLog, conversation: conversation)

        guard case .draftReady(_, _, let suggested, _) = turn else {
            return XCTFail("Expected a ready ad-hoc draft")
        }
        XCTAssertEqual(
            suggested,
            AssistantSuggestedLog(amount: "1", unit: "bowl", totalWeightGrams: "250")
        )
    }

    func testPurposeSpecificResponseShapesAreRejected() throws {
        XCTAssertThrowsError(
            try AssistantDraftTurn.decodeResponse(
                draftReadyJSON(purpose: .customFood, withSuggestedLog: false),
                purpose: .adHocLog
            )
        ) {
            XCTAssertEqual($0 as? AssistantDraftResponseError, .missingSuggestedLog)
        }

        XCTAssertThrowsError(
            try AssistantDraftTurn.decodeResponse(
                draftReadyJSON(purpose: .adHocLog, withSuggestedLog: true),
                purpose: .customFood
            )
        ) {
            XCTAssertEqual($0 as? AssistantDraftResponseError, .unexpectedSuggestedLog)
        }
    }

    func testAdapterMapsDisabledRateLimitProviderAndSessionErrors() async throws {
        let service = CalCoAssistantServiceAdapter(client: makeClient())
        let conversation = try AssistantConversation(
            turns: [try AssistantConversationTurn(role: .user, text: "Dal")]
        )

        AssistantURLProtocol.setUp { _ in
            .init(
                statusCode: 503,
                body: self.errorJSON(code: "assistant_disabled", message: "assistant is unavailable")
            )
        }
        do {
            _ = try await service.requestDraft(purpose: .customFood, conversation: conversation)
            XCTFail("Expected disabled")
        } catch {
            XCTAssertEqual(error as? AssistantServiceError, .disabled)
        }

        AssistantURLProtocol.setUp { _ in
            .init(
                statusCode: 429,
                headers: ["Retry-After": "15"],
                body: self.errorJSON(code: "rate_limited", message: "too many requests")
            )
        }
        do {
            _ = try await service.requestDraft(purpose: .customFood, conversation: conversation)
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(
                error as? AssistantServiceError,
                .rateLimited(retryAfterSeconds: 15)
            )
        }

        AssistantURLProtocol.setUp { _ in
            .init(
                statusCode: 502,
                body: self.errorJSON(code: "provider_unavailable", message: "provider down")
            )
        }
        do {
            _ = try await service.requestDraft(purpose: .customFood, conversation: conversation)
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertEqual(error as? AssistantServiceError, .providerUnavailable)
        }

        AssistantURLProtocol.setUp { _ in
            .init(
                statusCode: 401,
                body: self.errorJSON(code: "unauthenticated", message: "Unauthorized")
            )
        }
        do {
            _ = try await service.requestDraft(purpose: .customFood, conversation: conversation)
            XCTFail("Expected session expiry")
        } catch {
            XCTAssertEqual(error as? AssistantServiceError, .sessionExpired)
        }
    }

    func testReviewedAcceptSendsNoCatalogOrDiaryWrite() async throws {
        AssistantURLProtocol.setUp { request in
            if request.url?.path == "/api/ai/food-assistant/status" {
                return .init(body: Data(#"{"enabled":true,"supports_images":false}"#.utf8))
            }
            return .init(body: self.draftReadyJSON(purpose: .customFood, withSuggestedLog: false))
        }
        let viewModel = AssistantViewModel(
            purpose: .customFood,
            service: CalCoAssistantServiceAdapter(client: makeClient())
        )

        await viewModel.loadStatus()
        await viewModel.performSend("Dal")
        XCTAssertNotNil(viewModel.draft)
        viewModel.acceptDraft()

        let paths = AssistantURLProtocol.requests.compactMap { $0.url?.path }
        XCTAssertEqual(
            paths,
            ["/api/ai/food-assistant/status", "/api/ai/custom-food/draft"]
        )
    }

    // MARK: - Helpers

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                stream.read(
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    maxLength: rawBuffer.count
                )
            }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition")
    }
}

private final class AssistantRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
