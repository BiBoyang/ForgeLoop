import Foundation

/// 沙箱拒绝后的升级审批策略。
///
/// 挂在 `CodingAgentConfig` 上（与 sandboxProfile 并列）；
/// handler 缺失时任何 policy 都等价 `never`（安全兜底）。
public enum ApprovalPolicy: String, Codable, Sendable, Equatable {
    /// 从不升级：沙箱拒绝直接按失败回灌模型。
    case never
    /// 疑似沙箱拒绝时向用户请求升级，批准后以非沙箱方式重跑一次（仅一次）。
    case onFailure

    public static let `default`: ApprovalPolicy = .onFailure
}
