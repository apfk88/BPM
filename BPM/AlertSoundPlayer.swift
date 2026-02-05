//
//  AlertSoundPlayer.swift
//  BPM
//

import AVFoundation

final class AlertSoundPlayer {
    static let shared = AlertSoundPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private let amplitude: Float = 0.6
    private let queue = DispatchQueue(label: "bpm.alert-sound-player")

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func playBpmAscending() {
        playSequence(frequencies: [660, 880], toneDuration: 0.12, gap: 0.06)
    }

    func playBpmDescending() {
        playSequence(frequencies: [880, 660], toneDuration: 0.12, gap: 0.06)
    }

    func playZoneCount(_ count: Int) {
        guard count > 0 else { return }
        let tones = Array(repeating: 520.0, count: count)
        playSequence(frequencies: tones, toneDuration: 0.10, gap: 0.10)
    }

    private func playSequence(frequencies: [Double], toneDuration: TimeInterval, gap: TimeInterval) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureEngineRunning()

            var delay: TimeInterval = 0
            for frequency in frequencies {
                let buffer = self.makeBuffer(frequency: frequency, duration: toneDuration)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
                }
                delay += toneDuration + gap
            }
        }
    }

    private func ensureEngineRunning() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            if !player.isPlaying {
                player.play()
            }
        } catch {
            engine.stop()
        }
    }

    private func makeBuffer(frequency: Double, duration: TimeInterval) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let sample = sin(2.0 * Double.pi * frequency * Double(i) / sampleRate)
            channel[i] = Float(sample) * amplitude
        }
        return buffer
    }
}
