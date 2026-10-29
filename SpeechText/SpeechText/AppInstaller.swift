// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Security
import SpeechTextCore

/// The disk image's half of installing: opening the copy a drag put in Applications, or
/// moving an app that was opened straight from the image into Applications. The decision is `InstallLocation` (SetupServices.swift); this
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
        isLeaving = true

        // Dragged to Applications, then double-clicked in the image, as its window says:
        // open that copy and go.
        if case .openInstalled(let path) = DiskImageLaunch.decide(runningBuild: build(of: Bundle.main.bundleURL),
                                                                  copies: installedCopies()) {
            dlog("Install", "running from the disk image — opening the copy at \(path)")
            openInstalled(URL(fileURLWithPath: path))
            return true
        }

        dlog("Install", "running from the disk image \(image?.imagePath ?? "(translocated)") — offering the move")

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

    // MARK: Dragged to Applications

    /// The copies a drag may have put in Applications, the shared folder first.
    private static func installedCopies() -> [InstalledCopy] {
        let name = Bundle.main.bundleURL.lastPathComponent
        let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        return folders.map { $0.appendingPathComponent(name) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { InstalledCopy(path: $0.path, build: build(of: $0), isSameSigner: isSignedLikeThisCopy($0)) }
    }

    private static func build(of bundle: URL) -> String {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleVersion"] as? String ?? "0"
    }

    /// Whether the bundle at `url` is valid and satisfies this copy's designated
    /// requirement — the same app, signed by the same team.
    private static func isSignedLikeThisCopy(_ url: URL) -> Bool {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var other: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &other) == errSecSuccess, let other
        else { return false }
        let status = SecStaticCodeCheckValidity(other, [], requirement)
        if status != errSecSuccess { dlog("Install", "\(url.path) is not signed like this copy (\(status))") }
        return status == errSecSuccess
    }

    /// Opens the installed copy — or, when it is already running, brings it forward, where
    /// the reopen opens its main window — and quits this one.
    @MainActor
    private static func openInstalled(_ url: URL) {
        let isRunning = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        if !isRunning {
            // A Finder copy keeps the quarantine flag the user has just answered for this
            // copy; the signature check above is what makes it ours to clear, so macOS
            // does not ask "downloaded from the Internet — open it?" a second time.
            clearQuarantine(url)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Only for a launch: with it, a copy already running would get a second instance.
        configuration.createsNewApplicationInstance = !isRunning
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { dlog("Install", "opening \(url.path) failed: \(error.localizedDescription)", level: .error) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func clearQuarantine(_ url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "-r", "com.apple.quarantine", url.path]
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()
    }

    // MARK: Moving into Applications

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
        clearQuarantine(destination)

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
