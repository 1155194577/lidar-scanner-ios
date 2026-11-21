import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrintService.baseURLKey) private var printBaseURL = PrintService.defaultBaseURL
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
                    Text("Print uploads the scan to \(endpointPreview) and opens the returned STL so you can send it to a slicer app. The token is sent as a Bearer token and kept in the Keychain.")
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
