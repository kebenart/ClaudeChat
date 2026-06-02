// Tests/ChatKitTests/UISessionListViewModelTests.swift
import XCTest
@testable import ChatKit
@testable import ChatKitUI

@MainActor
final class UISessionListViewModelTests: XCTestCase {

    // MARK: - allSessions

    private func conv(_ id: String, pinned: Bool = false, deleted: Bool = false) -> ImConversationDTO {
        ImConversationDTO(id: id, contactId: "/p", providerId: "claude", title: id,
                          lastMessagePreview: nil, lastSeq: 1, lastActivityAt: 1,
                          isPinned: pinned, isMuted: false, note: nil,
                          isFolded: false, isDeleted: deleted)
    }

    func testAllSessionsIncludesDeletedDimmed() async {
        let vm = SessionListViewModel(storage: StubStorage())
        await vm.refreshAll(conversations: [conv("v1"), conv("h1", deleted: true)])

        XCTAssertEqual(vm.allSessions.count, 2)
        XCTAssertTrue(vm.allSessions.contains { $0.id == "h1" && $0.isHidden })
        XCTAssertTrue(vm.allSessions.contains { $0.id == "v1" && !$0.isHidden })
    }

    func testAllSessionsIsDistinctFromRows() async {
        let vm = SessionListViewModel(storage: StubStorage())
        // The visible row is pinned so retention keeps it; the deleted one is
        // filtered from rows but still listed (dimmed) in allSessions.
        await vm.refresh(conversations: [conv("v1", pinned: true), conv("h1", deleted: true)],
                         unreadCounts: [:])
        await vm.refreshAll(conversations: [conv("v1", pinned: true), conv("h1", deleted: true)])

        XCTAssertEqual(vm.rows.count, 1,         "rows should only show non-deleted")
        XCTAssertEqual(vm.allSessions.count, 2,  "allSessions should include the deleted one")
    }

    // MARK: - searchResults

    func testSearchResultsNilWhenSearchEmpty() async {
        let storage = StubStorage()
        let vm = SessionListViewModel(storage: storage)
        vm.searchText = ""
        await vm.refresh(sessions: [], unreadCounts: [:])
        XCTAssertNil(vm.searchResults)
    }

    func testSearchResultsPopulatedWhenSearchHasText() async {
        let storage = StubStorage()
        let session = SessionInfo(id: "s1", projectPath: "/p", title: "Hello world", lastActivityAt: Date())
        await storage.upsertSessions([session])

        let vm = SessionListViewModel(storage: storage)
        vm.searchText = "Hello"
        await vm.refresh(sessions: [session], unreadCounts: [:])
        XCTAssertNotNil(vm.searchResults)
        XCTAssertTrue(vm.searchResults!.matchingSessions.contains { $0.id == "s1" })
    }

    func testClearSearchResetsSearchResults() async {
        let storage = StubStorage()
        let vm = SessionListViewModel(storage: storage)
        vm.searchText = "query"
        await vm.refresh(sessions: [], unreadCounts: [:])
        vm.clearSearch()
        XCTAssertNil(vm.searchResults)
    }
}
