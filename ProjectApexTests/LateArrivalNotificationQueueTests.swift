// LateArrivalNotificationQueueTests.swift
// ProjectApexTests — Phase 2 / Slice A3 / issue #74
//
// Round-trip tests for the UserDefaults-backed LateArrivalNotificationQueue.
// The queue is the producer↔consumer seam between TraineeModelUpdateJob
// (enqueues on late_arrival:true) and PostWorkoutSummaryView (dequeues
// on .task). This test class exercises the queue itself; the WAQ-side
// contract is in TraineeModelUpdateJobTests.

import XCTest
@testable import ProjectApex

@MainActor
final class LateArrivalNotificationQueueTests: XCTestCase {

    // MARK: - Helpers

    /// Uses the production `lockedMessage` constant so this test class
    /// does not double as a drift detector — that role is owned by
    /// `TraineeModelUpdateJobTests.test_flushHandler_onLateArrivalTrue_enqueuesNotificationWithLockedCopy`,
    /// which hardcodes the literal verbatim.
    private func makeFixture(
        id: UUID = UUID(),
        receiptDate: Date = Date()
    ) -> LateArrivalNotification {
        LateArrivalNotification(
            id: id,
            message: LateArrivalNotification.lockedMessage,
            receiptDate: receiptDate,
            sessionId: nil,
            incomingLoggedAt: nil,
            watermark: nil
        )
    }

    // MARK: - Round-trip

    /// Single enqueue → dequeueAll yields the exact notification, queue
    /// becomes empty afterwards. The minimum contract the post-session
    /// summary surface depends on.
    func test_enqueueThenDequeueAll_returnsTheNotification_andEmptiesQueue() {
        let queue        = LateArrivalNotificationQueue.makeInMemory()
        let notification = makeFixture()

        XCTAssertEqual(queue.pendingCount, 0, "fresh queue must start empty")

        queue.enqueue(notification)
        XCTAssertEqual(queue.pendingCount, 1)

        let dequeued = queue.dequeueAll()
        XCTAssertEqual(dequeued, [notification],
                       "dequeueAll must return the exact enqueued notification (Codable round-trip)")
        XCTAssertEqual(queue.pendingCount, 0,
                       "dequeueAll must atomically clear — second call returns nothing")

        XCTAssertEqual(queue.dequeueAll(), [],
                       "subsequent dequeue on an emptied queue must return []")
    }

    /// Multiple enqueues are preserved in FIFO order, all returned in one
    /// dequeueAll call. This is the contract the UI relies on when
    /// rendering the banner stack.
    func test_multipleEnqueues_dequeueAllReturnsAllInOrder() {
        let queue = LateArrivalNotificationQueue.makeInMemory()
        let n1    = makeFixture()
        let n2    = makeFixture()
        let n3    = makeFixture()

        queue.enqueue(n1)
        queue.enqueue(n2)
        queue.enqueue(n3)

        let dequeued = queue.dequeueAll()
        XCTAssertEqual(dequeued, [n1, n2, n3],
                       "FIFO order must be preserved across enqueue/dequeue (Codable round-trip preserves field order)")
    }

    /// Two queues with different in-memory backing stores must NOT see
    /// each other's notifications — verifies makeInMemory()'s isolation
    /// guarantee so concurrent tests don't leak state.
    func test_makeInMemory_isolatesQueuesAcrossInstances() {
        let q1 = LateArrivalNotificationQueue.makeInMemory()
        let q2 = LateArrivalNotificationQueue.makeInMemory()

        q1.enqueue(makeFixture())
        XCTAssertEqual(q1.pendingCount, 1)
        XCTAssertEqual(q2.pendingCount, 0,
                       "q2 must NOT see q1's enqueue — each makeInMemory() call gets its own UserDefaults suite")
    }
}
