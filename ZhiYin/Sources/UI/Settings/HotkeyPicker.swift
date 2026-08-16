import SwiftUI

// MARK: - Hotkey Picker (cross-disables the option in use by the other role)

/// Menu-style picker for HotkeyOption. Greys out the option currently used
/// by the other role (Record vs AI Agent) so the same combo can't drive two
/// independent state machines — the event tap only delivers the press once,
/// whichever handler wins and the other goes silent.
struct HotkeyPicker: View {
    @Binding var selection: HotkeyOption
    /// The hotkey used by the sibling role; rendered disabled in the menu.
    let reservedBy: HotkeyOption

    var body: some View {
        Menu {
            ForEach(HotkeyOption.allCases) { option in
                let isReserved = option != .none && option == reservedBy
                Button {
                    if !isReserved { selection = option }
                } label: {
                    HStack {
                        if selection == option {
                            Image(systemName: "checkmark")
                        }
                        Text("\(option.symbol) \(option.displayName)")
                    }
                }
                .disabled(isReserved)
            }
        } label: {
            HStack {
                Text("\(selection.symbol) \(selection.displayName)")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}