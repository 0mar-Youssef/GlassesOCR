//
//  SheetsClient.swift
//  GlassesOCR
//
//  Appends stock observations to Google Sheets via REST API.
//  Uses Google Service Account authentication (JWT → access token).
//

import Foundation
import Security

// MARK: - Configuration

/// Environment configuration for Sheets API.
struct SheetsConfig {
    /// Google Sheets spreadsheet ID (from the URL)
    nonisolated(unsafe) static var sheetId: String = "1NRrHL9gfNy5uVjJah225K4lqwHB3o6re5TbPfD1QP1Q"
    
    /// Target range for appending (e.g., "Sheet1!A:F")
    nonisolated(unsafe) static var range: String = "Sheet1!A:F"
    
    /// Path to Google service account JSON key file (in app bundle or documents)
    /// Download from Google Cloud Console → IAM → Service Accounts → Keys
    nonisolated(unsafe) static var serviceAccountKeyPath: String = "service-account.json"
    
    /// Check if credentials are configured
    static var isConfigured: Bool {
        !sheetId.isEmpty && !serviceAccountKeyPath.isEmpty
    }
}

// MARK: - Service Account Credentials

/// Parsed service account JSON key file
private struct ServiceAccountCredentials: Codable {
    let type: String
    let projectId: String
    let privateKeyId: String
    let privateKey: String
    let clientEmail: String
    let clientId: String
    let authUri: String
    let tokenUri: String
    
    enum CodingKeys: String, CodingKey {
        case type
        case projectId = "project_id"
        case privateKeyId = "private_key_id"
        case privateKey = "private_key"
        case clientEmail = "client_email"
        case clientId = "client_id"
        case authUri = "auth_uri"
        case tokenUri = "token_uri"
    }
}

/// Response from Google token endpoint
private struct TokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

// MARK: - Log Result

enum LogResult {
    case success
    case dryRun(payload: String)
    case error(String)
}

// MARK: - SheetsClient Errors

enum SheetsClientError: LocalizedError {
    case credentialsFileNotFound(String)
    case credentialsParseError(String)
    case privateKeyError(String)
    case jwtSigningError(String)
    case tokenExchangeError(String)
    case networkError(String)
    case apiError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .credentialsFileNotFound(let path):
            return "Service account JSON not found: \(path)"
        case .credentialsParseError(let detail):
            return "Failed to parse credentials: \(detail)"
        case .privateKeyError(let detail):
            return "Private key error: \(detail)"
        case .jwtSigningError(let detail):
            return "JWT signing failed: \(detail)"
        case .tokenExchangeError(let detail):
            return "Token exchange failed: \(detail)"
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .apiError(let code, let message):
            return "API error \(code): \(message)"
        }
    }
}

// MARK: - SheetsClient

final class SheetsClient: Sendable {
    
    // MARK: Properties
    
    private let session: URLSession
    private let baseURL = "https://sheets.googleapis.com/v4/spreadsheets"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private let scope = "https://www.googleapis.com/auth/spreadsheets"
    
    // Token caching with actor for thread safety
    private actor TokenCache {
        var token: String?
        var expiry: Date?
        
        func get() -> (token: String?, expiry: Date?) {
            return (token, expiry)
        }
        
        func set(token: String, expiry: Date) {
            self.token = token
            self.expiry = expiry
        }
        
        func clear() {
            self.token = nil
            self.expiry = nil
        }
    }

    private let tokenCache = TokenCache()
    
    // ISO 8601 formatter for timestamps
    nonisolated(unsafe) private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
    // MARK: Initialization
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    // MARK: - Public Interface
    
    /// Appends a stock observation to Google Sheets.
    /// If dryRun is true, prints payload to console instead of sending.
    func log(_ observation: StockObservation, dryRun: Bool) async -> LogResult {
        let row = createRow(from: observation)
        let payload = createPayload(row: row)
        
        if dryRun {
            return handleDryRun(payload: payload, observation: observation)
        }
        
        guard SheetsConfig.isConfigured else {
            print("[SheetsClient] ⚠️ Service account not configured. Set SheetsConfig.serviceAccountKeyPath")
            return .error("Service account not configured")
        }
        
        do {
            // Get access token (cached or fresh)
            let accessToken = try await getAccessToken()
            return await sendToSheets(payload: payload, accessToken: accessToken)
        } catch let error as SheetsClientError {
            print("[SheetsClient] ❌ \(error.localizedDescription)")
            return .error(error.localizedDescription)
        } catch {
            print("[SheetsClient] ❌ Unexpected error: \(error)")
            return .error(error.localizedDescription)
        }
    }
    
    // MARK: - Service Account Authentication
    
    private func getAccessToken() async throws -> String {
        // Check if cached token is still valid (with 60s buffer)
        let (cachedToken, tokenExpiry) = await tokenCache.get()
        
        if let token = cachedToken, let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-60) {
            print("[SheetsClient] 🔑 Using cached access token")
            return token
        }
        
        print("[SheetsClient] 🔑 Fetching new access token...")
        
        // Load credentials
        let credentials = try loadCredentials()
        
        // Create and sign JWT
        let jwt = try createSignedJWT(credentials: credentials)
        
        // Exchange JWT for access token
        let tokenResponse = try await exchangeJWTForToken(jwt: jwt, tokenUri: credentials.tokenUri)
        
        // Cache the token
        await tokenCache.set(
            token: tokenResponse.accessToken,
            expiry: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
        
        print("[SheetsClient] ✅ Access token obtained, expires in \(tokenResponse.expiresIn)s")
        
        return tokenResponse.accessToken
    }
    
    /// Loads and parses the service account JSON key file
    private func loadCredentials() throws -> ServiceAccountCredentials {
        let path = SheetsConfig.serviceAccountKeyPath
        
        // Try as absolute path first, then bundle resource
        var fileURL: URL?
        
        if FileManager.default.fileExists(atPath: path) {
            fileURL = URL(fileURLWithPath: path)
        } else if let bundleURL = Bundle.main.url(forResource: path, withExtension: nil) {
            fileURL = bundleURL
        } else if let bundleURL = Bundle.main.url(forResource: (path as NSString).deletingPathExtension,
                                                   withExtension: (path as NSString).pathExtension) {
            fileURL = bundleURL
        }
        
        guard let url = fileURL else {
            throw SheetsClientError.credentialsFileNotFound(path)
        }
        
        do {
            let data = try Data(contentsOf: url)
            let credentials = try JSONDecoder().decode(ServiceAccountCredentials.self, from: data)
            print("[SheetsClient] 📄 Loaded credentials for: \(credentials.clientEmail)")
            return credentials
        } catch {
            throw SheetsClientError.credentialsParseError(error.localizedDescription)
        }
    }
    
    /// Creates a signed JWT for service account authentication
    private func createSignedJWT(credentials: ServiceAccountCredentials) throws -> String {
        let now = Date()
        let expiry = now.addingTimeInterval(3600) // 1 hour
        
        // JWT Header
        let header: [String: Any] = [
            "alg": "RS256",
            "typ": "JWT"
        ]
        
        // JWT Claims
        let claims: [String: Any] = [
            "iss": credentials.clientEmail,
            "scope": scope,
            "aud": credentials.tokenUri,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(expiry.timeIntervalSince1970)
        ]
        
        // Encode header and claims
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let claimsData = try JSONSerialization.data(withJSONObject: claims)
        
        let headerB64 = base64URLEncode(headerData)
        let claimsB64 = base64URLEncode(claimsData)
        
        let signatureInput = "\(headerB64).\(claimsB64)"
        
        // Sign with RSA-SHA256
        let signature = try signRS256(data: signatureInput.data(using: .utf8)!,
                                       privateKeyPEM: credentials.privateKey)
        
        let signatureB64 = base64URLEncode(signature)
        
        return "\(signatureInput).\(signatureB64)"
    }
    
    /// Signs data using RS256 (RSA-SHA256)
    private func signRS256(data: Data, privateKeyPEM: String) throws -> Data {
        // Extract the key data from PEM format
        let privateKeyData = try extractPrivateKeyData(from: privateKeyPEM)
        
        // Create SecKey from data
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &error) else {
            let errorDesc = error.map { $0.takeRetainedValue().localizedDescription } ?? "Unknown error"
            throw SheetsClientError.privateKeyError(errorDesc)
        }
        
        // Sign the data
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw SheetsClientError.jwtSigningError("RS256 algorithm not supported")
        }
        
        guard let signature = SecKeyCreateSignature(privateKey,
                                                     .rsaSignatureMessagePKCS1v15SHA256,
                                                     data as CFData,
                                                     &error) as Data? else {
            let errorDesc = error.map { $0.takeRetainedValue().localizedDescription } ?? "Unknown error"
            throw SheetsClientError.jwtSigningError(errorDesc)
        }
        
        return signature
    }
    
    /// Extracts raw key data from PEM format
    private func extractPrivateKeyData(from pem: String) throws -> Data {
        // Remove PEM headers and whitespace
        let key = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        
        guard let data = Data(base64Encoded: key) else {
            throw SheetsClientError.privateKeyError("Failed to decode base64 key data")
        }
        
        // For PKCS#8 format (BEGIN PRIVATE KEY), we need to strip the header
        // PKCS#8 header for RSA is typically 26 bytes
        if pem.contains("BEGIN PRIVATE KEY") && data.count > 26 {
            // Try to find the RSA key within PKCS#8 wrapper
            // The structure is: SEQUENCE { SEQUENCE { OID, NULL }, OCTET STRING { RSA key } }
            // We'll try to extract the inner key
            return try extractRSAKeyFromPKCS8(data)
        }
        
        return data
    }
    
    /// Extracts RSA private key from PKCS#8 DER format
    private func extractRSAKeyFromPKCS8(_ data: Data) throws -> Data {
        // PKCS#8 structure for RSA keys:
        // SEQUENCE {
        //   INTEGER (0)
        //   SEQUENCE { OID (rsaEncryption), NULL }
        //   OCTET STRING { RSA private key }
        // }
        // 
        // The OCTET STRING typically starts around byte 26 for a 2048-bit key
        // We look for the nested SEQUENCE that starts the RSA key
        
        let bytes = [UInt8](data)
        
        // Simple approach: find the OCTET STRING (0x04) followed by length,
        // then the inner SEQUENCE (0x30) that contains the RSA key
        for i in 0..<(bytes.count - 4) {
            if bytes[i] == 0x04 { // OCTET STRING
                var offset = i + 1
                var length = Int(bytes[offset])
                offset += 1
                
                // Handle long form length
                if length > 0x80 {
                    let numBytes = length - 0x80
                    length = 0
                    for j in 0..<numBytes {
                        length = (length << 8) | Int(bytes[offset + j])
                    }
                    offset += numBytes
                }
                
                // Check if next byte is SEQUENCE (0x30) - start of RSA key
                if offset < bytes.count && bytes[offset] == 0x30 {
                    return Data(bytes[offset...])
                }
            }
        }
        
        // If we can't parse it, return original data and let SecKey try
        return data
    }
    
    /// Base64 URL encoding (no padding, URL-safe characters)
    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    /// Exchanges JWT for access token via Google token endpoint
    private func exchangeJWTForToken(jwt: String, tokenUri: String) async throws -> TokenResponse {
        guard let url = URL(string: tokenUri) else {
            throw SheetsClientError.tokenExchangeError("Invalid token URI")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        request.httpBody = body.data(using: .utf8)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SheetsClientError.tokenExchangeError("Invalid response")
            }
            
            if httpResponse.statusCode == 200 {
                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
                return tokenResponse
            } else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                print("[SheetsClient] ❌ Token exchange failed: \(body)")
                throw SheetsClientError.tokenExchangeError("HTTP \(httpResponse.statusCode): \(body)")
            }
        } catch let error as SheetsClientError {
            throw error
        } catch {
            throw SheetsClientError.networkError(error.localizedDescription)
        }
    }
    
    // MARK: - Row Creation
    
    private func createRow(from observation: StockObservation) -> [String] {
        return [
            dateFormatter.string(from: observation.timestamp),
            observation.ticker,
            String(format: "%.2f", observation.price),
            observation.change,
            String(format: "%.2f", observation.confidence),
            observation.rawSnippet
        ]
    }
    
    private func createPayload(row: [String]) -> [String: Any] {
        return [
            "values": [row]
        ]
    }
    
    private func handleDryRun(payload: [String: Any], observation: StockObservation) -> LogResult {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("[SheetsClient] 📋 DRY RUN - Would send to Sheets:")
            print("  Ticker: \(observation.ticker)")
            print("  Price:  $\(String(format: "%.2f", observation.price))")
            print("  Change: \(observation.change)")
            print("  Payload: \(jsonString)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
            return .dryRun(payload: jsonString)
        } catch {
            return .error("Failed to serialize payload: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Sheets API
    
    private func sendToSheets(payload: [String: Any], accessToken: String) async -> LogResult {
        // Build URL for append operation
        let urlString = "\(baseURL)/\(SheetsConfig.sheetId)/values/\(SheetsConfig.range):append"
        
        guard var urlComponents = URLComponents(string: urlString) else {
            return .error("Invalid URL")
        }
        
        urlComponents.queryItems = [
            URLQueryItem(name: "valueInputOption", value: "USER_ENTERED"),
            URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS")
        ]
        
        guard let url = urlComponents.url else {
            return .error("Failed to build URL")
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .error("Failed to encode payload: \(error.localizedDescription)")
        }
        
        // Send request
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid response")
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                print("[SheetsClient] ✅ Successfully logged to Sheets")
                return .success
            } else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                print("[SheetsClient] ❌ Error \(httpResponse.statusCode): \(body)")
                
                // Retry once on server errors
                if (500...599).contains(httpResponse.statusCode) {
                    return await retryOnce(payload: payload, accessToken: accessToken)
                }
                
                // If token expired, clear cache so next request gets a new one
                // If token expired, clear cache so next request gets a new one
                if httpResponse.statusCode == 401 {
                    await tokenCache.clear()
                }
                
                return .error("HTTP \(httpResponse.statusCode): \(body)")
            }
        } catch {
            print("[SheetsClient] ❌ Network error: \(error.localizedDescription)")
            return .error("Network error: \(error.localizedDescription)")
        }
    }
    
    private func retryOnce(payload: [String: Any], accessToken: String) async -> LogResult {
        print("[SheetsClient] 🔄 Retrying in 2 seconds...")
        
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        
        return await sendToSheets(payload: payload, accessToken: accessToken)
    }
}
