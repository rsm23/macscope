import Foundation
import Testing
@testable import MacScopeCore

@Suite("Command runner responsiveness")
struct CommandRunnerTests {
    @Test("Output larger than a pipe buffer does not stall until timeout")
    func drainsOutputWhileRunning() async {
        let result = await CommandRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2"],
            timeout: 2
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 262_144)
        #expect(result.stderr.utf8.count == 262_144)
    }

    @Test("Timeout also stops a command that ignores SIGTERM")
    func killsUncooperativeCommand() async {
        let start = ContinuousClock.now
        let result = await CommandRunner.run(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1
        )

        #expect(start.duration(to: .now) < .seconds(2))
        #expect(result.exitCode != 0)
    }

    @Test("Cancelling a search stops its subprocess rather than waiting for timeout")
    func cancellationStopsCommand() async throws {
        let start = ContinuousClock.now
        let task = Task {
            await CommandRunner.run(
                executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 30
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value

        #expect(start.duration(to: .now) < .seconds(2))
        #expect(result.exitCode != 0)
    }

    @Test("Inherited pipes do not hold the result open after the direct child exits")
    func descendantsDoNotHoldResultOpen() async {
        let start = ContinuousClock.now
        let result = await CommandRunner.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 1 & printf done"], timeout: 2
        )

        #expect(start.duration(to: .now) < .milliseconds(500))
        #expect(result.exitCode == 0)
        #expect(result.stdout == "done")
    }

    @Test("Noisy output is bounded while the command continues to completion")
    func boundsNoisyOutput() async {
        let result = await CommandRunner.run(
            executable: "/bin/sh", arguments: ["-c", "head -c 9437184 /dev/zero"], timeout: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.hasSuffix("[Output truncated at 8 MiB.]"))
        #expect(result.stdout.utf8.count < 8 * 1_024 * 1_024 + 100)
    }
}
