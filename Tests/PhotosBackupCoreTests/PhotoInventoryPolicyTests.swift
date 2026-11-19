import XCTest
@testable import PhotosBackupCore

final class PhotoInventoryPolicyTests: XCTestCase {
    func testDefaultPolicyIncludesHiddenAssetsAndEveryBurstFrame() {
        let policy = PhotoInventoryPolicy.completeAccessibleLibrary
        XCTAssertTrue(policy.includeHiddenAssets)
        XCTAssertTrue(policy.includeAllBurstAssets)
        XCTAssertFalse(policy.includesRecentlyDeleted)
        XCTAssertFalse(policy.sharedAlbumCoverageVerified)
    }

    func testFullSizeVideoMappingIsSharedForImageLivePhotoInventoryAndResolution() {
        XCTAssertEqual(PhotoCurrentResourcePolicy.kind(resourceType: "fullSizeVideo", assetIsImage: true), "paired-video")
        XCTAssertEqual(PhotoCurrentResourcePolicy.kind(resourceType: "fullSizePairedVideo", assetIsImage: true), "paired-video")
        XCTAssertEqual(PhotoCurrentResourcePolicy.matchingTypes(kind: "paired-video", assetIsImage: true),
                       ["fullSizeVideo", "fullSizePairedVideo"])
        XCTAssertEqual(PhotoCurrentResourcePolicy.matchingTypes(kind: "video", assetIsImage: false), ["fullSizeVideo"])
    }

    func testRenderedVideoBudgetMonitorStaysActiveBeforeExportStartsAndStopsAtTerminalStates() {
        XCTAssertTrue(ExportBudgetPolicy.shouldMonitor(.unknown))
        XCTAssertTrue(ExportBudgetPolicy.shouldMonitor(.waiting))
        XCTAssertTrue(ExportBudgetPolicy.shouldMonitor(.exporting))
        XCTAssertFalse(ExportBudgetPolicy.shouldMonitor(.completed))
        XCTAssertFalse(ExportBudgetPolicy.shouldMonitor(.failed))
        XCTAssertFalse(ExportBudgetPolicy.shouldMonitor(.cancelled))
        XCTAssertFalse(ExportBudgetPolicy.exceedsLimit(currentBytes: 1024, limit: 1024))
        XCTAssertTrue(ExportBudgetPolicy.exceedsLimit(currentBytes: 1025, limit: 1024))
    }
}
