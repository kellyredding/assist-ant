import AppKit
import SwiftUI
import Galactic

/// Terminal settings tab. Hosts the Font, Scrollback, Cursor, and Shell cards
/// for the Terminal tab's panes — minus the color-theme card, since the theme
/// is hardcoded. Card order follows Galaxy's Terminal tab so the two read
/// alike side by side.
struct TerminalSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var fontSizeText: String = ""
    @State private var scrollbackText: String = ""
    @State private var shellHeightPercentText: String = ""
    @FocusState private var shellHeightFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            // Font
            SettingsCard(title: "Font") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Family") {
                        Picker(
                            "",
                            selection: $settingsManager.settings.terminalFontFamily
                        ) {
                            ForEach(Self.monospacedFontFamilies, id: \.self) { family in
                                Text(family)
                                    .font(.custom(family, size: 13))
                                    .tag(family)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .trailing)
                    }

                    SettingsRow(label: "Default size") {
                        HStack(spacing: 4) {
                            TextField("", text: $fontSizeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.trailing)
                                .onAppear {
                                    fontSizeText = "\(Int(settingsManager.settings.defaultTerminalFontSize))"
                                }
                                .onChange(of: fontSizeText) { _, newValue in
                                    if let value = Double(newValue) {
                                        let clamped = min(
                                            max(value, AppSettings.terminalFontSizeRange.lowerBound),
                                            AppSettings.terminalFontSizeRange.upperBound
                                        )
                                        settingsManager.settings.defaultTerminalFontSize = clamped
                                    }
                                }
                                .onChange(of: settingsManager.settings.defaultTerminalFontSize) { _, newValue in
                                    let newText = "\(Int(newValue))"
                                    if fontSizeText != newText {
                                        fontSizeText = newText
                                    }
                                }

                            Stepper(
                                "",
                                value: $settingsManager.settings.defaultTerminalFontSize,
                                in: AppSettings.terminalFontSizeRange,
                                step: AppSettings.terminalFontSizeStep
                            )
                            .labelsHidden()

                            Text("pt").foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Scrollback
            SettingsCard(title: "Scrollback") {
                SettingsRow(label: "Buffer size") {
                    HStack(spacing: 4) {
                        TextField("", text: $scrollbackText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onAppear {
                                scrollbackText = Self.formatWithCommas(
                                    settingsManager.settings.terminalScrollbackLines
                                )
                            }
                            .onChange(of: scrollbackText) { _, newValue in
                                if let value = Self.parseCommaNumber(newValue) {
                                    let clamped = min(
                                        max(value, AppSettings.terminalScrollbackRange.lowerBound),
                                        AppSettings.terminalScrollbackRange.upperBound
                                    )
                                    settingsManager.settings.terminalScrollbackLines = clamped
                                }
                            }
                            .onChange(of: settingsManager.settings.terminalScrollbackLines) { _, newValue in
                                let newText = Self.formatWithCommas(newValue)
                                if scrollbackText != newText {
                                    scrollbackText = newText
                                }
                            }

                        Text("lines").foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary)
                        Text(AppSettings.estimatedScrollbackMemory(
                            lines: settingsManager.settings.terminalScrollbackLines
                        ))
                        .foregroundColor(.secondary)
                    }
                }
            }

            // Cursor — the caret the engine renders, which doubles as
            // Claude's prompt cursor since Claude draws none of its own.
            SettingsCard(title: "Cursor") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Style") {
                        Picker(
                            "",
                            selection: $settingsManager.settings.terminalCursorStyle
                        ) {
                            ForEach(ShellCursorStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .trailing)
                    }

                    Toggle(
                        "Blink",
                        isOn: $settingsManager.settings.terminalCursorBlink
                    )
                    .toggleStyle(.checkbox)
                }
            }

            // Shell — the pane ⌘⇧T opens below the agent. Only its default
            // height is configurable; the live split is deliberately not
            // remembered across launches.
            SettingsCard(title: "Shell") {
                SettingsRow(label: "Default height") {
                    HStack(spacing: 4) {
                        TextField("", text: $shellHeightPercentText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .multilineTextAlignment(.trailing)
                            .focused($shellHeightFocused)
                            .onAppear {
                                shellHeightPercentText = Self.percentText(
                                    settingsManager.settings
                                        .shellDefaultHeightRatio
                                )
                            }
                            .onChange(of: shellHeightPercentText) { _, newValue in
                                // Commit only a valid in-range number, so
                                // typing "3" on the way to "35" doesn't snap
                                // the setting to the floor and fight the
                                // user's next keystroke. Blur and submit
                                // normalize whatever is left over.
                                guard let percent = Int(newValue) else { return }
                                let ratio = Double(percent) / 100.0
                                if AppSettings.shellDefaultHeightRatioRange
                                    .contains(ratio) {
                                    settingsManager.settings
                                        .shellDefaultHeightRatio = ratio
                                }
                            }
                            .onChange(of: shellHeightFocused) { _, isFocused in
                                if !isFocused { normalizeShellHeightText() }
                            }
                            .onSubmit { normalizeShellHeightText() }
                            .onChange(of: settingsManager.settings
                                .shellDefaultHeightRatio
                            ) { _, newValue in
                                let newText = Self.percentText(newValue)
                                if shellHeightPercentText != newText {
                                    shellHeightPercentText = newText
                                }
                            }

                        Stepper(
                            "",
                            value: $settingsManager.settings
                                .shellDefaultHeightRatio,
                            in: AppSettings.shellDefaultHeightRatioRange,
                            step: AppSettings.shellDefaultHeightRatioStep
                        )
                        .labelsHidden()

                        Text("%").foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Shell height

    private static func percentText(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))"
    }

    /// Settle the field once the user is done with it: clamp an out-of-range
    /// number into the allowed window, and restore the current setting when
    /// the field was left empty or unparseable.
    private func normalizeShellHeightText() {
        let range = AppSettings.shellDefaultHeightRatioRange
        let setting = settingsManager.settings.shellDefaultHeightRatio

        guard let percent = Int(shellHeightPercentText) else {
            shellHeightPercentText = Self.percentText(setting)
            return
        }
        let clamped = min(
            max(Double(percent) / 100.0, range.lowerBound), range.upperBound
        )
        if clamped != setting {
            settingsManager.settings.shellDefaultHeightRatio = clamped
        }
        let clampedText = Self.percentText(clamped)
        if shellHeightPercentText != clampedText {
            shellHeightPercentText = clampedText
        }
    }

    // MARK: - Font enumeration

    /// CJK families that report as fixed-pitch but aren't suitable for
    /// terminal display.
    private static let cjkFontFamilies: Set<String> = [
        "Lantinghei TC", "Lantinghei SC", "PCMyungjo",
        "Osaka", "Osaka\u{2212}\u{7B49}\u{5E45}",
    ]

    /// All monospaced font families suitable for terminal display, sorted.
    /// Includes "SF Mono" (the system monospaced font, which isn't
    /// enumerable via NSFontManager).
    static let monospacedFontFamilies: [String] = {
        let fontManager = NSFontManager.shared
        var families = fontManager.availableFontFamilies.filter { family in
            guard !cjkFontFamilies.contains(family) else { return false }
            guard let members = fontManager.availableMembers(ofFontFamily: family),
                  let firstMember = members.first,
                  let postscriptName = firstMember[0] as? String,
                  let font = NSFont(name: postscriptName, size: 13.0) else {
                return false
            }
            return font.isFixedPitch
        }
        families.append("SF Mono")
        return families.sorted()
    }()

    // MARK: - Comma formatting

    private static func formatWithCommas(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func parseCommaNumber(_ text: String) -> Int? {
        Int(text.replacingOccurrences(of: ",", with: ""))
    }
}
