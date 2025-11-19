//
//  PromptClassifier.swift
//  MLCChat
//

import Foundation
import MLCSwift

/// A lightweight zero-shot classifier that prompts the on-device LLM
/// to choose exactly one category from a fixed set of labels.
final class PromptClassifier {
    static let shared = PromptClassifier()

    // Keep categories in sync with data/prompts/categories.json
    // We intentionally hardcode to ensure the app bundles without external I/O.
    private let categories: [String] = [
        "Factual",
        "Reasoning",
        "Creative",
        "Instruction-heavy",
        "Role-based"
    ]

    private init() {}

    /// Classify the given text into one of the known categories.
    /// Uses the provided MLCEngine to run a short streamed completion.
    func classify(engine: MLCEngine, text: String) async -> String {
        // Zero-shot classification prompt with category descriptions only (no examples)
        let systemInstruction = """
        You are a text classifier. Classify the input into exactly ONE category:
        
        Factual: Facts, information, explanations, definitions, informational queries
        Reasoning: Logic puzzles, mathematics, problem-solving, analytical questions
        Creative: Storytelling, poetry, fiction, creative writing, imaginative content
        Instruction-heavy: Tutorials, guides, step-by-step instructions, procedural content
        Role-based: Character acting, personas, role-playing scenarios, identity-based prompts
        
        Output ONLY the exact category name. Nothing else.
        """

        let messages: [ChatCompletionMessage] = [
            ChatCompletionMessage(role: .system, content: systemInstruction),
            ChatCompletionMessage(role: .user, content: text)
        ]

        var streamed = ""
        do {
            for await res in await engine.chat.completions.create(
                messages: messages,
                max_tokens: 15,
                stream_options: StreamOptions(include_usage: true),
                temperature: 0.1,
            ) {
                for choice in res.choices {
                    if let delta = choice.delta.content {
                        streamed += delta.asText()
                    }
                }
            }
        }

        // Normalize and map to a known label
        let normalized = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
                                  .replacingOccurrences(of: "\n", with: " ")
                                  .lowercased()

        // Try exact match first
        if let exact = categories.first(where: { $0.lowercased() == normalized }) {
            return exact
        }
        
        // Try prefix match (handles partial outputs)
        if let pref = categories.first(where: { normalized.hasPrefix($0.lowercased()) }) {
            return pref
        }
        
        // Try substring match
        if let incl = categories.first(where: { normalized.contains($0.lowercased()) }) {
            return incl
        }

        // Robust fallback logic based on keyword patterns
        let textLower = text.lowercased()
        
        // Check for role-based FIRST (most specific)
        if textLower.contains("you are") || textLower.contains("act as") || textLower.contains("acting as") ||
           textLower.contains("pretend") || textLower.contains("role play") || textLower.contains("imagine you are") ||
           textLower.contains("as a") || textLower.contains("assume") {
            return "Role-based"
        }
        
        // Check for instruction-heavy NEXT
        if textLower.contains("step") || textLower.contains("how to") || textLower.contains("instructions") ||
           textLower.contains("guide") || textLower.contains("tutorial") || textLower.contains("create a") ||
           textLower.contains("write a") && (textLower.contains("guide") || textLower.contains("tutorial")) {
            return "Instruction-heavy"
        }
        
        // Check for creative content
        if textLower.contains("story") || textLower.contains("poem") || textLower.contains("fiction") ||
           textLower.contains("write") && !textLower.contains("code") || textLower.contains("compose") ||
           textLower.contains("imagine") && !textLower.contains("imagine you are") {
            return "Creative"
        }
        
        // Check for reasoning
        if textLower.contains("solve") || textLower.contains("calculate") || textLower.contains("logic") ||
           textLower.contains("reasoning") || textLower.contains("analyze") || textLower.contains("why") ||
           textLower.contains("puzzle") || textLower.contains("riddle") || textLower.contains("math") ||
           textLower.contains("proof") || textLower.contains("algorithm") {
            return "Reasoning"
        }
        
        // Default to Factual
        return "Factual"
    }
}


