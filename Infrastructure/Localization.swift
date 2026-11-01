import Foundation

/// Language selection is fixed for this process; a change applies on relaunch.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSHLocalizedString(key)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
