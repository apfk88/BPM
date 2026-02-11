//
//  TimerViewModelTests.swift
//  BPMTests
//
//  Created by Codex.
//

import Testing
import Foundation
@testable import BPM

struct TimerViewModelTests {
    @Test func bellCountIsSingleForAllPhases() {
        #expect(TimerViewModel.bellCount(for: .work) == 1)
        #expect(TimerViewModel.bellCount(for: .rest) == 1)
        #expect(TimerViewModel.bellCount(for: .cooldown) == 1)
    }

    @Test @MainActor
    func presetStartUsesFiveSecondCountdownBeforeWorkBegins() {
        let viewModel = TimerViewModel(presetStartCountdownDuration: 0.25)
        let preset = TimerPreset(
            name: "Threshold 4x4",
            workDuration: 30,
            restDuration: 30,
            numberOfSets: 4,
            includeCooldown: false,
            playSound: false
        )

        viewModel.loadPreset(preset)
        viewModel.startPreset()

        #expect(viewModel.state == .running)
        #expect(viewModel.isPresetPrestartCountdownActive)
        #expect(viewModel.elapsedTime == 0)
        #expect(viewModel.presetPhaseTimeRemaining <= 0.25)
        #expect(viewModel.presetPhaseTimeRemaining > 0)

        runMainRunLoop(for: 0.15)
        #expect(viewModel.isPresetPrestartCountdownActive)
        #expect(viewModel.elapsedTime == 0)
        #expect(viewModel.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)) == nil)

        viewModel.reset()
    }

    @Test @MainActor
    func presetNameBecomesDefaultWorkoutTitleOnSave() {
        let viewModel = TimerViewModel(presetStartCountdownDuration: 0)
        let preset = TimerPreset(
            name: "Norwegian 4x4",
            workDuration: 30,
            restDuration: 30,
            numberOfSets: 4,
            includeCooldown: false,
            playSound: false
        )

        viewModel.loadPreset(preset)
        viewModel.startPreset()
        viewModel.stopPresetAndComplete()

        #expect(viewModel.defaultWorkoutTitle == "Norwegian 4x4")
        #expect(viewModel.isCompleted)

        viewModel.reset()
        #expect(viewModel.defaultWorkoutTitle == nil)
    }

    @MainActor
    private func runMainRunLoop(for duration: TimeInterval) {
        let endTime = Date().addingTimeInterval(duration)
        while Date() < endTime {
            RunLoop.main.run(mode: .default, before: endTime)
        }
    }
}
