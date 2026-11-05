import SwiftUI

struct ConnectionForm: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let isFirstRun: Bool

    @State private var draft = ConnectionSettings()
    @State private var message: String?
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                TextField("http://homeassistant.local:8123", text: $draft.localURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(Color.inkRaised)
            } header: {
                Text("Your home's address")
            } footer: {
                Text("Works with the iPhone on your home Wi‑Fi. The connection is not encrypted.")
            }

            Section {
                SecureField("Paste the token here", text: $draft.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(Color.inkRaised)
            } header: {
                Text("Home Assistant token")
            } footer: {
                Text("Create it in Home Assistant under Profile, Security, Long-lived access tokens. It is stored in this iPhone's Keychain.")
            }

            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }

            Section {
                Button(isFirstRun ? "Connect" : "Save and reconnect") {
                    do {
                        draft.mode = .local
                        try store.apply(settings: draft)
                        message = nil
                        if !isFirstRun { dismiss() }
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .listRowBackground(Color.inkRaised)
            }

            if !isFirstRun {
                Section {
                    Button("Delete token from this iPhone", role: .destructive) { confirmingDelete = true }
                        .listRowBackground(Color.inkRaised)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.ink)
        .navigationTitle(isFirstRun ? "" : "Settings")
        .safeAreaInset(edge: .top, spacing: 0) {
            if isFirstRun {
                Text("Connect your home")
                    .font(Type.light(38))
                    .foregroundStyle(Color.lamplight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 4)
                    .background(Color.ink)
            }
        }
        .confirmationDialog("Delete the token from this iPhone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.signOut()
                dismiss()
            }
        }
        .onAppear { draft = store.settings ?? draft }
    }
}
