import SwiftUI

struct SkillDetailView: View {
    let summary: SkillSummary?
    let detail: SkillDetail?
    let errorMessage: String?
    let isLoading: Bool
    let onCreate: () -> Void
    let onEdit: () -> Void

    private let metadataColumns = [
        GridItem(.adaptive(minimum: 180), alignment: .topLeading)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let detail {
                    headerPanel(detail)

                    if let description = detail.trimmedDescription {
                        HermesSurfacePanel(
                            title: "Description",
                            subtitle: "Frontmatter summary for the selected skill."
                        ) {
                            Text(description)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }

                    if !detail.tags.isEmpty || !detail.relatedSkills.isEmpty || !detail.featureBadges.isEmpty {
                        metadataPanel(detail)
                    }

                    HermesSurfacePanel(
                        title: "SKILL.md",
                        subtitle: "Full source content loaded from the active host."
                    ) {
                        HermesInsetSurface {
                            Text(detail.markdownContent)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                } else if let summary, isLoading {
                    HermesSurfacePanel {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                Text(summary.resolvedName)
                                    .font(.os1TitleSection)
                                    .fontWeight(.semibold)

                                if !summary.source.isLocal {
                                    HermesBadge(text: summary.sourceLabel, tint: .secondary)
                                }
                            }

                            Text(summary.relativePath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.os1OnCoralSecondary)
                                .textSelection(.enabled)

                            HermesLoadingState(
                                label: "Loading skill detail…",
                                minHeight: 140
                            )
                        }
                    }
                } else if let errorMessage, summary != nil {
                    HermesSurfacePanel {
                        ContentUnavailableView(
                            "Unable to load skill detail",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }
                } else {
                    HermesSurfacePanel {
                        VStack(alignment: .leading, spacing: 18) {
                            ContentUnavailableView(
                                L10n.string("Select a skill"),
                                systemImage: "book.closed",
                                description: Text(L10n.string("Choose a Hermes skill from the active host to inspect its metadata and full SKILL.md."))
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)

                            Button {
                                onCreate()
                            } label: {
                                Label(L10n.string("Create New Skill"), systemImage: "plus")
                            }
                            .buttonStyle(.os1Primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private func headerPanel(_ detail: SkillDetail) -> some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(detail.resolvedName)
                                .font(.os1TitleSection)
                                .fontWeight(.semibold)

                            HermesBadge(
                                text: detail.sourceLabel,
                                tint: detail.source.isLocal ? .accentColor : .secondary
                            )
                        }

                        Text(detail.relativePath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.os1OnCoralSecondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        if let category = detail.category {
                            HermesBadge(text: category, tint: .secondary)
                        }

                        Button(L10n.string("Edit SKILL.md")) {
                            onEdit()
                        }
                        .buttonStyle(.os1Secondary)
                        .disabled(detail.isReadOnly)
                    }
                }

                LazyVGrid(columns: metadataColumns, alignment: .leading, spacing: 14) {
                    HermesLabeledValue(
                        label: "Slug",
                        value: detail.slug,
                        isMonospaced: true
                    )

                    HermesLabeledValue(
                        label: "Category",
                        value: detail.category ?? "Root",
                        isMonospaced: detail.category != nil
                    )

                    HermesLabeledValue(
                        label: "Relative path",
                        value: detail.relativePath,
                        isMonospaced: true,
                        emphasizeValue: true
                    )

                    HermesLabeledValue(
                        label: "Source",
                        value: detail.sourceLabel
                    )

                    if let version = detail.version {
                        HermesLabeledValue(
                            label: "Version",
                            value: version,
                            isMonospaced: true
                        )
                    }
                }

                HermesInsetSurface {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("Remote path"))
                            .font(.os1SmallCaps)
                            .foregroundStyle(.os1OnCoralSecondary)

                        Text(detail.skillFilePath)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if detail.isReadOnly {
                    Text(L10n.string("External skill directories are discovery-only in Hermes. This skill is available to inspect here, but edits still belong in the local Hermes skills store."))
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                }
            }
        }
    }

    private func metadataPanel(_ detail: SkillDetail) -> some View {
        HermesSurfacePanel(
            title: "Metadata",
            subtitle: "Optional frontmatter fields and companion directories discovered for this skill."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                if !detail.tags.isEmpty {
                    SkillMetadataSection(title: "Tags") {
                        SkillMetadataBadgeGroup(values: detail.tags, tint: Color.os1OnCoralPrimary)
                    }
                }

                if !detail.relatedSkills.isEmpty {
                    SkillMetadataSection(title: "Related skills") {
                        SkillMetadataBadgeGroup(
                            values: detail.relatedSkills,
                            tint: .secondary,
                            monospaced: true
                        )
                    }
                }

                if !detail.featureBadges.isEmpty {
                    SkillMetadataSection(title: "Companion directories") {
                        HermesWrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            ForEach(detail.featureBadges) { badge in
                                SkillMetadataBadge(text: badge.title, tint: badge.color)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SkillEditorView: View {
    @EnvironmentObject private var appState: AppState

    let mode: SkillEditorMode
    @Binding var draft: SkillDraft
    @Binding var rawMarkdownContent: String
    let detail: SkillDetail?
    let errorMessage: String?
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerPanel

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.os1OnCoralPrimary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.os1OnCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                switch mode {
                case .create:
                    createBasicsPanel
                    createMetadataPanel
                    createInstructionsPanel
                    generatedPreviewPanel
                case .edit:
                    editScopePanel
                    rawMarkdownPanel
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onChange(of: draft.name) { _, _ in
            guard mode == .create else { return }
            draft.refreshSuggestedSlug()
        }
    }

    private var headerPanel: some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string(mode.title))
                        .font(.os1TitleSection)
                        .fontWeight(.semibold)

                    Text(L10n.string(headerSubtitle))
                        .font(.os1Body)
                        .foregroundStyle(.os1OnCoralSecondary)
                }

                HStack(spacing: 10) {
                    Button(L10n.string(mode.actionTitle)) {
                        Task { await onSave() }
                    }
                    .buttonStyle(.os1Primary)
                    .disabled(isSaving || saveDisabled)

                    Button(L10n.string("Cancel"), action: onCancel)
                        .buttonStyle(.os1Secondary)
                        .disabled(isSaving)

                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var createBasicsPanel: some View {
        HermesSurfacePanel(
            title: "Basics",
            subtitle: "Use plain language. The app will turn these fields into the right SKILL.md frontmatter and folder path."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SkillFormField(label: "Skill Name") {
                    TextField(L10n.string("Remote debugging, Deploy to VPS, Research notes"), text: $draft.name)
                        .os1Underlined()
                }

                SkillFormField(label: "Short Description") {
                    TextField(L10n.string("When Hermes should use this skill and what it helps it do."), text: $draft.description, axis: .vertical)
                        .os1Underlined()
                        .lineLimit(2...3)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        SkillFormField(label: "Category Path") {
                            TextField(L10n.string("Optional: agent-workflows, ssh/tools"), text: $draft.categoryPath)
                                .os1Underlined()
                        }

                        SkillFormField(label: "Folder Name") {
                            TextField(L10n.string("deploy-to-vps"), text: $draft.slug)
                                .os1Underlined()
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SkillFormField(label: "Category Path") {
                            TextField(L10n.string("Optional: agent-workflows, ssh/tools"), text: $draft.categoryPath)
                                .os1Underlined()
                        }

                        SkillFormField(label: "Folder Name") {
                            TextField(L10n.string("deploy-to-vps"), text: $draft.slug)
                                .os1Underlined()
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                SkillFormField(label: "Version") {
                    TextField(L10n.string("Optional: 1.0.0"), text: $draft.version)
                        .os1Underlined()
                        .font(.system(.body, design: .monospaced))
                }

                HermesInsetSurface {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("Remote path"))
                            .font(.os1SmallCaps)
                            .foregroundStyle(.os1OnCoralSecondary)

                        Text(generatedRemoteSkillPath)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var createMetadataPanel: some View {
        HermesSurfacePanel(
            title: "Metadata",
            subtitle: "Optional tags and related skills help Hermes and the user understand the role of the skill."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SkillFormField(label: "Tags") {
                    TextField(L10n.string("Comma-separated: ssh, deploy, troubleshooting"), text: $draft.tagsText)
                        .os1Underlined()
                }

                SkillFormField(label: "Related Skills") {
                    TextField(L10n.string("Comma-separated slugs: playwright, security-best-practices"), text: $draft.relatedSkillsText)
                        .os1Underlined()
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("Companion Folders"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.os1OnCoralSecondary)

                    Toggle(L10n.string("Create references/ for longer docs or domain notes"), isOn: $draft.includeReferencesFolder)
                    Toggle(L10n.string("Create scripts/ for deterministic helpers"), isOn: $draft.includeScriptsFolder)
                    Toggle(L10n.string("Create templates/ for reusable output files"), isOn: $draft.includeTemplatesFolder)
                }
            }
        }
    }

    private var createInstructionsPanel: some View {
        HermesSurfacePanel(
            title: "Instructions",
            subtitle: "Write the actual guidance Hermes should follow once the skill triggers."
        ) {
            TextEditor(text: $draft.instructions)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.os1OnCoralPrimary)
                .frame(minHeight: 300)
                .padding(8)
                .background(Color.os1GlassFill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var generatedPreviewPanel: some View {
        HermesSurfacePanel(
            title: "Generated Preview",
            subtitle: "This is the SKILL.md the app will write on the remote Hermes host."
        ) {
            HermesInsetSurface {
                Text(draft.generatedMarkdown)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var editScopePanel: some View {
        HermesSurfacePanel(
            title: "Editing Scope",
            subtitle: "The existing skill path stays fixed while you edit the raw SKILL.md source."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HermesInsetSurface {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("Remote path"))
                            .font(.os1SmallCaps)
                            .foregroundStyle(.os1OnCoralSecondary)

                        Text(existingRemoteSkillPath)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("Companion Folders"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.os1OnCoralSecondary)

                    Toggle(L10n.string("Ensure references/ exists"), isOn: $draft.includeReferencesFolder)
                    Toggle(L10n.string("Ensure scripts/ exists"), isOn: $draft.includeScriptsFolder)
                    Toggle(L10n.string("Ensure templates/ exists"), isOn: $draft.includeTemplatesFolder)
                }
            }
        }
    }

    private var rawMarkdownPanel: some View {
        HermesSurfacePanel(
            title: "SKILL.md",
            subtitle: "Edit the existing skill source directly. Saves are atomic and checked against the last loaded remote version."
        ) {
            TextEditor(text: $rawMarkdownContent)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.os1OnCoralPrimary)
                .frame(minHeight: 420)
                .padding(8)
                .background(Color.os1GlassFill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .create:
            return "Create a new Hermes skill from a guided form instead of writing YAML frontmatter and folder structure by hand."
        case .edit:
            return "Update the existing SKILL.md directly while keeping the remote path fixed and protected by a conflict check."
        }
    }

    private var generatedRemoteSkillPath: String {
        let root = appState.activeConnection?.remoteSkillsPath ?? "~/.hermes/skills"
        let relativePath = draft.relativePath.isEmpty ? "<folder-name>" : draft.relativePath
        return "\(root)/\(relativePath)/SKILL.md"
    }

    private var existingRemoteSkillPath: String {
        detail?.skillFilePath ?? "<selected-skill>"
    }

    private var saveDisabled: Bool {
        switch mode {
        case .create:
            return draft.validationError != nil
        case .edit:
            return rawMarkdownContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private struct SkillFormField<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(label))
                .font(.os1SmallCaps)
                .foregroundStyle(.os1OnCoralSecondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SkillMetadataSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.os1OnCoralSecondary)

            content
        }
    }
}

private struct SkillMetadataBadgeGroup: View {
    let values: [String]
    let tint: Color
    var monospaced = false

    var body: some View {
        HermesWrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(values, id: \.self) { value in
                SkillMetadataBadge(
                    text: value,
                    tint: tint,
                    monospaced: monospaced
                )
            }
        }
    }
}

private struct SkillMetadataBadge: View {
    let text: String
    let tint: Color
    var monospaced = false

    // Tint is accepted for API compatibility but ignored: every metadata
    // badge renders in the unified OS1 on-coral glass palette so that
    // categorical colors (blue/orange/green from SkillFeatureBadge,
    // .secondary from related skills) don't clash with the coral surface.
    var body: some View {
        Text(text)
            .font(monospaced ? .system(.caption, design: .monospaced).weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(.os1OnCoralPrimary)
            .lineLimit(1)
            .truncationMode(monospaced ? .middle : .tail)
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.os1GlassFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.os1GlassBorder, lineWidth: 1)
            }
            .help(text)
    }
}
