import ComposableArchitecture
import Combine
import XCTest

@testable import CalCo

/// Bounded QA transitional log-editor bridge coverage. The editor *view model*
/// stays legacy on purpose; these tests pin the typed delivery seam, the
/// store-backed fresh-row lookup, and the single authoritative owner that
/// applies the write, refreshes and shows the notice. No timers, no sleeps, no
/// yield polling: every wait is a Combine/continuation rendezvous on real state.
@MainActor
final class DiaryEditorBridgeTests: XCTestCase {
    private let baseURL = URL(string: "https://calco.example.com")!
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 24)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 23)
    private let fixedDate = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 24)
    )!
    private let user = AuthUser(
        id: "user-1", username: "user", role: .user, displayName: "User"
    )

    // MARK: - Typed delivery shape

    func testDeliveryShapesAreTypedMutuallyExclusiveAndLocalized() {
        let notice = DiaryMutationNotice(kind: .saved, title: "Bridged Apple")
        let saved = makeDiaryLog(id: "edit-1", amount: "200")
        let editorDelivery = DiaryMutationDelivery(
            generation: 7,
            editor: .saved(
                originalID: "edit-1", date: today, log: saved, notice: notice
            )
        )
        XCTAssertEqual(editorDelivery.generation, 7)
        XCTAssertEqual(editorDelivery.affectedDates, [today])
        XCTAssertTrue(editorDelivery.logs.isEmpty, "An editor delivery has no created-row payload")
        guard case let .some(.saved(originalID, date, log, deliveredNotice)) = editorDelivery.editor else {
            return XCTFail("Expected the saved editor payload")
        }
        XCTAssertEqual(originalID, "edit-1")
        XCTAssertEqual(date, today)
        XCTAssertEqual(log, saved)
        XCTAssertEqual(deliveredNotice, notice)

        let deletedDelivery = DiaryMutationDelivery(
            generation: 7,
            editor: .deleted(id: "edit-1", date: today, notice: notice)
        )
        XCTAssertEqual(deletedDelivery.affectedDates, [today])
        XCTAssertTrue(deletedDelivery.logs.isEmpty)
        guard case let .some(.deleted(id, _, _)) = deletedDelivery.editor else {
            return XCTFail("Expected the deleted editor payload")
        }
        XCTAssertEqual(id, "edit-1")

        // The created init keeps its original signature and leaves editor nil.
        let created = DiaryMutationDelivery(
            generation: 7,
            drafts: [makeDraft(date: today), makeDraft(date: otherDate), makeDraft(date: today)],
            logs: []
        )
        XCTAssertNil(created.editor, "Created submissions must not fabricate an editor payload")
        XCTAssertEqual(created.affectedDates, [today, otherDate])

        // Native English messages come from DiaryMutationNotice localization.
        XCTAssertEqual(notice.message, String(localized: "diary.mutation.saved"))
        XCTAssertEqual(
            DiaryMutationNotice(kind: .deleted, title: "t").message,
            String(localized: "diary.mutation.deleted")
        )
        let blocked = DiaryMutationNotice(
            kind: .deleted, title: "t", blockedPendingCount: 2
        ).message
        XCTAssertNotEqual(blocked, String(localized: "diary.mutation.deleted"))
        XCTAssertTrue(blocked.contains("2"), "Blocked-pending suffix must carry the count")
    }

    // MARK: - Store-backed fresh-row lookup

    func testStoreBackedOpenUsesFreshTcaRowWhenLegacyVmIsStale() async {
        let runtime = makeStoreBackedRuntime(logsByDate: [:])
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialFetch(runtime)
        let generation = runtime.coordinator.session.sessionGeneration

        // The legacy VM is deliberately empty. Seed only the TCA owner with a
        // freshly saved row through the feature-owned action.
        let fresh = makeDiaryLog(id: "fresh-created", amount: "100")
        await runtime.store.send(
            .window(.diary(.diary(.applySavedLog(
                generation: generation,
                log: fresh,
                replacingID: fresh.id,
                onDate: today
            ))))
        ).finish()

        runtime.coordinator.openLogEditor(
            logID: fresh.id, date: today, generation: generation
        )
        guard let editor = runtime.coordinator.logEditorViewModel(for: fresh.id) else {
            return XCTFail("The fresh TCA row was not resolvable into the editor")
        }
        XCTAssertEqual(editor.logID, fresh.id)
        XCTAssertEqual(editor.title, fresh.title)
        XCTAssertNil(
            runtime.coordinator.diaryViewModel?.log(withID: fresh.id),
            "The legacy VM must remain stale — this is a TCA-only lookup proof"
        )
    }

    func testStoreBackedOpenDeniesMissingTombstonedStaleMovedAndExpired() async {
        let runtime = makeStoreBackedRuntime(logsByDate: [
            today: [makeDiaryLog(id: "visible"), makeDiaryLog(id: "doomed")]
        ])
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialFetch(runtime)
        let generation = runtime.coordinator.session.sessionGeneration

        runtime.coordinator.openLogEditor(logID: "missing", date: today, generation: generation)
        XCTAssertNil(runtime.coordinator.logEditorViewModel(for: "missing"))

        await runtime.store.send(
            .window(.diary(.diary(.applyDeletedLog(
                generation: generation, id: "doomed", onDate: today
            ))))
        ).finish()
        runtime.coordinator.openLogEditor(logID: "doomed", date: today, generation: generation)
        XCTAssertNil(runtime.coordinator.logEditorViewModel(for: "doomed"))

        runtime.coordinator.openLogEditor(
            logID: "visible", date: today, generation: generation + 1
        )
        XCTAssertNil(runtime.coordinator.logEditorViewModel(for: "visible"))

        await runtime.store.send(.window(.diary(.diary(.selectDate(otherDate))))).finish()
        runtime.coordinator.openLogEditor(
            logID: "visible", date: today, generation: generation
        )
        XCTAssertNil(runtime.coordinator.logEditorViewModel(for: "visible"))

        await runtime.store.send(.window(.diary(.diary(.selectDate(today))))).finish()
        await runtime.store.send(.window(.diary(.diary(.expireSession)))).finish()
        runtime.coordinator.openLogEditor(
            logID: "visible", date: today, generation: generation
        )
        XCTAssertNil(runtime.coordinator.logEditorViewModel(for: "visible"))
    }

    func testDeallocatedResolverSourceDeniesOpen() async {
        let coordinator = makeCoordinator(ownership: .storeBackedScreen)
        let generation = await signedInGeneration(coordinator)
        let box = LogBox(log: makeDiaryLog(id: "weak-row"))
        coordinator.installStoreLogResolver { [weak box] id, _, gen in
            guard gen == generation, let box, box.log?.id == id else { return nil }
            return box.log
        }
        coordinator.openLogEditor(logID: "weak-row", date: today, generation: generation)
        XCTAssertNotNil(coordinator.logEditorViewModel(for: "weak-row"))

        // Dirty + explicit discard confirmation removes the editor through the
        // public route so the second open is a genuinely fresh attempt.
        coordinator.logEditorViewModel(for: "weak-row")?.amount = "999"
        coordinator.requestBack()
        coordinator.confirmDiscardEditorChanges()
        XCTAssertNil(coordinator.logEditorViewModel(for: "weak-row"))
        box.log = nil
        coordinator.openLogEditor(logID: "weak-row", date: today, generation: generation)
        XCTAssertNil(
            coordinator.logEditorViewModel(for: "weak-row"),
            "A deallocated source must fail closed, not fall back to the legacy VM"
        )
    }

    // MARK: - Existing editor guards

    func testDirtySwitchStillDefersAndConfirmOpensFromStore() async {
        let runtime = makeStoreBackedRuntime(logsByDate: [
            today: [makeDiaryLog(id: "row-a"), makeDiaryLog(id: "row-b")]
        ])
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialFetch(runtime)
        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        let generation = runtime.coordinator.session.sessionGeneration

        runtime.coordinator.openLogEditor(logID: "row-a", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(runtime.coordinator.logEditorViewModel(for: "row-a")) else {
            return
        }
        XCTAssertNotNil(editor)
        editor.amount = "250"

        runtime.coordinator.openLogEditor(logID: "row-b", date: today, generation: generation)
        XCTAssertEqual(
            runtime.coordinator.pendingEditorDiscard,
            .openLogEditor(logID: "row-b", date: today)
        )
        XCTAssertNil(
            runtime.coordinator.logEditorViewModel(for: "row-b"),
            "A dirty editor must not be silently replaced"
        )

        runtime.coordinator.confirmDiscardEditorChanges()
        XCTAssertNotNil(
            runtime.coordinator.logEditorViewModel(for: "row-b"),
            "Confirmed switch must open the store-backed target row"
        )
        XCTAssertNil(runtime.coordinator.logEditorViewModel(for: "row-a"))
    }

    func testBusyEditorCannotBeDiscardedByAnotherRoute() async {
        let service = HeldUpdateDiaryService(logsByDate: [
            today: [makeDiaryLog(id: "busy-row"), makeDiaryLog(id: "next-row")]
        ])
        let coordinator = makeCoordinator(
            ownership: .storeBackedScreen,
            diaryService: service
        )
        let generation = await signedInGeneration(coordinator)
        coordinator.installStoreLogResolver { id, _, gen in
            guard gen == generation else { return nil }
            return self.makeDiaryLog(id: id)
        }
        coordinator.openLogEditor(logID: "busy-row", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(coordinator.logEditorViewModel(for: "busy-row")) else {
            return
        }
        editor.amount = "333"

        let saving = Task { @MainActor in await editor.save() }
        await service.waitForUpdateStart()
        coordinator.openLogEditor(logID: "next-row", date: today, generation: generation)
        XCTAssertNil(
            coordinator.pendingEditorDiscard,
            "A busy editor is ignored, not confirmation-gated"
        )
        XCTAssertNil(coordinator.logEditorViewModel(for: "next-row"))
        service.finishUpdate(returning: makeDiaryLog(id: "busy-row", amount: "333"))
        await saving.value
    }

    // MARK: - Exactly-once typed delivery at the coordinator boundary

    func testEditorSaveDeliversOneTypedPayloadAndReturnsSynchronously() async {
        let coordinator = makeCoordinator(ownership: .storeBackedScreen)
        let generation = await signedInGeneration(coordinator)
        coordinator.installStoreLogResolver { id, _, gen in
            guard gen == generation else { return nil }
            return self.makeDiaryLog(id: id)
        }
        let recorder = DeliveryRecorder()
        coordinator.installDiaryMutationCallback { recorder.record($0) }
        coordinator.openLogEditor(logID: "save-row", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(coordinator.logEditorViewModel(for: "save-row")) else {
            return
        }
        editor.amount = "200"

        await editor.save()
        await recorder.waitForFirst()

        XCTAssertEqual(recorder.deliveries.count, 1)
        guard let delivery = recorder.deliveries.first else { return }
        XCTAssertEqual(delivery.generation, generation)
        XCTAssertTrue(delivery.logs.isEmpty)
        XCTAssertEqual(delivery.affectedDates, [today])
        guard case let .some(.saved(originalID, date, log, notice)) = delivery.editor else {
            return XCTFail("Expected a typed saved payload")
        }
        XCTAssertEqual(originalID, "save-row")
        XCTAssertEqual(date, today)
        XCTAssertEqual(log.quantity?.amount, "200")
        XCTAssertEqual(notice.kind, .saved)
        XCTAssertEqual(notice.title, editor.title)
        XCTAssertNil(activeEditorID(coordinator), "Back must be synchronous")
    }

    func testEditorDeleteDeliversOneTypedPayloadWithNoticeTitle() async {
        let coordinator = makeCoordinator(ownership: .storeBackedScreen)
        let generation = await signedInGeneration(coordinator)
        coordinator.installStoreLogResolver { id, _, gen in
            guard gen == generation else { return nil }
            return self.makeDiaryLog(id: id)
        }
        let recorder = DeliveryRecorder()
        coordinator.installDiaryMutationCallback { recorder.record($0) }
        coordinator.openLogEditor(logID: "delete-row", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(coordinator.logEditorViewModel(for: "delete-row")) else {
            return
        }

        await editor.delete()
        await recorder.waitForFirst()

        XCTAssertEqual(recorder.deliveries.count, 1)
        guard let delivery = recorder.deliveries.first,
              case let .some(.deleted(id, date, notice)) = delivery.editor else {
            return XCTFail("Expected a typed deleted payload")
        }
        XCTAssertEqual(id, "delete-row")
        XCTAssertEqual(date, today)
        XCTAssertEqual(notice.kind, .deleted)
        XCTAssertEqual(notice.title, editor.title)
        XCTAssertEqual(notice.blockedPendingCount, editor.blockedPendingCount)
    }

    func testDuplicateEditorSuccessDeliversExactlyOnce() async {
        let service = EditorDiaryService(logsByDate: [:])
        let coordinator = makeCoordinator(ownership: .storeBackedScreen, diaryService: service)
        let generation = await signedInGeneration(coordinator)
        coordinator.installStoreLogResolver { id, _, gen in
            guard gen == generation else { return nil }
            return self.makeDiaryLog(id: id)
        }
        let recorder = DeliveryRecorder()
        coordinator.installDiaryMutationCallback { recorder.record($0) }
        coordinator.openLogEditor(logID: "dup-row", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(coordinator.logEditorViewModel(for: "dup-row")) else {
            return
        }
        let baselineGET = service.fetchCallCount

        // A replay is only meaningful after a real authoritative save: the first
        // success supplies the captured lastSavedLog the store-backed handler
        // requires. Replaying that same callback must still dedup to one write.
        editor.amount = "200"
        XCTAssertTrue(editor.canSave, "A changed amount must make the editor saveable")
        await editor.save()
        await recorder.waitForFirst()

        guard let onSaved = editor.onSaved else {
            return XCTFail("Expected the installed saved callback")
        }
        onSaved(today)
        onSaved(today)
        await recorder.waitForFirst()

        XCTAssertEqual(
            recorder.deliveries.count, 1,
            "Dedup must keep one delivery per editor instance"
        )
        XCTAssertEqual(service.updateCallCount, 1, "One authoritative write")
        XCTAssertEqual(service.fetchCallCount, baselineGET, "No extra GET")
        guard let delivery = recorder.deliveries.first,
              case let .some(.saved(originalID, date, log, notice)) = delivery.editor else {
            return XCTFail("Expected a typed saved payload")
        }
        XCTAssertEqual(delivery.generation, generation)
        XCTAssertTrue(delivery.logs.isEmpty)
        XCTAssertEqual(delivery.affectedDates, [today])
        XCTAssertEqual(originalID, "dup-row")
        XCTAssertEqual(date, today)
        XCTAssertEqual(log.quantity?.amount, "200")
        XCTAssertEqual(notice.kind, .saved)
        XCTAssertEqual(notice.title, editor.title)
        XCTAssertNil(activeEditorID(coordinator), "Back must be synchronous")
    }

    func testStaleGenerationEditorSuccessIsNeverDelivered() async {
        let service = HeldUpdateDiaryService(logsByDate: [
            today: [makeDiaryLog(id: "stale-row")]
        ])
        let coordinator = makeCoordinator(ownership: .storeBackedScreen, diaryService: service)
        let generation = await signedInGeneration(coordinator)
        coordinator.installStoreLogResolver { id, _, gen in
            guard gen == generation else { return nil }
            return self.makeDiaryLog(id: id)
        }
        let recorder = DeliveryRecorder()
        coordinator.installDiaryMutationCallback { recorder.record($0) }
        coordinator.openLogEditor(logID: "stale-row", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(coordinator.logEditorViewModel(for: "stale-row")) else {
            return
        }
        let baselineGET = service.fetchCallCount

        // A genuine PUT is held open, the owning generation moves on, then the
        // authoritative response is allowed to land on the editor.
        editor.amount = "200"
        XCTAssertTrue(editor.canSave, "A changed amount must make the editor saveable")
        let saving = Task { @MainActor in await editor.save() }
        await service.waitForUpdateStart()
        XCTAssertTrue(
            coordinator.session.handleUnauthorized(atGeneration: generation, reason: .expired),
            "The captured generation must still be current when unauthorized is handled"
        )
        service.finishUpdate(returning: makeDiaryLog(id: "stale-row", amount: "200"))
        await saving.value

        // The response is authoritative on the editor, but its generation is stale.
        XCTAssertEqual(editor.lastSavedLog?.quantity?.amount, "200")
        XCTAssertEqual(service.updateCallCount, 1, "One authoritative PUT")
        XCTAssertEqual(
            coordinator.session.sessionGeneration, generation + 1,
            "Only the explicit unauthorized transition advanced the session"
        )
        guard let onSaved = editor.onSaved else {
            return XCTFail("Expected the installed saved callback")
        }
        var recordedDate: LocalDiaryDate?
        editor.onSaved = { date in
            recordedDate = date
            onSaved(date)
        }
        guard let replay = editor.onSaved else { return XCTFail("Expected the wrapped callback") }
        replay(today)
        XCTAssertEqual(recordedDate, today, "The replay carried the editor's captured date")
        XCTAssertTrue(recorder.deliveries.isEmpty, "A stale generation must apply nothing")
        XCTAssertEqual(service.fetchCallCount, baselineGET, "A stale mutation issues no GET")
    }

    func testSavedEditorWithoutAuthoritativeRowFailsClosed() async {
        let coordinator = makeCoordinator(ownership: .storeBackedScreen)
        let generation = await signedInGeneration(coordinator)
        coordinator.installStoreLogResolver { id, _, gen in
            guard gen == generation else { return nil }
            return self.makeDiaryLog(id: id)
        }
        let recorder = DeliveryRecorder()
        coordinator.installDiaryMutationCallback { recorder.record($0) }
        coordinator.openLogEditor(logID: "no-response", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(coordinator.logEditorViewModel(for: "no-response")) else {
            return
        }
        XCTAssertNil(editor.lastSavedLog)
        editor.onSaved?(today)
        XCTAssertTrue(recorder.deliveries.isEmpty, "No fabricated row may be delivered")
    }

    // MARK: - Runtime owner: apply, one GET, one notice

    func testSavedEditorAppliesRowRefreshesOnceAndNoticesVisibleDate() async {
        let service = EditorDiaryService(logsByDate: [
            today: [makeDiaryLog(id: "edit-1", amount: "100")]
        ])
        let runtime = makeStoreBackedRuntime(service: service)
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialFetch(runtime)
        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        let generation = runtime.coordinator.session.sessionGeneration
        let baselineFetch = fetchCount(runtime)
        let baselineGET = service.fetchCallCount

        runtime.coordinator.openLogEditor(logID: "edit-1", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(runtime.coordinator.logEditorViewModel(for: "edit-1")) else {
            return
        }
        editor.amount = "200"
        XCTAssertTrue(editor.canSave, "A changed amount must make the editor saveable")
        await editor.save()

        await awaitStoreFetchCount(runtime, equals: baselineFetch + 1)
        // The runtime callback awaits its refresh before showing the notice;
        // the GET completion alone is not proof the notice has landed yet.
        await awaitStoreCondition(runtime.store) {
            $0.window?.diary.diary.mutationNotice?.kind == .saved
        }
        guard let diary = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing store-backed diary")
        }
        XCTAssertEqual(
            diary.visibleDay?.logs.first { $0.id == "edit-1" }?.quantity?.amount,
            "200",
            "The authoritative PUT row must be applied, not a stale GET row"
        )
        XCTAssertEqual(service.fetchCallCount, baselineGET + 1, "Exactly one GET after the write")
        XCTAssertEqual(diary.completedFetchCount, baselineFetch + 1)
        guard let notice = diary.mutationNotice else { return XCTFail("No editor notice") }
        XCTAssertEqual(notice.kind, .saved)
        XCTAssertEqual(notice.title, editor.title)
        XCTAssertNil(activeEditorID(runtime.coordinator), "Back must be synchronous")
    }

    func testDeletedEditorAppliesTombstoneThatStaleGetCannotResurrect() async {
        // Hold a genuine in-flight GET whose stale payload still echoes `gone`.
        // The tombstone applied by the callback must prune it when that snapshot
        // finally settles, and the callback's own refresh is deduped against the
        // read already in flight.
        let stale = makeDiaryLog(id: "gone")
        let kept = makeDiaryLog(id: "kept")
        let service = EditorDiaryService(logsByDate: [
            today: [stale, kept]
        ])
        let runtime = makeStoreBackedRuntime(service: service)
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialFetch(runtime)
        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        let generation = runtime.coordinator.session.sessionGeneration
        let baselineFetch = fetchCount(runtime)
        let baselineGET = service.fetchCallCount

        // The editor must be opened from the TCA-loaded row before the read is
        // held, so the delete is driven by a real editor instance.
        runtime.coordinator.openLogEditor(logID: "gone", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(runtime.coordinator.logEditorViewModel(for: "gone")) else {
            return
        }

        let gate = service.holdNextFetch(
            for: today,
            returning: DiaryDay(date: today, logs: [stale, kept])
        )
        let refresh = Task { @MainActor in
            await runtime.store.send(.window(.diary(.diary(.refresh)))).finish()
        }
        await gate.waitForStart()
        XCTAssertEqual(
            service.fetchCallCount, baselineGET + 1,
            "The held refresh issued exactly one GET"
        )

        await editor.delete()

        // The tombstone must land before the stale snapshot is released.
        await awaitStoreCondition(runtime.store) {
            $0.window?.diary.diary.deletedIDs[self.today]?.contains("gone") == true
        }

        // Release the old snapshot (still carrying gone + kept) and let the
        // refresh settle against the already-applied tombstone.
        gate.release()
        await refresh.value
        await awaitStoreCondition(runtime.store) {
            $0.window?.diary.diary.mutationNotice?.kind == .deleted
        }

        guard let diary = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing store-backed diary")
        }
        XCTAssertNil(
            diary.visibleDay?.logs.first { $0.id == "gone" },
            "A stale GET must not resurrect a deleted row"
        )
        XCTAssertNotNil(diary.visibleDay?.logs.first { $0.id == "kept" })
        XCTAssertEqual(service.fetchCallCount, baselineGET + 1, "No extra GET after the delete")
        XCTAssertEqual(diary.completedFetchCount, baselineFetch + 1)
        XCTAssertEqual(diary.mutationNotice?.kind, .deleted)
        XCTAssertEqual(diary.mutationNotice?.title, editor.title)
    }

    func testCrossDateEditorMutationAppliesToCacheWithoutGetOrNotice() async {
        let service = EditorDiaryService(logsByDate: [
            otherDate: [makeDiaryLog(id: "cross")],
            today: [makeDiaryLog(id: "visible-row")],
        ])
        let runtime = makeStoreBackedRuntime(service: service)
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialFetch(runtime)
        let generation = runtime.coordinator.session.sessionGeneration

        await runtime.store.send(.window(.diary(.diary(.selectDate(otherDate))))).finish()
        runtime.coordinator.openLogEditor(logID: "cross", date: otherDate, generation: generation)
        guard let editor = try? XCTUnwrap(runtime.coordinator.logEditorViewModel(for: "cross")) else {
            return
        }
        editor.amount = "200"
        XCTAssertTrue(editor.canSave, "A changed amount must make the editor saveable")

        // Move back to Today while the editor is alive: the captured date stays
        // otherDate, so the write must land in that date's cache only.
        await runtime.store.send(.window(.diary(.diary(.selectDate(today))))).finish()
        let baselineFetch = fetchCount(runtime)
        let baselineGET = service.fetchCallCount
        await editor.save()
        await awaitStoreCondition(runtime.store) {
            $0.window?.diary.diary.savedLogOverrides[self.otherDate]?["cross"]?.quantity?.amount == "200"
        }

        guard let diary = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing store-backed diary")
        }
        XCTAssertEqual(
            diary.savedLogOverrides[otherDate]?["cross"]?.quantity?.amount,
            "200",
            "A cross-date write must still apply on its captured date"
        )
        XCTAssertEqual(service.fetchCallCount, baselineGET, "No GET for a non-visible write")
        XCTAssertEqual(diary.completedFetchCount, baselineFetch, "No refresh for a non-visible write")
        XCTAssertNil(diary.mutationNotice, "No notice for a non-visible write")
        XCTAssertEqual(diary.selectedDate, today, "No navigation pullback to the edited date")
    }

    func testStaleStoreGenerationAppliesNothing() async {
        let service = HeldUpdateDiaryService(logsByDate: [
            today: [makeDiaryLog(id: "stale-apply")]
        ])
        let runtime = makeStoreBackedRuntime(service: service)
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialFetch(runtime)
        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        let generation = runtime.coordinator.session.sessionGeneration
        runtime.coordinator.openLogEditor(logID: "stale-apply", date: today, generation: generation)
        guard let editor = try? XCTUnwrap(runtime.coordinator.logEditorViewModel(for: "stale-apply")) else {
            return
        }
        let baselineGET = service.fetchCallCount

        // Hold a real PUT, advance the store's root generation while it is in
        // flight, then let the authoritative row land on the still-open editor.
        editor.amount = "200"
        XCTAssertTrue(editor.canSave, "A changed amount must make the editor saveable")
        let saving = Task { @MainActor in await editor.save() }
        await service.waitForUpdateStart()
        runtime.store.send(
            .sessionSnapshot(SessionSnapshot(
                phase: .signedOut(.signedOut), generation: generation + 1
            ))
        )
        service.finishUpdate(returning: makeDiaryLog(id: "stale-apply", amount: "200"))
        await saving.value

        XCTAssertEqual(editor.lastSavedLog?.quantity?.amount, "200")
        XCTAssertEqual(service.updateCallCount, 1, "One authoritative PUT")
        XCTAssertEqual(
            runtime.store.state.sessionGeneration, generation + 1,
            "The root generation advanced exactly once"
        )
        guard let onSaved = editor.onSaved else {
            return XCTFail("Expected the installed saved callback")
        }
        var recordedDate: LocalDiaryDate?
        editor.onSaved = { date in
            recordedDate = date
            onSaved(date)
        }
        guard let replay = editor.onSaved else { return XCTFail("Expected the wrapped callback") }
        replay(today)
        XCTAssertEqual(recordedDate, today, "The replay carried the editor's captured date")

        XCTAssertEqual(service.fetchCallCount, baselineGET, "A stale mutation issues no GET")
        XCTAssertNil(
            runtime.store.state.window,
            "A newer generation must tear down the signed-in window"
        )
    }

    func testWeakRuntimeResolverDoesNotRetainStoreOrCoordinator() async {
        // Sole durable owner. The sign-in helpers use a scoped binding so no
        // `let runtime` alias survives to keep the graph alive past `owned = nil`.
        var owned: NativeWindowRuntime? = makeStoreBackedRuntime(logsByDate: [:])
        if let runtime = owned {
            await ensureSignedIn(runtime)
            await awaitAbsoluteInitialFetch(runtime)
        }
        weak var weakStore = owned?.store
        weak var weakCoordinator = owned?.coordinator
        owned = nil
        XCTAssertNil(weakStore, "The installed resolver/callback retained the store")
        XCTAssertNil(weakCoordinator, "The installed resolver/callback retained the coordinator")
    }

    // MARK: - Delegate forwarding

    func testWindowForwardsEditorDelegateAndFiltersStaleGeneration() async {
        let generation = UInt64(7)
        let store = TestStore(initialState: WindowFeature.State(
            sessionGeneration: generation, today: today
        )) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in DiaryDay(date: self.today) })
        }

        await store.send(.diary(.delegate(.openLogEditor(
            id: "log-1", date: today, generation: generation
        ))))
        await store.receive(\.delegate, WindowFeature.Delegate.openLogEditor(
            id: "log-1", date: today, generation: generation
        ))

        await store.send(.diary(.delegate(.openLogEditor(
            id: "stale", date: today, generation: generation + 1
        ))))
        await store.finish()
    }

    func testWindowFiltersExpiredEditorDelegate() async {
        let generation = UInt64(7)
        let expiredDiary = DiaryFeature.State(
            today: today,
            phase: .sessionExpired(requestDate: today),
            sessionGeneration: generation
        )
        let expiredScreen = DiaryScreenFeature.State(
            diary: expiredDiary,
            latest: DiaryLatestFeature.State(
                destinationDate: today, today: today, sessionGeneration: generation
            )
        )
        let store = TestStore(initialState: WindowFeature.State(
            sessionGeneration: generation, today: today, diary: expiredScreen
        )) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in DiaryDay(date: self.today) })
        }
        await store.send(.diary(.delegate(.openLogEditor(
            id: "expired", date: today, generation: generation
        ))))
        await store.finish()
    }

    func testAppRootRoutesEditorWithRootAndWindowGeneration() async {
        let generation = UInt64(7)
        let recorder = EditorRouteRecorder()
        let client = LegacyDiaryRoutingClient(
            openLogEditor: { id, date, gen in
                recorder.id = id
                recorder.date = date
                recorder.generation = gen
            },
            startLogging: { _, _, _ in }
        )
        let matched = AppFeature.SignedInState(
            user: user,
            window: WindowFeature.State(sessionGeneration: generation, today: today)
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(matched), sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = .unimplemented
            $0.date = .constant(fixedDate)
            $0.legacyDiaryRoutingClient = client
        }

        await store.send(.window(.delegate(.openLogEditor(
            id: "routed", date: otherDate, generation: generation
        ))))
        await store.finish()
        XCTAssertEqual(recorder.id, "routed")
        XCTAssertEqual(recorder.date, otherDate)
        XCTAssertEqual(recorder.generation, generation)

        recorder.id = nil
        let mismatched = AppFeature.SignedInState(
            user: user,
            window: WindowFeature.State(sessionGeneration: generation + 1, today: today)
        )
        let blockedStore = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(mismatched), sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = .unimplemented
            $0.date = .constant(fixedDate)
            $0.legacyDiaryRoutingClient = client
        }
        await blockedStore.send(.window(.delegate(.openLogEditor(
            id: "blocked", date: otherDate, generation: generation
        ))))
        await blockedStore.finish()
        XCTAssertNil(recorder.id, "A stale window generation must not navigate")
    }

    // MARK: - Harness

    private func makeDiaryLog(
        id: String,
        amount: String = "100",
        title: String = "Bridged Apple"
    ) -> DiaryLog {
        DiaryLog(
            id: id,
            mealSlot: .breakfast,
            title: title,
            calories: Double(amount) ?? 100,
            proteinG: 2,
            carbsG: 20,
            fatG: 1,
            quantity: NutritionQuantity(amount: amount, unit: "g"),
            notes: nil,
            brand: "QA Brand",
            itemReference: nil,
            logItem: nil
        )
    }

    private func makeDraft(date: LocalDiaryDate) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: .product(id: "qa-apple"),
            date: date,
            mealSlot: .breakfast,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "UTC"
        )
    }

    private final class LogBox {
        var log: DiaryLog?
        init(log: DiaryLog?) { self.log = log }
    }

    private final class EditorRouteRecorder: @unchecked Sendable {
        var id: String?
        var date: LocalDiaryDate?
        var generation: UInt64?
    }

    private func makeAuthority() -> (CalCoSessionAuthority, EditorSessionService) {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-editor-bridge", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-editor-bridge", displayName: "Alice")
        )
        let service = EditorSessionService(session: session)
        let coordinatorSession = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: EditorCookieClearer()
        )
        return (
            CalCoSessionAuthority(
                client: CalCoAPIClient(baseURL: baseURL),
                session: coordinatorSession
            ),
            service
        )
    }

    private final class SessionStreamBox: @unchecked Sendable {
        var continuation: AsyncStream<SessionSnapshot>.Continuation?
    }

    private func makeFiniteSessionClient(
        authority: CalCoSessionAuthority,
        box: SessionStreamBox
    ) -> SessionClient {
        SessionClient(
            restore: { await authority.session.restore() },
            start: {
                let phase = await authority.session.start()
                let snapshot = await MainActor.run {
                    SessionSnapshot(
                        phase: phase, generation: authority.session.sessionGeneration
                    )
                }
                box.continuation?.yield(snapshot)
                box.continuation?.finish()
                return phase
            },
            signIn: { _, _ in .failed(.invalidCredentials) },
            signOut: { .completed },
            handleUnauthorized: { _, _ in false },
            dismissUnsupportedAccount: {},
            snapshot: {
                await MainActor.run {
                    SessionSnapshot(
                        phase: authority.session.phase,
                        generation: authority.session.sessionGeneration
                    )
                }
            },
            events: {
                let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
                box.continuation = continuation
                return stream
            }
        )
    }

    private func applyStableDependencies(
        _ dependencies: inout DependencyValues,
        authority: CalCoSessionAuthority,
        box: SessionStreamBox
    ) {
        dependencies.date = .constant(fixedDate)
        dependencies.uuid = .incrementing
        dependencies.calendar = Calendar(identifier: .gregorian)
        dependencies.timeZone = TimeZone(identifier: "UTC")!
        dependencies.sessionClient = makeFiniteSessionClient(authority: authority, box: box)
        dependencies.continuousClock = TestClock()
        dependencies.foodSearchClient = .unimplemented
        dependencies.searchHistoryClient = SearchHistoryClient(
            recentItems: { _, _, _ in [] },
            categorySuggestions: { _, _ in [] }
        )
        dependencies.barcodeClient = .unimplemented
        dependencies.searchQuickAddClient = SearchQuickAddFeature.Client(
            submit: { @MainActor _, _, _, _ in .failure(.failed("unimplemented")) }
        )
        dependencies.legacySearchRoutingClient = .unimplemented
    }

    private func makeStoreBackedRuntime(
        service: (any DiaryServicing)? = nil,
        logsByDate: [LocalDiaryDate: [DiaryLog]] = [:]
    ) -> NativeWindowRuntime {
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let diaryService: any DiaryServicing = service
            ?? EditorDiaryService(logsByDate: logsByDate)
        return NativeWindowRuntime(
            sessionAuthority: authority,
            makeDiaryService: { _ in diaryService },
            logSubmissionService: LogSubmissionService(
                sender: StubSubmissionSender(logs: [])
            ),
            diaryScreenOwnership: .storeBackedScreen,
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(&dependencies, authority: authority, box: box)
            }
        )
    }

    private func ensureSignedIn(_ runtime: NativeWindowRuntime) async {
        await runtime.store.send(.task).finish()
    }

    /// Absolute bootstrap contract: the first authoritative read for a fresh
    /// coordinator/store must complete (count becomes exactly 1) before any
    /// later read is measured. No relative baseline and no timing sleep.
    private func awaitAbsoluteInitialFetch(_ runtime: NativeWindowRuntime) async {
        guard let viewModel = runtime.coordinator.diaryViewModel else {
            XCTFail("Missing legacy diary view model for bootstrap")
            return
        }
        await awaitLegacyFetchCount(viewModel, equals: 1)
    }

    private func awaitLegacyFetchCount(_ viewModel: DiaryViewModel, equals target: Int) async {
        if viewModel.completedFetchCount == target { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = CountBox()
            box.continuation = continuation
            box.cancellable = viewModel.$completedFetchCount.sink { count in
                guard !box.fulfilled, count == target else { return }
                box.fulfilled = true
                let pending = box.continuation
                box.continuation = nil
                box.cancellable?.cancel()
                box.cancellable = nil
                pending?.resume()
            }
            if box.fulfilled {
                box.cancellable?.cancel()
                box.cancellable = nil
            }
        }
    }

    private func fetchCount(_ runtime: NativeWindowRuntime) -> Int {
        runtime.store.state.window?.diary.diary.completedFetchCount ?? -1
    }

    /// Deterministic rendezvous on any store state predicate. No polling and no
    /// duration: the nested MainActor task runs after the change has landed.
    private func awaitStoreCondition(
        _ store: StoreOf<AppFeature>,
        condition: @escaping @MainActor (AppFeature.State) -> Bool
    ) async {
        if condition(store.state) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = CountBox()
            box.continuation = continuation
            box.cancellable = store.publisher.sink { _ in
                Task { @MainActor in
                    guard !box.fulfilled, condition(store.state) else { return }
                    box.fulfilled = true
                    let pending = box.continuation
                    box.continuation = nil
                    box.cancellable?.cancel()
                    box.cancellable = nil
                    pending?.resume()
                }
            }
            if box.fulfilled {
                box.cancellable?.cancel()
                box.cancellable = nil
            }
        }
    }

    private func activeEditorID(_ coordinator: AppShellCoordinator) -> String? {
        guard case .logEditor(let id) = coordinator.navigationState.activePane else { return nil }
        return id
    }

    /// Waits on the persistent store's own publisher for an exact absolute
    /// fetch count. The nested MainActor task runs after the state change has
    /// landed, so this is a rendezvous, not a timeout or a yield poll.
    private func awaitStoreFetchCount(_ runtime: NativeWindowRuntime, equals target: Int) async {
        if fetchCount(runtime) == target { return }
        let observed = runtime.store
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = CountBox()
            box.continuation = continuation
            box.cancellable = observed.publisher.sink { _ in
                Task { @MainActor in
                    let current = observed.state.window?.diary.diary.completedFetchCount ?? -1
                    guard !box.fulfilled, current == target else { return }
                    box.fulfilled = true
                    let pending = box.continuation
                    box.continuation = nil
                    box.cancellable?.cancel()
                    box.cancellable = nil
                    pending?.resume()
                }
            }
            if box.fulfilled {
                box.cancellable?.cancel()
                box.cancellable = nil
            }
        }
    }

    private func makeCoordinator(
        ownership: DiaryScreenOwnership = .legacy,
        diaryService: (any DiaryServicing)? = nil
    ) -> AppShellCoordinator {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-editor-direct", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-editor-direct", displayName: "Alice")
        )
        let coordinatorSession = SessionCoordinator(
            service: EditorSessionService(session: session),
            cookieBaseURL: baseURL,
            cookieClearer: EditorCookieClearer()
        )
        return AppShellCoordinator(
            client: CalCoAPIClient(baseURL: baseURL),
            session: coordinatorSession,
            diaryService: diaryService ?? EditorDiaryService(logsByDate: [:]),
            logSubmissionStore: makeIsolatedStore(),
            logSubmissionService: LogSubmissionService(
                sender: StubSubmissionSender(logs: [])
            ),
            diaryScreenOwnership: ownership,
            todayProvider: { self.today }
        )
    }

    private func makeIsolatedStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-editor-bridge-\(UUID().uuidString)", isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }

    private func signedInGeneration(_ coordinator: AppShellCoordinator) async -> UInt64 {
        let phase = await coordinator.start()
        guard case .signedIn = phase else {
            XCTFail("Expected signed in, got \(phase)")
            return 0
        }
        guard let viewModel = coordinator.diaryViewModel else {
            XCTFail("Missing legacy bootstrap view model")
            return 0
        }
        await awaitLegacyFetchCount(viewModel, equals: 1)
        return coordinator.session.sessionGeneration
    }
}

// MARK: - Doubles

private final class CountBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
    var continuation: CheckedContinuation<Void, Never>?
    var fulfilled = false
}

private final class EditorSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession
    init(session: LoginSession) { self.session = session }
    func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
    func login(username: String, password: String) async throws -> LoginSession { session }
    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class EditorCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private final class StubSubmissionSender: LogSubmissionSending, @unchecked Sendable {
    private let logs: [FoodLog]
    init(logs: [FoodLog]) { self.logs = logs }
    func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] { logs }
}

/// TEST-ONLY rendezvous for one authoritative read. A test can hold a stale
/// snapshot in flight while a tombstone is applied, proving the reconciled day
/// cannot resurrect it. All hand-off state is NSLock-protected; no continuation
/// is resumed under the lock and every resume is one-shot, including the
/// cancellation-before-start path.
private final class HeldFetchGate: @unchecked Sendable {
    private final class State {
        let snapshot: DiaryDay
        var started = false
        var startCancelled = false
        var startWaiter: CheckedContinuation<Void, Never>?
        var releaseWaiter: CheckedContinuation<DiaryDay, Error>?
        var outcome: Result<DiaryDay, Error>?
        init(snapshot: DiaryDay) { self.snapshot = snapshot }
    }

    private let lock = NSLock()
    private let state: State

    init(snapshot: DiaryDay) { state = State(snapshot: snapshot) }

    /// Called by the service when the armed fetch actually begins.
    func signalStart() {
        lock.lock()
        state.started = true
        let waiter = state.startWaiter
        state.startWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    /// Waits for the armed read to begin. The sticky `started` flag makes a late
    /// install unable to miss the signal; cancellation resumes exactly once.
    func waitForStart() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if state.started || state.startCancelled {
                    lock.unlock()
                    c.resume()
                    return
                }
                state.startWaiter = c
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            state.startCancelled = true
            let waiter = state.startWaiter
            state.startWaiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    /// Suspends the held fetch until the test releases the stale snapshot.
    func waitForRelease() async throws -> DiaryDay {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<DiaryDay, Error>) in
                lock.lock()
                if let outcome = state.outcome {
                    lock.unlock()
                    c.resume(with: outcome)
                    return
                }
                state.releaseWaiter = c
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard state.outcome == nil, let waiter = state.releaseWaiter else {
                lock.unlock()
                return
            }
            state.outcome = .failure(CancellationError())
            state.releaseWaiter = nil
            lock.unlock()
            waiter.resume(throwing: CancellationError())
        }
    }

    /// Frees the held fetch with the pre-seeded stale snapshot, exactly once.
    func release() {
        lock.lock()
        guard state.outcome == nil else { lock.unlock(); return }
        let outcome = Result<DiaryDay, Error>.success(state.snapshot)
        state.outcome = outcome
        let waiter = state.releaseWaiter
        state.releaseWaiter = nil
        lock.unlock()
        waiter?.resume(with: outcome)
    }
}

private final class EditorDiaryService: DiaryServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let logsByDate: [LocalDiaryDate: [DiaryLog]]
    private var fetchCountStorage = 0
    private var updateCountStorage = 0
    private var armedGate: (date: LocalDiaryDate, gate: HeldFetchGate)?

    init(logsByDate: [LocalDiaryDate: [DiaryLog]]) { self.logsByDate = logsByDate }

    var fetchCallCount: Int { lock.withLock { fetchCountStorage } }
    var updateCallCount: Int { lock.withLock { updateCountStorage } }

    /// Opt-in only: arms the next fetch for `date` to block on `gate` and then
    /// return the supplied stale snapshot. Default fetches stay immediate.
    func holdNextFetch(for date: LocalDiaryDate, returning snapshot: DiaryDay) -> HeldFetchGate {
        let gate = HeldFetchGate(snapshot: snapshot)
        lock.lock()
        armedGate = (date, gate)
        lock.unlock()
        return gate
    }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        lock.lock()
        fetchCountStorage += 1
        var gate: HeldFetchGate?
        if let armed = armedGate, armed.date == date {
            gate = armed.gate
            armedGate = nil
        }
        lock.unlock()
        guard let gate else {
            return DiaryDay(date: date, logs: logsByDate[date] ?? [])
        }
        gate.signalStart()
        return try await gate.waitForRelease()
    }

    func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog {
        lock.withLock { updateCountStorage += 1 }
        let amount = request.quantity?.amount ?? "100"
        return DiaryLog(
            id: id,
            mealSlot: .breakfast,
            title: "Bridged Apple",
            calories: Double(amount) ?? 100,
            quantity: NutritionQuantity(amount: amount, unit: request.quantity?.unit ?? "g")
        )
    }

    func deleteLog(id: String) async throws {}
}

private final class HeldUpdateDiaryService: DiaryServicing, @unchecked Sendable {
    private final class Waiter {
        var start: CheckedContinuation<Void, Never>?
        var response: CheckedContinuation<DiaryLog, Error>?
        var pending: DiaryLog?
        var started = false
    }

    private let lock = NSLock()
    private let logsByDate: [LocalDiaryDate: [DiaryLog]]
    private let waiter = Waiter()
    private var fetchCountStorage = 0
    private var updateCountStorage = 0

    init(logsByDate: [LocalDiaryDate: [DiaryLog]]) { self.logsByDate = logsByDate }

    var fetchCallCount: Int { lock.withLock { fetchCountStorage } }
    var updateCallCount: Int { lock.withLock { updateCountStorage } }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        lock.withLock { fetchCountStorage += 1 }
        return DiaryDay(date: date, logs: logsByDate[date] ?? [])
    }

    func waitForUpdateStart() async {
        lock.lock()
        if waiter.started { lock.unlock(); return }
        let pending = waiter.start
        lock.unlock()
        if let pending { return pending.resume() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if waiter.started { lock.unlock(); c.resume(); return }
            waiter.start = c
            lock.unlock()
        }
    }

    func finishUpdate(returning log: DiaryLog) {
        lock.lock()
        let response = waiter.response
        waiter.response = nil
        if response == nil { waiter.pending = log }
        lock.unlock()
        response?.resume(returning: log)
    }

    func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog {
        lock.lock()
        updateCountStorage += 1
        waiter.started = true
        let starter = waiter.start
        waiter.start = nil
        lock.unlock()
        starter?.resume()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<DiaryLog, Error>) in
            lock.lock()
            if let pending = waiter.pending {
                waiter.pending = nil
                lock.unlock()
                c.resume(returning: pending)
            } else {
                waiter.response = c
                lock.unlock()
            }
        }
    }

    func deleteLog(id: String) async throws {}
}

private final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveriesStorage: [DiaryMutationDelivery] = []
    private var continuation: CheckedContinuation<Void, Never>?

    var deliveries: [DiaryMutationDelivery] {
        lock.lock(); defer { lock.unlock() }; return deliveriesStorage
    }

    func record(_ delivery: DiaryMutationDelivery) {
        lock.lock()
        deliveriesStorage.append(delivery)
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func waitForFirst() async {
        lock.lock()
        let alreadyDone = !deliveriesStorage.isEmpty
        lock.unlock()
        guard !alreadyDone else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if deliveriesStorage.isEmpty {
                continuation = c
                lock.unlock()
            } else {
                lock.unlock()
                c.resume()
            }
        }
    }
}

