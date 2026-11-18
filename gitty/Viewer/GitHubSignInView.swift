import SwiftUI
import UIKit

/// Sign in with GitHub, as a sheet: shows a code, you enter it on github.com (in Safari, where
/// you're likely signed in already), and gitty gets a token that can read only the repositories
/// you chose for its GitHub app. No password is typed into gitty.
struct GitHubSignInView: View {
    let onSignedIn: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .starting
    /// Bumped by Get a New Code, which restarts the sign-in.
    @State private var attempt = 0

    private enum Phase {
        case starting
        case waiting(DeviceCode)
        case signedIn(String?)
        case expired
        case failed(String)
    }

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(onSignedIn: @escaping @MainActor () -> Void) {
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Sign In to GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Cancelled when the sheet closes, which stops the waiting too.
        .task(id: attempt) { await signIn() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .starting:
            ProgressView()
        case .waiting(let code):
            Text("Enter this code on GitHub")
                .font(.headline)
            Text(code.userCode)
                .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
                .accessibilityLabel(code.userCode.map(String.init).joined(separator: " "))
            Button {
                UIPasteboard.general.string = code.userCode
                openURL(code.verificationURI)
            } label: {
                Label("Copy Code and Open GitHub", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for GitHub…")
            }
            .foregroundStyle(.secondary)
            Text("gitty can only read the repositories you choose for its GitHub app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .signedIn(let login):
            Label(login.map { "Signed in as \($0)" } ?? "Signed In", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        case .expired:
            message("The code expired before it was entered.")
        case .failed(let text):
            message(text)
        }
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 16) {
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Get a New Code") { attempt += 1 }
                .buttonStyle(.borderedProminent)
        }
    }

    private func signIn() async {
        phase = .starting
        do {
            let code = try await GitHubAuth.shared.startSignIn()
            phase = .waiting(code)
            let credential = try await GitHubAuth.shared.finishSignIn(code)
            phase = .signedIn(credential.login)
            try await Task.sleep(for: .seconds(1))  // let the check mark show
            onSignedIn()
        } catch GitHubAuthError.codeExpired {
            phase = .expired
        } catch {
            guard !Task.isCancelled else { return }  // the sheet closed
            phase = .failed(error.localizedDescription)
        }
    }
}
