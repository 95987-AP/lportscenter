import AppKit
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private enum SystemProcessClassifier {
    static let knownSystemCommands: Set<String> = [
        "controlcenter",
        "rapportd",
        "mDNSResponder".lowercased(),
        "sharingd",
        "locationd",
        "airportd",
        "bluetoothd",
        "distnoted",
        "identityservicesd",
        "nsurlsessiond",
        "cfprefsd",
        "powerd",
        "wifianalyticsd",
        "configd",
        "apsd",
        "notifyd",
    ]

    static func isLikelySystemProcess(command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return false
        }
        if knownSystemCommands.contains(normalized) {
            return true
        }
        return normalized.hasPrefix("com.apple.")
    }
}

struct OpenPort: Identifiable, Hashable {
    let pid: Int
    let command: String
    let port: Int
    let address: String

    var id: String { "\(pid)-\(port)" }
    var localhostURL: URL? { URL(string: "http://localhost:\(port)") }
    var appDisplayName: String { command.isEmpty ? "unknown app" : command }
    var isLikelySystemProcess: Bool { SystemProcessClassifier.isLikelySystemProcess(command: command) }
}

enum PortsError: LocalizedError {
    case invalidUTF8
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Nie udało się odczytać wyniku lsof (UTF-8)."
        case .commandFailed(let message):
            return "lsof zakończył się błędem: \(message)"
        }
    }
}

final class PortsService {
    func fetchOpenPorts() throws -> [OpenPort] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? "unknown"
            throw PortsError.commandFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else {
            throw PortsError.invalidUTF8
        }

        return parseLsofFields(raw)
    }

    private func parseLsofFields(_ raw: String) -> [OpenPort] {
        var results: [OpenPort] = []
        var seen = Set<String>()
        var currentPID: Int?
        var currentCommand: String = ""

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                currentPID = Int(value)
            case "c":
                currentCommand = value
            case "n":
                guard let pid = currentPID else { continue }
                guard let (address, port) = extractAddressAndPort(from: value) else { continue }

                let key = "\(pid)-\(port)"
                if seen.contains(key) { continue }
                seen.insert(key)

                results.append(
                    OpenPort(
                        pid: pid,
                        command: currentCommand.isEmpty ? "unknown" : currentCommand,
                        port: port,
                        address: address
                    )
                )
            default:
                continue
            }
        }

        return results.sorted {
            if $0.port == $1.port { return $0.pid < $1.pid }
            return $0.port < $1.port
        }
    }

    private func extractAddressAndPort(from nameField: String) -> (String, Int)? {
        // Examples: "*:5000", "127.0.0.1:5432", "[::1]:5173"
        guard let colon = nameField.lastIndex(of: ":") else { return nil }
        let address = String(nameField[..<colon])
        let portString = String(nameField[nameField.index(after: colon)...])
        guard let port = Int(portString) else { return nil }
        return (address, port)
    }
}

@MainActor
final class PortsViewModel: ObservableObject {
    @Published var ports: [OpenPort] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var showSystemProcesses = false

    private let service = PortsService()
    private var refreshTask: Task<Void, Never>?

    var displayedPorts: [OpenPort] {
        if showSystemProcesses {
            return ports
        }
        return ports.filter { !$0.isLikelySystemProcess }
    }

    var hiddenSystemPortsCount: Int {
        ports.reduce(into: 0) { partialResult, port in
            if port.isLikelySystemProcess {
                partialResult += 1
            }
        }
    }

    func startAutoRefresh() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
    }

    func refresh() {
        isLoading = true
        defer { isLoading = false }

        do {
            ports = try service.fetchOpenPorts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openInBrowser(_ port: OpenPort) {
        guard let url = port.localhostURL else { return }
        NSWorkspace.shared.open(url)
    }

    func terminateProcess(_ port: OpenPort) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-TERM", String(port.pid)]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                refresh()
            } else {
                errorMessage = "Nie udało się zamknąć PID \(port.pid)."
            }
        } catch {
            errorMessage = "Błąd kill: \(error.localizedDescription)"
        }
    }
}

struct MenuView: View {
    @ObservedObject var vm: PortsViewModel

    var body: some View {
        let visiblePorts = vm.displayedPorts

        VStack(alignment: .leading, spacing: 8) {
            if vm.isLoading && visiblePorts.isEmpty {
                Text("Ładowanie…")
            } else if visiblePorts.isEmpty {
                if vm.ports.isEmpty {
                    Text("Brak otwartych portów")
                } else {
                    Text("Brak portów (systemowe ukryte)")
                }
            } else {
                ForEach(visiblePorts) { port in
                    PortRowView(
                        port: port,
                        disableClose: port.isLikelySystemProcess,
                        onClose: { vm.terminateProcess(port) },
                        onOpen: { vm.openInBrowser(port) }
                    )
                }
            }

            if vm.hiddenSystemPortsCount > 0 && !vm.showSystemProcesses {
                Text("Ukryto \(vm.hiddenSystemPortsCount) procesów systemowych")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            if let error = vm.errorMessage {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Toggle("Pokaż systemowe", isOn: $vm.showSystemProcesses)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10))

            HStack(spacing: 8) {
                Button("Odśwież") {
                    vm.refresh()
                }
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium))

                Button("Zakończ aplikację") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(8)
    }
}

struct PortRowView: View {
    let port: OpenPort
    let disableClose: Bool
    let onClose: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text("localhost:\(port.port)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Text(port.appDisplayName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("\(port.command) (PID \(port.pid))")

            Spacer(minLength: 6)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(disableClose)
            .opacity(disableClose ? 0.35 : 1)
            .help(disableClose ? "Proces systemowy — zamykanie zablokowane" : "Zamknij PID \(port.pid)")

            Button(action: onOpen) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Otwórz localhost:\(port.port)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}

@main
struct OpenPortsMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = PortsViewModel()

    var body: some Scene {
        MenuBarExtra("Ports", systemImage: "door.left.hand.open") {
            MenuView(vm: vm)
                .frame(minWidth: 240)
                .onAppear {
                    vm.startAutoRefresh()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
