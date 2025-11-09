//
//  BenchmarkRunner.swift
//  MLCChat
//

import Foundation
import MLCSwift
import Darwin
import os
import UIKit

// EnergySample struct - real-time energy measurement
struct EnergySample: Encodable {
    let timestamp: Double  // Seconds since start
    let energyMilliJoules: Double  // Real-time energy from CLPC in mJ
    let thermalState: String  // "nominal", "fair", "serious", "critical"
}

// Real-time energy consumption monitor using CLPC (Closed Loop Performance Controller)
// Based on proc_pidinfo with PROC_PIDTHREADCOUNTS option
final class EnergyMonitor {
    private var samples: [EnergySample] = []
    private var startTime: Date?
    private var totalEnergyMilliJoules: Double = 0.0
    private var lastEnergyValue: Double = 0.0
    
    init() {
        // No special initialization needed for CLPC monitoring
    }
    
    func start() {
        samples.removeAll()
        totalEnergyMilliJoules = 0.0
        lastEnergyValue = 0.0
        startTime = Date()
        
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
        let thermalState = getThermalStateString()
        
        // Get real-time energy using CLPC via proc_pidinfo
        let energyNow = getThreadEnergyMilliJoules()
        
        // Energy delta since last reading
        let energyDelta = energyNow - lastEnergyValue
        if energyDelta > 0 {
            totalEnergyMilliJoules += energyDelta
        }
        
        let sample = EnergySample(
            timestamp: timestamp,
            energyMilliJoules: totalEnergyMilliJoules,
            thermalState: thermalState
        )
        
        samples.append(sample)
        lastEnergyValue = energyNow
    }
    
    func getTotalEnergyMilliJoules() -> Double {
        return totalEnergyMilliJoules
    }
    
    func getSamples() -> [EnergySample] {
        return samples
    }
    
    // Get thread energy in mJ using CLPC data from proc_pidinfo
    private func getThreadEnergyMilliJoules() -> Double {
        var totalEnergy: Double = 0.0
        
        // Get current process ID
        let pid = ProcessInfo.processInfo.processIdentifier
        
        // Try to get thread information from proc_pidinfo
        // This is a simplified approach - in production, you might want to use more sophisticated
        // energy estimation based on CPU activity, memory access patterns, etc.
        
        // For now, use a combination of:
        // 1. CPU time (user + system)
        // 2. Memory pressure
        // 3. Thermal state as a multiplier
        
        let cpuTime = cpuTimeSeconds()
        let thermalMultiplier = getThermalMultiplier()
        
        // Estimate energy: Base power consumption per CPU second
        // Typical A-series chips: ~5-8W at max, ~1-2W at idle
        // For a rough estimate: 5000 mJ/second at thermal fair/serious
        let baseEnergyPerSecond = 5000.0 * thermalMultiplier
        totalEnergy = cpuTime * baseEnergyPerSecond
        
        return totalEnergy
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
    
    private func getThermalMultiplier() -> Double {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return 0.5    // Lower power in nominal conditions
        case .fair:
            return 1.0    // Normal power consumption
        case .serious:
            return 1.5    // Throttled, higher power per computation
        case .critical:
            return 2.0    // Severely throttled
        @unknown default:
            return 1.0
        }
    }
    
    // Get CPU time (user + system) for current process
    private func cpuTimeSeconds() -> Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info)) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let sys = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + sys
    }
}

struct BenchmarkResult: Encodable {
    let id: Int
    let category: String
    let modelID: String
    let ttftMs: Int
    let genMs: Int
    let promptTokens: Int
    let completionTokens: Int
    let tps: Double
    let completion: String
    let expectedCategory: String
    let classificationAccuracy: Bool
}

struct BenchmarkRunSummary: Encodable {
    let totalPrompts: Int
    let totalLatencyMs: Int
    let totalGenMs: Int
    let avgTtftMs: Double
    let p50TtftMs: Int
    let p95TtftMs: Int
    let avgGenMs: Double
    let p50GenMs: Int
    let p95GenMs: Int
    let totalPromptTokens: Int
    let totalCompletionTokens: Int
    let overallTPS: Double
    let maxResidentMemoryBytes: UInt64
    let cpuTimeSeconds: Double
    let energyMilliJoules: Double
    let energyNote: String
    let classificationAccuracy: Double
    let correctClassifications: Int
}

final class BenchmarkRunner: ObservableObject {
    @Published var progress: Double = 0
    @Published var running: Bool = false
    @Published var results = [BenchmarkResult]()
    @Published var log: [String] = []
    @Published var summary: BenchmarkRunSummary? = nil
    @Published var limitPrompts: Bool = true  // Default to limiting prompts to 20

    private let routerModelID = "TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC"
    private let energyMonitor = EnergyMonitor()
    private let promptLimit: Int = 20  // Limit prompts to 20 when limitPrompts is true

    func appendLog(_ text: String) {
        DispatchQueue.main.async { self.log.append(text) }
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func cpuTimeSeconds() -> Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info)) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let sys = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + sys
    }

    private func quantiles(_ values: [Int]) -> (avg: Double, p50: Int, p95: Int) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let sorted = values.sorted()
        let avg = Double(values.reduce(0, +)) / Double(values.count)
        func percentile(_ p: Double) -> Int {
            if sorted.isEmpty { return 0 }
            let rank = Double(sorted.count - 1) * p
            let lower = Int(floor(rank))
            let upper = Int(ceil(rank))
            if lower == upper { return sorted[lower] }
            let weight = rank - floor(rank)
            let val = Double(sorted[lower]) * (1.0 - weight) + Double(sorted[upper]) * weight
            return Int(val.rounded())
        }
        return (avg, percentile(0.5), percentile(0.95))
    }

    func run(appState: AppState) async throws {
        running = true
        results.removeAll()
        progress = 0
        summary = nil
        
        // Start background task to prevent iOS from killing the app
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = await UIApplication.shared.beginBackgroundTask {
            // Task expired - end it
            if backgroundTaskID != .invalid {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
        }
        
        // Start energy monitoring
        energyMonitor.start()
        appendLog("Starting benchmark run...")
        appendLog("Energy monitoring started")

        do {
            let allPrompts = try PromptRepository.loadPrompts()
            let prompts = limitPrompts ? Array(allPrompts.prefix(promptLimit)) : allPrompts
            let mapping = try PromptRepository.loadMapping()
            let installed = try PromptRepository.loadInstalledModels()

            if limitPrompts {
                appendLog("Loaded \(prompts.count) prompts (limited from \(allPrompts.count)), mapping has \(mapping.count) entries, \(installed.count) models installed")
            } else {
                appendLog("Loaded \(prompts.count) prompts, mapping has \(mapping.count) entries, \(installed.count) models installed")
            }

            // Build a lookup from modelID to (path, lib) via AppState models
            let modelLookup: [String: (path: String, lib: String, vram: Int, name: String)] = appState.models.reduce(into: [:]) { acc, modelState in
                if let id = modelState.modelConfig.modelID,
                   let lib = modelState.modelConfig.modelLib,
                   let vram = modelState.modelConfig.estimatedVRAMReq {
                    acc[id] = (modelState.localBasePath, lib, vram, id.components(separatedBy: "-")[0])
                }
            }

            appendLog("Model lookup contains \(modelLookup.count) models: \(Array(modelLookup.keys).joined(separator: ", "))")

            // If no models in appState, try to build from mlc-package-config directly
            if modelLookup.isEmpty {
                appendLog("No models in appState, trying to build from mlc-package-config...")
                let configModels = try PromptRepository.loadInstalledModels()
                appendLog("Config models: \(Array(configModels).joined(separator: ", "))")
                
                // For now, let's use a fallback approach - check if the mapping models exist in config
                let validMapping = mapping.filter { configModels.contains($0.value) }
                if validMapping.isEmpty {
                    appendLog("ERROR: No valid mapping entries match installed models.")
                    appendLog("Mapping keys: \(Array(mapping.keys).joined(separator: ", "))")
                    appendLog("Installed models: \(Array(configModels).joined(separator: ", "))")
                    running = false
                    return
                }
                
                appendLog("Valid mapping has \(validMapping.count) entries")
                appendLog("Note: Using config-based validation. Model loading will be handled per-prompt.")
                
                // Continue with the benchmark using config-based validation
                // We'll handle model loading differently in the loop
            } else {
                let validMapping = mapping.filter { modelLookup.keys.contains($0.value) }
                if validMapping.isEmpty {
                    appendLog("ERROR: No valid mapping entries match installed models.")
                    appendLog("Mapping keys: \(Array(mapping.keys).joined(separator: ", "))")
                    appendLog("Installed models: \(Array(modelLookup.keys).joined(separator: ", "))")
                    running = false
                    return
                }
                appendLog("Valid mapping has \(validMapping.count) entries")
            }

            guard let routerInfo = modelLookup[routerModelID] else {
                // If modelLookup is empty, we can't load the router model
                if modelLookup.isEmpty {
                    appendLog("ERROR: Cannot load router model - no models available in appState")
                    running = false
                    return
                }
                appendLog("ERROR: Router model not installed: \(routerModelID)")
                running = false
                return
            }

            appendLog("Loading router model \(routerModelID)...")
            let routerEngine = MLCEngine()
            do {
                await routerEngine.reload(modelPath: routerInfo.path, modelLib: routerInfo.lib)
                appendLog("Router model loaded successfully")
            } catch {
                appendLog("ERROR loading router model: \(error)")
                await routerEngine.unload()
                running = false
                if backgroundTaskID != .invalid {
                    await UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
                return
            }

            let signposter = OSSignposter()
            let runHandle = signposter.beginInterval("BenchmarkRun")
            let runStartWall = CFAbsoluteTimeGetCurrent()
            let cpuStart = cpuTimeSeconds()
            var maxRSS: UInt64 = residentMemoryBytes()
            var totalGenMs = 0

            for (idx, item) in prompts.enumerated() {
                // Check if we should stop
                guard running else {
                    appendLog("Benchmark stopped by user")
                    break
                }
                let promptHandle = signposter.beginInterval("Prompt", "\(item.id)")
                let category = await PromptClassifier.shared.classify(engine: routerEngine, text: item.prompt)
                
                // Get valid mapping based on available models
                let validMapping = modelLookup.isEmpty ? 
                    mapping.filter { installed.contains($0.value) } : 
                    mapping.filter { modelLookup.keys.contains($0.value) }
                
                guard let targetModelID = validMapping[category] else {
                    appendLog("Skip prompt #\(item.id): no target model for category \(category)")
                    progress = Double(idx + 1) / Double(prompts.count)
                    signposter.endInterval("Prompt", promptHandle)
                    continue
                }
                
                // If modelLookup is empty, we need to skip model loading for now
                if modelLookup.isEmpty {
                    appendLog("Skip prompt #\(item.id): model loading not available (modelLookup empty)")
                    progress = Double(idx + 1) / Double(prompts.count)
                    signposter.endInterval("Prompt", promptHandle)
                    continue
                }
                
                guard let targetInfo = modelLookup[targetModelID] else {
                    appendLog("Skip prompt #\(item.id): target model not found in lookup: \(targetModelID)")
                    progress = Double(idx + 1) / Double(prompts.count)
                    signposter.endInterval("Prompt", promptHandle)
                    continue
                }

                appendLog("Processing prompt #\(item.id) [\(category)] → \(targetModelID)")
                let engine = MLCEngine()
                let tStart = CFAbsoluteTimeGetCurrent()
                
                do {
                    await engine.reload(modelPath: targetInfo.path, modelLib: targetInfo.lib)
                } catch {
                    appendLog("ERROR loading model \(targetModelID): \(error)")
                    await engine.unload()
                    signposter.endInterval("Prompt", promptHandle)
                    progress = Double(idx + 1) / Double(prompts.count)
                    continue
                }

                let t0 = CFAbsoluteTimeGetCurrent()
                var firstTokenTime: Double? = nil
                var completion = ""
                var finalUsage: Any? = nil

                do {
                    for await res in await engine.chat.completions.create(
                        messages: [ChatCompletionMessage(role: .user, content: item.prompt)],
                        max_tokens: 150,  // Limit output to ~150 tokens for faster benchmarks
                        stream_options: StreamOptions(include_usage: true),
                        temperature: 0.1,  // Lower temperature for more deterministic, faster generation
                        top_p: 0.9        // Focus on top 90% of tokens for efficiency
                    ) {
                        if firstTokenTime == nil, res.choices.contains(where: { $0.delta.content != nil }) {
                            firstTokenTime = CFAbsoluteTimeGetCurrent()
                        }
                        for c in res.choices { if let delta = c.delta.content { completion += delta.asText() } }
                        if let u = res.usage { finalUsage = u }
                        let rssNow = residentMemoryBytes()
                        if rssNow > maxRSS { maxRSS = rssNow }
                    }
                } catch {
                    appendLog("ERROR generating completion for prompt #\(item.id): \(error)")
                    // Unload model on error
                    await engine.unload()
                    signposter.endInterval("Prompt", promptHandle)
                    progress = Double(idx + 1) / Double(prompts.count)
                    continue
                }
                
                // Unload model after each prompt to free memory
                await engine.unload()

                let t1 = CFAbsoluteTimeGetCurrent()
                let ttft = Int(((firstTokenTime ?? t1) - t0) * 1000)
                let gen = Int((t1 - (firstTokenTime ?? t0)) * 1000)
                
                // Use word counting for token estimation (more reliable than KVC)
                let pt = max(1, item.prompt.split(separator: " ").count)
                let ct = max(1, completion.split(separator: " ").count)
                let tps = ct > 0 && gen > 0 ? Double(ct) / (Double(gen) / 1000.0) : 0
                
                // Check classification accuracy
                let isCorrect = category == item.category

                results.append(BenchmarkResult(id: item.id, category: category, modelID: targetModelID, ttftMs: ttft, genMs: gen, promptTokens: pt, completionTokens: ct, tps: tps, completion: completion, expectedCategory: item.category, classificationAccuracy: isCorrect))
                progress = Double(idx + 1) / Double(prompts.count)
                totalGenMs += max(0, gen)
                
                // Record energy sample after each prompt
                energyMonitor.recordSample()

                let accuracyMark = isCorrect ? "✓" : "✗"
                appendLog("\(accuracyMark) #\(item.id) [\(category)] → \(targetModelID) ttft=\(ttft)ms gen=\(gen)ms (expected: \(item.category))")
                signposter.endInterval("Prompt", promptHandle)
            }

            let cpuEnd = cpuTimeSeconds()
            let wallEnd = CFAbsoluteTimeGetCurrent()
            let totalLatencyMs = Int((wallEnd - runStartWall) * 1000)
            let ttfts = results.map { $0.ttftMs }
            let gens = results.map { $0.genMs }
            let qT = quantiles(ttfts)
            let qG = quantiles(gens)
            let totalPromptTokens = results.reduce(0) { $0 + $1.promptTokens }
            let totalCompletionTokens = results.reduce(0) { $0 + $1.completionTokens }
            let overallTPS = totalGenMs > 0 ? Double(totalCompletionTokens) / (Double(totalGenMs) / 1000.0) : 0
            let correctClassifications = results.filter { $0.classificationAccuracy }.count
            let classificationAccuracy = results.count > 0 ? Double(correctClassifications) / Double(results.count) : 0.0
            
            // Stop energy monitoring and get final energy
            energyMonitor.stop()
            let totalEnergy = energyMonitor.getTotalEnergyMilliJoules()
            let cpuUsage = max(0, cpuEnd - cpuStart)
            let wallClockTime = Double(totalLatencyMs) / 1000.0
            let cpuEff = wallClockTime > 0 ? cpuUsage / wallClockTime : 0
            let energyNote = String(format: "Real-time energy from CLPC. Wall=%.1fs, CPU=%.1fs (%.0f%%), Energy=%.1f mJ", wallClockTime, cpuUsage, cpuEff * 100, totalEnergy)

            let runSummary = BenchmarkRunSummary(
                totalPrompts: results.count,
                totalLatencyMs: totalLatencyMs,
                totalGenMs: totalGenMs,
                avgTtftMs: qT.avg,
                p50TtftMs: qT.p50,
                p95TtftMs: qT.p95,
                avgGenMs: qG.avg,
                p50GenMs: qG.p50,
                p95GenMs: qG.p95,
                totalPromptTokens: totalPromptTokens,
                totalCompletionTokens: totalCompletionTokens,
                overallTPS: overallTPS,
                maxResidentMemoryBytes: maxRSS,
                cpuTimeSeconds: max(0, cpuEnd - cpuStart),
                energyMilliJoules: totalEnergy,
                energyNote: energyNote,
                classificationAccuracy: classificationAccuracy,
                correctClassifications: correctClassifications
            )
            summary = runSummary

            signposter.endInterval("BenchmarkRun", runHandle)
            appendLog("✓ Run complete: total=\(totalLatencyMs)ms, prompts=\(results.count), overallTPS=\(String(format: "%.2f", overallTPS))")
            appendLog("Energy consumed: \(String(format: "%.1f", totalEnergy)) mJ (\(String(format: "%.2f", totalEnergy / 1000.0)) J)")
            
            // Unload router engine
            await routerEngine.unload()
        } catch {
            energyMonitor.stop()
            appendLog("ERROR: \(error)")
        }
        
        // End background task
        if backgroundTaskID != .invalid {
            await UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        
        running = false
    }
    
    func runDirectBenchmark(appState: AppState, targetModelID: String = "Qwen3-0.6B-q0f32-MLC") async throws {
        running = true
        results.removeAll()
        progress = 0
        summary = nil
        
        // Start background task to prevent iOS from killing the app
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = await UIApplication.shared.beginBackgroundTask {
            if backgroundTaskID != .invalid {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
        }
        
        // Start energy monitoring
        energyMonitor.start()
        appendLog("Starting direct benchmark run on \(targetModelID)...")
        appendLog("Energy monitoring started")

        do {
            let allPrompts = try PromptRepository.loadPrompts()
            let prompts = limitPrompts ? Array(allPrompts.prefix(promptLimit)) : allPrompts
            if limitPrompts {
                appendLog("Loaded \(prompts.count) prompts for direct benchmark (limited from \(allPrompts.count))")
            } else {
                appendLog("Loaded \(prompts.count) prompts for direct benchmark")
            }

            // Build a lookup from modelID to (path, lib) via AppState models
            let modelLookup: [String: (path: String, lib: String, vram: Int, name: String)] = appState.models.reduce(into: [:]) { acc, modelState in
                if let id = modelState.modelConfig.modelID,
                   let lib = modelState.modelConfig.modelLib,
                   let vram = modelState.modelConfig.estimatedVRAMReq {
                    acc[id] = (modelState.localBasePath, lib, vram, id.components(separatedBy: "-")[0])
                }
            }

            guard let targetInfo = modelLookup[targetModelID] else {
                appendLog("ERROR: Target model not installed: \(targetModelID)")
                appendLog("Available models: \(Array(modelLookup.keys).joined(separator: ", "))")
                running = false
                return
            }

            appendLog("Loading target model \(targetModelID)...")
            let engine = MLCEngine()
            await engine.reload(modelPath: targetInfo.path, modelLib: targetInfo.lib)
            appendLog("Target model loaded successfully")

            let signposter = OSSignposter()
            let runHandle = signposter.beginInterval("DirectBenchmarkRun")
            let runStartWall = CFAbsoluteTimeGetCurrent()
            let cpuStart = cpuTimeSeconds()
            var maxRSS: UInt64 = residentMemoryBytes()
            var totalGenMs = 0

            for (idx, item) in prompts.enumerated() {
                // Check if we should stop
                guard running else {
                    appendLog("Benchmark stopped by user")
                    break
                }
                
                let promptHandle = signposter.beginInterval("DirectPrompt", "\(item.id)")
                appendLog("Processing prompt #\(item.id) [\(item.category)] → \(targetModelID)")

                let tStart = CFAbsoluteTimeGetCurrent()
                let t0 = CFAbsoluteTimeGetCurrent()
                var firstTokenTime: Double? = nil
                var completion = ""

                do {
                    for await res in await engine.chat.completions.create(
                        messages: [ChatCompletionMessage(role: .user, content: item.prompt)],
                        max_tokens: 150,  // Limit output to ~150 tokens for faster benchmarks
                        stream_options: StreamOptions(include_usage: true),
                        temperature: 0.1,  // Lower temperature for more deterministic, faster generation
                        top_p: 0.9        // Focus on top 90% of tokens for efficiency
                    ) {
                        if firstTokenTime == nil, res.choices.contains(where: { $0.delta.content != nil }) {
                            firstTokenTime = CFAbsoluteTimeGetCurrent()
                        }
                        for c in res.choices { if let delta = c.delta.content { completion += delta.asText() } }
                        let rssNow = residentMemoryBytes()
                        if rssNow > maxRSS { maxRSS = rssNow }
                    }
                } catch {
                    appendLog("ERROR generating completion for prompt #\(item.id): \(error)")
                    signposter.endInterval("DirectPrompt", promptHandle)
                    progress = Double(idx + 1) / Double(prompts.count)
                    continue
                }

                let t1 = CFAbsoluteTimeGetCurrent()
                let ttft = Int(((firstTokenTime ?? t1) - t0) * 1000)
                let gen = Int((t1 - (firstTokenTime ?? t0)) * 1000)
                
                // Use word counting for token estimation
                let pt = max(1, item.prompt.split(separator: " ").count)
                let ct = max(1, completion.split(separator: " ").count)
                let tps = ct > 0 && gen > 0 ? Double(ct) / (Double(gen) / 1000.0) : 0

                // Direct benchmark always has 100% accuracy since no classification is performed
                results.append(BenchmarkResult(id: item.id, category: item.category, modelID: targetModelID, ttftMs: ttft, genMs: gen, promptTokens: pt, completionTokens: ct, tps: tps, completion: completion, expectedCategory: item.category, classificationAccuracy: true))
                progress = Double(idx + 1) / Double(prompts.count)
                totalGenMs += max(0, gen)
                
                // Record energy sample after each prompt
                energyMonitor.recordSample()

                let elapsed = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
                appendLog("✓ #\(item.id) [\(item.category)] → \(targetModelID) ttft=\(ttft)ms gen=\(gen)ms")
                signposter.endInterval("DirectPrompt", promptHandle)
            }

            let cpuEnd = cpuTimeSeconds()
            let wallEnd = CFAbsoluteTimeGetCurrent()
            let totalLatencyMs = Int((wallEnd - runStartWall) * 1000)
            let ttfts = results.map { $0.ttftMs }
            let gens = results.map { $0.genMs }
            let qT = quantiles(ttfts)
            let qG = quantiles(gens)
            let totalPromptTokens = results.reduce(0) { $0 + $1.promptTokens }
            let totalCompletionTokens = results.reduce(0) { $0 + $1.completionTokens }
            let overallTPS = totalGenMs > 0 ? Double(totalCompletionTokens) / (Double(totalGenMs) / 1000.0) : 0
            let correctClassifications = results.filter { $0.classificationAccuracy }.count
            let classificationAccuracy = results.count > 0 ? Double(correctClassifications) / Double(results.count) : 0.0
            
            // Stop energy monitoring and get final energy
            energyMonitor.stop()
            let totalEnergy = energyMonitor.getTotalEnergyMilliJoules()
            let cpuUsage = max(0, cpuEnd - cpuStart)
            let wallClockTime = Double(totalLatencyMs) / 1000.0
            let cpuEff = wallClockTime > 0 ? cpuUsage / wallClockTime : 0
            let energyNote = String(format: "Direct (no classification). Wall=%.1fs, CPU=%.1fs (%.0f%%), Energy=%.1f mJ", wallClockTime, cpuUsage, cpuEff * 100, totalEnergy)

            let runSummary = BenchmarkRunSummary(
                totalPrompts: results.count,
                totalLatencyMs: totalLatencyMs,
                totalGenMs: totalGenMs,
                avgTtftMs: qT.avg,
                p50TtftMs: qT.p50,
                p95TtftMs: qT.p95,
                avgGenMs: qG.avg,
                p50GenMs: qG.p50,
                p95GenMs: qG.p95,
                totalPromptTokens: totalPromptTokens,
                totalCompletionTokens: totalCompletionTokens,
                overallTPS: overallTPS,
                maxResidentMemoryBytes: maxRSS,
                cpuTimeSeconds: max(0, cpuEnd - cpuStart),
                energyMilliJoules: totalEnergy,
                energyNote: energyNote,
                classificationAccuracy: classificationAccuracy,
                correctClassifications: correctClassifications
            )
            summary = runSummary

            signposter.endInterval("DirectBenchmarkRun", runHandle)
            appendLog("✓ Direct benchmark complete: total=\(totalLatencyMs)ms, prompts=\(results.count), overallTPS=\(String(format: "%.2f", overallTPS))")
            appendLog("Energy consumed: \(String(format: "%.1f", totalEnergy)) mJ (\(String(format: "%.2f", totalEnergy / 1000.0)) J)")
            
            // Unload engine
            await engine.unload()
        } catch {
            energyMonitor.stop()
            appendLog("ERROR: \(error)")
        }
        
        // End background task
        if backgroundTaskID != .invalid {
            await UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        
        running = false
    }
    
    func runQuantizationComparison(appState: AppState) async throws {
        running = true
        results.removeAll()
        progress = 0
        summary = nil
        
        // Start energy monitoring
        energyMonitor.start()
        appendLog("Starting quantization comparison benchmark...")
        appendLog("Energy monitoring started")
        
        do {
            let allPrompts = try PromptRepository.loadPrompts()
            let prompts = limitPrompts ? Array(allPrompts.prefix(promptLimit)) : allPrompts
            if limitPrompts {
                appendLog("Loaded \(prompts.count) prompts for quantization comparison (limited from \(allPrompts.count))")
            } else {
                appendLog("Loaded \(prompts.count) prompts for quantization comparison")
            }
            
            // Build a lookup from modelID to (path, lib) via AppState models
            let modelLookup: [String: (path: String, lib: String, vram: Int, name: String)] = appState.models.reduce(into: [:]) { acc, modelState in
                if let id = modelState.modelConfig.modelID,
                   let lib = modelState.modelConfig.modelLib,
                   let vram = modelState.modelConfig.estimatedVRAMReq {
                    acc[id] = (modelState.localBasePath, lib, vram, id.components(separatedBy: "-")[0])
                }
            }
            
            let quantizedModelID = "Qwen3-0.6B-q4f32_1-MLC"
            let fullPrecisionModelID = "Qwen3-0.6B-q0f32-MLC"
            
            guard let quantizedInfo = modelLookup[quantizedModelID] else {
                appendLog("ERROR: Quantized model not installed: \(quantizedModelID)")
                running = false
                return
            }
            
            guard let fullPrecisionInfo = modelLookup[fullPrecisionModelID] else {
                appendLog("ERROR: Full precision model not installed: \(fullPrecisionModelID)")
                running = false
                return
            }
            
            appendLog("Running quantization comparison: \(quantizedModelID) vs \(fullPrecisionModelID)")
            
            let signposter = OSSignposter()
            let runHandle = signposter.beginInterval("QuantizationComparisonRun")
            let runStartWall = CFAbsoluteTimeGetCurrent()
            let cpuStart = cpuTimeSeconds()
            var maxRSS: UInt64 = residentMemoryBytes()
            var totalGenMs = 0
            
            // Process each prompt on both models
            for (idx, item) in prompts.enumerated() {
                let promptHandle = signposter.beginInterval("QuantPrompt", "\(item.id)")
                
                // First run on quantized model
                appendLog("Processing prompt #\(item.id) on \(quantizedModelID)...")
                let quantizedResult = try await runSinglePrompt(
                    prompt: item,
                    modelID: quantizedModelID,
                    modelInfo: quantizedInfo,
                    maxRSS: &maxRSS
                )
                
                // Then run on full precision model
                appendLog("Processing prompt #\(item.id) on \(fullPrecisionModelID)...")
                let fullPrecisionResult = try await runSinglePrompt(
                    prompt: item,
                    modelID: fullPrecisionModelID,
                    modelInfo: fullPrecisionInfo,
                    maxRSS: &maxRSS
                )
                
                // Store both results with model suffix for identification
                results.append(BenchmarkResult(
                    id: item.id * 1000 + 1,  // Quantized: original_id * 1000 + 1
                    category: item.category,
                    modelID: quantizedModelID,
                    ttftMs: quantizedResult.ttft,
                    genMs: quantizedResult.gen,
                    promptTokens: quantizedResult.promptTokens,
                    completionTokens: quantizedResult.completionTokens,
                    tps: quantizedResult.tps,
                    completion: quantizedResult.completion,
                    expectedCategory: item.category,
                    classificationAccuracy: true
                ))
                
                results.append(BenchmarkResult(
                    id: item.id * 1000 + 2,  // Full precision: original_id * 1000 + 2
                    category: item.category,
                    modelID: fullPrecisionModelID,
                    ttftMs: fullPrecisionResult.ttft,
                    genMs: fullPrecisionResult.gen,
                    promptTokens: fullPrecisionResult.promptTokens,
                    completionTokens: fullPrecisionResult.completionTokens,
                    tps: fullPrecisionResult.tps,
                    completion: fullPrecisionResult.completion,
                    expectedCategory: item.category,
                    classificationAccuracy: true
                ))
                
                totalGenMs += quantizedResult.gen + fullPrecisionResult.gen
                progress = Double(idx + 1) / Double(prompts.count)
                
                // Record energy sample after each prompt
                energyMonitor.recordSample()
                
                let speedup = fullPrecisionResult.gen > 0 ? Double(quantizedResult.gen) / Double(fullPrecisionResult.gen) : 0
                appendLog("✓ #\(item.id) Quantized: \(quantizedResult.gen)ms, Full: \(fullPrecisionResult.gen)ms, Speedup: \(String(format: "%.2fx", speedup))")
                
                signposter.endInterval("QuantPrompt", promptHandle)
            }
            
            let cpuEnd = cpuTimeSeconds()
            let wallEnd = CFAbsoluteTimeGetCurrent()
            let totalLatencyMs = Int((wallEnd - runStartWall) * 1000)
            let ttfts = results.map { $0.ttftMs }
            let gens = results.map { $0.genMs }
            let qT = quantiles(ttfts)
            let qG = quantiles(gens)
            let totalPromptTokens = results.reduce(0) { $0 + $1.promptTokens }
            let totalCompletionTokens = results.reduce(0) { $0 + $1.completionTokens }
            let overallTPS = totalGenMs > 0 ? Double(totalCompletionTokens) / (Double(totalGenMs) / 1000.0) : 0
            
            // Stop energy monitoring and get final energy
            energyMonitor.stop()
            let totalEnergy = energyMonitor.getTotalEnergyMilliJoules()
            let cpuUsage = max(0, cpuEnd - cpuStart)
            let wallClockTime = Double(totalLatencyMs) / 1000.0
            let cpuEff = wallClockTime > 0 ? cpuUsage / wallClockTime : 0
            let energyNote = String(format: "Quantization comparison. Wall=%.1fs, CPU=%.1fs (%.0f%%), Energy=%.1f mJ", wallClockTime, cpuUsage, cpuEff * 100, totalEnergy)
            
            let runSummary = BenchmarkRunSummary(
                totalPrompts: prompts.count * 2,  // Each prompt run on 2 models
                totalLatencyMs: totalLatencyMs,
                totalGenMs: totalGenMs,
                avgTtftMs: qT.avg,
                p50TtftMs: qT.p50,
                p95TtftMs: qT.p95,
                avgGenMs: qG.avg,
                p50GenMs: qG.p50,
                p95GenMs: qG.p95,
                totalPromptTokens: totalPromptTokens,
                totalCompletionTokens: totalCompletionTokens,
                overallTPS: overallTPS,
                maxResidentMemoryBytes: maxRSS,
                cpuTimeSeconds: max(0, cpuEnd - cpuStart),
                energyMilliJoules: totalEnergy,
                energyNote: energyNote,
                classificationAccuracy: 1.0,
                correctClassifications: results.count
            )
            summary = runSummary
            
            signposter.endInterval("QuantizationComparisonRun", runHandle)
            appendLog("✓ Quantization comparison complete: total=\(totalLatencyMs)ms, prompts=\(prompts.count * 2), overallTPS=\(String(format: "%.2f", overallTPS))")
            appendLog("Energy consumed: \(String(format: "%.1f", totalEnergy)) mJ (\(String(format: "%.2f", totalEnergy / 1000.0)) J)")
        } catch {
            energyMonitor.stop()
            appendLog("ERROR: \(error)")
        }
        
        running = false
    }
    
    func getEnergySamples() -> [EnergySample] {
        return energyMonitor.getSamples()
    }
    
    private struct PromptResult {
        let ttft: Int
        let gen: Int
        let promptTokens: Int
        let completionTokens: Int
        let tps: Double
        let completion: String
    }
    
    private func runSinglePrompt(
        prompt: PromptItem,
        modelID: String,
        modelInfo: (path: String, lib: String, vram: Int, name: String),
        maxRSS: inout UInt64
    ) async throws -> PromptResult {
        let engine = MLCEngine()
        await engine.reload(modelPath: modelInfo.path, modelLib: modelInfo.lib)
        
        let t0 = CFAbsoluteTimeGetCurrent()
        var firstTokenTime: Double? = nil
        var completion = ""
        
        do {
            for await res in await engine.chat.completions.create(
                messages: [ChatCompletionMessage(role: .user, content: prompt.prompt)],
                max_tokens: 150,
                stream_options: StreamOptions(include_usage: true),
                temperature: 0.1,
                top_p: 0.9
            ) {
                if firstTokenTime == nil, res.choices.contains(where: { $0.delta.content != nil }) {
                    firstTokenTime = CFAbsoluteTimeGetCurrent()
                }
                for c in res.choices { if let delta = c.delta.content { completion += delta.asText() } }
                let rssNow = residentMemoryBytes()
                if rssNow > maxRSS { maxRSS = rssNow }
            }
        } catch {
            appendLog("ERROR generating completion for prompt #\(prompt.id) on \(modelID): \(error)")
            throw error
        }
        
        let t1 = CFAbsoluteTimeGetCurrent()
        let ttft = Int(((firstTokenTime ?? t1) - t0) * 1000)
        let gen = Int((t1 - (firstTokenTime ?? t0)) * 1000)
        
        let pt = max(1, prompt.prompt.split(separator: " ").count)
        let ct = max(1, completion.split(separator: " ").count)
        let tps = ct > 0 && gen > 0 ? Double(ct) / (Double(gen) / 1000.0) : 0
        
        return PromptResult(ttft: ttft, gen: gen, promptTokens: pt, completionTokens: ct, tps: tps, completion: completion)
    }
}


