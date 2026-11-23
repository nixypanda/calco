import XCTest

@testable import CalCo

private actor LifecycleAssistantService: AssistantServicing {
    private var holdStatus = false
    private var holdRequest = false
    private var statusStarted = false
    private var requestStarted = false
    private var statusCancelled = false
    private var requestCancelled = false

    func setHoldStatus(_ value: Bool) { holdStatus = value }
    func setHoldRequest(_ value: Bool) { holdRequest = value }
    func didStartStatus() -> Bool { statusStarted }
    func didStartRequest() -> Bool { requestStarted }
    func wasStatusCancelled() -> Bool { statusCancelled }
    func wasRequestCancelled() -> Bool { requestCancelled }

    func assistantStatus() async throws -> AssistantStatus {
        if holdStatus {
            statusStarted = true
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                statusCancelled = true
                throw CancellationError()
            }
        }
        return AssistantStatus(enabled: true, supportsImages: false)
    }

    func requestDraft(
        purpose: AssistantDraftPurpose,
        conversation: AssistantConversation
    ) async throws -> AssistantDraftTurn {
        if holdRequest {
            requestStarted = true
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                requestCancelled = true
                throw CancellationError()
            }
        }
        throw AssistantServiceError.invalidResponse
    }
}

@MainActor
final class AssistantLifecycleTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await predicate()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let matched = await predicate()
        XCTAssertTrue(matched, "Timed out waiting for condition")
    }

    func testShutdownCancelsInFlightStatusRequest() async {
        let service = LifecycleAssistantService()
        await service.setHoldStatus(true)
        let viewModel = AssistantViewModel(purpose: .customFood, service: service)

        viewModel.retryStatus()
        await waitUntil { await service.didStartStatus() }
        XCTAssertEqual(viewModel.statusState, .loading)

        viewModel.shutdown()

        await waitUntil { await service.wasStatusCancelled() }
        await waitUntil { viewModel.statusState == .idle }
    }

    func testShutdownCancelsInFlightDraftAndRestoresComposer() async {
        let service = LifecycleAssistantService()
        await service.setHoldRequest(true)
        let viewModel = AssistantViewModel(purpose: .customFood, service: service)
        await viewModel.loadStatus()
        viewModel.composerChanged("Dal for dinner")
        viewModel.send()
        await waitUntil { await service.didStartRequest() }

        viewModel.shutdown()

        await waitUntil { await service.wasRequestCancelled() }
        await waitUntil {
            viewModel.requestState == .idle
                && viewModel.composerText == "Dal for dinner"
                && viewModel.messages.isEmpty
        }
    }

    func testResetForSessionChangeStopsWorkAndClearsTranscript() async {
        let service = LifecycleAssistantService()
        await service.setHoldRequest(true)
        let viewModel = AssistantViewModel(purpose: .customFood, service: service)
        await viewModel.loadStatus()
        viewModel.composerChanged("Dal")
        viewModel.send()
        await waitUntil { await service.didStartRequest() }

        viewModel.resetForSessionChange()

        await waitUntil { await service.wasRequestCancelled() }
        XCTAssertEqual(viewModel.statusState, .idle)
        XCTAssertEqual(viewModel.requestState, .idle)
        XCTAssertEqual(viewModel.messages, [])
        XCTAssertEqual(viewModel.composerText, "")
        XCTAssertNil(viewModel.draft)
    }

    func testShutdownIsIdempotentAndRetainsComposerAndStatus() async {
        let service = LifecycleAssistantService()
        let viewModel = AssistantViewModel(purpose: .customFood, service: service)
        await viewModel.loadStatus()
        viewModel.composerChanged("Dal")
        viewModel.shutdown()
        viewModel.shutdown()

        XCTAssertEqual(viewModel.composerText, "Dal")
        XCTAssertEqual(viewModel.statusState, .enabled(
            AssistantStatus(enabled: true, supportsImages: false)
        ))
    }
}
