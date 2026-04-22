import Foundation

public enum Style {
    public static func user(_ text: String) -> String { text }
    public static func prompt(_ text: String) -> String { text }
    public static func dimmed(_ text: String) -> String { text }
    public static func header(_ text: String) -> String { text }
}
