import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testInfraSmoke() {
    // STEP 0 infra probe (#66) -- confirms the RunnerTests target actually
    // RUNS via `xcodebuild test` in this environment before authoring the
    // real AR-math tests. See ios/RunnerTests/RockRegistrationEngineTests.swift.
    XCTAssertTrue(true)
  }

}
