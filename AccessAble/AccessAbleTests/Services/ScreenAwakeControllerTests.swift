import Testing
@testable import AccessAble

@MainActor
struct ScreenAwakeControllerTests {
    @Test func overlappingScreensKeepAwakeUntilTheLastRequestEnds() {
        var disabled = false
        let coordinator = ScreenAwakeCoordinator(read: { disabled }, write: { disabled = $0 })
        let first = ScreenAwakeController(coordinator: coordinator)
        let second = ScreenAwakeController(coordinator: coordinator)
        first.setAwake(true)
        second.setAwake(true)
        first.setAwake(false)
        #expect(disabled)
        second.setAwake(false)
        #expect(!disabled)
    }

    @Test func anExistingMapsKeepAwakeSettingIsRestored() {
        var disabled = true
        let coordinator = ScreenAwakeCoordinator(read: { disabled }, write: { disabled = $0 })
        let controller = ScreenAwakeController(coordinator: coordinator)
        controller.setAwake(true)
        controller.setAwake(false)
        #expect(disabled)
    }

    @Test func repeatedUpdatesDoNotCreateExtraRequestsOrReleaseSomeoneElsesRequest() {
        var disabled = false
        let coordinator = ScreenAwakeCoordinator(read: { disabled }, write: { disabled = $0 })
        let first = ScreenAwakeController(coordinator: coordinator)
        let second = ScreenAwakeController(coordinator: coordinator)
        first.setAwake(true)
        first.setAwake(true)
        second.setAwake(false)
        #expect(disabled)
        first.setAwake(false)
        #expect(!disabled)
        first.setAwake(false)
        #expect(!disabled)
    }
}
