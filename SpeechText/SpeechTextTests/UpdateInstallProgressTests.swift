// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

final class UpdateInstallProgressTests: XCTestCase {

    func testStartsIdleWithNoFraction() {
        XCTAssertEqual(UpdateInstallProgress().status, .idle)
        XCTAssertNil(UpdateInstallStatus.idle.fraction)
    }

    func testDownloadCountsChunksAgainstTheExpectedLength() {
        var progress = UpdateInstallProgress()
        progress.downloadStarted()
        XCTAssertEqual(progress.status, .downloading(percent: nil))
        progress.expectedLengthReceived(1_000)
        XCTAssertEqual(progress.status, .downloading(percent: 0))
        progress.dataReceived(250)
        progress.dataReceived(150)
        XCTAssertEqual(progress.status, .downloading(percent: 40))
        XCTAssertEqual(progress.status.fraction, 0.4)
    }

    func testAChunkThatDoesNotReachAWholePercentLeavesTheStatusAlone() {
        var progress = UpdateInstallProgress()
        progress.downloadStarted()
        progress.expectedLengthReceived(1_000_000)
        progress.dataReceived(9_999)
        XCTAssertEqual(progress.status, .downloading(percent: 0))
    }

    func testAnUnknownLengthStaysWithoutAPercent() {
        var progress = UpdateInstallProgress()
        progress.downloadStarted()
        progress.expectedLengthReceived(0)
        progress.dataReceived(4_096)
        XCTAssertEqual(progress.status, .downloading(percent: nil))
        XCTAssertNil(progress.status.fraction)
    }

    func testMoreBytesThanStatedStopAtFull() {
        var progress = UpdateInstallProgress()
        progress.downloadStarted()
        progress.expectedLengthReceived(100)
        progress.dataReceived(150)
        XCTAssertEqual(progress.status, .downloading(percent: 100))
    }

    func testASecondDownloadStartsFromZero() {
        var progress = UpdateInstallProgress()
        progress.downloadStarted()
        progress.expectedLengthReceived(100)
        progress.dataReceived(90)
        progress.downloadStarted()
        progress.expectedLengthReceived(100)
        progress.dataReceived(10)
        XCTAssertEqual(progress.status, .downloading(percent: 10))
    }

    func testExtractionIsClampedToWholePercents() {
        var progress = UpdateInstallProgress()
        progress.extractionStarted()
        XCTAssertEqual(progress.status, .extracting(percent: 0))
        progress.extractionProgressed(0.259)
        XCTAssertEqual(progress.status, .extracting(percent: 25))
        progress.extractionProgressed(1.5)
        XCTAssertEqual(progress.status, .extracting(percent: 100))
    }

    func testTheLastStagesAndAReset() {
        var progress = UpdateInstallProgress()
        progress.readyToInstall()
        XCTAssertEqual(progress.status, .readyToInstall)
        XCTAssertEqual(progress.status.fraction, 1)
        progress.installationStarted()
        XCTAssertEqual(progress.status, .installing)
        XCTAssertNil(progress.status.fraction)
        progress.reset()
        XCTAssertEqual(progress, UpdateInstallProgress())
    }
}
