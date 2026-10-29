import Foundation
import XCTest
@testable import Tendedero

/// Fork guard: neither update path may activate for the fork's bundle ID, even
/// if every official update key were copied into its Info.plist.
@MainActor
final class ForkUpdateIsolationTests: XCTestCase {
    private let forkBundleID = "io.github.selcukozbilgi.clipboardline"

    /// Official channel keys, so only the bundle ID decides the outcome.
    private func info(bundleID: String) -> [String: Any] {
        ["CFBundleIdentifier": bundleID,
         "ClipboardLinePublicUpdateRepository": PublicUpdateChannel.repository,
         "SUFeedURL": PublicUpdateChannel.feed,
         "SUPublicEDKey": PublicUpdateChannel.publicKey,
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
         "SUSignedFeedFailureExpirationInterval": 0,
         "SUAllowsAutomaticUpdates": false, "SUAutomaticallyUpdate": false,
         "SUEnableSystemProfiling": false,
         "ClipboardLineUpdateRepository": "orkunisitmak/clipboardline-desktop",
         "ClipboardLineUpdatePublicKey": Data(repeating: 7, count: 32).base64EncodedString()]
    }

    func testSparkleChannelStaysDisabledForForkBundleID() {
        XCTAssertNotNil(PublicUpdateChannel(info: info(bundleID: "local.clipboardline.review")), "fixture must be a valid official channel")
        XCTAssertNil(PublicUpdateChannel(info: info(bundleID: forkBundleID)))
        #if canImport(Sparkle)
        XCTAssertNil(SparkleUpdateDriver(defaults: UserDefaults(suiteName: "fork-update-isolation-\(UUID().uuidString)")!,
                                         info: info(bundleID: forkBundleID)))
        #endif
    }

    func testGitHubUpdaterStaysDisabledForForkBundleID() {
        XCTAssertNotNil(AppUpdateController.bundledConfiguration(info: info(bundleID: "local.clipboardline.review"), build: "78"),
                        "fixture must be a valid official configuration")
        XCTAssertNil(AppUpdateController.bundledConfiguration(info: info(bundleID: forkBundleID), build: "78"))
    }

    func testForkBuildInfoPlistHasNoUpdateFeed() {
        // Mirrors the Info.plist keys written by scripts/build-community.sh.
        let forkInfo: [String: Any] = ["CFBundleIdentifier": forkBundleID, "SUEnableAutomaticChecks": false,
                                       "SUAutomaticallyUpdate": false, "SUAllowsAutomaticUpdates": false]
        XCTAssertNil(PublicUpdateChannel(info: forkInfo))
        XCTAssertNil(AppUpdateController.bundledConfiguration(info: forkInfo, build: "125"))
    }
}
