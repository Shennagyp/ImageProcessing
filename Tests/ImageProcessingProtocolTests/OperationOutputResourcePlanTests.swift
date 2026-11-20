import GeneralExecutionProtocol
@testable import ImageProcessingProtocol
import Testing

struct OperationOutputResourcePlanTests {
    @Test
    func outputResourcePlanOrdersSlotsAndRejectsDuplicateIndices() throws {
        let higher = try OperationOutputResourceRequirement(
            outputIndex: 4,
            minimumCapacityBytes: 128,
            minimumAlignmentBytes: 16
        )
        let lower = try OperationOutputResourceRequirement(
            outputIndex: 1,
            minimumCapacityBytes: 64
        )

        let plan = try OperationOutputResourcePlan(resources: [higher, lower])
        #expect(plan.resources.map(\.outputIndex) == [1, 4])

        #expect(throws: OperationOutputResourcePlanError.duplicateOutputIndex(1)) {
            try OperationOutputResourcePlan(resources: [lower, lower])
        }
    }

    @Test
    func outputResourceRequirementRejectsInvalidCapacityAndAlignment() throws {
        #expect(throws: OperationOutputResourcePlanError.zeroCapacity(0)) {
            try OperationOutputResourceRequirement(
                outputIndex: 0,
                minimumCapacityBytes: 0
            )
        }
        #expect(throws: OperationOutputResourcePlanError.invalidAlignment(0)) {
            try OperationOutputResourceRequirement(
                outputIndex: 0,
                minimumCapacityBytes: 1,
                minimumAlignmentBytes: 3
            )
        }
    }
}
