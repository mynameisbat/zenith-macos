import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("Annotation Command Stack Test Suite")
struct AnnotationCommandStackTests {

    private func makeDummyCommand(id: UUID = UUID()) -> AnnotationCommand {
        RectangleAnnotationCommand(
            id: id,
            rect: CGRect(x: 10, y: 10, width: 20, height: 20),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
    }

    @Test("CS-01: Initial stack is empty and cannot undo or redo")
    func testInitialStackState() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        #expect(stack.commands.isEmpty)
        #expect(stack.count == 0)
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.undoCount == 0)
        #expect(stack.redoCount == 0)
        #expect(stack.activeCrop == nil)
    }

    @Test("CS-02: Pushing a command enables undo and increases count")
    func testPushCommand() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        let cmd = makeDummyCommand()
        stack.push(cmd)

        #expect(stack.count == 1)
        #expect(stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.commands.count == 1)
    }

    @Test("CS-03: Undo pops last command and moves it to redo stack")
    func testUndoCommand() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        let cmd1 = makeDummyCommand()
        let cmd2 = makeDummyCommand()
        stack.push(cmd1)
        stack.push(cmd2)

        let undone = stack.undo()
        #expect(undone != nil)
        #expect(stack.count == 1)
        #expect(stack.canUndo)
        #expect(stack.canRedo)
        #expect(stack.redoCount == 1)

        let undoneSecond = stack.undo()
        #expect(undoneSecond != nil)
        #expect(stack.count == 0)
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
        #expect(stack.redoCount == 2)

        let undoneEmpty = stack.undo()
        #expect(undoneEmpty == nil)
    }

    @Test("CS-04: Redo restores undone command in reverse order")
    func testRedoCommand() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        let cmd1 = makeDummyCommand()
        let cmd2 = makeDummyCommand()
        stack.push(cmd1)
        stack.push(cmd2)

        stack.undo()
        stack.undo()

        let redone1 = stack.redo()
        #expect(redone1 != nil)
        #expect(stack.count == 1)
        #expect(stack.canUndo)
        #expect(stack.canRedo)

        let redone2 = stack.redo()
        #expect(redone2 != nil)
        #expect(stack.count == 2)
        #expect(stack.canUndo)
        #expect(!stack.canRedo)

        let redoneEmpty = stack.redo()
        #expect(redoneEmpty == nil)
    }

    @Test("CS-05: New push invalidates redo history completely")
    func testBranchingHistoryClearsRedo() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        stack.push(makeDummyCommand())
        stack.push(makeDummyCommand())
        stack.undo()
        #expect(stack.canRedo)

        // Push new command
        stack.push(makeDummyCommand())
        #expect(!stack.canRedo)
        #expect(stack.redoCount == 0)
        #expect(stack.count == 2)
    }

    @Test("CS-06: Capacity limit evicts oldest commands when exceeded")
    func testCapacityEviction() {
        let capacity = 10
        let stack = AnnotationCommandStack(maxCapacity: capacity)

        var commandIds: [UUID] = []
        for _ in 0..<25 {
            let id = UUID()
            commandIds.append(id)
            stack.push(makeDummyCommand(id: id))
        }

        #expect(stack.count == capacity)
        #expect(stack.commands.count == capacity)

        // Verify that the remaining commands are the last 10 pushed
        let remainingIds = stack.commands.compactMap { ($0 as? RectangleAnnotationCommand)?.id }
        let expectedIds = Array(commandIds.suffix(capacity))
        #expect(remainingIds == expectedIds)
    }

    @Test("CS-07: ReplaceTop updates active draft in place")
    func testReplaceTop() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        let cmd1 = makeDummyCommand()
        stack.push(cmd1)
        #expect(stack.count == 1)

        let cmd2 = makeDummyCommand()
        stack.replaceTop(cmd2)
        #expect(stack.count == 1)
        let top = stack.commands.last as? RectangleAnnotationCommand
        #expect(top?.id == (cmd2 as? RectangleAnnotationCommand)?.id)

        // replaceTop on empty stack pushes command
        let emptyStack = AnnotationCommandStack(maxCapacity: 50)
        emptyStack.replaceTop(cmd1)
        #expect(emptyStack.count == 1)
    }

    @Test("CS-08: Clear empties both undo and redo stacks")
    func testClearStack() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        stack.push(makeDummyCommand())
        stack.push(makeDummyCommand())
        stack.undo()

        stack.clear()
        #expect(stack.count == 0)
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.commands.isEmpty)
    }

    @Test("CS-09: ActiveCrop tracks latest crop annotation in stack")
    func testActiveCropTracking() {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        #expect(stack.activeCrop == nil)

        stack.push(makeDummyCommand())
        #expect(stack.activeCrop == nil)

        let crop1 = CropAnnotationCommand(
            cropRect: CGRect(x: 10, y: 10, width: 100, height: 100),
            originalSize: CGSize(width: 500, height: 500)
        )
        stack.push(crop1)
        #expect(stack.activeCrop?.cropRect == crop1.cropRect)

        stack.push(makeDummyCommand())
        #expect(stack.activeCrop?.cropRect == crop1.cropRect)

        stack.undo() // undo dummy command
        #expect(stack.activeCrop?.cropRect == crop1.cropRect)

        stack.undo() // undo crop1
        #expect(stack.activeCrop == nil)
    }

    @Test("CS-10: Multi-threaded concurrency stress test with 80 concurrent tasks")
    func testConcurrentTorture() async {
        let stack = AnnotationCommandStack(maxCapacity: 30)
        let taskCount = 80

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    for op in 0..<20 {
                        let step = (i + op) % 4
                        switch step {
                        case 0:
                            stack.push(RectangleAnnotationCommand(
                                rect: CGRect(x: Double(i), y: Double(op), width: 10, height: 10),
                                color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                            ))
                        case 1:
                            _ = stack.undo()
                        case 2:
                            _ = stack.redo()
                        case 3:
                            _ = stack.commands
                            _ = stack.canUndo
                            _ = stack.canRedo
                        default:
                            break
                        }
                    }
                }
            }
        }

        #expect(stack.count <= 30)
    }

    @Test("CS-11: Undo, redo, push, and clear mutate version counter and trigger objectWillChange")
    func testObservationAndVersionTracking() {
        let stack = AnnotationCommandStack(maxCapacity: 10)
        #expect(stack.version == 0)

        stack.push(makeDummyCommand())
        #expect(stack.version == 1)

        stack.push(makeDummyCommand())
        #expect(stack.version == 2)

        stack.undo()
        #expect(stack.version == 3)

        stack.redo()
        #expect(stack.version == 4)

        stack.replaceTop(makeDummyCommand())
        #expect(stack.version == 5)

        stack.clear()
        #expect(stack.version == 6)
    }

    @Test("CS-12: Undo/redo count and activeCrop property tracking and observation")
    func testUndoRedoCountAndCropTracking() {
        let stack = AnnotationCommandStack(maxCapacity: 10)
        #expect(stack.undoCount == 0)
        #expect(stack.redoCount == 0)
        #expect(stack.activeCrop == nil)

        let crop = CropAnnotationCommand(
            cropRect: CGRect(x: 10, y: 10, width: 100, height: 100),
            originalSize: CGSize(width: 500, height: 500)
        )
        stack.push(crop)
        #expect(stack.undoCount == 1)
        #expect(stack.redoCount == 0)
        #expect(stack.activeCrop != nil)
        #expect(stack.activeCrop?.cropRect == CGRect(x: 10, y: 10, width: 100, height: 100))

        stack.undo()
        #expect(stack.undoCount == 0)
        #expect(stack.redoCount == 1)
        #expect(stack.activeCrop == nil)

        stack.redo()
        #expect(stack.undoCount == 1)
        #expect(stack.redoCount == 0)
        #expect(stack.activeCrop != nil)

        stack.clear()
        #expect(stack.undoCount == 0)
        #expect(stack.redoCount == 0)
        #expect(stack.activeCrop == nil)
    }
}
