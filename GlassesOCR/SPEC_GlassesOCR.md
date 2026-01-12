# GlassesOCR — Specification Document

## 1. High-Level Overview

GlassesOCR is an iOS application that connects to Ray-Ban Meta smart glasses via Meta's Device Access Toolkit (DAT) SDK, captures live video frames from the glasses' camera, performs on-device optical character recognition (OCR), and extracts structured stock market data (ticker symbols, prices, and price changes). The extracted data is then logged to a Google Sheets spreadsheet for personal record-keeping and analysis.

The app is designed as a personal productivity tool for quickly logging stock information observed through the glasses—such as when viewing a trading terminal, TV ticker, or financial news screen—without needing to manually type or switch apps. All OCR processing happens on-device for privacy, and Google Sheets integration provides a lightweight, accessible data store.

---

## 2. Goals

- **Seamless glasses integration**: Connect to Ray-Ban Meta glasses with minimal friction and stream camera frames in real-time.
- **Accurate stock extraction**: Use on-device OCR to recognize text and parse ticker symbols, prices, and change indicators with reasonable accuracy.
- **Simple logging workflow**: Automatically append extracted stock observations to a Google Sheets spreadsheet.
- **Privacy-first design**: Perform all OCR on-device; no frames or raw text leave the device unless explicitly enabled.
- **Minimal, focused UI**: Provide a clean interface with Start/Stop control, status indicators, and a dry-run toggle.
- **Developer-friendly architecture**: Modular code with clear interfaces for easy testing and future extension.

---

## 3. Non-Goals

- **Real-time trading integration**: This is a logging/observation tool, not a trading platform.
- **Cloud-based OCR**: We do not use external OCR services (Google Vision, AWS Textract, etc.).
- **Multi-user or shared access**: This is a personal tool; no authentication or multi-tenancy.
- **Historical data analysis in-app**: The app logs data; analysis is done externally in Google Sheets.
- **Support for other wearables**: Only Ray-Ban Meta glasses (via Meta DAT SDK) are supported.
- **Continuous recording/storage of video**: Frames are processed and discarded; no video is saved.
- **Complex UI or animations**: The interface is utilitarian, not consumer-polished.

---

## 4. Requirements (Must-Have)

1. **Glasses Connection**: Connect to paired Ray-Ban Meta glasses using Meta DAT SDK.
2. **Camera Streaming**: Start and stop live camera stream from glasses.
3. **Frame Throttling**: Process at most one frame every 3 seconds (configurable constant).
4. **On-Device OCR**: Use Apple Vision framework (`VNRecognizeTextRequest`) for text recognition.
5. **Stock Parsing**: Extract ticker symbol (1–5 uppercase letters, optional "."), price (numeric with optional $ and decimals), and change/direction (+/− percentage or up/down indicators).
6. **Structured Output**: Produce a `StockObservation` object with: timestamp, ticker, price, change, confidence, rawTextSnippet.
7. **Google Sheets Logging**: Append observation rows to a Google Sheets spreadsheet via Sheets API v4.
8. **Dry-Run Mode**: Toggle to print payloads to console instead of sending to Sheets (default ON).
9. **UI Controls**: Start/Stop button, connection/streaming status, last extracted data display, dry-run toggle.
10. **Error Resilience**: Never crash if OCR returns no results; handle all errors gracefully.

---

## 5. Constraints / Assumptions

### iOS Permissions
- **Bluetooth**: Required for Meta DAT SDK to discover/connect glasses. Add `NSBluetoothAlwaysUsageDescription` to Info.plist.
- **Local Network**: May be required by DAT SDK. Add `NSLocalNetworkUsageDescription` if needed.
- **No Camera Permission on Phone**: The camera used is on the glasses, streamed via DAT SDK—not the phone's camera.

### Pairing
- Glasses must be paired with the Meta View app first. This app assumes pairing is already complete.
- DAT SDK handles connection handshake; we rely on SDK callbacks/events.

### Bandwidth / Latency
- DAT SDK streams at a resolution/framerate determined by the SDK. We do not control this directly.
- Network bandwidth for Sheets API is minimal (small JSON payloads).

### Frame Sampling
- We process one frame every `kFrameIntervalSeconds = 3.0` seconds.
- Intermediate frames are dropped to reduce CPU/battery usage.

### Battery
- Continuous OCR and Bluetooth streaming will consume battery. Extended use (>1 hour) will noticeably drain both phone and glasses.
- Recommendation: Use in short bursts.

---

## 6. Architecture Diagram (ASCII)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              GlassesOCR App                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐       ┌─────────────────┐       ┌───────────────┐  │
│  │  ContentView    │◀─────▶│  AppState       │◀─────▶│ GlassesManager│  │
│  │  (SwiftUI)      │       │  (ObservableObj)│       │ (DAT SDK)     │  │
│  └─────────────────┘       └────────┬────────┘       └───────┬───────┘  │
│          │                          │                        │          │
│          │                          ▼                        ▼          │
│          │                 ┌─────────────────┐      ┌────────────────┐  │
│          │                 │  OcrPipeline    │◀─────│ CVPixelBuffer  │  │
│          │                 │  (Apple Vision) │      │ (from glasses) │  │
│          │                 └────────┬────────┘      └────────────────┘  │
│          │                          │                                   │
│          │                          ▼                                   │
│          │                 ┌─────────────────┐                          │
│          │                 │  Parser         │                          │
│          │                 │  (Regex/Logic)  │                          │
│          │                 └────────┬────────┘                          │
│          │                          │                                   │
│          │                          ▼                                   │
│          │                 ┌─────────────────┐      ┌────────────────┐  │
│          │                 │ StockObservation│─────▶│ SheetsClient   │  │
│          │                 │ (Data Model)    │      │ (HTTP/REST)    │  │
│          │                 └─────────────────┘      └────────┬───────┘  │
│          │                                                   │          │
│          │                                                   ▼          │
│          │                                          ┌────────────────┐  │
│          └─────────────────────────────────────────▶│ Google Sheets  │  │
│                         (Status Updates)            │ (External)     │  │
│                                                     └────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

Data Flow:
1. User taps "Start" in ContentView
2. GlassesManager connects to glasses via DAT SDK
3. GlassesManager starts camera stream, emits CVPixelBuffer frames
4. AppState throttles frames (1 per 3s), sends to OcrPipeline
5. OcrPipeline runs VNRecognizeTextRequest, returns recognized text
6. Parser extracts ticker/price/change from text
7. StockObservation created with timestamp and metadata
8. SheetsClient appends row to Google Sheets (or logs if dry-run)
9. UI updates with status and last extracted data
```

---

## 7. Data Schema: Log Row

Each row logged to Google Sheets represents one `StockObservation`:

| Column       | Type    | Description                                         | Example              |
|--------------|---------|-----------------------------------------------------|----------------------|
| timestamp    | String  | ISO 8601 datetime when observation was captured     | 2025-12-24T14:32:05Z |
| ticker       | String  | Extracted stock ticker symbol                       | AAPL                 |
| price        | Decimal | Extracted price (USD)                               | 185.42               |
| change       | String  | Price change indicator (+/− %, or direction)        | +1.25%               |
| confidence   | Decimal | OCR confidence score (0.0–1.0)                      | 0.92                 |
| rawSnippet   | String  | Short snippet of raw OCR text for debugging         | AAPL 185.42 +1.25%   |

**Swift Data Model:**

```swift
struct StockObservation: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let ticker: String
    let price: Double
    let change: String
    let confidence: Double
    let rawSnippet: String
}
```

---

## 8. Error Handling Policy

### What to Show (User-Facing)
- **Connection Errors**: Display "Failed to connect" with brief reason (e.g., "Bluetooth off", "Glasses not found").
- **Streaming Errors**: Display "Stream interrupted" if frames stop unexpectedly.
- **Sheets Errors**: Display "Failed to log" with HTTP status or network error type.

### What to Log (Console/Debug)
- Full error descriptions with stack traces (via `print()` or `os_log`).
- OCR failures (empty results) logged as debug info, not errors.
- Sheets API response bodies for debugging.

### Retry Behavior
- **Glasses Connection**: No automatic retry; user must tap "Start" again.
- **Sheets API**: Retry once after 2-second delay on transient errors (5xx, timeout). Fail after one retry.
- **OCR Failures**: No retry; move on to next frame interval.

### Safe Defaults
- If OCR returns nothing, do nothing (no log, no crash).
- If parser finds no ticker/price, skip logging for that frame.
- If Sheets credentials missing, auto-enable dry-run mode.

---

## 9. Privacy Notes

### On-Device Processing
- All OCR is performed on-device using Apple Vision. No images or text are sent to external OCR services.
- Video frames are processed in memory and discarded immediately after OCR.

### Data Transmission
- Only structured `StockObservation` data (not raw images or full OCR text) is sent to Google Sheets.
- Transmission only occurs when dry-run mode is OFF and valid credentials are configured.

### No Persistent Storage
- The app does not save frames, images, or video to disk.
- OCR results are held in memory for display and logging only.

### User Control
- Dry-run mode (default ON) prevents any data from leaving the device.
- User must explicitly configure Sheets credentials and disable dry-run to enable logging.

### Third-Party SDKs
- Meta DAT SDK handles glasses communication. Review Meta's privacy policy for SDK data handling.
- Google Sheets API is used for logging. Data is stored in user's own Google account.

---

## 10. Acceptance Criteria / Test Plan

### Prerequisites
1. Ray-Ban Meta glasses paired with Meta View app on test device.
2. iOS device with Bluetooth enabled.
3. (For Sheets testing) Google Sheets API credentials configured.

### Test Scenarios

#### TC1: Glasses Connection
1. Open app.
2. Tap "Start".
3. **Expected**: Status shows "Connecting…" then "Connected" within 10 seconds.
4. **Pass if**: Glasses LED indicates connected; status updates correctly.

#### TC2: Camera Streaming
1. Complete TC1 (connected).
2. **Expected**: Status shows "Streaming".
3. **Pass if**: App receives frames (verified via debug logs or frame counter).

#### TC3: OCR Extraction
1. While streaming, hold glasses so camera sees text containing a stock ticker (e.g., "AAPL 185.42 +1.2%").
2. Wait 3+ seconds for frame processing.
3. **Expected**: UI shows extracted ticker, price, change.
4. **Pass if**: Displayed values match visible text (±minor OCR errors acceptable).

#### TC4: Dry-Run Logging
1. Ensure dry-run toggle is ON.
2. Trigger extraction (as in TC3).
3. **Expected**: Console logs the payload that would be sent to Sheets.
4. **Pass if**: Console shows correctly formatted JSON; no network request made.

#### TC5: Sheets Logging (Live)
1. Configure valid Sheets credentials (sheetId, access token).
2. Turn dry-run toggle OFF.
3. Trigger extraction.
4. **Expected**: Row appears in Google Sheets within 5 seconds.
5. **Pass if**: Sheets contains new row with correct data.

#### TC6: Stop Streaming
1. While streaming, tap "Stop".
2. **Expected**: Status shows "Stopped"; frame processing ceases.
3. **Pass if**: No further OCR logs; glasses LED indicates stream stopped.

#### TC7: Error Handling – No Text
1. Point glasses at blank wall or dark area.
2. Wait 3+ seconds.
3. **Expected**: No crash; no log entry; UI shows "No data" or previous data.
4. **Pass if**: App remains responsive.

#### TC8: Error Handling – Network Failure
1. Enable airplane mode on phone.
2. Turn dry-run OFF, trigger extraction.
3. **Expected**: UI shows "Failed to log" error; no crash.
4. **Pass if**: Error displayed; app recovers when network restored.

---

## Appendix: Environment Configuration

### Google Sheets API Setup (Service Account)

The app uses **Google Service Account authentication** with a JSON key file. This provides server-to-server auth without user interaction.

#### Configuration Values

| Key                       | Description                                    | Example                                       |
|---------------------------|------------------------------------------------|-----------------------------------------------|
| `SHEETS_ID`               | Google Sheets spreadsheet ID from URL          | `1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms`|
| `SHEETS_RANGE`            | Target sheet and range for appends             | `Sheet1!A:F`                                  |
| `serviceAccountKeyPath`   | Path to service account JSON key file          | `service-account.json` or absolute path       |

#### How to Obtain Service Account Credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create or select a project
3. **Enable Google Sheets API**:
   - Navigate to APIs & Services → Library
   - Search for "Google Sheets API" and enable it
4. **Create a Service Account**:
   - Navigate to IAM & Admin → Service Accounts
   - Click "Create Service Account"
   - Give it a name (e.g., `glassesocr-sheets`)
   - Grant no additional roles (we only need Sheets access)
5. **Generate a JSON Key**:
   - Click on the created service account
   - Go to Keys tab → Add Key → Create new key
   - Select JSON format
   - Download and save the file securely
6. **Share the Sheet with the Service Account**:
   - Open your Google Sheet
   - Click Share
   - Add the service account email (found in the JSON as `client_email`, e.g., `glassesocr@project.iam.gserviceaccount.com`)
   - Give it "Editor" access

#### Integration Steps

1. Add the JSON key file to your Xcode project (drag into project navigator)
2. Set the path in `SheetsConfig`:

```swift
// In SheetsClient.swift
struct SheetsConfig {
    static var sheetId: String = "YOUR_SHEET_ID"
    static var range: String = "Sheet1!A:F"
    static var serviceAccountKeyPath: String = "service-account.json"  // Bundle resource name
}
```

3. Ensure the JSON file is included in the app bundle (Target → Build Phases → Copy Bundle Resources)

#### Authentication Flow

1. App loads JSON key file containing service account credentials
2. Creates a JWT (JSON Web Token) signed with the private key
3. Exchanges JWT for access token via `https://oauth2.googleapis.com/token`
4. Uses access token in API requests (cached for ~1 hour)
5. Token is automatically refreshed when expired

**Security Notes**:
- Never commit the JSON key file to source control (add to `.gitignore`)
- For production, consider storing credentials in iOS Keychain
- The service account can only access sheets explicitly shared with it

---

*Last updated: December 24, 2025*

