// Inspect actual Core ML compiler placement; CPU_AND_NE is only a request.
// Run: xcrun swift scripts/laya_export_compute_plan.swift /tmp/sift-laya-export/laya_english.mlpackage
import CoreML
import Foundation

let package = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndNeuralEngine
let compiled = try MLModel.compileModel(at: package)
let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: configuration)
guard case let .program(program) = plan.modelStructure,
      let function = program.functions["main"] else {
    fatalError("Expected a Core ML program with a main function")
}
func deviceName(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: return "cpu"
    case .gpu: return "gpu"
    case .neuralEngine: return "neuralEngine"
    }
}
var preferred: [String: Int] = [:]
var supportedANE = 0
var byOperation: [String: [String: Int]] = [:]
var weightedCost: [String: Double] = [:]
var unknown = 0
for operation in function.block.operations {
    guard let usage = plan.deviceUsage(for: operation) else {
        unknown += 1
        continue
    }
    let device = deviceName(usage.preferred)
    preferred[device, default: 0] += 1
    byOperation[operation.operatorName, default: [:]][device, default: 0] += 1
    if usage.supported.contains(where: { deviceName($0) == "neuralEngine" }) {
        supportedANE += 1
    }
    weightedCost[device, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
}
let report: [String: Any] = [
    "package": package.path,
    "computeUnits": "cpuAndNeuralEngine",
    "operationCount": function.block.operations.count,
    "unknownDeviceCount": unknown,
    "preferred": preferred,
    "supportedANECount": supportedANE,
    "weightedCostByPreferredDevice": weightedCost,
    "byOperation": byOperation
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
let reportURL = package.deletingLastPathComponent().appendingPathComponent("compute_plan.json")
try data.write(to: reportURL)
print("Compute plan: \(reportURL.path)\n" + String(data: data, encoding: .utf8)!)
