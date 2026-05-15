import SwiftUI

struct OS1Commands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu(L10n.string("Hermes")) {
            Button(L10n.string("New Host")) {
                appState.requestNewConnectionEditorFromCommand()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(L10n.string("New Chat")) {
                appState.requestNewSessionFromCommand()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(appState.activeConnection == nil || appState.isSendingSessionMessage)

            Button(L10n.string("New Terminal Tab")) {
                appState.openNewTerminalTabFromCommand()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(appState.activeConnection == nil)

            Divider()

            Button(L10n.string("Toggle Voice Mode")) {
                appState.toggleRealtimeVoiceMode()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Button(L10n.string("Refresh Current Section")) {
                Task {
                    await appState.refreshCurrentSectionFromCommand()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!appState.canRefreshCurrentSection)

            Button(L10n.string("Save Current File")) {
                Task {
                    await appState.saveSelectedWorkspaceFile()
                }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!appState.canSaveCurrentWorkspaceFile)
        }

        CommandMenu(L10n.string("Navigate")) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) { index, section in
                let button = Button(L10n.string("Show %@", section.title)) {
                    appState.requestSectionSelection(section)
                }
                .disabled(!appState.isSectionAvailable(section))

                // Cmd+1..Cmd+9 cover the first nine sections; the rest go
                // unshortcut (Character("\(10)") would crash since
                // multi-character strings are invalid for Character).
                if index < 9 {
                    button.keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")),
                        modifiers: [.command]
                    )
                } else {
                    button
                }
            }
        }
    }
}
