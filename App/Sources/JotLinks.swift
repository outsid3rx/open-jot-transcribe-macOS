// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Every outbound link in one place, so the About panel, the Settings pane and
/// the docs can never drift apart.
enum JotLinks {
    static let authorName = "Max Zernyaev"
    static let author = URL(string: "https://github.com/outsid3rx")!
    static let repository = URL(string: "https://github.com/outsid3rx/open-jot-transcribe-macOS")!
    static let issues = repository.appendingPathComponent("issues")
    static let privacy = repository.appendingPathComponent("blob/main/docs/PRIVACY.md")
    static let originalRepository = URL(string: "https://github.com/google-gemini/jot-gemini-transcribe-macOS")!
}
