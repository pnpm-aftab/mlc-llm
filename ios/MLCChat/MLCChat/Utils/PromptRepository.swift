//
//  PromptRepository.swift
//  MLCChat
//

import Foundation

struct PromptItem: Decodable { let id: Int; let category: String; let prompt: String }
struct PromptList: Decodable { let prompts: [PromptItem] }

struct InstalledModels: Decodable {
    struct Item: Decodable { let model_id: String }
    let model_list: [Item]
}

enum ResourceLoadError: Error { case missing, decode }

final class PromptRepository {
    static func loadPrompts() throws -> [PromptItem] {
        guard let url = Bundle.main.url(forResource: "prompts", withExtension: "json") else {
            throw ResourceLoadError.missing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PromptList.self, from: data).prompts
    }

    static func loadMapping() throws -> [String: String] {
        guard let url = Bundle.main.url(forResource: "model-mapping", withExtension: "json") else {
            throw ResourceLoadError.missing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    static func loadInstalledModels() throws -> Set<String> {
        guard let url = Bundle.main.url(forResource: "mlc-package-config", withExtension: "json") else {
            throw ResourceLoadError.missing
        }
        let data = try Data(contentsOf: url)
        let cfg = try JSONDecoder().decode(InstalledModels.self, from: data)
        return Set(cfg.model_list.map { $0.model_id })
    }
}


