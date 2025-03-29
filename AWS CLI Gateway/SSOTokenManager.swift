import Foundation
import CommonCrypto

// Define the AWS CLI credentials format
struct AWSCliCredentials: Codable {
    let providerType: String
    let credentials: Credentials

    struct Credentials: Codable {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String
        let expiration: Date

        // Add CodingKeys to match the capitalized JSON field names
        enum CodingKeys: String, CodingKey {
            case accessKeyId = "AccessKeyId"
            case secretAccessKey = "SecretAccessKey"
            case sessionToken = "SessionToken"
            case expiration = "Expiration"
        }
    }

    enum CodingKeys: String, CodingKey {
        case providerType = "ProviderType"
        case credentials = "Credentials"
    }
}

// Update SSOToken to be more flexible
struct SSOToken: Codable {
    // Make required fields optional so we can work with both formats
    let startUrl: String?
    let region: String?
    let accessToken: String?
    let expiresAt: Date
    let clientId: String?
    let clientSecret: String?
    let refreshToken: String?
    let sessionName: String?

    enum CodingKeys: String, CodingKey {
        case startUrl
        case region
        case accessToken
        case expiresAt
        case clientId
        case clientSecret
        case refreshToken
        case sessionName
    }

    // Custom initializer to support creating from CLI credentials
    init(expiresAt: Date, startUrl: String? = nil, region: String? = nil,
         accessToken: String? = nil, clientId: String? = nil, clientSecret: String? = nil,
         refreshToken: String? = nil, sessionName: String? = nil) {
        self.startUrl = startUrl
        self.region = region
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.sessionName = sessionName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Make these fields optional for flexibility
        startUrl = try container.decodeIfPresent(String.self, forKey: .startUrl)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)

        // Try to decode expiresAt
        if let expiresAtString = try? container.decode(String.self, forKey: .expiresAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            if let date = formatter.date(from: expiresAtString) {
                expiresAt = date
            } else {
                // Try with just internet date time
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: expiresAtString) {
                    expiresAt = date
                } else {
                    throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container,
                                                         debugDescription: "Date string does not match expected format")
                }
            }
        } else {
            // If we can't find expiresAt, just use a default (will be replaced)
            expiresAt = Date()
        }

        clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
        clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
    }
}

class SSOTokenManager {
    static let shared = SSOTokenManager()

    private init() {}

    // Model for token info
    struct TokenInfo {
        let isValid: Bool
        let expiresAt: Date
        let remainingTime: TimeInterval

        var isExpired: Bool {
            return Date() >= expiresAt
        }
    }

    // Retrieves token information for a specific SSO session
    func getTokenInfo(startUrl: String, region: String) -> TokenInfo? {
        // First try SSO cache
        if let tokenInfo = getTokenInfoFromSSOCache(startUrl: startUrl, region: region) {
            return tokenInfo
        }

        // If not found, try CLI cache
        if let tokenInfo = getTokenInfoFromCLICache() {
            return tokenInfo
        }

        return nil
    }

    // Get token info from SSO cache
    private func getTokenInfoFromSSOCache(startUrl: String, region: String) -> TokenInfo? {
        guard let tokenFilePath = findTokenFile(startUrl: startUrl, region: region),
              let tokenData = try? Data(contentsOf: tokenFilePath),
              let tokenDict = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let expiresAtString = tokenDict["expiresAt"] as? String else {
            return nil
        }

        // Parse the expiration date
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let expiresAt = dateFormatter.date(from: expiresAtString) else {
            return nil
        }

        let remainingTime = expiresAt.timeIntervalSince(Date())
        let isValid = remainingTime > 0

        return TokenInfo(
            isValid: isValid,
            expiresAt: expiresAt,
            remainingTime: remainingTime
        )
    }

    // Get token info from CLI cache
    private func getTokenInfoFromCLICache() -> TokenInfo? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil) else {
            return nil
        }

        for file in cacheFiles where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let decoder = JSONDecoder()

                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)

                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]

                    if let date = formatter.date(from: dateString) {
                        return date
                    }

                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
                }

                // Try to decode as CLI credentials
                if let cliCredentials = try? decoder.decode(AWSCliCredentials.self, from: data) {
                    let expiresAt = cliCredentials.credentials.expiration
                    let remainingTime = expiresAt.timeIntervalSince(Date())
                    let isValid = remainingTime > 0

                    return TokenInfo(
                        isValid: isValid,
                        expiresAt: expiresAt,
                        remainingTime: remainingTime
                    )
                }
            } catch {
                // Just skip this file if it can't be parsed
                continue
            }
        }

        return nil
    }

    func getTokenForProfile(_ profileName: String) async throws -> SSOToken? {
        print("SSOTokenManager: Searching for token for profile: \(profileName)")

        // Try both SSO token and CLI token formats
        if let token = try await getSSOModeTokenForProfile(profileName) {
            return token
        }

        if let token = try await getCLIModeTokenForProfile(profileName) {
            return token
        }

        print("SSOTokenManager: No valid token found")
        return nil
    }

    // Get token in SSO format
    private func getSSOModeTokenForProfile(_ profileName: String) async throws -> SSOToken? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cachePath = homeDir.appendingPathComponent(".aws/sso/cache")

        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil) else {
            print("SSOTokenManager: Cannot access SSO cache directory")
            return nil
        }

        // Try to find the config file to get the SSO session name
        let ssoSessionName = try getSSOSessionNameForProfile(profileName)

        print("SSOTokenManager: SSO session name for \(profileName): \(ssoSessionName ?? "nil")")

        for file in cacheFiles {
            // Only look at json files
            guard file.pathExtension == "json" else { continue }

            do {
                let data = try Data(contentsOf: file)

                // Create a decoder with appropriate date decoding strategy
                let decoder = JSONDecoder()

                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)

                    // Create the formatter inside the closure
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                    if let date = formatter.date(from: dateString) {
                        return date
                    }

                    // Try with just internet date time
                    formatter.formatOptions = [.withInternetDateTime]
                    if let date = formatter.date(from: dateString) {
                        return date
                    }

                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
                }

                if let token = try? decoder.decode(SSOToken.self, from: data) {
                    // If we know the session name, check it directly
                    if let sessionName = ssoSessionName,
                       (token.sessionName == sessionName || file.lastPathComponent.contains(sessionName)) {
                        print("SSOTokenManager: Found matching SSO token by session name")
                        return token
                    }

                    // As a fallback, try to use the most recent valid token
                    if token.expiresAt > Date() {
                        print("SSOTokenManager: Found valid SSO token: \(file.lastPathComponent)")
                        return token
                    }
                }
            } catch {
                print("SSOTokenManager: Error decoding SSO token file \(file.lastPathComponent): \(error)")
                continue
            }
        }

        return nil
    }

    // Get token in CLI format
    private func getCLIModeTokenForProfile(_ profileName: String) async throws -> SSOToken? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil) else {
            print("SSOTokenManager: Cannot access CLI cache directory")
            return nil
        }

        for file in cacheFiles {
            // Only look at json files and skip .DS_Store
            guard file.pathExtension == "json" && file.lastPathComponent != ".DS_Store" else { continue }

            do {
                let data = try Data(contentsOf: file)
                let jsonString = String(data: data, encoding: .utf8) ?? ""
                print("SSOTokenManager: Examining CLI file: \(file.lastPathComponent), content preview: \(jsonString.prefix(100))")

                // Try to decode using the CLI credentials format
                let decoder = JSONDecoder()

                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)

                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]

                    if let date = formatter.date(from: dateString) {
                        return date
                    }

                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
                }

                // Try to decode as CLI credentials
                if let cliCredentials = try? decoder.decode(AWSCliCredentials.self, from: data) {
                    print("SSOTokenManager: Successfully decoded CLI credentials, expires: \(cliCredentials.credentials.expiration)")

                    // Check if it's a valid token
                    if cliCredentials.credentials.expiration > Date() {
                        // Convert to our SSOToken format
                        return SSOToken(
                            expiresAt: cliCredentials.credentials.expiration,
                            startUrl: nil,
                            region: nil,
                            accessToken: nil,
                            sessionName: nil
                        )
                    }
                }
            } catch {
                print("SSOTokenManager: Error decoding CLI token file \(file.lastPathComponent): \(error)")
                continue
            }
        }

        return nil
    }

    // Helper method to get SSO session name from profile
    private func getSSOSessionNameForProfile(_ profileName: String) throws -> String? {
        // Read the AWS config file
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configPath = homeDir.appendingPathComponent(".aws/config")

        guard let configContents = try? String(contentsOf: configPath, encoding: .utf8) else {
            return nil
        }

        // Look for the profile section
        let profilePattern = "\\[profile \(profileName)\\]([^\\[]*)?"
        guard let profileRange = configContents.range(of: profilePattern, options: .regularExpression) else {
            return nil
        }

        let profileSection = configContents[profileRange]

        // Look for sso_session within that section
        let ssoSessionPattern = "sso_session\\s*=\\s*([^\\s\\n]+)"
        guard let ssoSessionMatch = profileSection.range(of: ssoSessionPattern, options: .regularExpression) else {
            return nil
        }

        let ssoSessionLine = profileSection[ssoSessionMatch]

        // Extract just the session name
        let sessionNamePattern = "=\\s*([^\\s\\n]+)"
        guard let sessionNameMatch = ssoSessionLine.range(of: sessionNamePattern, options: .regularExpression) else {
            return nil
        }

        let sessionNameWithEquals = ssoSessionLine[sessionNameMatch]
        let sessionName = sessionNameWithEquals.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines)

        return sessionName
    }

    // Finds the token file path for the given SSO session parameters
    private func findTokenFile(startUrl: String, region: String) -> URL? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cacheDirPath = homeDir.appendingPathComponent(".aws/sso/cache")

        // Calculate hash - similar to how AWS CLI does it
        let sessionKey = "\(startUrl)|\(region)"
        let hash = sha1Hash(sessionKey)

        // Check if file exists directly with hash name
        let potentialTokenFile = cacheDirPath.appendingPathComponent("\(hash).json")
        if FileManager.default.fileExists(atPath: potentialTokenFile.path) {
            return potentialTokenFile
        }

        // If not found by direct hash match, look through all files
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: cacheDirPath,
                includingPropertiesForKeys: nil
            )

            for fileURL in fileURLs {
                if fileURL.pathExtension == "json" {
                    // Try to load the file and check its content
                    do {
                        let data = try Data(contentsOf: fileURL)
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let storedStartUrl = json["startUrl"] as? String,
                           let storedRegion = json["region"] as? String,
                           storedStartUrl == startUrl && storedRegion == region {
                            return fileURL
                        }
                    } catch {
                        continue
                    }
                }
            }
        } catch {
            print("Error reading SSO cache directory: \(error)")
        }

        return nil
    }

    // SHA1 hash function (simplified version)
    private func sha1Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
