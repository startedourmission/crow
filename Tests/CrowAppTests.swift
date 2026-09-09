import XCTest
@testable import Crow

final class CrowAppTests: XCTestCase {
    @MainActor
    func testModelBootstrapsLocalWorkspace() {
        let model = AppModel()
        XCTAssertFalse(model.workspaces.isEmpty)
        XCTAssertEqual(model.selectedWorkspace.kind, .local)
        XCTAssertFalse(model.files.isEmpty)
    }
}
