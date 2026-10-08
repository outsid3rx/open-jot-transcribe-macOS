// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import JotCore

final class ExternalAPITests: XCTestCase {
    @MainActor func testExternalAPIContractsWithoutNetwork() async throws {
        let passed = try await APIContractChecks.run()
        XCTAssertEqual(passed.count, 18)
    }
}
