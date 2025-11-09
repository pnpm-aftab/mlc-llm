//
//  BenchmarkView.swift
//  MLCChat
//

import SwiftUI

struct BenchmarkView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var runner = BenchmarkRunner()
    @State private var showShareSheet: Bool = false
    @State private var exportURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(runner.running ? "Running…" : "Run Benchmark") {
                    Task {
                        do {
                            try await runner.run(appState: appState)
                        } catch {
                            runner.appendLog("CRITICAL ERROR: \(error)")
                        }
                    }
                }
                .disabled(runner.running)
                
                Button(runner.running ? "Running…" : "Direct Benchmark") {
                    Task {
                        do {
                            try await runner.runDirectBenchmark(appState: appState)
                        } catch {
                            runner.appendLog("CRITICAL ERROR: \(error)")
                        }
                    }
                }
                .disabled(runner.running)
                .foregroundColor(.orange)
                
                ProgressView(value: runner.progress)
                    .frame(maxWidth: 200)
            }
            
            HStack {
                Toggle("Limit to 20 prompts", isOn: $runner.limitPrompts)
                    .disabled(runner.running)
                Spacer()
            }

            Text("Results: \(runner.results.count)")
                .font(.subheadline)

            if let s = runner.summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .font(.headline)
                    Text("Total latency: \(s.totalLatencyMs) ms  Overall TPS: \(String(format: "%.2f", s.overallTPS))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("TTFT avg/p50/p95: \(String(format: "%.0f", s.avgTtftMs))/\(s.p50TtftMs)/\(s.p95TtftMs) ms  Gen avg/p50/p95: \(String(format: "%.0f", s.avgGenMs))/\(s.p50GenMs)/\(s.p95GenMs) ms")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Tokens: prompt=\(s.totalPromptTokens) completion=\(s.totalCompletionTokens)  Max RSS: \(String(format: "%.2f", Double(s.maxResidentMemoryBytes) / (1024.0*1024.0))) MB  CPU: \(String(format: "%.2f", s.cpuTimeSeconds)) s")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Energy: \(String(format: "%.1f", s.energyMilliJoules)) mJ (\(String(format: "%.2f", s.energyMilliJoules / 1000.0)) J)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Classification Accuracy: \(String(format: "%.1f", s.classificationAccuracy * 100))% (\(s.correctClassifications)/\(s.totalPrompts))")
                        .font(.caption2)
                        .foregroundColor(s.classificationAccuracy >= 0.8 ? .green : .orange)
                    Text(s.energyNote)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            List(runner.results, id: \.id) { r in
                VStack(alignment: .leading) {
                    Text("#\(r.id) [\(r.category)] → \(r.modelID)")
                        .font(.headline)
                    Text("TTFT: \(r.ttftMs)ms  Gen: \(r.genMs)ms  TPS: \(String(format: "%.2f", r.tps))  Tokens: \(r.completionTokens)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Export JSON") {
                    if let url = generateJSONReport() {
                        exportURL = url
                        showShareSheet = true
                    }
                }
                .disabled(runner.results.isEmpty)

                Button("Export CSV") {
                    if let url = generateCSVReport() {
                        exportURL = url
                        showShareSheet = true
                    }
                }
                .disabled(runner.results.isEmpty)
            }

            Text("Log")
                .font(.subheadline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Benchmark")
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ActivityView(activityItems: [url])
            }
        }
    }

    private func generateJSONReport() -> URL? {
        struct Report: Encodable { let createdAt: String; let summary: BenchmarkRunSummary?; let results: [BenchmarkResult] }
        let formatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let report = Report(createdAt: formatter.string(from: Date()), summary: runner.summary, results: runner.results)
        do {
            let data = try JSONEncoder().encode(report)
            let filename = "mlc-benchmark_\(timestamp).json"
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent(filename)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func generateCSVReport() -> URL? {
        var lines: [String] = []
        if let s = runner.summary {
            lines.append("summary_totalPrompts,\(s.totalPrompts)")
            lines.append("summary_totalLatencyMs,\(s.totalLatencyMs)")
            lines.append("summary_totalGenMs,\(s.totalGenMs)")
            lines.append("summary_avgTtftMs,\(String(format: "%.0f", s.avgTtftMs))")
            lines.append("summary_p50TtftMs,\(s.p50TtftMs)")
            lines.append("summary_p95TtftMs,\(s.p95TtftMs)")
            lines.append("summary_avgGenMs,\(String(format: "%.0f", s.avgGenMs))")
            lines.append("summary_p50GenMs,\(s.p50GenMs)")
            lines.append("summary_p95GenMs,\(s.p95GenMs)")
            lines.append("summary_totalPromptTokens,\(s.totalPromptTokens)")
            lines.append("summary_totalCompletionTokens,\(s.totalCompletionTokens)")
            lines.append("summary_overallTPS,\(String(format: "%.2f", s.overallTPS))")
            lines.append("summary_maxResidentMemoryBytes,\(s.maxResidentMemoryBytes)")
            lines.append("summary_cpuTimeSeconds,\(String(format: "%.2f", s.cpuTimeSeconds))")
            lines.append("summary_energyMilliJoules,\(String(format: "%.2f", s.energyMilliJoules))")
            lines.append("summary_classificationAccuracy,\(String(format: "%.3f", s.classificationAccuracy))")
            lines.append("summary_correctClassifications,\(s.correctClassifications)")
            lines.append("")
            
            // Add energy samples section
            let energySamples = runner.getEnergySamples()
            if !energySamples.isEmpty {
                lines.append("")
                lines.append("# Energy samples (real-time monitoring via CLPC)")
                lines.append("timestamp_seconds,thermalState,energy_mJ")
                for sample in energySamples {
                    lines.append("\(String(format: "%.3f", sample.timestamp)),\(sample.thermalState),\(String(format: "%.2f", sample.energyMilliJoules))")
                }
                lines.append("")
            }
        }
        lines.append("id,category,modelID,ttftMs,genMs,promptTokens,completionTokens,tps,expectedCategory,classificationAccuracy,completion")
        for r in runner.results {
            lines.append("\(r.id),\(r.category),\(r.modelID),\(r.ttftMs),\(r.genMs),\(r.promptTokens),\(r.completionTokens),\(String(format: "%.2f", r.tps)),\(r.expectedCategory),\(r.classificationAccuracy),\"\(r.completion.replacingOccurrences(of: "\"", with: "\"\""))\"")
        }
        do {
            let csv = lines.joined(separator: "\n")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let filename = "mlc-benchmark_\(timestamp).csv"
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent(filename)
            try csv.data(using: .utf8)!.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


