import Foundation

class CommandRunner {
    static let shared = CommandRunner()
    
    private init() {}
    
    func runCommand(_ command: String, args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/\(command)")
        process.arguments = args
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Store data from multiple threads safely using this queue
        let dataQueue = DispatchQueue(label: "com.yourapp.commandrunner.data")
        
        var collectedStdout = Data()
        var collectedStderr = Data()
        
        // Print + accumulate output in real-time
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                dataQueue.sync {
                    collectedStdout.append(data)
                }
                if let output = String(data: data, encoding: .utf8) {
                    print(output)
                }
            }
        }
        
        // Print + accumulate error in real-time
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                dataQueue.sync {
                    collectedStderr.append(data)
                }
                if let output = String(data: data, encoding: .utf8) {
                    print(output)
                }
            }
        }
        
        print("Running command: \(command) \(args.joined(separator: " "))")
        
        try process.run()
        process.waitUntilExit()
        
        // Stop read handlers
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        
        // Read any leftover data, appending under the lock
        let leftoverStdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if !leftoverStdout.isEmpty {
            dataQueue.sync {
                collectedStdout.append(leftoverStdout)
            }
            if let leftoverString = String(data: leftoverStdout, encoding: .utf8) {
                print(leftoverString)
            }
        }
        
        let leftoverStderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if !leftoverStderr.isEmpty {
            dataQueue.sync {
                collectedStderr.append(leftoverStderr)
            }
            if let leftoverString = String(data: leftoverStderr, encoding: .utf8) {
                print(leftoverString)
            }
        }
        
        // Convert final data to strings
        let outputString: String = dataQueue.sync {
            String(data: collectedStdout, encoding: .utf8) ?? ""
        }
        let errorString: String = dataQueue.sync {
            String(data: collectedStderr, encoding: .utf8) ?? ""
        }
        
        // If the process errored, throw
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
        
        // Return stdout
        return outputString
    }
}
