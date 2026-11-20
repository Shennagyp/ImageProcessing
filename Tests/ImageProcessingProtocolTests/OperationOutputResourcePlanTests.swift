import GeneralExecutionProtocol
@testable import ImageProcessingProtocol
import Testing

struct OperationResourcePlanTests {
    @Test
    func operationResourcePlanOrdersRolesAndRejectsDuplicates() throws {
        let temporaryZ = try OperationResourcePlanRequirement(
            role: .temporary("z-scratch"),
            minimumCapacityBytes: 128,
            minimumAlignmentBytes: 16
        )
        let outputFour = try OperationResourcePlanRequirement(
            role: .output(4),
            minimumCapacityBytes: 64
        )
        let outputOne = try OperationResourcePlanRequirement(
            role: .output(1),
            minimumCapacityBytes: 32
        )
        let temporaryA = try OperationResourcePlanRequirement(
            role: .temporary("a-scratch"),
            minimumCapacityBytes: 256
        )

        let plan = try OperationResourcePlan(
            resources: [temporaryZ, outputFour, outputOne, temporaryA]
        )
        #expect(plan.resources.map(\\.role) == [
            .output(1),
            .output(4),
            .temporary("a-scratch"),
            .temporary("z-scratch")
        ])

        #expect(throws: OperationResourcePlanError.duplicateRole(.output(1))) {
            try OperationResourcePlan(resources: [outputOne, outputOne])
        }
    }

    @Test
    func operationResourcePlanRejectsInvalidRoles() throws {
        #expect(throws: OperationResourcePlanError.invalidRole(.output(-1))) {
            try OperationResourcePlanRequirement(
                role: .output(-1),
                minimumCapacityBytes: 1
            )
        }
        #expect(throws: OperationResourcePlanError.invalidRole(.temporary(""))) {
            try OperationResourcePlanRequirement(
                role: .temporary(""),
                minimumCapacityBytes: 1
            )
        }
    }

    @Test
    func operationResourceRequirementRejectsInvalidCapacityAndAlignment() throws {
        #expect(throws: OperationResourcePlanError.zeroCapacity(.output(0))) {
            try OperationResourcePlanRequirement(
                role: .output(0),
                minimumCapacityBytes: 0
            )
        }
        #expect(throws: OperationResourcePlanError.invalidAlignment(.temporary("scratch"))) {
            try OperationResourcePlanRequirement(
                role: .temporary("scratch"),
                minimumCapacityBytes: 1,
                minimumAlignmentBytes: 3
            )
        }
    }
}
