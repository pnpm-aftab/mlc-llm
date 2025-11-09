//
//  EnergyMonitor.swift
//  MLCChat
//
//  Simple real-time energy consumption monitor using battery level monitoring
//

import Foundation
import UIKit

struct EnergySample: Encodable {
    let timestamp: Double  // Seconds since start
    let batteryLevel: Float  // 0.0 to 1.0
    let batteryState: String  // "charging", "unplugged", "full", "unknown"
    let thermalState: String  // "nominal", "fair", "serious", "critical"
    let energyMilliJoules: Double  // Calculated energy consumption
}

final class EnergyMonitor {
    private var samples: [EnergySample] = []
    private var startTime: Date?
    private var startBatteryLevel: Float = -1.0
    private var lastBatteryLevel: Float = -1.0
    private var lastSampleTime: Date?
    private var totalEnergyMilliJoules: Double = 0.0
    
    // Battery capacity estimates in mAh for different iPhone models
    // These are approximate values - actual capacity may vary
    private let batteryCapacityMilliAmpereHours: Double = 3000.0  // Typical iPhone capacity
    private let batteryVoltage: Double = 3.7  // Typical battery voltage (V)
    
    init() {
        // Enable battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true
    }
    
    func start() {
        samples.removeAll()
        totalEnergyMilliJoules = 0.0
        startTime = Date()
        lastSampleTime = startTime
        startBatteryLevel = UIDevice.current.batteryLevel
        lastBatteryLevel = startBatteryLevel
        
        // Record initial sample
        recordSample()
    }
    
    func stop() {
        // Record final sample
        recordSample()
    }
    
    func recordSample() {
        guard let startTime = startTime else { return }
        
        let now = Date()
        let timestamp = now.timeIntervalSince(startTime)
        let batteryLevel = UIDevice.current.batteryLevel
        let batteryState = getBatteryStateString()
        let thermalState = getThermalStateString()
        
        // Calculate energy consumed since last sample
        var energyDelta: Double = 0.0
        if lastBatteryLevel >= 0 && batteryLevel >= 0 && lastSampleTime != nil {
            let batteryDelta = Double(lastBatteryLevel - batteryLevel)
            let timeDelta = now.timeIntervalSince(lastSampleTime!)
            
            if batteryDelta > 0 && timeDelta > 0 {
                // Energy = Battery Capacity (mAh) × Voltage (V) × Battery Level Change
                // Convert mAh to mJ: mAh × V × 3600 = mJ (since 1 Ah = 3600 C, and 1 J = 1 C × 1 V)
                // Total battery capacity in mJ = mAh × V × 3600
                let totalCapacityMilliJoules = batteryCapacityMilliAmpereHours * batteryVoltage * 3600.0
                // Energy consumed = capacity × battery level change
                energyDelta = totalCapacityMilliJoules * batteryDelta
                totalEnergyMilliJoules += energyDelta
            }
        }
        
        let sample = EnergySample(
            timestamp: timestamp,
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            thermalState: thermalState,
            energyMilliJoules: totalEnergyMilliJoules
        )
        
        samples.append(sample)
        lastBatteryLevel = batteryLevel
        lastSampleTime = now
    }
    
    func getTotalEnergyMilliJoules() -> Double {
        return totalEnergyMilliJoules
    }
    
    func getSamples() -> [EnergySample] {
        return samples
    }
    
    private func getBatteryStateString() -> String {
        switch UIDevice.current.batteryState {
        case .charging:
            return "charging"
        case .unplugged:
            return "unplugged"
        case .full:
            return "full"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
    
    private func getThermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}

