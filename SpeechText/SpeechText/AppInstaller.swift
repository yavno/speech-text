// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SpeechTextCore

/// The disk image's half of installing: moving an app that was opened straight from the
/// image into Applications. The decision is `InstallLocation` (SetupServices.swift); this
/// is the I/O around it. The image itself is the user's to eject and throw away.
enum AppInstaller {
    /// Where the running copy is. Asks `hdiutil` which images are mounted — a few tens of
    /// milliseconds, needing no permission, and never reading the volumes themselves.
    static func currentLocation() -> InstallLocation {
        InstallLocation.decide(bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                               appName: Bundle.main.bundleURL.deletingPathExtension().lastPathComponent,
                               images: mountedImages())
    }

    private static func mountedImages() -> [MountedDiskImage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            dlog("Install", "hdiutil info: \(error.localizedDescription)", level: .error)
            return []
        }
        // Read before waiting: a full pipe would otherwise block hdiutil forever.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return MountedDiskImage.parse(hdiutilInfo: data)
    }

    // MARK: Opened from the disk image

    /// Called first thing at launch. Returns true when this copy is going away — moved
    /// and relaunched from Applications, or quit — and nothing else should start: no
    /// setup, no login item pointing into `/Volumes`, no settings written.
    /// Set once this copy has decided to go: it quits without touching anything the
    /// installed copy owns (History's folder included).
    @MainActor private(set) static var isLeaving = false

    @MainActor
    static func moveIfRunningFromDiskImage() -> Bool {
        // Nothing to ask hdiutil on an ordinary launch: only these two paths can be an image.
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return false }
        guard case .inDiskImage(let image) = currentLocation() else { return false }
        dlog("Install", "running from the disk image \(image?.imagePath ?? "(translocated)") — offering the move")
        isLeaving = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Move SpeechText to Applications?"
        alert.informativeText = "SpeechText is running from the disk image it was downloaded in, "
            + "and would stop working once the disk image is closed. "
            + "It will open again from Applications and walk you through setup."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return true
        }

        do {
            let installed = try install()
            relaunch(installed)
        } catch {
            dlog("Install", "move failed: \(error.localizedDescription)", level: .error)
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "SpeechText couldn't move itself to Applications"
            failure.informativeText = "\(error.localizedDescription)\n\n"
                + "Drag SpeechText onto the Applications folder in the disk image's window, then open it from Applications."
            failure.runModal()
            NSApp.terminate(nil)
        }
        return true
    }

    /// Copies the running bundle into Applications — the user's own `~/Applications` when
    /// the shared folder is not writable (an account that is not an administrator) —
    /// replacing an older copy, which goes to the Trash rather than being deleted.
    private static func install() throws -> URL {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
        var folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if !fileManager.isWritableFile(atPath: folder.path) {
            folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destination = folder.appendingPathComponent(source.lastPathComponent)

        if fileManager.fileExists(atPath: destination.path) {
            quitCopies(at: destination)
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
            dlog("Install", "moved the previous \(destination.path) to the Trash")
        }
        try fileManager.copyItem(at: source, to: destination)

        // The user already opened this copy past Gatekeeper; without this the installed
        // copy would ask "downloaded from the Internet — open it?" a second time.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "-r", "com.apple.quarantine", destination.path]
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        dlog("Install", "installed at \(destination.path)")
        return destination
    }

    /// An older copy that is running would keep its files busy and its shortcuts taken.
    private static func quitCopies(at url: URL) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @MainActor
    private static func relaunch(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        // This copy is still running under the same identifier until it quits.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { dlog("Install", "relaunch failed: \(error.localizedDescription)", level: .error) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
