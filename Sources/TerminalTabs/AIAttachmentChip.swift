import SwiftUI

struct AIAttachmentChip: View {
    let attachment: AIInputAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.systemImage)
                .foregroundStyle(TerminalTheme.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.title)
                    .lineLimit(1)
                Text(attachment.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let onRemove {
                Button("Remove attachment", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Remove \(attachment.title) from AI input")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.white.opacity(0.045))
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}
