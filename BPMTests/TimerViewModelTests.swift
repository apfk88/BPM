//
//  TimerViewModelTests.swift
//  BPMTests
//
//  Created by Codex.
//

import Testing
@testable import BPM

struct TimerViewModelTests {
    @Test func bellCountIsSingleForAllPhases() {
        #expect(TimerViewModel.bellCount(for: .work) == 1)
        #expect(TimerViewModel.bellCount(for: .rest) == 1)
        #expect(TimerViewModel.bellCount(for: .cooldown) == 1)
    }
}
