## A. Current system summary (what exists now, assumptions)

### What you have today (confirmed from repo)
- **Frame source**: `GlassesManager` exposes `frameStream: AsyncStream<CVPixelBuffer>` and yields buffers from MWDAT `VideoFrame.sampleBuffer` (`CMSampleBufferGetImageBuffer`) while streaming at ~15 FPS. (`GlassesManager.swift`)
- **UI**: `ContentView` shows connection/streaming state, frame counter, last extracted “stock observation”, dry-run toggle, Start/Stop. (`ContentView.swift`)
- **Processing loop**: `AppState.startFrameProcessing()` consumes `frameStream`, **throttles to 1 frame / 3 seconds**, runs OCR, parses, then logs. It uses `nonisolated(unsafe)` to “capture” the buffer (works but is not the safest Swift 6 concurrency story long-term). (`ContentView.swift`)
- **OCR**: `OcrPipeline` uses Vision `VNRecognizeTextRequest` (accurate, en-US) and returns `OcrResult` (recognizedText, avg confidence, observations). (`OcrPipeline.swift`)
- **Parser**: `Parser` extracts **ticker + price (+ optional change)** via regex heuristics into `StockObservation`. (`Parser.swift`)
- **Spec**: `SPEC_GlassesOCR.md` describes a stock-text OCR logger architecture and constraints (privacy-first, no frame storage, simple UI).

### Key assumptions for the upgrade
- Frames continue to arrive from the glasses as **`CVPixelBuffer`** via `AsyncStream`.
- All processing stays **on-device**: SwiftUI + Vision + Core Data (no external services).
- We will add a **chart-first gate** and only do heavy OCR when needed.
- We will introduce **persistence** and a **session timeline** UI.
- We will harden concurrency to avoid unsafe buffer sharing across tasks/actors.

---

## B. Target user stories (3–6 user stories)

1. **Live understanding**
   - As a user, when I look at my screen through the glasses, the app tells me in real-time whether I’m looking at a **candlestick chart** and how confident it is.

2. **Structured extraction**
   - As a user, when a candlestick chart is detected, the app extracts **symbol, timeframe, visible price bounds, trend**, and shows me what it found with confidence and debug context.

3. **Session memory**
   - As a user, when I’m looking at charts over time, the app automatically groups extractions into a **session** (start/end time, top symbols) and ends the session after inactivity.

4. **Review & search**
   - As a user, I can browse sessions by day, open a session, and review each extracted CandleObject (thumbnail + fields + raw OCR) and search by symbol/timeframe.

5. **Debug & iterate**
   - As a developer, I can toggle a **debug overlay** showing detected chart box and crop regions, and see structured logs proving each pipeline stage is working.

---

## C. Data model (CandleObject, Session, confidence model, enums)

### Core concepts
- **Session**: a contiguous window of time where chart detection is “active enough” (with automatic start/end).
- **CandleObject**: one “best-known interpretation” of the chart at a moment, with revision/dedup logic.
- **Confidence**: per-field confidence + overall confidence with traceable components.

### Entities (Core Data)

#### `CDSession`
- **id**: UUID (unique)
- **startAt**: Date
- **endAt**: Date? (nil while active)
- **lastActiveAt**: Date (for inactivity timeout)
- **createdAt**: Date
- **updatedAt**: Date
- **platformHintRaw**: String? (e.g., `"tradingview"`, `"coinbase"`, `"unknown"`)
- **platformHintConfidence**: Double
- **summaryTopSymbols**: Transformable or String (e.g., `"BTC,ETH,AAPL"` cached for list speed)
- **candleCount**: Int32 (denormalized/cached)
- Relationship: **candles** (to-many) → `CDCandleObject`

#### `CDCandleObject`
- **id**: UUID (unique)
- **timestampCaptured**: Date (phone time)
- **updatedAt**: Date
- **dedupKey**: String (computed fingerprint used for merge/revision)
- **chartDetectedConfidence**: Double
- **sourceAppHintRaw**: String? + **sourceAppHintConfidence**: Double
- **symbol**: String? + **symbolConfidence**: Double
- **timeframeRaw**: String? + **timeframeConfidence**: Double
- **visiblePriceMin**: Double? + **visiblePriceMinConfidence**: Double
- **visiblePriceMax**: Double? + **visiblePriceMaxConfidence**: Double
- **visibleTimeStart**: Date? + **visibleTimeStartConfidence**: Double
- **visibleTimeEnd**: Date? + **visibleTimeEndConfidence**: Double
- **trendRaw**: String? (e.g., `"up"|"down"|"flat"|"volatile"`) + **trendConfidence**: Double
- **slopeMetric**: Double? (normalized slope; definition in section H)
- **rawOcrHeader**: String?
- **rawOcrYAxis**: String?
- **rawOcrFooter**: String?
- **rawOcrBody**: String? (optional; keep capped/truncated for size)
- **debugJSON**: Binary/Data (JSON-encoded debug metadata; or Transformable)
- **thumbnailRef**: String? (file path) OR **thumbnailData**: Binary/Data (see section J)
- **chartBoxX/Y/W/H**: Double (normalized [0,1], for overlay + dedup)
- Relationship: **session** (to-one) → `CDSession`

### Enums (Swift-side, stored as RawValue strings)
- `PlatformHint`: `kraken`, `coinbase`, `etrade`, `tradingview`, `unknown`
- `Trend`: `up`, `down`, `flat`, `volatile`, `unknown`
- `Timeframe`: `m1`, `m5`, `m15`, `h1`, `h4`, `d1`, `w1`, `unknown` (store display string too)

### Confidence model
Use a simple, explainable confidence structure:

- **Per-stage confidence**: each pipeline stage outputs a score \(0...1\)
- **Per-field confidence**: each extracted field has its own score \(0...1\)
- **Overall CandleObject confidence**: weighted combination:

\[
C_\text{overall} = w_\text{gate} C_\text{gate} + w_\text{fields} \cdot \text{mean}(C_\text{symbol}, C_\text{timeframe}, C_\text{range}, C_\text{trend}) - w_\text{conflict} \cdot P_\text{conflict}
\]

Where:
- \(P_\text{conflict}\) penalizes contradictory parses (e.g., two different symbols with similar confidence).

Store **debug components** (weights, raw signal scores, conflicts) inside `debugJSON` so you can tune later without schema changes.

---

## D. Processing pipeline (Stage A–E) with explicit inputs/outputs + confidence scoring

### Overview
We split processing into a **fast path** (chart gate) and a **slow path** (OCR + parsing), with backpressure and revision.

#### Stage A — Frame intake, throttling, and safe snapshotting
- **Input**: `CVPixelBuffer` from `GlassesManager.frameStream`
- **Output**: `FrameSnapshot` (Sendable) containing:
  - downsampled grayscale image buffer (for gating)
  - optional full-resolution `CGImage` (only when needed)
  - timestampCaptured
- **Confidence**: N/A (plumbing stage)
- **Notes**: This is where we fix Swift 6 non-Sendable issues by converting buffers *within a single isolation domain*.

#### Stage B — Real-time candlestick chart gate (fast, no OCR by default)
- **Input**: `FrameSnapshot.lowResGray`
- **Output**: `ChartGateResult`
  - `isChart: Bool`
  - `confidence: Double`
  - `chartBox: CGRect?` (normalized) when available
  - `signals: [SignalScore]` (for debug)
- **Confidence**: computed from signal table (section E)

#### Stage C — Region detection + crop plan (UI-agnostic first, adapters optional)
- **Input**: `FrameSnapshot.fullImage` (or request it if gate is high)
- **Output**: `CropPlan`
  - `chartBox`
  - `headerRegion`, `yAxisRegion`, `footerRegion`, `bodyRegion` (normalized rects)
  - optional `volumeRegion`
  - `platformHint` + confidence (from lightweight detection)
- **Confidence**: `cropConfidence` based on geometric plausibility and text-cluster alignment

#### Stage D — OCR execution (throttled, region-specific)
- **Input**: cropped `CGImage` regions + OCR config
- **Output**: `RegionOcrBundle`
  - text per region + per-region confidence + observations (optional)
- **Confidence**: OCR confidence combined with region quality score (contrast/blur)

#### Stage E — Parsing + trajectory + persistence + session update + revision/dedup
- **Input**: `RegionOcrBundle`, `CropPlan`, gate confidence, timestamps
- **Output**: `CandleObjectDraft` → persisted `CDCandleObject` (insert or update)
- **Confidence**: per-field + overall; includes conflict penalties
- **Revision**: merge into existing candle if rules match (section I)

---

## E. Region detection and cropping strategy (UI-agnostic first; adapter fallback)

### Core idea
1. Use **UI-agnostic visual signals** to find the chart region and axis structures.
2. Build a **crop plan** that targets small regions where the needed text typically lives (header/timeframe, y-axis prices).
3. Only if confidence is low do we invoke **platform adapters** that apply more specific heuristics.

### Signals table (candlestick chart detection)
Compute signals from a **downsampled grayscale** image (e.g., 256 px wide) using edge maps + simple morphology.

| Signal | What it detects | How to compute (fast heuristic) | Expected in candlestick charts | Common false positives | Contribution |
|---|---|---|---|---|---|
| Vertical wick density | Many thin vertical segments | Sobel edges → threshold → count vertical-connected components with high aspect ratio | High | Barcodes, text columns | + |
| Body rectangles pattern | Candle bodies (filled/unfilled blocks) | Edge map → find small rectangles via contour detection; measure repetition | Medium–High | UI cards, tables | + |
| Gridline lattice | Chart grid | Hough line transform (coarse) or projection peaks in x/y | Medium | Spreadsheets | + |
| Axis text clusters (without OCR) | Dense text near edges | `VNDetectTextRectanglesRequest` → cluster boxes along right/left | High | Any chart/screen with labels | + |
| Price-like glyph distribution | Many decimal-ish tokens | Very small OCR on y-axis only OR digit-shape classifier via connected components | Medium | Order books, tables | + |
| Plot area “ink ratio” | Chart occupies large region | Compute edge pixel ratio within candidate box | Medium | News pages with images | + |
| Repeated OHLC-like markers | Candlestick uniqueness | Presence of both vertical segments + nearby rectangles | High | line charts (low rectangles) | +++ |
| Line-chart dominance penalty | Smooth continuous curve | Detect long continuous polyline; high continuity penalizes | Low | line charts | − |
| Text-page penalty | Mostly text blocks | High density of text rectangles across entire frame penalizes | Low | articles, docs | − |

**Gate confidence**: weighted sum of normalized signals with penalties. Output `chartBox` when a dominant candidate region emerges (largest plausible plot area with grid + axis cluster alignment).

### Chart box detection (UI-agnostic)
- Start with candidate rectangles from:
  - strongest edge-bounded region (contours)
  - largest area that contains gridline signals
- Validate by:
  - axis text cluster alignment on left/right edge of candidate
  - aspect ratio plausibility (e.g., width/height in [1.1, 2.5], configurable)
- Produce `chartBox` in normalized coordinates.

### Crop plan (normalized rects relative to full frame)
Given `chartBox`, define:
- **Header**: a band above chartBox (or inside top 12% of chartBox), for symbol/timeframe
- **Y-Axis**: thin strip along right edge (or left if detected), for visible price bounds
- **Footer/X-axis**: bottom band for time window hints
- **Body**: interior of chartBox for trajectory features + debug

### Adapter fallback
Adapters run only when:
- `gateConfidence` is borderline (e.g., 0.45–0.65), or
- we have high `platformHintConfidence` but cropConfidence is low.

Adapters are **never the baseline**; they refine crop regions (e.g., header location) and parsing expectations (e.g., timeframe formatting).

---

## F. OCR strategy (which regions, preprocessing, throttling, languages)

### OCR regions (minimal set)
- **Header region**: symbol + timeframe + sometimes market name
- **Y-axis region**: visible price labels (min/max)
- **Footer region**: optional time window hints (e.g., “Jan 12”, “13:30”)
- **Body region**: **not full OCR by default** (expensive and noisy); only in debug mode or when parsing fails

### Preprocessing (cheap, on-device)
- Convert crop to grayscale
- Apply contrast enhancement (CIColorControls)
- Apply unsharp mask lightly (optional)
- Downscale y-axis crop to manageable size while keeping text legible

### Vision configuration
- `VNRecognizeTextRequest`:
  - `.fast` for y-axis (often enough), `.accurate` for header (symbol/timeframe are critical)
  - `recognitionLanguages = ["en-US"]` initially
  - Consider adding `"en-GB"` if you see consistent formatting differences
- Keep observations only in debug mode to reduce memory

### Throttling & scheduling (battery-conscious)
Two independent rates:
- **Gate FPS**: 4–8 FPS (fast signals; low-res)
- **OCR FPS**: 0.2–0.5 FPS (every 2–5 seconds) *only when gate is confidently true*

Additionally:
- If session is active and chart seems unchanged, OCR backs off (e.g., exponential backoff up to 10–15s) and relies on revision updates.

---

## G. Parsing strategy (ticker normalization, timeframe parsing, range extraction, error handling)

### Field extraction map (region → parsing → confidence → failure modes)

| Field | Source region | Parsing method | Confidence heuristic | Failure modes |
|---|---|---|---|---|
| `sourceAppHint` | header + global UI cues | keyword match (“TradingView”, “Kraken”, etc.) + adapter hints | boosts when multiple tokens match; penalize if only 1 weak token | localized UI strings; icons-only |
| `symbol/ticker` | header | regex + normalization + blacklist + adapter synonyms | high if uppercase token near known separators (/, -) and repeated across frames | false positives (“USD”, “MAX”); crypto pairs (“BTC/USD”) |
| `timeframe` | header (sometimes footer) | parse tokens: `1m`, `5m`, `15m`, `1h`, `4h`, `1D`, `1W` + variants (`D`, `H`, `min`) | high if token is in a known set; boost if adjacent to “chart” controls keywords | OCR confuses `1D` vs `10`; missing timeframe on some UIs |
| `visible price min/max` | y-axis | collect numeric tokens, normalize separators, choose extremes | high if multiple monotonic labels exist; penalize if only one number | currency symbols, commas/period swaps, scientific notation |
| `visible time window start/end` (optional) | footer/x-axis | date/time parsing via `DateFormatter` + relative time hints | only set when parse is unambiguous; otherwise nil | missing x-axis labels; locale formats |
| `trend` + `slopeMetric` | body (pixels) | MVP slope from price-scale mapping + candle midline changes | confidence grows with more candles & stable chart box | noisy camera motion; partial chart view |
| `raw OCR per region` | header/yAxis/footer/body | store truncated strings + confidence | always stored if OCR ran | privacy/storage bloat if uncapped |
| `debug metadata` | all stages | structured JSON | N/A | none |
| `thumbnail reference` | full frame or chart crop | encode JPEG/HEIF at low quality | N/A | storage growth if too frequent |

### Ticker normalization rules
- Uppercase, trim whitespace
- If pair detected (`BTC/USD`, `ETH-USD`), store:
  - `symbol = "BTC"` (or store full pair as separate `symbolPair` in debug until you add schema)
- Blacklist common false positives (extend your current list):
  - `USD`, `USDT`, `NYSE`, `NASDAQ`, `MAX`, `MIN`, `VOL`, etc.
- Confidence boost if symbol repeats across consecutive CandleObjects in same session.

### Timeframe parsing rules
- Accept: `1m 3m 5m 15m 30m 1h 2h 4h 1D 1W`
- OCR normalization:
  - treat `I` as `1` when surrounded by timeframe context
  - treat `O` as `0` only when token shape matches `10m` etc.
- If timeframe missing: set `unknown` with low confidence, do not block persistence.

### Range extraction rules (visible price bounds)
- Collect numeric tokens from y-axis OCR:
  - normalize `1,234.56` → `1234.56`
  - normalize `1.234,56` (if seen) via locale heuristic (optional Phase 3)
- Choose min/max as:
  - extremes after filtering out outliers by median absolute deviation
- Confidence:
  - high if ≥4 labels and consistent spacing
  - medium if 2–3 labels
  - low if 1 label (store it but do not claim bounds)

### Error handling policy (parsing)
- Never “fail the CandleObject” because one field is missing.
- Persist CandleObjects when:
  - `gateConfidence >= persistThreshold` (e.g., 0.65) **and**
  - at least one of: symbol/timeframe/range/trend is present with non-trivial confidence.
- Store raw OCR snippets to enable later parser improvements and reprocessing (optional future feature).

---

## H. Trajectory strategy (MVP pixel-based method + upgraded method)

### MVP (no ML): pixel-based slope with y-axis mapping (when possible)
1. If y-axis labels yield a credible **min/max**, map pixel y within chartBox to price:
   - \( price(y) = max - (y - y_{top})/(h) \cdot (max-min) \)
2. Sample a set of x-columns across chart body (e.g., 32 samples):
   - For each x, estimate candle “mid” by finding the densest vertical ink segment.
3. Convert each sampled mid to a price estimate and fit a robust linear regression:
   - Output `slopeMetric` = normalized slope (e.g., price change per chart width, scaled to [-1,1])
4. Derive `trend`:
   - `up` if slope > +T
   - `down` if slope < −T
   - `flat` if |slope| ≤ T and volatility low
   - `volatile` if residual error high or sign changes frequent

**Confidence** increases with:
- stable chartBox across frames
- more detected candle-like verticals
- valid price bounds

### Upgraded method (still non-ML): candle sequence extraction
- Detect individual candles (body + wick) using contour grouping in chartBox.
- Compute candle closes across x-order; use them for slope and volatility.
- More robust to gridlines and UI noise than the MVP column sampling.

(Phase 3 optional) add a lightweight CoreML classifier for “candlestick vs not” only if heuristics struggle, but keep heuristics as explainable baseline.

---

## I. Session management (start/end rules, dedup rules, revision rules)

### Session lifecycle rules
- **Session starts** when:
  - `gateConfidence >= startThreshold` (e.g., 0.70) for **K out of last N** gated frames (e.g., 3 of 5), to avoid flicker.
- **Session stays active** while:
  - chart detections continue intermittently and `now - lastActiveAt < inactivityTimeout` (configurable, default 5–10 minutes).
- **Session ends** when:
  - no `gateConfidence >= activeThreshold` (e.g., 0.60) for `inactivityTimeout`.

### Dedup/revision rules (exact, implementation-ready)
When a new `CandleObjectDraft` arrives, compute `dedupKey` from:
- quantized `chartBox` (e.g., round x/y/w/h to 0.02)
- normalized symbol (if present)
- timeframe (if present)
- platform hint (if high confidence)
- header OCR hash prefix (e.g., stable tokens only)

**Rule set (in order):**
1. **Hard reject spam**: if last persisted candle in session was < `minPersistInterval` (e.g., 2s), drop.
2. **Strong match update**: if an existing candle (most recent) has:
   - same `dedupKey` AND
   - `timestampCaptured` within `updateWindow` (e.g., 120s)
   → **update** that candle: merge fields by confidence (keep best), refresh `updatedAt`, optionally update thumbnail only every M updates.
3. **Soft match update**: if:
   - chartBox IoU ≥ 0.85 AND
   - symbol matches (or one missing) AND
   - timeframe matches (or one missing) AND
   - header token overlap ≥ 0.7
   → update most recent candle within `softUpdateWindow` (e.g., 60s).
4. **New candle**: otherwise insert new `CDCandleObject`.
5. **Confidence merge rule** (field-by-field):
   - If new field confidence > old + `delta` (e.g., 0.10), replace.
   - If within ±delta, keep old but append debug note.
6. **Thumbnail rule**:
   - Store/refresh thumbnail only when:
     - new candle inserted OR
     - major change detected (symbol/timeframe changed) OR
     - chartBox moved significantly (IoU < 0.7)

### “Same chart for minutes” behavior
- The system converges to a single candle object for that chart state, updating it as OCR improves, while still allowing a new candle when the chart meaningfully changes (symbol/timeframe/zoom/range shift).

---

## J. Persistence (Core Data schema, indexes, migrations, storage of thumbnails)

### Core Data model setup
- Add `Model.xcdatamodeld` with `CDSession` and `CDCandleObject`.
- Enable lightweight migration.
- Use **unique constraints**:
  - `CDSession.id`
  - `CDCandleObject.id`
- Add fetch indexes (Core Data “Indexes”):
  - `CDSession.startAt`, `CDSession.endAt`, `CDSession.lastActiveAt`
  - `CDCandleObject.timestampCaptured`, `CDCandleObject.symbol`, `CDCandleObject.timeframeRaw`, `CDCandleObject.dedupKey`

### Thumbnail storage (recommended)
Prefer **file-backed thumbnails** to keep Core Data lean:
- Store thumbnail JPEG (e.g., 320px wide, quality 0.5–0.7) in:
  - `Application Support/Thumbnails/<candleId>.jpg`
- Save `thumbnailRef` path (relative) in Core Data.

Fallback (simpler, but heavier):
- `thumbnailData: Data` in Core Data, but enforce max size and consider “Allows External Storage”.

### Debug metadata storage
- `debugJSON: Data` containing:
  - gate signal scores
  - chartBox
  - crop rects
  - OCR confidences per region
  - parsing candidates and conflicts
  - slope computation summary

### Retention policy (battery/storage hygiene)
- Configurable limits:
  - max sessions retained (e.g., last 30 days)
  - max candles per session (optional)
  - prune thumbnails for low-confidence candles if storage is constrained

---

## K. UI design (screens, navigation, state management, debug overlay)

### Navigation structure (SwiftUI)
- `TabView` (optional) or `NavigationStack` with top-level routes:
  1. **Live** (stream + status + overlay toggle)
  2. **Sessions** (timeline memory)

### Screen 1: Live
**Wireframe description**
- Top: connection/streaming status + frame/gate/OCR rates
- Middle: “Chart Detected” badge with confidence
- Toggles:
  - OCR enabled
  - Debug overlay
- Bottom: Start/Stop streaming
- Optional: compact “last CandleObject summary”

**Components**
- Status rows: Registered/Streaming, FPS, OCR cadence
- Chart badge: `Detected/Not Detected` + confidence bar
- Debug overlay: draw chartBox + crop rects on a preview image (if you render one) or show numeric rects + last thumbnail
- “Last extraction” card: symbol, timeframe, range, trend, overall confidence

### Screen 2: Sessions (grouped by day)
**Wireframe**
- List grouped by date (Today, Yesterday, …)
- Each session row:
  - “12:55–1:55”
  - candle count
  - top symbols chips (BTC, AAPL)
  - platform hint (optional)

### Screen 3: Session detail
- Header: session start/end + summary
- List of CandleObjects:
  - thumbnail
  - symbol + timeframe
  - range + trend
  - confidence

### Screen 4: Candle detail
- Sections:
  - Extracted fields (with confidences)
  - Raw OCR per region (collapsible)
  - Debug info (chartBox, crop rects, signal scores, slope details)
  - Thumbnail full view

### State management
- `@MainActor AppModel: ObservableObject` owns:
  - streaming state, gate confidence, last results
  - references to pipeline orchestrator (actor-backed)
- Core Data:
  - `PersistenceController` provides `NSPersistentContainer`
  - Views use `@Environment(\.managedObjectContext)` + `@FetchRequest`

---

## L. Extensibility (adapter interface, platform detection approach)

### “General engine + optional adapters”
- **General engine**:
  - chart gate
  - chart box detection
  - crop plan generation
  - OCR + parsing
  - session/dedup
- **Adapters**:
  - provide refinements only: better crop rects, extra parsing rules, platform hints

### Adapter interface (conceptual)
- `PlatformAdapter` capabilities:
  - `detectPlatform(from headerText, uiSignals) -> (hint, confidence)`
  - `refineCropPlan(basePlan, frame) -> CropPlan`
  - `augmentParsing(bundle) -> ParsedFieldsDelta`

### Adding a new adapter checklist
- Define platform tokens/signals (no layout hardcoding as default path)
- Implement adapter methods
- Add it to adapter registry with priority rules:
  - only apply when `platformConfidence` high OR general confidence low
- Add golden screenshots for that platform to test dataset

---

## M. Performance and concurrency (threading model, throttles, instrumentation)

### Concurrency safety (Swift 6, CVPixelBuffer non-Sendable)
**Principle**: never pass `CVPixelBuffer` across actor/task boundaries. Convert it immediately into Sendable representations.

**Recommended isolation approach**
- A dedicated `FrameIntakeActor`:
  - receives `CVPixelBuffer` synchronously from the stream consumption context
  - locks base address, creates:
    - low-res grayscale buffer (Data)
    - optionally `CGImage`/`CIImage` render for crops
  - returns a **Sendable** `FrameSnapshot`

Minimal starter snippet (pattern only):

```swift
// Conceptual only: create a Sendable snapshot before crossing concurrency domains.
struct FrameSnapshot: Sendable {
  let capturedAt: Date
  let lowResGray: Data
  let width: Int
  let height: Int
  // Optionally: an encoded JPEG Data for crops/thumbnail, instead of CVPixelBuffer/CGImage
  let fullFrameJPEG: Data?
}
```

### Throttles (recommended defaults)
- **Gate**: 6 FPS (every ~166ms) using low-res gray only
- **OCR**: every 3–5s when chart confidence is high; slower when stable
- **Backpressure**:
  - keep only the latest frame snapshot for gating
  - OCR stage should be “latest-wins” (drop queued OCR jobs if new supersedes)

### Battery/perf tradeoffs
- Reduce CPU by:
  - using low-res gating
  - OCR only on small crops (header + y-axis)
  - adaptive OCR cadence during stable sessions
- Reduce memory by:
  - not storing full-resolution frames
  - thumbnail file size caps + retention pruning

### Instrumentation (must-have logs + optional signposts)
- Use `os.Logger` categories: `frame`, `gate`, `crop`, `ocr`, `parse`, `trend`, `session`, `persist`
- Add `os_signpost` around:
  - gate computation
  - OCR per region
  - persistence write

### “Log lines to print for each stage” (implementation checklist)
- Stage A:
  - `[frame] rx ts=<iso> dropped=<bool> gateFPS=<n> ocrDueIn=<sec>`
- Stage B:
  - `[gate] conf=0.78 isChart=true box=(x,y,w,h) signals={wick:0.9 grid:0.6 axis:0.8 linePenalty:0.1}`
- Stage C:
  - `[crop] conf=0.72 platform=tradingview(0.61) regions={header:..., yAxis:..., footer:...}`
- Stage D:
  - `[ocr] header conf=0.84 chars=42`
  - `[ocr] yAxis conf=0.76 nums=8`
- Stage E:
  - `[parse] symbol=BTC(0.88) timeframe=1h(0.71) range=[41250, 42780](0.66)`
  - `[trend] slope=0.23 trend=up(0.62) samples=32 residual=0.18`
  - `[dedup] action=update existingId=<uuid> reason=dedupKey match`
  - `[persist] sessionId=<uuid> candleId=<uuid> overall=0.73`

---

## N. Testing plan (unit/integration, datasets, mocks)

### Unit tests (fast, deterministic)
- Parsing tests from OCR strings:
  - symbol normalization (crypto pairs, equities, false positives)
  - timeframe parsing variants
  - y-axis numeric extraction and bounds selection
- Confidence scoring tests:
  - signal weighting and penalty behavior
  - merge/revision field replacement rules

### Golden dataset (screenshots → expected outputs)
- Add an on-device test bundle with:
  - screenshots from Kraken/Coinbase/E*TRADE/TradingView-like UIs
  - non-candlestick negatives: line charts, tables, articles, order books, watchlists
- For each image:
  - expected gate result (isChart + confidence threshold)
  - expected chartBox plausibility (IoU range or sanity checks)
  - expected extracted fields (symbol/timeframe/range when present)

### Mock frame source (“Mock Device Kit”)
- `MockFrameStream` that replays:
  - images from bundle at configurable FPS
  - jitter, blur, brightness shifts to simulate head motion
- Enables development without glasses and repeatable regression tests.

### On-device debugging steps
- Toggle debug overlay
- Confirm logs per stage match expectations
- Save last N debugJSON blobs locally for inspection (developer-only setting)

### Acceptance criteria / Definition of Done per phase
(See section O for phase-specific DoD.)

---

## O. Phased implementation plan (Phase 1–3) with tasks, acceptance criteria, and time estimates removed (no time estimates)

### Phase 1 — Foundation: pipeline skeleton + Core Data + sessions
**Tasks**
- Add Core Data stack (`PersistenceController`)
- Implement `SessionManager` (start/end/inactivity)
- Implement safe `FrameSnapshot` creation and “latest-wins” throttling
- Build UI: Live status + Sessions list (empty state ok)
- Persist dummy CandleObjects (no real chart logic yet) to validate UI + storage

**Acceptance criteria**
- Sessions auto-start/auto-end based on simulated “active” toggles
- CandleObjects persist and appear in Sessions UI
- No concurrency warnings about sending `CVPixelBuffer` across tasks

### Phase 2 — Candlestick gate + crop plan + targeted OCR
**Tasks**
- Implement Stage B gate signals (low-res)
- Implement chartBox detection + crop plan (header/y-axis/footer/body)
- Run OCR only on header + y-axis, gated by confidence
- Implement parsing for symbol/timeframe/range
- Add debug overlay showing chartBox + regions
- Add revision/dedup rules (update vs insert)

**Acceptance criteria**
- On golden dataset: candlestick charts detected reliably; non-candlestick mostly rejected
- While staring at same chart: CandleObjects update rather than spam
- UI shows extracted symbol/timeframe/range with confidences

### Phase 3 — Trajectory + adapters + robustness
**Tasks**
- Implement MVP slopeMetric + trend
- Add adapter framework and 1–2 optional adapters (used only when needed)
- Expand golden dataset and regression tests
- Add pruning/retention policies and performance signposts

**Acceptance criteria**
- Trend and slopeMetric stable across short head movements
- Adapter usage is rare and observable in logs
- Battery/perf within acceptable bounds (gate fast, OCR infrequent)

---

## Next Actions Checklist (10–20 concrete steps, in order)

1. Create a new `DESIGN.md` in your repo and paste this doc as the baseline spec.
2. Add Core Data stack (`PersistenceController`) and create `Model.xcdatamodeld` with `CDSession` + `CDCandleObject`.
3. Implement `SessionManager` rules (start/end/inactivity) and persist sessions.
4. Replace direct buffer passing with a **Sendable `FrameSnapshot`** approach (convert immediately; no `nonisolated(unsafe)` for pixel buffers).
5. Add pipeline orchestrator separation: Stage A (snapshot) → Stage B (gate) → Stage C/D (conditional).
6. Implement Stage B gating signals (low-res) and log `[gate]` lines with signal breakdown.
7. Implement chartBox detection and generate a `CropPlan` (header/yAxis/footer/body).
8. Wire OCR to run **only on header + y-axis** when `gateConfidence` is high and OCR cooldown allows.
9. Implement parsing for symbol + timeframe + y-axis bounds with per-field confidence.
10. Persist CandleObjects into the active session; implement dedup/revision rules (update most recent by dedupKey).
11. Build SwiftUI Sessions list grouped by day using `@FetchRequest`.
12. Build Session detail and Candle detail screens; show confidences and raw OCR snippets.
13. Add debug overlay toggle in Live view and render chartBox + crop rects (or show rect values + thumbnail as MVP).
14. Create a `MockFrameStream` that replays bundled screenshots for development without glasses.
15. Add unit tests for symbol/timeframe/range parsing (using your sample OCR strings + new cases).
16. Add golden image tests for gate pass/fail across multiple platforms and negatives.
17. Implement MVP trajectory (`slopeMetric` + `trend`) and show it in Candle detail.
18. Add adapter interface + registry; implement one adapter only as a fallback demonstration.
19. Add retention/pruning policy for thumbnails and low-confidence debug artifacts.
20. Add `os_signpost` around gate/OCR/persist and validate performance under real streaming.

---

## Progress Checklist

- [ ] Core Data stack and entities in `Model.xcdatamodeld`
- [ ] `SessionManager` (start/end/inactivity + dedup/update)
- [ ] `FrameIntakeActor` snapshotting (Sendable, no unsafe CVPixelBuffer hops)
- [ ] Pipeline orchestrator wiring (Stages A–E, throttles)
- [ ] Gate signals + confidence + chartBox logging
- [ ] Crop plan + adapter interface + registry
- [ ] Region OCR (header/y-axis) with cadence control
- [ ] Parsing (symbol/timeframe/range) + trend/slope MVP + confidence aggregation
- [ ] Persistence integration (CandleObjectDraft→Core Data, thumbnails)
- [ ] SwiftUI Live UI updates (status, overlay toggle, last extraction)
- [ ] SwiftUI Sessions list/detail + Candle detail (fields, confidences, raw OCR, debug)
- [ ] Debug overlay rendering (chartBox/regions) or textual fallback
- [ ] Mock frame source + golden image dataset
- [ ] Unit tests (parsing, signals, dedup), integration/golden tests (gate/OCR)
- [ ] Instrumentation (`os_signpost`, logs), perf/battery verification
- [ ] Retention/pruning policies and threshold tuning
