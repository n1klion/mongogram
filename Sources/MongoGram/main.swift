import AppKit

if CommandLine.arguments.contains("--mongoose") {
    exit(MongooseExporter.runCommandLine(CommandLine.arguments))
}
if CommandLine.arguments.contains("--render") {
    exit(ImageExporter.runCommandLine(CommandLine.arguments))
}
// No window restoration: it would bring back stale and empty windows. Recent files are on the start screen.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
MongoGramApp.main()
