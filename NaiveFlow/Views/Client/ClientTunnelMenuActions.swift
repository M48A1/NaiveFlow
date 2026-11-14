import SwiftUI
import NetworkExtension

struct ClientTunnelMenuActions: View {
    @Environment(ClientModel.self) private var model
    @Environment(TunnelController.self) private var tunnel

    private var canRun: Bool {
        tunnel.isManagerReady && !tunnel.isPreparingConnection && !model.isBusy && model.hasApplied &&
            (tunnel.rawStatus == .disconnected || tunnel.rawStatus == .invalid)
    }
    private var canStop: Bool {
        tunnel.isManagerReady && !model.isBusy && (tunnel.hasRunningTunnel || tunnel.isPreparingConnection)
    }

    var body: some View {
        Button("Run", systemImage: "play.fill") {
            guard canRun else { return }
            tunnel.startError = nil
            model.operations.tunnel.connect()
        }.disabled(!canRun)
        Button("Stop", systemImage: "stop.fill") {
            guard canStop else { return }
            model.operations.tunnel.disconnect()
        }.disabled(!canStop)
    }
}
