import Foundation

class CommandRunner {
    static let shared = CommandRunner()

    // Cache the AWS CLI path
    private let awsCliPath: String

    private init() {
        // Find AWS CLI path once at initialization
        let paths = ["/usr/local/bin/aws", "/opt/homebrew/bin/aws", "/usr/bin/aws"]
        self.awsCliPath = paths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin/aws"
        print("CommandRunner: Using AWS CLI at: \(self.awsCliPath)")
    }

    func runCommand(_ command: String, args: [String]) async throws -> String {
        // Early feedback for UI responsiveness
        print("Preparing command: \(command) \(args.joined(separator: " "))")

        // Create the process
        let process = Process()
        let executablePath = command == "aws" ? self.awsCliPath : "/usr/local/bin/\(command)"
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args

        // Set up pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Start the process
        print("Running command: \(command) \(args.joined(separator: " "))")
        try process.run()

        // Create a separate task to read output while the process runs
        // This avoids concurrency issues and Swift 6 warnings
        let outputTask = Task.detached {
            let outputHandle = outputPipe.fileHandleForReading
            var output = ""

            repeat {
                let data = outputHandle.availableData
                if data.isEmpty { break }

                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                    output += str
                }
            } while true

            return output
        }

        // Same for error output
        let errorTask = Task.detached {
            let errorHandle = errorPipe.fileHandleForReading
            var errorOutput = ""

            repeat {
                let data = errorHandle.availableData
                if data.isEmpty { break }

                if let str = String(data: data, encoding: .utf8) {
                    print("Error: \(str)")
                    errorOutput += str
                }
            } while true

            return errorOutput
        }

        // Wait for process to complete
        process.waitUntilExit()

        // Get results from our detached tasks
        let outputString = await outputTask.value
        let errorString = await errorTask.value

        // Check exit status
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "CommandRunner",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorString.isEmpty
                        ? "Command failed with no error output" : errorString
                ]
            )
        }

        return outputString
    }

    func login(profileName: String, completion: @escaping (Bool) -> Void) {
        Task {
            do {
                _ = try await runCommand("aws", args: ["sso", "login", "--profile", profileName])
                completion(true)
            } catch {
                print("Login error: \(error)")
                completion(false)
            }
        }
    }
}
