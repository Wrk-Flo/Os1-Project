import SwiftUI

/// Replacement for `Picker(.menu)` that renders the dropdown in the OS1
/// coral palette instead of macOS's system NSPopUpButton menu (which
/// reads as charcoal/black under `.preferredColorScheme(.dark)` and
/// can't be re-tinted). The trigger is a glass-on-coral capsule; the
/// drop is a SwiftUI `.popover` painted with `palette.coral` so we get
/// onCoral text on a coral surface, matching the rest of the app.
///
/// Callers pass display state explicitly (selected label, placeholder,
/// list of options) instead of a generic `Binding`, which keeps the
/// component free of `Hashable` constraints and lets the caller handle
/// nuanced placeholder behavior (e.g. "Pick a workspace first").
struct OS1DropdownMenu: View {
    /// Label shown in the trigger when something is selected. Pass nil
    /// to show the placeholder instead.
    let selectedLabel: String?
    let placeholder: String
    var isDisabled: Bool = false
    let options: [Option]

    @State private var isOpen = false
    @Environment(\.os1Theme) private var theme

    struct Option: Identifiable {
        let id: String
        let label: String
        let isSelected: Bool
        let action: () -> Void
    }

    var body: some View {
        Button {
            guard !isDisabled, !options.isEmpty else { return }
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selectedLabel ?? placeholder)
                    .foregroundStyle(selectedLabel == nil
                                     ? theme.palette.onCoralMuted
                                     : theme.palette.onCoralPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .os1GlassSurface(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || options.isEmpty)
        .opacity((isDisabled || options.isEmpty) ? 0.55 : 1)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { option in
                    OS1DropdownMenuRow(option: option) {
                        option.action()
                        isOpen = false
                    }
                }
            }
            .frame(minWidth: 240)
            .padding(.vertical, 4)
            .background(theme.palette.coral)
        }
    }
}

private struct OS1DropdownMenuRow: View {
    let option: OS1DropdownMenu.Option
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.os1Theme) private var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(option.label)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.palette.onCoralPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHovered ? theme.palette.glassFill : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
