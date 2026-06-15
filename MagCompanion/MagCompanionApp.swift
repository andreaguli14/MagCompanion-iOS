import SwiftUI
import CoreMotion
import CoreBluetooth
import UIKit
import simd

// ── UUIDs ─────────────────────────────────────────────────────────────────────
private let SERVICE_UUID = CBUUID(string: "0000EE01-0000-1000-8000-00805F9B34FB")
private let MAG_UUID     = CBUUID(string: "0000EE02-0000-1000-8000-00805F9B34FB")
private let CTRL_UUID    = CBUUID(string: "0000EE03-0000-1000-8000-00805F9B34FB")

// ── App ───────────────────────────────────────────────────────────────────────
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

    enum CalibrationState: Int, Comparable {
        case uncalibrated = 0
        case low          = 1
        case medium       = 2
        case high         = 3

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(_ accuracy: CMMagneticFieldCalibrationAccuracy) {
            switch accuracy {
            case .uncalibrated: self = .uncalibrated
            case .low:          self = .low
            case .medium:       self = .medium
            case .high:         self = .high
            @unknown default:   self = .uncalibrated
            }
        }

        var label: String {
            switch self {
            case .uncalibrated: return "Non calibrato"
            case .low:          return "Calibrazione bassa"
            case .medium:       return "Calibrazione media"
            case .high:         return "Calibrazione alta"
            }
        }

        var color: Color {
            switch self {
            case .uncalibrated: return .red
            case .low:          return .orange
            case .medium:       return .yellow
            case .high:         return .green
            }
        }

        var isAcceptable: Bool { self >= .medium }
    }

    // ── Published state ───────────────────────────────────────────────────────
    @Published var bleStatus       = "In attesa del Quest…"
    @Published var isStreaming     = false
    @Published var isCalibrating   = false   // calibrazione manuale attiva
    @Published var calibration     = CalibrationState.uncalibrated
    @Published var hz: Int         = 0
    @Published var bx: Float       = 0
    @Published var by: Float       = 0
    @Published var bz: Float       = 0
    @Published var skippedSamples  = 0       // campioni scartati per bassa calibrazione

    // ── CoreBluetooth ─────────────────────────────────────────────────────────
    private var peripheralMgr: CBPeripheralManager!
    private var magCharacteristic: CBMutableCharacteristic!
    private var ctrlCharacteristic: CBMutableCharacteristic!
    private var subscribedCentral: CBCentral?

    // ── CoreMotion ────────────────────────────────────────────────────────────
    private let motion  = CMMotionManager()
    private let motionQ = OperationQueue()
    private var hzTimer: Timer?
    private var pktCount      = 0
    private var pendingStart  = false   // START ricevuto prima di calibrazione ok

    override init() {
        super.init()
        motionQ.qualityOfService = .userInteractive
        motionQ.maxConcurrentOperationCount = 1
        setupBLE()
        startCalibrationMonitor()
    }

    // ── Calibrazione continua ─────────────────────────────────────────────────
    // Monitora l'accuracy anche prima dello streaming per mostrare lo stato all'utente
    private func startCalibrationMonitor() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: motionQ) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let cal = CalibrationState(dm.magneticField.accuracy)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.calibration != cal {
                    self.calibration = cal
                }
                // Se stavamo aspettando calibrazione per far partire lo streaming
                if self.pendingStart && cal.isAcceptable {
                    self.pendingStart = false
                    self.isCalibrating = false
                    self.startStreaming()
                }
            }
        }
    }

    // ── BLE Setup ─────────────────────────────────────────────────────────────
    private func setupBLE() {
        peripheralMgr = CBPeripheralManager(delegate: self, queue: .global(qos: .userInteractive))
    }

    private func startAdvertising() {
        magCharacteristic = CBMutableCharacteristic(
            type: MAG_UUID,
            properties: [.notify],
            value: nil,
            permissions: .readable
        )
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

    // ── Streaming ─────────────────────────────────────────────────────────────
    func requestStart() {
        guard !isStreaming else { return }
        if calibration.isAcceptable {
            isCalibrating = false
            pendingStart  = false
            startStreaming()
        } else {
            // Mostra schermata calibrazione e aspetta
            isCalibrating = true
            pendingStart  = true
            bleStatus     = "Calibra il sensore…"
        }
    }

    private func startStreaming() {
        guard !isStreaming, motion.isDeviceMotionAvailable else { return }

        // Ferma il monitor di calibrazione e riavvia alla frequenza piena
        motion.stopDeviceMotionUpdates()

        skippedSamples = 0
        motion.deviceMotionUpdateInterval = 1.0 / 90.0
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: motionQ) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.onMotion(dm)
        }

        hzTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hz = self.pktCount
                self.pktCount = 0
            }
        }
        isStreaming = true
        bleStatus   = "Streaming 90 Hz"
    }

    func stopStreaming() {
        guard isStreaming else { return }
        motion.stopDeviceMotionUpdates()
        hzTimer?.invalidate(); hzTimer = nil
        isStreaming   = false
        isCalibrating = false
        pendingStart  = false
        hz = 0
        bleStatus = subscribedCentral != nil ? "Connesso – in attesa di START" : "Advertising…"
        // Riavvia il monitor di calibrazione a bassa frequenza
        startCalibrationMonitor()
    }

    // ── Pacchetto magnetico ───────────────────────────────────────────────────
    private func onMotion(_ dm: CMDeviceMotion) {
        let cal = CalibrationState(dm.magneticField.accuracy)

        // Aggiorna stato calibrazione
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.calibration != cal { self.calibration = cal }
        }

        // Scarta campioni non calibrati durante lo streaming
        guard cal.isAcceptable else {
            Task { @MainActor [weak self] in
                self?.skippedSamples += 1
            }
            return
        }

        let ts  = Int64(Date().timeIntervalSince1970 * 1000)
        let mf  = dm.magneticField.field

        // Rotazione in world frame con double precision (come la master app)
        let quat = dm.attitude.quaternion
        let q    = simd_quatd(ix: quat.x, iy: quat.y, iz: quat.z, r: quat.w)
        let mfVec = simd_double3(mf.x, mf.y, mf.z)
        let world = q.act(mfVec)

        let bx  = Float(mf.x),    by  = Float(mf.y),    bz  = Float(mf.z)
        let bxr = Float(world.x), byr = Float(world.y), bzr = Float(world.z)

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
                case "START": self.requestStart()
                case "STOP":  self.stopStreaming()
                default: break
                }
            }
        }
    }
}

// ── Data little-endian helper ─────────────────────────────────────────────────
private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &le, Array.init))
    }
    mutating func appendLE(_ v: Float) { appendLE(v.bitPattern) }
}

// ── UI ────────────────────────────────────────────────────────────────────────
struct ContentView: View {
    @StateObject private var ctrl = MagController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if ctrl.isCalibrating {
                CalibrationView(ctrl: ctrl)
            } else {
                StreamingView(ctrl: ctrl)
            }
        }
    }
}

// ── Calibration Screen ────────────────────────────────────────────────────────
struct CalibrationView: View {
    @ObservedObject var ctrl: MagController
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 64))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Text("Calibra il magnetometro")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("Ruota il telefono descrivendo una\n**figura a 8** nello spazio.\nTieni il telefono lontano da superfici metalliche.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 32)

            CalibrationBar(state: ctrl.calibration)
                .padding(.horizontal, 40)

            Text(ctrl.calibration.label)
                .font(.caption.bold())
                .foregroundStyle(ctrl.calibration.color)

            Spacer()

            Text("Lo streaming partirà automaticamente\nquando la calibrazione è sufficiente.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 40)
        }
        .padding()
    }
}

struct CalibrationBar: View {
    let state: MagController.CalibrationState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.15))
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 6)
                    .fill(state.color)
                    .frame(width: geo.size.width * CGFloat(state.rawValue) / 3.0, height: 12)
                    .animation(.easeInOut(duration: 0.4), value: state)
            }
        }
        .frame(height: 12)
    }
}

// ── Streaming Screen ──────────────────────────────────────────────────────────
struct StreamingView: View {
    @ObservedObject var ctrl: MagController

    var body: some View {
        VStack(spacing: 20) {
            // Status pill
            HStack(spacing: 8) {
                Circle()
                    .fill(ctrl.isStreaming ? .green : (ctrl.bleStatus.contains("connesso") ? .yellow : .orange))
                    .frame(width: 10, height: 10)
                Text(ctrl.bleStatus).foregroundStyle(.white).font(.subheadline)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.white.opacity(0.1), in: Capsule())

            // Calibration badge (sempre visibile)
            HStack(spacing: 6) {
                Circle().fill(ctrl.calibration.color).frame(width: 8, height: 8)
                Text(ctrl.calibration.label)
                    .font(.caption)
                    .foregroundStyle(ctrl.calibration.color)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(ctrl.calibration.color.opacity(0.1), in: Capsule())

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

                if ctrl.skippedSamples > 0 {
                    Text("\(ctrl.skippedSamples) campioni scartati (bassa calibrazione)")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }

            Spacer()
            Text("Monta il telefono sul visore.\nStart/Stop automatici dal Quest.")
                .multilineTextAlignment(.center).font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding()
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
