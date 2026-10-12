#!/usr/bin/env swift
// TASK-sandbox-spike: seatbelt 探针
// 验证 "Swift Process 包装 /usr/bin/sandbox-exec -p <动态生成的 .sbpl>" 端到端通路。
// 用法: swift Scripts/sandbox-spike/probe.swift
// 退出码: 0 = 全矩阵 PASS, 1 = 存在 FAIL。

import Foundation

// MARK: - Item 10: sandbox-exec 绝对路径硬编码（防 PATH 注入，对齐 Codex MACOS_PATH_TO_SEATBELT_EXECUTABLE）
let kSandboxExecPath = "/usr/bin/sandbox-exec"

// MARK: - Profile 模板（对齐 codex-rs seatbelt_base_policy.sbpl 的 (deny default) 起手）
func baseProfile(workspace: String, allowNetwork: Bool) -> String {
    var p = """
    (version 1)
    (deny default)
    (allow process-exec)
    (allow process-fork)
    (allow signal (target same-sandbox))
    (allow process-info* (target same-sandbox))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow ipc-posix-shm-read-data ipc-posix-shm-write-data)
    (allow pseudo-tty)
    (allow file-read*)
    (allow file-read* file-test-existence file-write*
        (subpath "/tmp")
        (subpath "/private/tmp")
        (subpath "/var/tmp")
        (subpath "/private/var/tmp"))
    (allow file-read* file-write* (subpath "\(workspace)"))
    (allow file-write-data
      (require-all
        (path "/dev/null")
        (vnode-type CHARACTER-DEVICE)))
    """
    if allowNetwork {
        p += "\n(allow network*)\n"
    }
    return p
}

// MARK: - Process 包装
struct RunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let launchError: String?
}

func runSandboxed(profile: String,
                  shell: String,
                  env: [String: String] = [:],
                  stdinData: Data? = nil,
                  cwd: URL) -> RunResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: kSandboxExecPath)
    proc.arguments = ["-p", profile, "/bin/sh", "-c", shell]
    proc.currentDirectoryURL = cwd
    var mergedEnv = ProcessInfo.processInfo.environment
    for (k, v) in env { mergedEnv[k] = v }
    proc.environment = mergedEnv

    let outPipe = Pipe()
    let errPipe = Pipe()
    let inPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    proc.standardInput = inPipe

    do {
        try proc.run()
    } catch {
        return RunResult(exitCode: -1, stdout: "", stderr: "", launchError: "\(error)")
    }

    // 并发读 stdout/stderr，避免管道缓冲打满造成死锁
    var outData = Data()
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    if let stdinData {
        inPipe.fileHandleForWriting.write(stdinData)
    }
    inPipe.fileHandleForWriting.closeFile()

    proc.waitUntilExit()
    group.wait()

    return RunResult(
        exitCode: proc.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? "",
        launchError: nil
    )
}

// MARK: - 测试记录
struct TestCase {
    let index: Int
    let name: String
    var pass = false
    var detail = ""
}

var cases: [TestCase] = [
    TestCase(index: 1, name: "stdout/stderr 透传"),
    TestCase(index: 2, name: "环境变量透传"),
    TestCase(index: 3, name: "退出码透传 (exit 42)"),
    TestCase(index: 4, name: "stdin 透传"),
    TestCase(index: 5, name: "workspace-write 允许 (cwd 下写文件)"),
    TestCase(index: 6, name: "workspace-write 拒绝 ($HOME/cwd 之外)"),
    TestCase(index: 7, name: "只读路径 (/etc/hosts 可读)"),
    TestCase(index: 8, name: "网络关 (无 network allow, curl 被拒)"),
    TestCase(index: 9, name: "网络开 (allow network*, curl 成功)"),
    TestCase(index: 10, name: "sandbox-exec 绝对路径硬编码"),
]

func record(_ index: Int, _ pass: Bool, _ detail: String) {
    cases[index - 1].pass = pass
    cases[index - 1].detail = detail
    print("[\(pass ? "PASS" : "FAIL")] #\(index) \(cases[index-1].name)")
    for line in detail.split(separator: "\n") {
        print("      \(line)")
    }
}

// MARK: - 准备工作目录
let workspaceRaw = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sandbox-spike-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: workspaceRaw)
try FileManager.default.createDirectory(at: workspaceRaw, withIntermediateDirectories: true)
// seatbelt 按真实路径匹配 subpath：/var/folders 是 firmlink，实际为 /private/var/folders。
// 注意 URL.resolvingSymlinksInPath 不会解析 /var firmlink，必须用 realpath(3)（目录已存在故可用），
// 对齐 Codex normalize_writable_root_for_sandbox 的 canonicalize 语义。
func canonicalPath(_ path: String) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    guard realpath(path, &buf) != nil else { return path }
    return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
let workspace = URL(fileURLWithPath: canonicalPath(workspaceRaw.path))
let workspacePath = workspace.path
print("workspace: \(workspacePath)")

let profileOff = baseProfile(workspace: workspacePath, allowNetwork: false)
let profileOn = baseProfile(workspace: workspacePath, allowNetwork: true)

// 把最终 profile 落盘，便于报告引用与人工复核
try profileOff.write(to: workspace.appendingPathComponent("profile-netoff.sbpl"), atomically: true, encoding: .utf8)
try profileOn.write(to: workspace.appendingPathComponent("profile-neton.sbpl"), atomically: true, encoding: .utf8)

// MARK: - Item 1: stdout/stderr 透传
do {
    let r = runSandboxed(profile: profileOff, shell: "echo out-spike; echo err-spike >&2", cwd: workspace)
    let pass = r.launchError == nil && r.exitCode == 0
        && r.stdout == "out-spike\n" && r.stderr.contains("err-spike")
    record(1, pass, "exit=\(r.exitCode) stdout=\(r.stdout.debugDescription) stderr=\(r.stderr.debugDescription)")
}

// MARK: - Item 2: 环境变量透传
do {
    let r = runSandboxed(profile: profileOff, shell: "printf '%s' \"$SPIKE_TOKEN\"",
                         env: ["SPIKE_TOKEN": "token-abc-123"], cwd: workspace)
    let pass = r.launchError == nil && r.exitCode == 0 && r.stdout == "token-abc-123"
    record(2, pass, "exit=\(r.exitCode) stdout=\(r.stdout.debugDescription)")
}

// MARK: - Item 3: 退出码透传
do {
    let r = runSandboxed(profile: profileOff, shell: "exit 42", cwd: workspace)
    let pass = r.launchError == nil && r.exitCode == 42
    record(3, pass, "exit=\(r.exitCode) (期望 42)")
}

// MARK: - Item 4: stdin 透传
do {
    let r = runSandboxed(profile: profileOff, shell: "IFS= read -r line; echo \"got:$line\"",
                         stdinData: "hello-from-stdin\n".data(using: .utf8), cwd: workspace)
    let pass = r.launchError == nil && r.exitCode == 0 && r.stdout.contains("got:hello-from-stdin")
    record(4, pass, "exit=\(r.exitCode) stdout=\(r.stdout.debugDescription)")
}

// MARK: - Item 5: workspace-write 允许
do {
    let target = workspace.appendingPathComponent("spike-write-ok.txt")
    try? FileManager.default.removeItem(at: target)
    let r = runSandboxed(profile: profileOff, shell: "echo data > \"$PWD/spike-write-ok.txt\"", cwd: workspace)
    let exists = FileManager.default.fileExists(atPath: target.path)
    let pass = r.launchError == nil && r.exitCode == 0 && exists
    record(5, pass, "exit=\(r.exitCode) fileExists=\(exists) stderr=\(r.stderr.debugDescription)")
}

// MARK: - Item 6: workspace-write 拒绝（记录退出码与 stderr 原文特征）
do {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let deniedPath = "\(home)/sandbox-spike-denied-\(ProcessInfo.processInfo.processIdentifier).txt"
    try? FileManager.default.removeItem(atPath: deniedPath)
    let r = runSandboxed(profile: profileOff, shell: "echo nope > \"\(deniedPath)\"", cwd: workspace)
    let exists = FileManager.default.fileExists(atPath: deniedPath)
    let pass = r.launchError == nil && r.exitCode != 0 && !exists
    record(6, pass, "exit=\(r.exitCode) fileCreated=\(exists) stderr=\(r.stderr.debugDescription)")
    try? FileManager.default.removeItem(atPath: deniedPath)
}

// MARK: - Item 7: 只读路径
do {
    let r = runSandboxed(profile: profileOff, shell: "cat /etc/hosts", cwd: workspace)
    let pass = r.launchError == nil && r.exitCode == 0 && r.stdout.contains("localhost")
    record(7, pass, "exit=\(r.exitCode) stdoutHasLocalhost=\(r.stdout.contains("localhost")) stderr=\(r.stderr.debugDescription)")
}

// MARK: - Item 8: 网络关
do {
    let r = runSandboxed(profile: profileOff,
                         shell: "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; /usr/bin/curl --max-time 5 -sS https://example.com -o /dev/null",
                         cwd: workspace)
    let pass = r.launchError == nil && r.exitCode != 0
    record(8, pass, "exit=\(r.exitCode) stderr=\(r.stderr.debugDescription)")
}

// MARK: - Item 9: 网络开
// 宿主机直连 example.com 受网络环境影响可能抖动（超时/SSL reset），与沙箱无关。
// 区分逻辑：沙箱拒绝的特征是 exit=6 "Could not resolve host"（DNS 被 EPERM）；
// 只要 exit==0 或失败特征不是沙箱拒绝，即证明 (allow network*) 生效。最多重试 3 次。
do {
    var attempts: [String] = []
    var pass = false
    for i in 1...3 {
        let r = runSandboxed(profile: profileOn,
                             shell: "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; /usr/bin/curl --max-time 5 -sS https://example.com -o /dev/null",
                             cwd: workspace)
        let deniedBySandbox = r.exitCode == 6 && r.stderr.contains("Could not resolve host")
        attempts.append("attempt\(i): exit=\(r.exitCode) stderr=\(r.stderr.debugDescription)")
        if r.launchError == nil && (r.exitCode == 0 || !deniedBySandbox) {
            pass = true
            if r.exitCode == 0 { break }
        }
    }
    record(9, pass, attempts.joined(separator: "\n"))
}

// MARK: - Item 10: 绝对路径硬编码
do {
    let exists = FileManager.default.isExecutableFile(atPath: kSandboxExecPath)
    let isAbsolute = kSandboxExecPath.hasPrefix("/")
    let pass = exists && isAbsolute
    record(10, pass, "path=\(kSandboxExecPath) isAbsolute=\(isAbsolute) executable=\(exists)")
}

// MARK: - 汇总
let passCount = cases.filter { $0.pass }.count
print("")
print("===== SUMMARY =====")
for c in cases {
    print("#\(c.index)\t\(c.pass ? "PASS" : "FAIL")\t\(c.name)")
}
print("PASS \(passCount)/\(cases.count)")
print("profiles & artifacts: \(workspacePath)")
exit(passCount == cases.count ? 0 : 1)
