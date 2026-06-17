import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 读取用户输入并隐藏回显。
/// 在 macOS 上使用 `getpass(3)`；其他平台回退到 `readLine()`。
public func readHiddenInput(prompt: String) -> String? {
    #if canImport(Darwin)
    guard let ptr = getpass(prompt) else { return nil }
    return String(cString: ptr)
    #else
    print(prompt, terminator: "")
    return readLine()
    #endif
}
