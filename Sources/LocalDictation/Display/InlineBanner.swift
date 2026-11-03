import SwiftUI

/// An inline banner at the top of a page for a condition that needs the user, instead of an alert.
struct InlineBanner: View {
    struct Content: Identifiable {
        let id: String
        let message: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.accentColor)
            Text(content.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let title = content.actionTitle, let action = content.action {
                Button(title, action: action).controlSize(.large)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
