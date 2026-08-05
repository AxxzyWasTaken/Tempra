import Testing
@testable import Tempra

@Suite("Rule guidance")
struct RuleGuidanceTests {
    @Test("Destructive idle actions receive the highest-severity guidance")
    func destructiveIdleActionGuidance() {
        let rule = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .pause,
            protectAudio: false,
            quitAfterMinutes: 10
        )

        let guidance = RuleGuidanceEvaluator.evaluate(rule)

        #expect(guidance.first?.kind == .forceQuitCanDiscardWork)
        #expect(guidance.first?.severity == .critical)
        #expect(guidance.contains { $0.kind == .audioProtectionDisabled })
        #expect(guidance.contains { $0.kind == .visibleBackgroundPause })
    }

    @Test("A conservative rule does not invent warnings")
    func conservativeRuleHasNoGuidance() {
        let rule = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitPercent: 50,
            delaySeconds: 10,
            protectAudio: true,
            onlyWhenHidden: true
        )

        #expect(RuleGuidanceEvaluator.evaluate(rule).isEmpty)
    }
}
