// SPDX-License-Identifier: Apache-2.0

import Foundation

@main enum APIContractMain {
    @MainActor static func main() async throws {
        let passed = try await APIContractChecks.run()
        for check in passed { print("PASS: \(check)") }
        print("\(passed.count) contract checks passed. No external requests or Keychain access.")
    }
}
