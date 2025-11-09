<!-- 5d6ea624-c9fc-4b02-8d7c-ac3de339331b 97733c82-80b5-49db-b878-deecfcf1d02e -->
# Auto-route Benchmarking and JSON Mapping

### Scope

- Batch-run prompts from `data/prompts/prompts.json` on iOS.
- Zero-shot classify each prompt with a lightweight on-device “router” model (TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC).
- Route to target model via data-driven `model-mapping.json` (validated against installed models in `ios/MLCChat/mlc-package-config.json`).
- Record metrics (TTFT, tokens, TPS, total latency) and export results.

### Router Model

- Use `TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC` for the zero-shot classifier (fast TTFT, good on-device fit) — see model card: [TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC](https://huggingface.co/mlc-ai/TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC).

### Configure TinyLlama in mlc-package-config.json

- Edit `ios/MLCChat/mlc-package-config.json` to add TinyLlama to `model_list` (keep your existing Qwen entries):
```json
{
  "device": "iphone",
  "model_list": [
    {
      "model": "HF://mlc-ai/Qwen3-0.6B-q0f16-MLC",
      "model_id": "Qwen3-0.6B-q0f16-MLC",
      "estimated_vram_bytes": 3000000000,
      "overrides": { "prefill_chunk_size": 128, "context_window_size": 2048 }
    },
    {
      "model": "HF://mlc-ai/Qwen3-1.7B-q4f16_1-MLC",
      "model_id": "Qwen3-1.7B-q4f16_1-MLC",
      "estimated_vram_bytes": 3000000000,
      "overrides": { "prefill_chunk_size": 128, "context_window_size": 2048 }
    },
    {
      "model": "HF://mlc-ai/TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC",
      "model_id": "TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC",
      "estimated_vram_bytes": 1500000000,
      "overrides": { "prefill_chunk_size": 128, "context_window_size": 2048 }
    }
  ]
}
```

- Then rebuild iOS libs per docs: [MLC iOS: Build from Source](https://llm.mlc.ai/docs/deploy/ios.html#use-pre-built-ios-app)
```bash
cd ios/MLCChat
export MLC_LLM_SOURCE_DIR=../..
mlc_llm package
```


### Files to Add

- `ios/MLCChat/MLCChat/Resources/model-mapping.json` (new): category→modelID mapping.
- `ios/MLCChat/MLCChat/Utils/PromptRepository.swift` (new): load prompts/categories/mapping from bundle.
- `ios/MLCChat/MLCChat/Utils/BenchmarkRunner.swift` (new): core batch logic, metrics, mapping validation.
- `ios/MLCChat/MLCChat/Views/BenchmarkView.swift` (new): simple UI to run/monitor/export.

### Files to Update

- `ios/MLCChat/MLCChat/Utils/PromptClassifier.swift`: optionally load categories from `categories.json` (fallback to hardcoded).
- `ios/MLCChat/MLCChat/Views/StartView.swift`: add navigation entry to `BenchmarkView`.
- Xcode project: include `data/prompts/categories.json`, `data/prompts/prompts.json`, and `Resources/model-mapping.json` as app resources.

### Data Files

- `model-mapping.json` example (uses your installed models for generation):
```json
{
  "Factual": "Qwen3-0.6B-q0f16-MLC",
  "Reasoning": "Qwen3-1.7B-q4f16_1-MLC",
  "Creative": "Qwen3-1.7B-q4f16_1-MLC",
  "Instruction-heavy": "Qwen3-1.7B-q4f16_1-MLC",
  "Role-based": "Qwen3-0.6B-q0f16-MLC"
}
```


### Metrics & Energy

- In-app:
  - Latency/throughput: already computed per prompt; add run-level aggregates (sum, mean, p50/p95 for TTFT/gen; overall TPS).
  - Memory: sample resident memory via `mach_task_basic_info` during the run, keep max value; include in report.
  - CPU time: compute user+system seconds via `task_thread_times_info`; include in report.
  - Add `os.signpost` intervals for the whole run and per-prompt to correlate with Instruments.
- XCTest performance test (optional):
  - Use `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric` inside `measure {}` to capture wall time/CPU/memory for a single run of the benchmark API. See Apple guidance and testing articles.
- Energy measurement:
  - Use Xcode Instruments “Energy Log” to capture energy usage while the benchmark runs; signposts segment runs for attribution.

Essential snippets:

```swift
// Resident memory (bytes)
import Darwin
func residentMemoryBytes() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
  let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

// CPU time (seconds)
func cpuTimeSeconds() -> Double {
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

// Signposts
import os
let signposter = OSSignposter()
let runHandle = signposter.beginInterval("BenchmarkRun")
// per-prompt: let h = signposter.beginInterval("Prompt_\(id)") ... signposter.endInterval("Prompt_\(id)", h)
signposter.endInterval("BenchmarkRun", runHandle)
```

XCTest (separate test target):

```swift
import XCTest
@testable import MLCChat

final class BenchmarkPerformanceTests: XCTestCase {
  func testBenchmarkPerformance() throws {
    let metrics: [XCTMetric] = [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]
    measure(metrics: metrics) {
      let appState = AppState()
      let runner = BenchmarkRunner()
      let exp = expectation(description: "run")
      Task { try? await runner.run(appState: appState); exp.fulfill() }
      wait(for: [exp], timeout: 600)
      XCTAssertGreaterThan(runner.results.count, 0)
    }
  }
}
```

### Output

- Save results as JSON (and optional CSV) to app Caches and present a share sheet.
- Include summary aggregates (per-category average TTFT/TPS) at run end in `BenchmarkView`.
- Record full-run metrics: total latency, aggregate throughput, max resident memory, CPU time; emit in report.

### Notes

- If a mapping refers to a model not installed, it is skipped and surfaced in the UI.
- `PromptClassifier` will accept categories from `categories.json` if present; fallback to current hardcoded list.

### References

- Router model: TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC — https://huggingface.co/mlc-ai/TinyLlama-1.1B-Chat-v1.0-q4f16_1-MLC
- MLC iOS build/deploy docs — https://llm.mlc.ai/docs/deploy/ios.html#use-pre-built-ios-app
- Apple performance testing guidance — https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/TestPerformance.html
- iOS performance testing overview — https://www.browserstack.com/guide/how-to-conduct-ios-performance-testing
- Energy/metrics overview (article) — https://medium.com/%40pepsins_17173/performance-testing-ios-apps-a-comprehensive-guide-fcee5748c844

### To-dos

- [ ] Bundle prompts.json under iOS Resources/benchmark
- [ ] Create category_model_map.json and include in target
- [ ] Implement BenchmarkRunner to route and run prompts
- [ ] Create BenchmarkView UI with progress and export
- [ ] Add Run Benchmark button in StartView
- [ ] Save JSON and CSV reports to Documents with share sheet