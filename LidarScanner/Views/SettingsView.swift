import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrintService.baseURLKey) private var printBaseURL = PrintService.defaultBaseURL

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
                } header: {
                    Text("Print Server")
                } footer: {
                    Text("Print uploads the scan to \(endpointPreview) and opens the returned STL so you can send it to a slicer app.")
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
