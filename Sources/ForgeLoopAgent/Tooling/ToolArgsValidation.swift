import Foundation
import ForgeLoopAI

// MARK: - Schema Definition

public enum ToolArgType: Sendable {
    case string
    case int
    case bool
    case numberOrString // 兼容 number 和数字字符串（如 timeoutMs）
    case stringArray // 字符串数组
}

public struct ToolArgField: Sendable {
    public let name: String
    public let type: ToolArgType
    public let required: Bool

    public init(name: String, type: ToolArgType, required: Bool = false) {
        self.name = name
        self.type = type
        self.required = required
    }
}

public struct ToolArgsSchema: Sendable {
    public let fields: [ToolArgField]

    public init(fields: [ToolArgField]) {
        self.fields = fields
    }

    public var requiredFieldNames: [String] {
        fields.filter(\.required).map(\.name)
    }

    public var knownFieldNames: Set<String> {
        Set(fields.map(\.name))
    }
}

// MARK: - Validation Error

public struct ValidationError: Sendable {
    public let code: ToolErrorCode
    public let message: String
    public let path: String?

    public init(code: ToolErrorCode, message: String, path: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
    }
}

// MARK: - Validated Args

public struct ValidatedArgs: @unchecked Sendable {
    private let raw: [String: Any]

    public init(raw: [String: Any]) {
        self.raw = raw
    }

    public func string(_ key: String) -> String? {
        raw[key] as? String
    }

    public func int(_ key: String) -> Int? {
        if let num = raw[key] as? NSNumber {
            // 用 CFTypeID 排除 __NSCFBoolean（Swift `is Bool`/`is Int` 对 NSNumber 子类均返回 true）
            guard CFGetTypeID(num as CFTypeRef) == CFNumberGetTypeID() else { return nil }
            return num.intValue
        }
        if let str = raw[key] as? String {
            return Int(str)
        }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if let num = raw[key] as? NSNumber {
            // 用 CFTypeID 精确识别 __NSCFBoolean，排除 __NSCFNumber
            guard CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
            return num.boolValue
        }
        if let str = raw[key] as? String {
            let lower = str.lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
        }
        return nil
    }

    public func has(_ key: String) -> Bool {
        raw[key] != nil
    }

    public func stringArray(_ key: String) -> [String]? {
        raw[key] as? [String]
    }
}

// MARK: - Validator

public enum ValidationOutcome {
    case success(ValidatedArgs)
    case failure([ValidationError])
}

public enum ToolArgsValidator {
    /// 校验 JSON 参数字符串是否符合给定 schema。
    /// 成功返回 `.success(ValidatedArgs)`，失败返回 `.failure([ValidationError])`。
    public static func validate(_ json: String, schema: ToolArgsSchema) -> ValidationOutcome {
        guard let data = json.data(using: .utf8) else {
            return .failure([ValidationError(code: .invalidJson, message: "Invalid UTF-8 encoding")])
        }

        let dict: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure([ValidationError(code: .invalidJson, message: "JSON must be an object")])
            }
            dict = parsed
        } catch {
            return .failure([ValidationError(code: .invalidJson, message: "Invalid JSON: \(error.localizedDescription)")])
        }

        var errors: [ValidationError] = []

        // 1) 检查必填字段
        for field in schema.fields where field.required {
            if dict[field.name] == nil {
                errors.append(ValidationError(
                    code: .missingRequired,
                    message: "Missing required argument: \(field.name)",
                    path: "$.\(field.name)"
                ))
            }
        }

        // 2) 检查类型与未知字段
        for (key, value) in dict {
            guard let field = schema.fields.first(where: { $0.name == key }) else {
                // 未知字段
                errors.append(ValidationError(
                    code: .unknownField,
                    message: "Unknown field: \(key)",
                    path: "$.\(key)"
                ))
                continue
            }

            if !isValidType(value: value, expected: field.type) {
                errors.append(ValidationError(
                    code: .invalidType,
                    message: "Invalid type for \(key): expected \(typeDescription(field.type))",
                    path: "$.\(key)"
                ))
            }
        }

        if errors.isEmpty {
            return .success(ValidatedArgs(raw: dict))
        } else {
            return .failure(errors)
        }
    }

    /// 将校验错误列表格式化为统一的 ToolResult.error 输出。
    public static func formatErrors(_ errors: [ValidationError]) -> ToolResult {
        let lines = errors.map { err in
            var line = "[\(err.code.rawValue)] \(err.message)"
            if let path = err.path {
                line += " (path: \(path))"
            }
            return line
        }
        return ToolResult(output: lines.joined(separator: "\n"), isError: true, errorCode: errors.first?.code)
    }
}

// MARK: - Helpers

private func isValidType(value: Any, expected: ToolArgType) -> Bool {
    switch expected {
    case .string:
        return value is String
    case .int:
        // 必须用 CFTypeID 区分：Swift `is Int`/`is Bool` 对 __NSCFNumber/__NSCFBoolean 均返回 true
        if let num = value as? NSNumber {
            return CFGetTypeID(num as CFTypeRef) == CFNumberGetTypeID()
        }
        return false
    case .bool:
        // 必须用 CFTypeID 区分：Swift `is Bool` 对 __NSCFNumber 也返回 true
        if let num = value as? NSNumber {
            return CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID()
        }
        if let str = value as? String {
            return str.lowercased() == "true" || str.lowercased() == "false"
        }
        return false
    case .numberOrString:
        // 排除布尔值，只接受数字或数字字符串
        if let num = value as? NSNumber {
            return CFGetTypeID(num as CFTypeRef) == CFNumberGetTypeID()
        }
        if let str = value as? String {
            return Int(str) != nil
        }
        return false
    case .stringArray:
        guard let array = value as? [Any] else { return false }
        return array.allSatisfy { $0 is String }
    }
}

private func typeDescription(_ type: ToolArgType) -> String {
    switch type {
    case .string: return "string"
    case .int: return "int"
    case .bool: return "bool"
    case .numberOrString: return "number or numeric string"
    case .stringArray: return "array of strings"
    }
}

// MARK: - JSON Schema Mapping

extension ToolArgType {
    /// 映射为 JSON Schema 类型片段，与 `ToolArgsValidator` 的类型判定语义对齐。
    var jsonSchema: [String: Any] {
        switch self {
        case .string:
            return ["type": "string"]
        case .int:
            return ["type": "integer"]
        case .bool:
            // 校验器额外容忍 "true"/"false" 字符串属于宽松兼容；对模型只声明 boolean。
            return ["type": "boolean"]
        case .numberOrString:
            // 与校验器一致：数字，或可解析为 Int 的数字字符串。
            return ["anyOf": [
                ["type": "number"],
                ["type": "string", "pattern": "^-?\\d+$"]
            ]]
        case .stringArray:
            return ["type": "array", "items": ["type": "string"]]
        }
    }
}

extension ToolArgsSchema {
    /// 映射为 JSON Schema 对象（供 provider 请求体 `tools` 字段使用）。
    /// 与 `ToolArgsValidator` 语义一致：required 一致；校验器拒绝未知字段，故 `additionalProperties: false`。
    public func jsonSchema() -> [String: Any] {
        var properties: [String: Any] = [:]
        for field in fields {
            properties[field.name] = field.type.jsonSchema
        }
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        let required = requiredFieldNames
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }
}

extension ToolDefinition {
    /// 由 `ToolArgsSchema` 生成工具定义。`jsonSchema()` 仅含 JSON 可序列化值，正常路径必然成功；
    /// 兜底退化为空 object schema 而不是崩溃，避免单个工具的 schema 问题拖垮整个注册表。
    public static func make(name: String, description: String, argsSchema: ToolArgsSchema) -> ToolDefinition {
        if let definition = try? ToolDefinition(name: name, description: description, parameters: argsSchema.jsonSchema()) {
            return definition
        }
        return ToolDefinition(
            name: name,
            description: description,
            parametersJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
        )
    }
}
