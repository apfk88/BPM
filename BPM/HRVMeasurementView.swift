//
//  HRVMeasurementView.swift
//  BPM
//
//  Created for HRV measurement feature
//

import SwiftUI

struct HRVMeasurementView: View {
    @ObservedObject var viewModel: HRVMeasurementViewModel
    @EnvironmentObject var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject var sharingService: SharingService
    var onDismiss: () -> Void
    @State private var showClearAlert = false
    @State private var showStopAlert = false
    @State private var showDevicePicker = false
    @State private var showFirstTimeAlert = false
    @State private var hasShownFirstTimeAlert = false
    @State private var pendingMeasurement = false
    
    private var displayedHeartRate: Int? {
        if sharingService.isViewing {
            return sharingService.friendHeartRate
        } else {
            return bluetoothManager.currentHeartRate
        }
    }
    
    private var heartButtonColor: Color {
        if bluetoothManager.hasActiveDataSource {
            return .green
        } else if sharingService.isViewing {
            return .green
        } else {
            return .white
        }
    }

    private var heartIconName: String {
        bluetoothManager.hasActiveDataSource ? "heart.fill" : "heart"
    }
    
    private var buttonText: String {
        if viewModel.hasError {
            return "OK"
        } else if viewModel.isCompleted {
            return "Measure HRV"
        } else if case .countingDown = viewModel.state {
            return "Measuring..."
        } else {
            return "Measure HRV"
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Top bar with device picker and close button
                    HStack {
                        Button {
                            showDevicePicker = true
                        } label: {
                            Image(systemName: heartIconName)
                                .font(.system(size: 20))
                                .foregroundColor(heartButtonColor)
                                .padding(12)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        Button {
                            if viewModel.isCompleted {
                                showClearAlert = true
                            } else if case .countingDown = viewModel.state {
                                showStopAlert = true
                            } else {
                                viewModel.reset()
                                onDismiss()
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .sheet(isPresented: $showDevicePicker) {
                        DevicePickerView()
                            .environmentObject(bluetoothManager)
                            .environmentObject(sharingService)
                    }
                    .alert("Stop Measurement", isPresented: $showStopAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Stop", role: .destructive) {
                            viewModel.reset()
                            onDismiss()
                        }
                    } message: {
                        Text("Are you sure you want to stop the measurement? All progress will be lost.")
                    }
                    .alert("Clear Measurement", isPresented: $showClearAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear", role: .destructive) {
                            viewModel.reset()
                            onDismiss()
                        }
                    } message: {
                        Text("Are you sure you want to clear the existing measurement? This cannot be undone.")
                    }
                    .alert("Starting Measurement", isPresented: $showFirstTimeAlert) {
                        Button("OK") {
                            hasShownFirstTimeAlert = true
                            if pendingMeasurement {
                                viewModel.startMeasurement()
                                pendingMeasurement = false
                            }
                        }
                    } message: {
                        Text("Lay down, close your eyes, and keep the app open.")
                    }
                    
                    Spacer()
                    
                    // Main display area
                    VStack(spacing: 40) {
                        // Timer/HRV display - fixed position
                        VStack(spacing: 16) {
                            if viewModel.hasError {
                                // Show error message
                                VStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 48))
                                        .foregroundColor(.orange)
                                    
                                    if let errorMessage = viewModel.errorMessage {
                                        Text(errorMessage)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(.white)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 40)
                                    }
                                }
                            } else if viewModel.isCompleted {
                                // Show HRV value in same position as timer
                                if let hrv = viewModel.hrvValue {
                                    Text("\(Int(hrv.rounded()))ms")
                                        .font(.system(size: min(geometry.size.width * 0.4, geometry.size.height * 0.3), weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .minimumScaleFactor(0.5)
                                        .lineLimit(1)
                                } else {
                                    Text("---")
                                        .font(.system(size: min(geometry.size.width * 0.4, geometry.size.height * 0.3), weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                }
                            } else {
                                // Show countdown timer
                                Text(formatTime(viewModel.remainingTime))
                                    .font(.system(size: min(geometry.size.width * 0.4, geometry.size.height * 0.3), weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            
                            // Stats bar - BPM, Min, Max (BPM becomes avg when completed)
                            // Only show stats if not in error state
                            if !viewModel.hasError {
                                HStack(spacing: 20) {
                                    statColumn(
                                        title: viewModel.isCompleted ? "Avg" : "BPM",
                                        value: viewModel.isCompleted ? viewModel.avgHeartRate : viewModel.currentBPM,
                                        scaleFactor: 1.0
                                    )
                                    
                                    Spacer()
                                    
                                    statColumn(
                                        title: "Min",
                                        value: viewModel.minHeartRate,
                                        scaleFactor: 1.0
                                    )
                                    
                                    Spacer()
                                    
                                    statColumn(
                                        title: "Max",
                                        value: viewModel.maxHeartRate,
                                        scaleFactor: 1.0
                                    )
                                }
                                .padding(.horizontal, 40)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Measure HRV button
                    Button {
                        if viewModel.hasError {
                            // If there's an error, reset to try again
                            viewModel.reset()
                        } else if case .idle = viewModel.state {
                            // Check if this is the first measurement in this session
                            if !hasShownFirstTimeAlert {
                                showFirstTimeAlert = true
                                pendingMeasurement = true
                            } else {
                                // Start new measurement
                                viewModel.startMeasurement()
                            }
                        } else if viewModel.isCompleted {
                            // Start new measurement (clears existing one automatically)
                            viewModel.startMeasurement()
                        }
                    } label: {
                        Text(buttonText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(viewModel.state == .countingDown ? Color.gray.opacity(0.3) : Color.gray.opacity(0.5))
                            .cornerRadius(12)
                    }
                    .disabled(viewModel.state == .countingDown)
                    .padding(.horizontal, 40)
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 40)
                }
            }
        }
        .onAppear {
            // Reset first time alert flag for new session
            hasShownFirstTimeAlert = false
            
            // Set up heart rate callback
            viewModel.currentHeartRate = { [weak bluetoothManager, weak sharingService] in
                if sharingService?.isViewing == true {
                    return sharingService?.friendHeartRate
                } else {
                    return bluetoothManager?.currentHeartRate
                }
            }
            
            // Set up RR intervals callback
            viewModel.getRRIntervals = { [weak bluetoothManager] in
                guard let bluetoothManager = bluetoothManager else { return [] }
                // Only return RR intervals if not viewing shared data
                if sharingService.isViewing {
                    return []
                }
                return bluetoothManager.rrIntervals
            }
            
            // Set up RR intervals support check callback
            viewModel.supportsRRIntervals = { [weak bluetoothManager] in
                guard let bluetoothManager = bluetoothManager else { return false }
                // Only check support if not viewing shared data
                if sharingService.isViewing {
                    return false
                }
                return bluetoothManager.supportsRRIntervals
            }
            
            // Start live heart rate updates
            viewModel.startLiveHeartRateUpdates()
        }
        .onDisappear {
            // Stop live heart rate updates when view disappears
            viewModel.stopLiveHeartRateUpdates()
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func statColumn(title: String, value: Int?, customText: String? = nil, scaleFactor: Double = 1.0) -> some View {
        VStack(spacing: 4 * scaleFactor) {
            Text(title)
                .font(.system(size: 20 * scaleFactor, weight: .semibold))
                .foregroundColor(.gray)
            Text(customText ?? value.map(String.init) ?? "---")
                .font(.system(size: 36 * scaleFactor, weight: .bold, design: .monospaced))
                .foregroundColor((value == nil && customText == nil) ? .gray : .white)
                .frame(minWidth: 80 * scaleFactor, alignment: .center) // Fixed minimum width for 3 digits
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 80 * scaleFactor, alignment: .center) // Fixed width to prevent layout shifts
    }
}

