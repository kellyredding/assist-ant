import AppKit
import SwiftUI

/// Agent settings tab. Hosts the Font card (family + default size) and the
/// Scrollback card for the embedded agent terminal — minus the color-theme
/// card (the theme is hardcoded) and the shell subcard.
struct AgentSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var fontSizeText: String = ""
    @State private var scrollbackText: String = ""

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

            Spacer()
        }
        .padding(20)
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
