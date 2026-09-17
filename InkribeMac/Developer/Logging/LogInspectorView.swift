#if DEBUG
import AppKit
import SwiftUI

struct LogInspectorView: View {
    @ObservedObject var store: LogStore

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Copy Log", action: copyLog)
                    .disabled(store.entries.isEmpty)
                Button("Clear", action: store.clear)
                    .disabled(store.entries.isEmpty)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                            Text(logLine(entry))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    index.isMultiple(of: 2)
                                        ? Color.clear
                                        : Color.primary.opacity(0.05)
                                )
                                .contextMenu {
                                    Button("Copy Log") {
                                        copy(entry)
                                    }
                                }
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: store.entries.count) {
                    guard let id = store.entries.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func logLine(_ entry: LogEntry) -> String {
        let timestamp = timestampFormatter.string(from: entry.timestamp)
        let line = "\(timestamp) [\(entry.level)] \(entry.label): \(entry.message)"
        guard let metadata = entry.metadata else { return line }
        return "\(line)\n  \(metadata)"
    }

    private func copyLog() {
        copyToPasteboard(store.entries.map(logLine).joined(separator: "\n\n"))
    }

    private func copy(_ entry: LogEntry) {
        copyToPasteboard(logLine(entry))
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
