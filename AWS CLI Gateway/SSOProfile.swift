import Foundation

struct SSOProfile: Codable, Identifiable {
    let id: UUID
    let name: String
    let startUrl: String
    let region: String
    let accountId: String
    let roleName: String
    let output: String

    init(
        id: UUID = UUID(),
        name: String,
        startUrl: String,
        region: String,
        accountId: String,
        roleName: String,
        output: String = "json"
    ) {
        self.id = id
        self.name = name
        self.startUrl = startUrl
        self.region = region
        self.accountId = accountId
        self.roleName = roleName
        self.output = output
    }

    // Validate profile data
    func validate() -> Bool {
        !name.isEmpty &&
        !startUrl.isEmpty &&
        !region.isEmpty &&
        !accountId.isEmpty &&
        !roleName.isEmpty &&
        !output.isEmpty &&
        isValidUrl(startUrl) &&
        isValidRegion(region) &&
        isValidRole(roleName) &&
        isValidAccountId(accountId)
    }

    private func isValidUrl(_ url: String) -> Bool {
        guard let urlObj = URL(string: url) else { return false }
        return urlObj.scheme?.lowercased() == "https"
    }

    private func isValidRegion(_ region: String) -> Bool {
        // Basic AWS region format validation
        let regionPattern = "^[a-z]{2}(-[a-z]+)?-[0-9]{1}$"
        let regionPredicate = NSPredicate(format: "SELF MATCHES %@", regionPattern)
        return regionPredicate.evaluate(with: region)
    }

    private func isValidRole(_ role: String) -> Bool {
        // Updated to check against permission sets from the manager
        if role == "-----" {
            return false
        }
        return PermissionSetManager.shared.getPermissionSets().contains(where: { $0.permissionSetName == role })
    }

    private func isValidAccountId(_ accountId: String) -> Bool {
        // AWS account IDs are 12 digits
        let accountPattern = "^[0-9]{12}$"
        let accountPredicate = NSPredicate(format: "SELF MATCHES %@", accountPattern)
        return accountPredicate.evaluate(with: accountId)
    }
}

// MARK: - AWS Regions
extension SSOProfile {
    static let commonRegions = [
        "-----",
        "us-east-1",
        "us-east-2",
        "us-west-1",
        "us-west-2",
        "ap-south-1",
        "ap-northeast-1",
        "ap-northeast-2",
        "ap-southeast-1",
        "ap-southeast-2",
        "ca-central-1",
        "eu-central-1",
        "eu-west-1",
        "eu-west-2",
        "eu-north-1",
        "sa-east-1"
    ]
}

// MARK: - AWS Permission Sets
extension SSOProfile {
}

// MARK: - Preview Helper
extension SSOProfile {
    static var preview: SSOProfile {
        SSOProfile(
            name: "Development",
            startUrl: "https://example.awsapps.com/start",
            region: "us-west-2",
            accountId: "123456789012",
            roleName: "Developer"
        )
    }
}
