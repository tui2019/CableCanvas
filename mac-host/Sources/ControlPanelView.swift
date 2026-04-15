import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let hasConnectedDevice = viewModel.connectedDeviceSerial != nil
        let canStartNow = hasConnectedDevice && !viewModel.isInstallingAndroidClient
        VStack(alignment: .leading, spacing: 10) {
            Text("CableCanvas Host")
                .font(.headline)

            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(viewModel.connectedDeviceLabel)
                .font(.caption2)
                .foregroundStyle(viewModel.hasConnectedAdbDevice ? .green : .secondary)

            HStack(spacing: 8) {
                Button("Create Virtual Monitor") {
                    viewModel.createVirtualDisplay()
                }
                Button("Remove Virtual Monitor") {
                    viewModel.destroyVirtualDisplay()
                }
                if hasConnectedDevice {
                    Button("Create + Start Stream") {
                        viewModel.createVirtualDisplayAndStartStreaming()
                    }
                    .disabled(viewModel.isInstallingAndroidClient)
                }
            }

            HStack(spacing: 8) {
                if viewModel.isStreaming {
                    Button("Stop Stream") {
                        viewModel.stopStreaming()
                    }
                    .keyboardShortcut(.defaultAction)
                } else if canStartNow {
                    Button("Start Stream") {
                        viewModel.startStreaming()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onChange(of: viewModel.settings) { _ in
            viewModel.saveSettings()
        }
    }
}
