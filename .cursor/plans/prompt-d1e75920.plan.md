<!-- d1e75920-3634-401d-8c3a-4a9979d5af49 39e64e2b-a7ff-42e8-aa1c-6a3f42012fe1 -->
# Plan: Zero-shot classifier + prompt routing + logging + evaluation

- **Goal**: Categorize each prompt (factual, reasoning, creative, instructional, role-based), select the best quantized LLM per category, log request/response and timings, and evaluate performance.

### Architecture outline

- **Classifier**: Lightweight zero-shot classifier (e.g., MNLI-style) exposed as a local module and CLI in `python/mlc_llm/zero_shot/` with a simple Python API and optional REST shim in `examples/rest/`.
- **Routing**: A routing layer that maps categories → model/quant config via a YAML/JSON table under `python/mlc_llm/config/prompt_routing.json` and a small selector utility.
- **Integration points**:
- Python reference path: hook into prompt submission pipeline (entry utility in `python/mlc_llm`) to classify then select model.
- iOS (`ios/MLCChat`): add a thin switch that, before dispatch, calls classifier (local or REST) and resolves `mlc-package-config.json` to the chosen model tag.
- Android: analogous toggle after iOS.
- **Logging**: Append structured logs (JSONL) to `dist/logs/` with prompt metadata, category, chosen model, quant, timings, token counts, and outcome fields.
- **Evaluation**: Offline scripts under `python/mlc_llm/eval/` to compute latency/throughput and accuracy (using a small labeled set or heuristics), plus plots.

### Data privacy/safety

- Apply lightweight redaction (emails, phone numbers, etc.) before persisting logs.

### Configurability

- Feature flag to enable/disable classifier and routing. Allow manual override per request.

### Deliverables

- Classifier module + API/CLI, routing config, platform hooks, logging pipeline, evaluation scripts, documentation.

### Acceptance criteria

- End-to-end run: prompt → category → model selection → response → log written.
- Batch evaluation produces a metrics report for latency, efficiency, and accuracy.

### To-dos

- [ ] Select target quantized LLM variants and deployment targets; write routing_config.yaml
- [ ] Build/download and register quantized model artifacts for use in harness
- [ ] Choose fast zero-shot classifier (e.g., MiniLM or similar) and label schema
- [ ] Implement classifier wrapper with batched inference and caching
- [ ] Define routing policy mapping classifier signals to model choice + fallbacks
- [ ] Implement router module exposing select_model(prompt, metadata) API
- [ ] Define JSONL logging schema (prompt, model, scores, tokens, latency, output)
- [ ] Add logging to all request paths; write to logs/*.jsonl with rotation
- [ ] Create Python harness to run prompts across router and baselines
- [ ] Assemble representative prompts and optional references/labels
- [ ] Run controlled trials; collect logs for latency, tokens, accuracy proxies
- [ ] Create notebook/scripts to compute metrics and visualize trade-offs
- [ ] Iterate on thresholds/weights to improve cost-latency-quality trade-offs
- [ ] Expose router via REST or integrate into app request path
- [ ] Document setup, configs, how to run benchmarks, and interpret results