//
//  LoginView.swift
//  DataExchangeViewer
//

import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) private var auth

    var body: some View {
        VStack(spacing: 20) {
            Text("Data Exchange Viewer")
                .font(.largeTitle.bold())

            if let lastError = auth.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await auth.login() }
            } label: {
                if auth.isBusy {
                    ProgressView()
                } else {
                    Text("Login with Autodesk")
                }
            }
            .disabled(auth.isBusy)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
