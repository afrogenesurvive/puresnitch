import SwiftUI

/// A sheet for creating a rule by hand, the manual counterpart to the rules a
/// connection alert remembers. The same `Rule.validateForPersistence()` gate
/// the helper applies on its side runs here first, so the form cannot offer a
/// rule the helper would refuse.
struct RuleEditorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var processNameText = ""
    @State private var processPathText = ""
    @State private var processBundleIdText = ""
    @State private var hostText = ""
    @State private var ipText = ""
    @State private var portText = ""
    @State private var direction: RuleDirection = .outgoing
    @State private var action: RuleAction = .ask
    @State private var priority: Int = 100
    @State private var profileText = ""
    @State private var groupText = ""
    @State private var notesText = ""
    @State private var enabled = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(PSTheme.stroke)
            form
            Divider().background(PSTheme.stroke)
            footer
        }
        .frame(width: 440, height: 540)
        .background(PSTheme.bgPrimary)
        .preferredColorScheme(state.themeMode.colorScheme)
        .onAppear {
            if profileText.isEmpty { profileText = state.activeProfile }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(PSTheme.accent)
            Text("New Rule")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(PSTheme.textPrimary)
            Spacer()
        }
        .padding(16)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                fieldGroup("Process", help: "Leave all three blank for a rule that matches any process.") {
                    textField("Name", text: $processNameText)
                    textField("Path", text: $processPathText)
                    textField("Bundle ID", text: $processBundleIdText)
                }

                fieldGroup("Remote endpoint", help: "Host (domain) or IP/CIDR, plus an optional port. Leave blank for any endpoint.") {
                    textField("Domain / host", text: $hostText)
                    textField("IP / CIDR", text: $ipText)
                    textField("Port", text: $portText)
                }

                fieldGroup("Decision") {
                    enumPickerRow("Direction", selection: $direction, cases: RuleDirection.allCases) { $0.rawValue.capitalized }
                    enumPickerRow("Action", selection: $action, cases: RuleAction.allCases) { $0.rawValue.capitalized }
                    stepperRow("Priority", value: $priority, range: 0...1000)
                    Toggle("Enabled", isOn: $enabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .foregroundColor(PSTheme.textPrimary)
                }

                fieldGroup("Labels", help: "Optional. Group and notes show up in the rule list.") {
                    textField("Profile", text: $profileText)
                    textField("Group", text: $groupText)
                    textField("Notes", text: $notesText)
                }

                if !state.helperConnected {
                    Label("The PureSnitch helper is not connected; the rule will be kept locally and pushed once it reconnects.",
                          systemImage: "bolt.horizontal.circle")
                        .font(.system(size: 10))
                        .foregroundColor(PSTheme.accentYellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(PSTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Add Rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    // MARK: - Building blocks

    private func fieldGroup<Content: View>(
        _ title: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PSTheme.textMuted)
            if let help {
                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(PSTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PSTheme.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func textField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(PSTheme.textSecondary)
                .frame(width: 88, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .foregroundColor(PSTheme.textPrimary)
        }
    }

    private func enumPickerRow<Selection: Hashable>(
        _ label: String,
        selection: Binding<Selection>,
        cases: [Selection],
        title: @escaping (Selection) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(PSTheme.textSecondary)
                .frame(width: 88, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(cases, id: \.self) { value in
                    Text(title(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(PSTheme.textSecondary)
                .frame(width: 88, alignment: .leading)
            Stepper("\(value.wrappedValue)", value: value, in: range)
                .foregroundColor(PSTheme.textPrimary)
        }
    }

    // MARK: - Build + save

    private func nilIfEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func buildRule() throws -> Rule {
        let hostRaw = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ipRaw = ipText.trimmingCharacters(in: .whitespacesAndNewlines)
        let portRaw = portText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Mirror `AppState.resolveAlert`: an IPv4 address typed into the host
        // field is an IP rule, anything else in that field is a domain rule.
        let hostIsIPv4 = Rule.isIPv4Address(hostRaw)
        let remoteHost = !hostRaw.isEmpty && !hostIsIPv4 ? hostRaw : nil
        let remoteIP = hostIsIPv4 ? hostRaw : nilIfEmpty(ipRaw)

        var remotePort: Int?
        if !portRaw.isEmpty {
            guard let parsed = Int(portRaw), (0...65_535).contains(parsed) else {
                throw RuleValidationError.invalidRemotePort
            }
            remotePort = parsed
        }

        let scope: RuleScope
        if remoteHost != nil {
            scope = .domain
        } else if remoteIP != nil {
            scope = .ip
        } else if remotePort != nil {
            scope = .port
        } else {
            scope = .any
        }

        let profile = nilIfEmpty(profileText) ?? state.activeProfile
        let rule = Rule(
            processBundleId: nilIfEmpty(processBundleIdText),
            processPath: nilIfEmpty(processPathText),
            processName: nilIfEmpty(processNameText),
            remoteHost: remoteHost,
            remoteIP: remoteIP,
            remotePort: remotePort,
            direction: direction,
            action: action,
            scope: scope,
            priority: priority,
            profile: profile,
            groupName: nilIfEmpty(groupText),
            notes: nilIfEmpty(notesText),
            enabled: enabled
        )
        try rule.validateForPersistence()
        return rule
    }

    private func save() {
        do {
            let rule = try buildRule()
            state.addRule(rule)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
