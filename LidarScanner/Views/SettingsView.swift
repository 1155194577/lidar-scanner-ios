import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrintService.baseURLKey) private var printBaseURL = PrintService.defaultBaseURL
    @AppStorage(FaceScanModel.turnHeadKey) private var faceTurnHead = false
    @AppStorage(PrintService.optimiseKey) private var optimise = false
    @State private var printToken = KeychainStore.read(PrintService.tokenKey) ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Print server URL", text: $printBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("printBaseURLField")
                    Button("Reset to Default") { printBaseURL = PrintService.defaultBaseURL }
                        .disabled(printBaseURL == PrintService.defaultBaseURL)
                    SecureField("Print token", text: $printToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("printTokenField")
                        .onChange(of: printToken) { _, token in
                            KeychainStore.write(token.trimmingCharacters(in: .whitespacesAndNewlines), account: PrintService.tokenKey)
                        }
                } header: {
                    Text("Print Server")
                } footer: {
                    Text("Print uploads the scan to \(endpointPreview). You can save the returned STL in My Scans or share it with a slicer app. The token is sent as a Bearer token and kept in the Keychain.")
                }
                Section {
                    Toggle("Save print material", isOn: $optimise)
                        .accessibilityIdentifier("printOptimiseToggle")
                } header: {
                    Text("Print Options")
                } footer: {
                    Text("Ask a compatible print server to remove material from object scans and Photo Prints. Check strength before using an optimised part under load.")
                }
                Section {
                    Toggle("Turn-your-head capture", isOn: $faceTurnHead)
                        .accessibilityIdentifier("faceTurnHeadToggle")
                } header: {
                    Text("Face Scan")
                } footer: {
                    Text("Face Scan also captures your head turned left and right, so the print server only has to guess the back of the head. Needs a print server with multi-view face support.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settingsDoneButton")
                }
            }
        }
    }

    private var endpointPreview: String {
        (try? PrintService(baseURL: printBaseURL).endpoint.absoluteString) ?? "<server>/print"
    }
}
