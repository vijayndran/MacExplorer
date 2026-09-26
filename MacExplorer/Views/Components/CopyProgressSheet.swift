import SwiftUI

/// Modal progress sheet shown during a paste/copy. Presents a determinate bar
/// when the total size is known, an indeterminate one otherwise, and a Cancel
/// button wired to the shared cancellation flag.
struct CopyProgressSheet: View {
    let progress: CopyProgress

    private var byteText: String {
        guard progress.bytesTotal > 0 else { return "" }
        let done = ByteCountFormatter.string(fromByteCount: progress.bytesCompleted, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
        return "\(done) of \(total)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copying…")
                        .font(.headline)
                    if progress.totalCount > 1 {
                        Text("Item \(progress.currentIndex) of \(progress.totalCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if !progress.currentFileName.isEmpty {
                Text(progress.currentFileName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                Text(byteText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    progress.requestCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
