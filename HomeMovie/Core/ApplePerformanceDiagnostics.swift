import Foundation
import MetricKit

// Apple delivers these asynchronously; no network endpoint or third-party SDK.
final class ApplePerformanceDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = ApplePerformanceDiagnostics()
    private override init() { super.init(); MXMetricManager.shared.add(self) }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads.suffix(4) { ReliabilityDiagnostics.shared.saveSystemReport(payload.jsonRepresentation()) }
    }
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads.suffix(1) { ReliabilityDiagnostics.shared.saveSystemReport(payload.jsonRepresentation()) }
    }
}
