import SwiftUI
import CoreMotion
import CoreBluetooth
import UIKit

// ── UUIDs (devono corrispondere al Java) ──────────────────────────────────────
private let SERVICE_UUID = CBUUID(string: "0000EE01-0000-1000-8000-00805F9B34FB")
private let MAG_UUID     = CBUUID(string: "0000EE02-0000-1000-8000-00805F9B34FB")
private let CTRL_UUID    = CBUUID(string: "0000EE03-0000-1000-8000-00805F9B34FB")

@main
struct MagCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

// ── Controller ────────────────────────────────────────────────────────────────
@MainActor
final class MagController: NSObject, ObservableObject {

    @Published var bleStatus  = "In attesa del Quest…"
    @Published var isStreaming = false
    @Published var hz: Int    = 0
    @Published var bx: Float = 0
    @Published var by: Float = 0
    @Published var bz: Float = 0

    // CoreBluetooth
    private var peripheralMgr: CBPeripheralManager!
    private var magCharacteristic: CBMutableCharacteristic!
    private var ctrlCharacteristic: CBMutableCharacteristic!
    private var subscribedCentral: CBCentral?

    // CoreMotion
    private let motion   = CMMotionManager()
    private let motionQ  = OperationQueue()
    private var hzTimer: Timer?
    private var pktCount = 0

    override init() {
        super.init()
        motionQ.qualityOfService = .userInteractive
        motionQ.maxConcurrentOperationCount = 1
        setupBLE()
    }

    // ── Setup BLE Peripheral ──────────────────────────────────────────────────
    private func setupBLE() {
        peripheralMgr = CBPeripheralManager(delegate: self, queue: .global(qos: .userInteractive))
    }

    private func startAdvertising() {
        // Carattere dati mag (notify, read)
        magCharacteristic = CBMutableCharacteristic(
            type: MAG_UUID,
            properties: [.notify],
            value: nil,
            permissions: .readable
        )
        // Carattere controllo (write without response)
        ctrlCharacteristic = CBMutableCharacteristic(
            type: CTRL_UUID,
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: .writeable
        )
        let service = CBMutableService(type: SERVICE_UUID, primary: true)
        service.characteristics = [magCharacteristic, ctrlCharacteristic]
        peripheralMgr.add(service)
        peripheralMgr.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID],
            CBAdvertisementDataLocalNameKey: "MagCompanion"
        ])
        bleStatus = "Advertising…"
    }

    // ── Streaming mag ─────────────────────────────────────────────────────────
    private func startStreaming() {
        guard !isStreaming, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval  = 1.0 / 90.0   // 90 Hz = stesso rate del Quest
        motion.magnetometerUpdateInterval  = 1.0 / 90.0
        motion.startMagnetometerUpdates()

        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: motionQ) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.sendMagPacket(dm)
        }

        hzTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hz = self.pktCount; self.pktCount = 0
            }
        }
        isStreaming = true
        bleStatus   = "Streaming 90 Hz"
    }

    private func stopStreaming() {
        guard isStreaming else { return }
        motion.stopDeviceMotionUpdates()
        motion.stopMagnetometerUpdates()
        hzTimer?.invalidate(); hzTimer = nil
        isStreaming = false
        hz = 0
        bleStatus = subscribedCentral != nil ? "Connesso – in attesa di START" : "Advertising…"
    }

    // ── Costruzione e invio pacchetto binario ─────────────────────────────────
    // Formato: int64 ts(8) + float32×9 (36) = 44 bytes, little-endian
    private func sendMagPacket(_ dm: CMDeviceMotion) {
        let ts  = Int64(Date().timeIntervalSince1970 * 1000)
        let mf  = dm.magneticField.field
        let rot = dm.attitude.rotationMatrix

        // Calibrato device frame
        let bx  = Float(mf.x), by = Float(mf.y), bz = Float(mf.z)
        // World frame (gravity-aligned)
        let bxr = Float(rot.m11*mf.x + rot.m12*mf.y + rot.m13*mf.z)
        let byr = Float(rot.m21*mf.x + rot.m22*mf.y + rot.m23*mf.z)
        let bzr = Float(rot.m31*mf.x + rot.m32*mf.y + rot.m33*mf.z)
        // Non calibrato
        let raw = motion.magnetometerData?.magneticField
        let bxu = Float(raw?.x ?? 0), byu = Float(raw?.y ?? 0), bzu = Float(raw?.z ?? 0)

        var data = Data(capacity: 44)
        data.appendLE(ts)
        data.appendLE(bx);  data.appendLE(by);  data.appendLE(bz)
        data.appendLE(bxr); data.appendLE(byr); data.appendLE(bzr)
        data.appendLE(bxu); data.appendLE(byu); data.appendLE(bzu)

        peripheralMgr.updateValue(data, for: magCharacteristic, onSubscribedCentrals: nil)
        pktCount += 1

        if pktCount % 9 == 0 {
            let (cbx, cby, cbz) = (bx, by, bz)
            Task { @MainActor [weak self] in
                self?.bx = cbx; self?.by = cby; self?.bz = cbz
            }
        }
    }
}

// ── CBPeripheralManagerDelegate ───────────────────────────────────────────────
extension MagController: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        if pm.state == .poweredOn {
            Task { @MainActor in self.startAdvertising() }
        }
    }

    nonisolated func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                              didSubscribeTo char: CBCharacteristic) {
        guard char.uuid == MAG_UUID else { return }
        Task { @MainActor in
            self.subscribedCentral = central
            self.bleStatus = "Quest connesso – in attesa di START"
        }
    }

    nonisolated func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                              didUnsubscribeFrom char: CBCharacteristic) {
        Task { @MainActor in
            self.subscribedCentral = nil
            self.stopStreaming()
            self.bleStatus = "Quest disconnesso"
        }
    }

    nonisolated func peripheralManager(_ pm: CBPeripheralManager,
                              didReceiveWrite requests: [CBATTRequest]) {
        for req in requests where req.characteristic.uuid == CTRL_UUID {
            guard let data = req.value,
                  let cmd  = String(data: data, encoding: .utf8) else { continue }
            Task { @MainActor in
                switch cmd.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "START": self.startStreaming()
                case "STOP":  self.stopStreaming()
                default: break
                }
            }
        }
    }
}

// ── Helper: appende valori little-endian a Data ───────────────────────────────
private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &le, Array.init))
    }
    mutating func appendLE(_ v: Float) {
        appendLE(v.bitPattern)
    }
}

// ── UI ────────────────────────────────────────────────────────────────────────
struct ContentView: View {
    @StateObject private var ctrl = MagController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                // Status
                HStack(spacing: 8) {
                    Circle()
                        .fill(ctrl.isStreaming ? .green : (ctrl.bleStatus.contains("connesso") ? .yellow : .orange))
                        .frame(width: 10, height: 10)
                    Text(ctrl.bleStatus).foregroundStyle(.white).font(.subheadline)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.white.opacity(0.1), in: Capsule())

                if ctrl.isStreaming {
                    VStack(spacing: 4) {
                        MagLine(label: "Bx", value: ctrl.bx)
                        MagLine(label: "By", value: ctrl.by)
                        MagLine(label: "Bz", value: ctrl.bz)
                        MagLine(label: "|B|", value: sqrt(ctrl.bx*ctrl.bx + ctrl.by*ctrl.by + ctrl.bz*ctrl.bz))
                    }
                    .padding()
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                    Text("\(ctrl.hz) Hz")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(ctrl.hz >= 80 ? .green : .orange)
                }

                Spacer()
                Text("Monta il telefono sul visore.\nStart/Stop automatici dal Quest.")
                    .multilineTextAlignment(.center).font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding()
        }
    }
}

struct MagLine: View {
    let label: String; let value: Float
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 36, alignment: .leading)
            Spacer()
            Text(String(format: "%+.2f µT", value)).monospacedDigit().foregroundStyle(.white)
        }
    }
}
