import Foundation

/// The app was called "Meeting Notes" (bundle io.stackera.notes, data in Application Support/Notes)
/// before it became Off the Record. On the first launch under the new name, the old data folder is
/// moved over and the old settings are copied, so meetings, voices and the vocabulary carry on.
/// Runs before anything reads settings or opens the database.
enum LegacyData {
    static let oldBundleId = "io.stackera.notes"
    private static let doneKey = "legacy.migrated"

    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Notes", isDirectory: true)
        let new = AppDatabase.supportDirectory
        // Only a folder that is ours: it holds this app's database.
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.appendingPathComponent("notes.sqlite").path) {
            do {
                try fm.moveItem(at: old, to: new)
                NSLog("Moved data from \(old.path) to \(new.path)")
            } catch {
                NSLog("Could not move the old data folder: \(error.localizedDescription)")
            }
        }

        // Settings: everything except window positions and "setup done" (the new bundle id needs the
        // microphone and system-audio permissions again, so the Setup Assistant shows once more).
        guard let previous = defaults.persistentDomain(forName: oldBundleId) else { return }
        for (key, value) in previous where !key.hasPrefix("NS") && key != "setup.done" && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
