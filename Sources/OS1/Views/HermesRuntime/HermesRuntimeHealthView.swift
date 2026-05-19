import SwiftUI

struct HermesRuntimeHealthView: View {
    @ObservedObject var viewModel: HermesRuntimeHealthViewModel

    init(viewModel: HermesRuntimeHealthViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        HermesPageContainer(width: .dashboard) {
            VStack(alignment: .leading, spacing: 16) {
                HermesPageHeader(
                    title: "Hermes Runtime",
                    subtitle: viewModel.headerSubtitle
                ) {
                    if viewModel.canRefresh {
                        HermesRefreshButton(isRefreshing: viewModel.isRefreshing) {
                            Task { await viewModel.refresh() }
                        }
                    }
                }

                if let error = viewModel.lastRefreshError {
                    HermesRuntimeErrorBanner(message: error)
                }

                HermesRuntimeHealthPanel(
                    snapshot: viewModel.snapshot,
                    statusRows: viewModel.statusRows,
                    overallLevel: viewModel.overallLevel
                )
            }
        }
    }
}

struct HermesRuntimeHealthPanel: View {
    @Environment(\.os1Theme) private var theme

    let snapshot: HermesRuntimeHealthSnapshot
    let statusRows: [HermesRuntimeComponentStatus]
    let overallLevel: HermesRuntimeHealthLevel

    init(
        snapshot: HermesRuntimeHealthSnapshot,
        statusRows: [HermesRuntimeComponentStatus]? = nil,
        overallLevel: HermesRuntimeHealthLevel? = nil
    ) {
        self.snapshot = snapshot
        self.statusRows = statusRows ?? snapshot.normalizedComponents
        self.overallLevel = overallLevel ?? snapshot.overallLevel
    }

    var body: some View {
        HermesSurfacePanel(
            title: "Runtime health",
            subtitle: "Local Hermes CLI, profile, and feature availability."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    HermesRuntimeLevelGlyph(level: overallLevel)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: overallLevel.displayName)
                            .os1Style(theme.typography.titlePanel)
                            .foregroundStyle(theme.palette.onCoralPrimary)

                        Text(verbatim: "\(snapshot.readyComponentCount) ready, \(snapshot.attentionComponentCount) need attention")
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                    }

                    Spacer(minLength: 12)
                }

                HermesRuntimeIdentityGrid(snapshot: snapshot)

                Divider()
                    .overlay(theme.palette.glassBorder.opacity(0.6))

                HermesRuntimeStatusRows(rows: statusRows)
            }
        }
    }
}

struct HermesRuntimeStatusRows: View {
    @Environment(\.os1Theme) private var theme

    let rows: [HermesRuntimeComponentStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HermesRuntimeComponentStatusRow(status: row)

                if index < rows.count - 1 {
                    Divider()
                        .overlay(theme.palette.glassBorder.opacity(0.45))
                        .padding(.leading, 34)
                }
            }
        }
    }
}

private struct HermesRuntimeIdentityGrid: View {
    let snapshot: HermesRuntimeHealthSnapshot

    private let columns = [
        GridItem(.adaptive(minimum: 190), spacing: 18, alignment: .topLeading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            HermesRuntimeMetric(
                label: "CLI",
                value: snapshot.cli.displayValue,
                detail: snapshot.cli.supportingDetail,
                emphasizeValue: snapshot.cli.level == .ready
            )

            HermesRuntimeMetric(
                label: "HERMES_HOME",
                value: snapshot.hermesHome.displayPath,
                detail: snapshot.hermesHome.supportingDetail,
                isMonospaced: true,
                emphasizeValue: snapshot.hermesHome.level == .ready
            )

            HermesRuntimeMetric(
                label: "Provider",
                value: snapshot.activeSelection.providerDisplay,
                detail: snapshot.activeSelection.supportingDetail,
                emphasizeValue: snapshot.activeSelection.providerName != nil
            )

            HermesRuntimeMetric(
                label: "Model",
                value: snapshot.activeSelection.modelDisplay,
                emphasizeValue: snapshot.activeSelection.modelName != nil
            )
        }
    }
}

private struct HermesRuntimeMetric: View {
    @Environment(\.os1Theme) private var theme

    let label: String
    let value: String
    var detail: String?
    var isMonospaced = false
    var emphasizeValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            Text(verbatim: value)
                .font(valueFont)
                .foregroundStyle(emphasizeValue ? theme.palette.onCoralPrimary : theme.palette.onCoralSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .textSelection(.enabled)

            if let detail {
                Text(verbatim: detail)
                    .font(.system(.caption, design: isMonospaced ? .monospaced : .default))
                    .foregroundStyle(theme.palette.onCoralMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueFont: Font {
        if isMonospaced {
            return .system(.subheadline, design: .monospaced).weight(emphasizeValue ? .semibold : .regular)
        }

        return emphasizeValue
            ? theme.typography.bodyEmphasis.font
            : theme.typography.body.font
    }
}

private struct HermesRuntimeComponentStatusRow: View {
    @Environment(\.os1Theme) private var theme

    let status: HermesRuntimeComponentStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HermesRuntimeLevelGlyph(
                level: status.level,
                systemImage: status.kind.systemImage,
                compact: true
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: status.kind.title)
                        .os1Style(theme.typography.bodyEmphasis)
                        .foregroundStyle(theme.palette.onCoralPrimary)

                    Spacer(minLength: 8)

                    Text(verbatim: status.level.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.level == .unknown ? theme.palette.onCoralMuted : theme.palette.onCoralPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Text(verbatim: status.displayValue)
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .textSelection(.enabled)

                if let path = status.path, path != status.displayValue {
                    Text(verbatim: path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .textSelection(.enabled)
                }

                if let detail = status.detail {
                    Text(verbatim: detail)
                        .os1Style(theme.typography.body)
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct HermesRuntimeLevelGlyph: View {
    @Environment(\.os1Theme) private var theme

    let level: HermesRuntimeHealthLevel
    var systemImage: String?
    var compact = false

    var body: some View {
        Image(systemName: systemImage ?? level.symbolName)
            .font(.system(size: compact ? 14 : 18, weight: .semibold))
            .foregroundStyle(foregroundStyle)
            .frame(width: compact ? 22 : 26, height: compact ? 22 : 26, alignment: .center)
            .accessibilityLabel(Text(verbatim: level.displayName))
    }

    private var foregroundStyle: Color {
        switch level {
        case .ready, .degraded, .unavailable:
            return theme.palette.onCoralPrimary
        case .unknown:
            return theme.palette.onCoralMuted
        }
    }
}

private struct HermesRuntimeErrorBanner: View {
    @Environment(\.os1Theme) private var theme

    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)

            Text(verbatim: message)
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }
}
