//
//  Components.swift
//  HPRT Utility
//
//  Shared building blocks so every panel reads the same way.
//

import SwiftUI
import AppKit

// MARK: - Status chip

struct StatusChip: View {
    let status: CheckStatus
    var text: String? = nil
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .imageScale(compact ? .small : .medium)
            if let text, !compact {
                Text(text).font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 3)
        .background(
            compact ? nil :
                Capsule().fill(status.tint.opacity(0.12))
        )
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var systemImage: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .imageScale(.medium)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title).font(.headline)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let accessory { accessory }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

// MARK: - Rows

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = true
    var selectable = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 190, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

struct CheckRow: View {
    let check: Check
    var onRemedy: ((Remedy) -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusChip(status: check.status, compact: true)
                    .frame(width: 18)

                Text(check.title)
                    .frame(width: 180, alignment: .leading)
                    .foregroundStyle(.primary)

                Text(check.value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if check.detail != nil {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide details" : "Show details")
                }

                if let remedy = check.remedy, let onRemedy {
                    Button(remedy.title) { onRemedy(remedy) }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.medium))
                }
            }

            if expanded, let detail = check.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
                    .padding(.trailing, 8)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Headline banner

struct HeadlineBanner: View {
    let status: CheckStatus
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: status.symbol)
                .font(.system(size: 34))
                .foregroundStyle(status.tint)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(status.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(status.tint.opacity(0.28))
        )
    }
}

// MARK: - Misc

struct PanelScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.largeTitle.weight(.bold))
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                content
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EmptyHint: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct MonoLog: View {
    let lines: [String]
    var colorise: ((String) -> CheckStatus)? = nil
    var maxHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colorise.map { $0(line) }.map(tint) ?? Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .frame(height: maxHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func tint(_ status: CheckStatus) -> Color {
        status == .unknown ? .primary : status.tint
    }
}
