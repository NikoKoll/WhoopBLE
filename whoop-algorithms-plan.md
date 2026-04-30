# Whoop BLE — Algorithms & Implementation Plan

> **Purpose**: This document defines the concepts, data structures, and algorithms needed to
> rebuild Whoop biometric metrics from raw BLE data. It is intended as a reference for
> Claude Code to implement in Swift. No Swift syntax here — only logic, formulas, and flow.

---

## 0. Foundation: BLE Communication Protocol

Before any feature can work, the app must be able to write commands to the device and read
notifications back. Everything else depends on this layer being correct.

### 0.1 BLE Characteristics

| Characteristic UUID | Name | Direction |
|---|---|---|
| `61080002-...` | CMD_TO_STRAP | Write (app → device) |
| `61080003-...` | CMD_FROM_STRAP | Notify (device → app) |
| `61080004-...` | EVENTS_FROM_STRAP | Notify (device → app) |
| `61080005-...` | DATA_FROM_STRAP | Notify (device → app) |
| `00002a37-...` | Standard BLE HR | Notify (device → app) |

The app must subscribe to notifications on CMD_FROM_STRAP, EVENTS_FROM_STRAP, and
DATA_FROM_STRAP immediately after connecting.

---

## 0.2 Packet Structure — Short Command (8 bytes + checksum)

Used for: activity start/stop, HR broadcast toggle, data retrieval trigger.

```
Byte 0-4:   Header — always aa 08 00 a8 23
Byte 5:     Packet counter — increment by 1 each command (wraps at 255)
Byte 6:     Category byte — defines what the command does (see table below)
Byte 7:     Value — 01 = ON/start, 00 = OFF/stop
Byte 8-11:  CRC-32 checksum of bytes 0–7
```

**Category byte reference:**

| Hex | Purpose |
|---|---|
| `0x03` | Start / stop activity recording |
| `0x0e` | Enable / disable HR broadcast |
| `0x16` | Trigger data retrieval from DATA_FROM_STRAP |
| `0x73` | Ping — device replies with 01 on CMD_FROM_STRAP |
| `0x74` | Request string data from device |

---

## 0.3 Packet Structure — Alarm (16 bytes + checksum)

Used for: setting the vibration alarm.

```
Byte 0-4:   Header — always aa 10 00 57 23
Byte 5:     Packet counter
Byte 6-7:   Flags — always 42 01
Byte 8-11:  Unix timestamp (little-endian uint32) of next alarm ring time
Byte 12-15: Padding — always 00 00 00 00
Byte 16-19: CRC-32 checksum of bytes 0–15
```

---

## 0.4 The CRC-32 Checksum — Critical Detail

Every packet written to CMD_TO_STRAP must end with a valid CRC-32 checksum or the device
will silently ignore it. This is NOT standard CRC-32. It uses a custom XOR output value.

> **⚠ IMPORTANT — VERIFIED VIA TESTING**
> The original reverse-engineering repo only documented ONE CRC variant (the alarm/erase
> one). Empirical testing against 35 known packets revealed that **the device uses THREE
> different XOR output values depending on packet type**. All other parameters are the
> same — only the final XOR mask changes.
> 
> This was verified by brute-force searching CRC parameter space against all known
> (message, checksum) pairs from the repo logs. All 35 test packets pass with the
> three-variant scheme below.

**Common parameters (all three variants):**

```
Polynomial:       0x04C11DB7   (standard CRC-32 polynomial)
Initial value:    0x00000000
Reflect input:    true
Reflect output:   true
```

**XOR output value depends on packet header:**

| Packet type | Header (5 bytes) | XOR output | Used for |
|---|---|---|---|
| 16-byte commands | `aa 10 00 57 23` | `0xF43F44AC` | Alarm setting, erase device, sync requests |
| 8-byte commands  | `aa 08 00 a8 23` | `0x6971BE68` | Activity start/stop, HR broadcast, reboot, all short commands |
| 28-byte activity | `aa 18 00 ff 28` | `0xE02CCD0E` | DATA_FROM_STRAP activity packets |

**How to compute it:**

1. Look at the first 5 bytes of the packet to determine which XOR output to use.
2. Take the raw packet bytes (everything EXCEPT the last 4 checksum bytes).
3. Initialize the CRC register to `0x00000000`.
4. For each byte, reflect the byte (reverse its 8 bits), then XOR it into the register's high byte.
5. Process 8 bits per byte using the polynomial `0x04C11DB7`.
6. After all bytes, reflect the entire 32-bit register.
7. XOR the result with the appropriate XOR output value from the table above.
8. Append the result as 4 bytes, little-endian.

**Verified test vectors:**

```
Alarm packet (uses 0xF43F44AC):
  Input:    aa 10 00 57 23 6d 42 01 d0 36 65 66 00 00 00 00
  Expected: f6 2d eb 81  ✓

Activity start command (uses 0x6971BE68):
  Input:    aa 08 00 a8 23 8c 03 01
  Expected: 7d 5e c6 27  ✓

Activity data packet (uses 0xE02CCD0E):
  Input:    aa 18 00 ff 28 02 ad 89 65 66 f0 65 42 01 67 06 00 00 00 00 00 00 01 01
  Expected: 3b a0 0d 4d  ✓
```

**Implementation note for Swift**: Build a single CRC function that takes the message bytes
and an XOR output parameter. Then write a wrapper that inspects the packet header and
selects the correct XOR output automatically:

```
function whoopCRC(message: bytes) -> uint32:
    header = first 5 bytes of message
    
    if header == [0xaa, 0x10, 0x00, 0x57, 0x23]:
        xor_out = 0xF43F44AC
    elif header == [0xaa, 0x08, 0x00, 0xa8, 0x23]:
        xor_out = 0x6971BE68
    elif header == [0xaa, 0x18, 0x00, 0xff, 0x28]:
        xor_out = 0xE02CCD0E
    else:
        throw "Unknown packet type"
    
    return crc32_with_xorout(message, xor_out)
```

**Note on packet counter**: The device does NOT validate the counter — confirmed by the
reverse engineering (sending old counter values still works). Increment it anyway for
correctness, but do not treat counter mismatch as a failure.

---

## 1. Phase 1 — Core Data Acquisition

### 1.1 Heart Rate Stream

**Source**: Two independent streams available simultaneously.

**Stream A — Standard BLE HR Service (recommended for simplicity)**
- Subscribe to characteristic `0x2A37`
- Parse byte 1 as uint8 BPM value (flags byte at position 0 indicates 8-bit vs 16-bit format)
- No custom protocol needed — this is standard Bluetooth Heart Rate Profile

**Stream B — DATA_FROM_STRAP activity packets**
- Only active when an activity is running (after sending start command with category `0x03`)
- Arrives every 1 second
- Packet format (32 bytes + checksum):

```
Byte 0-5:   Header — aa 18 00 ff 28 02
Byte 6-9:   Unix timestamp (little-endian uint32) — current second
Byte 10-11: Unknown signal data (likely raw sensor)
Byte 12:    Heart rate BPM (uint8)
Byte 13:    RR interval count in this packet (uint8) — how many RR values follow
Byte 14-21: RR interval data — up to 4 values, each uint16 little-endian, in milliseconds
Byte 22-27: Unknown
Byte 28-31: CRC-32 checksum
```

**Algorithm — HR stream manager:**

```
on connect:
    subscribe to 0x2A37 notifications
    subscribe to DATA_FROM_STRAP notifications
    send start activity command (category 0x03, value 0x01)

on 0x2A37 notification:
    parse BPM from byte 1 (or bytes 1-2 if 16-bit flag set)
    emit HRSample(bpm, timestamp: now())

on DATA_FROM_STRAP notification:
    parse unix timestamp from bytes 6-9
    parse bpm from byte 12
    parse rr_count from byte 13
    for i in 0..<rr_count:
        parse rr[i] from bytes (14 + i*2)..<(16 + i*2) as uint16 little-endian
    emit HRSample(bpm, timestamp)
    emit RRSamples(rr[], timestamp)
```

---

### 1.2 RR Interval Decoder

RR intervals are the time in milliseconds between successive heartbeats. They are the
foundation of HRV. Getting this right is essential for Phase 2.

> **✓ VERIFIED VIA TESTING**
> The decoder logic below was validated against real RR data from the repo's sync packet
> dumps. For HR=88 BPM, decoded RR values ranged 693–763 ms (expected ~682 ms for 88 BPM).
> The match confirms `uint16 LE in milliseconds` is the correct interpretation.

**Decoding rules:**

```
rr_count = packet[13]  // how many valid RR values in this packet (0–4)

for i from 0 to rr_count - 1:
    low_byte  = packet[14 + i*2]
    high_byte = packet[15 + i*2]
    rr_ms = low_byte | (high_byte << 8)  // little-endian uint16

    if rr_ms > 300 and rr_ms < 2000:    // sanity filter: 30–200 BPM range
        accept rr_ms
    else:
        discard (artifact)
```

> **⚠ Sanity filter tightened**: Original plan used 200–3000 ms, but testing showed an
> outlier first-beat artifact of 1639 ms in real activity packet data. A tighter
> 300–2000 ms window (30–200 BPM) better rejects these without losing real beats.
> Note that the very first RR packet after activity start often contains an unreliable
> "first beat" value — consider discarding the first RR sample of any new session.

**Note on the rr_count byte**: In activity packets, this is typically 0 or 1 (one RR per
1-second packet). In sync packets it can be up to 4 (multiple beats packed into one
historical packet). Either format works with the same decoder.

**Storage**: Maintain a rolling buffer of the last 300 RR values (approx. 5 minutes at
60 BPM). New values append to the end; oldest are dropped when buffer exceeds capacity.

---

### 1.3 Activity Start / Stop Control

**Start activity:**

```
build packet:
    header:  aa 08 00 a8 23
    counter: current_counter (then increment)
    category: 0x03
    value:    0x01
    checksum: CRC32(bytes 0..7)

write to CMD_TO_STRAP
set activity_active = true
record activity_start_time = now()
```

**Stop activity:**

```
build packet:
    header:  aa 08 00 a8 23
    counter: current_counter (then increment)
    category: 0x03
    value:    0x00
    checksum: CRC32(bytes 0..7)

write to CMD_TO_STRAP
set activity_active = false
record activity_end_time = now()
finalize activity session
```

---

### 1.4 HR Broadcast Toggle

Enables the Whoop to broadcast HR to other BLE devices (like Apple Watch or gym equipment).
This is a separate feature from the app's own HR reading.

```
to enable:
    category: 0x0e, value: 0x01

to disable:
    category: 0x0e, value: 0x00
```

Note: The app must re-send the enable command periodically (every few minutes) because the
device does not persist this setting across connection drops.

---

### 1.5 Alarm Setting

```
target_unix = unix timestamp of next desired alarm ring time

build packet:
    header:   aa 10 00 57 23
    counter:  current_counter (then increment)
    flags:    42 01
    unix:     target_unix as 4 bytes, little-endian
    padding:  00 00 00 00
    checksum: CRC32(bytes 0..15)

write to CMD_TO_STRAP
```

**Important**: The device only rings once per alarm time. To set a recurring alarm, the
app must listen for the alarm trigger (category `0x16` notification on CMD_FROM_STRAP
after the alarm fires) and immediately send the next alarm packet.

---

## 2. Phase 2 — Derived Biometrics

All Phase 2 metrics are computed from the HR and RR streams established in Phase 1.
No additional BLE commands are needed.

### 2.1 Resting Heart Rate (RHR)

**Concept**: The lowest sustained heart rate during a low-motion period. Best computed
overnight but can be estimated from any extended quiet period.

**Algorithm:**

```
WINDOW_DURATION = 300 seconds (5 minutes)
MOTION_THRESHOLD = 0.1 g (low-motion gate)
MIN_SAMPLES = 200  // need enough data to be meaningful

every 60 seconds:
    collect all HR samples from the last WINDOW_DURATION
    if sample_count < MIN_SAMPLES: skip

    compute motion_variance over same window
    if motion_variance > MOTION_THRESHOLD: skip  // too much movement

    window_average = mean(hr_samples)
    
    // track rolling minimum over the day
    if window_average < daily_rhr_candidate:
        daily_rhr_candidate = window_average

at end of day (or after sleep):
    rhr = daily_rhr_candidate
    persist to history with date
    reset daily_rhr_candidate = infinity
```

---

### 2.2 Heart Rate Variability (HRV) — RMSSD and SDNN

**Concept**: HRV measures the variation between heartbeats. Two complementary metrics:
- **RMSSD** (Root Mean Square of Successive Differences) — short-term parasympathetic activity
- **SDNN** (Standard Deviation of NN intervals) — total variability across both ANS branches

> **✓ VERIFIED VIA TESTING**
> The RMSSD formula was validated with multiple test cases including a hand-calculated
> case (input [800, 820, 810, 830, 815] → RMSSD = 16.77 ms exact match). Both formulas
> below are correct.

**Why both**: Many recovery score algorithms weight RMSSD AND SDNN together because they
capture different physiological signals. Computing both adds essentially zero cost since
they share the same input data.

**RMSSD formula:**

```
RMSSD = sqrt( (1 / (N-1)) * sum( (RR[i+1] - RR[i])^2 ) for i in 0..N-2 )
```

**SDNN formula:**

```
mean_rr = sum(RR) / N
SDNN = sqrt( (1 / (N-1)) * sum( (RR[i] - mean_rr)^2 ) for i in 0..N-1 )
```

**Algorithm:**

```
function computeHRV(rr_buffer):
    if rr_buffer.count < 2: return nil
    
    // Use last 60 values for "live" reading, last 300 for "stable" reading
    window = rr_buffer.last(WINDOW_SIZE)
    
    // RMSSD
    sum_sq_diff = 0
    for i from 0 to window.count - 2:
        diff = window[i+1] - window[i]
        sum_sq_diff += diff * diff
    rmssd = sqrt(sum_sq_diff / (window.count - 1))
    
    // SDNN (extra ~3 lines)
    mean_rr = sum(window) / window.count
    sum_sq_dev = 0
    for rr in window:
        sum_sq_dev += (rr - mean_rr) * (rr - mean_rr)
    sdnn = sqrt(sum_sq_dev / (window.count - 1))
    
    return (rmssd: rmssd, sdnn: sdnn)
```

**Window sizes — use both:**

```
LIVE_WINDOW   = 60   // last 60 RR (~1 minute) → updates frequently for live UI
STABLE_WINDOW = 300  // last 300 RR (~5 minutes) → standard HRV literature window
```

The 5-minute stable RMSSD is the value to persist as the "morning HRV" used in recovery
scoring. The 1-minute live RMSSD is what to display in real-time stress indicators.

**Computation schedule:**
- During sleep: every 5 minutes continuously
- During wake hours, low motion: every 5 minutes
- During activity (high motion): pause computation — motion artifact corrupts RR intervals

**Typical values (RMSSD):**
- < 20 ms: low (stress, fatigue, overtraining)
- 20–50 ms: moderate (most healthy adults)
- > 50 ms: high (good recovery, often seen in trained athletes)

**Typical values (SDNN):**
- < 50 ms: low
- 50–100 ms: moderate
- > 100 ms: high

Note: These thresholds are population averages. Personal baseline tracking (Phase 3)
makes them far more meaningful.

---

### 2.3 Sleep Detection

**Concept**: Infer sleep from the combination of sustained low HR, low motion, and
absence of activity commands. No dedicated sleep stream exists in the BLE protocol.

**Algorithm:**

```
// State machine: AWAKE → SLEEP_CANDIDATE → SLEEPING → AWAKE

SLEEP_HR_THRESHOLD = (personal_rhr + 10)  // within 10 BPM of resting HR
SLEEP_MOTION_THRESHOLD = 0.05 g
CANDIDATE_DURATION = 600 seconds  // must sustain conditions for 10 min

state = AWAKE
candidate_start = nil

every 30 seconds:
    current_hr = average HR over last 60 seconds
    current_motion = motion variance over last 60 seconds
    
    low_hr     = current_hr < SLEEP_HR_THRESHOLD
    low_motion = current_motion < SLEEP_MOTION_THRESHOLD
    time_of_day = is it between 9 PM and 11 AM?  // optional prior

    if state == AWAKE:
        if low_hr and low_motion:
            candidate_start = now()
            state = SLEEP_CANDIDATE

    if state == SLEEP_CANDIDATE:
        if not (low_hr and low_motion):
            state = AWAKE  // conditions broke, reset
            candidate_start = nil
        else if (now() - candidate_start) >= CANDIDATE_DURATION:
            sleep_onset = candidate_start
            state = SLEEPING
            emit SleepEvent(onset: sleep_onset)

    if state == SLEEPING:
        if not (low_hr and low_motion):
            // sustained waking: confirm after 5 minutes of high activity
            wake_candidate_start = now()
        if (now() - wake_candidate_start) > 300:
            sleep_end = now()
            state = AWAKE
            emit WakeEvent(time: sleep_end)
            record SleepSession(onset: sleep_onset, end: sleep_end)
```

**Outputs per session:**
- Sleep onset time
- Wake time
- Total sleep duration
- Number of interruptions (brief wake events during the night)

---

### 2.4 HR Zones and Cardiovascular Load

**Concept**: Classify each heart rate sample into a zone based on percentage of max HR.
Accumulate time in each zone to compute daily cardiovascular load.

**Zone definitions (% of max HR):**

```
Zone 1: 50–60%  — Very light / recovery
Zone 2: 60–70%  — Light / fat burning
Zone 3: 70–80%  — Moderate / aerobic
Zone 4: 80–90%  — Hard / threshold
Zone 5: 90–100% — Max effort / anaerobic
```

**Max HR estimation (if not user-provided):**

```
max_hr = 220 - age
```

**Zone weights for strain calculation (exponential — more physiologically accurate):**

```
Zone 1: weight 0.50   // exp(0.0) × 0.5
Zone 2: weight 1.01   // exp(0.7) × 0.5
Zone 3: weight 2.03   // exp(1.4) × 0.5
Zone 4: weight 4.08   // exp(2.1) × 0.5
Zone 5: weight 8.20   // exp(2.8) × 0.5
```

> Zone 5 effort is weighted 16× Zone 1 — matching observed cardiovascular cost curves
> better than the linear model. See Section 9.9 for full rationale.

**Algorithm:**

```
// Per second, during active HR stream:
zone = classify(current_bpm, max_hr)
time_in_zone[zone] += 1 second
daily_strain += zone.weight / 3600  // normalize to hours

// Summary:
cardiovascular_load = sum(time_in_zone[z] * zone_weight[z]) for all z
```

---

### 2.5 Calorie Estimation

**Concept**: HR-based calorie estimation using the Keytel formula. More accurate than
step-based because it accounts for cardiovascular effort.

**Formula (for males):**

```
calories_per_minute = (-55.0969 + 0.6309 * HR + 0.1988 * weight_kg + 0.2017 * age) / 4.184
```

**Formula (for females):**

```
calories_per_minute = (-20.4022 + 0.4472 * HR - 0.1263 * weight_kg + 0.074 * age) / 4.184
```

**Algorithm:**

```
// Compute every 60 seconds during active HR stream:
calories_this_minute = formula(avg_hr_last_60s, user.weight, user.age, user.sex)
daily_calories += calories_this_minute

// Apply BMR baseline for resting periods:
if not activity_active:
    bmr_per_minute = user.bmr / 1440
    daily_calories += bmr_per_minute
```

**Important**: Use for trends and relative comparisons, not absolute values. HR-based
calorie estimation has ±15–20% error vs metabolic testing.

---

## 3. Phase 3 — Advanced Metrics

### 3.1 Baseline Tracking

**Concept**: Personal baselines make all metrics meaningful. A 40 ms HRV is excellent for
one person and poor for another. Baselines must be built from at least 7 days of data.

**Algorithm:**

```
// Rolling 30-day baseline for each metric:
function updateBaseline(metric_name, new_value):
    history = load last 30 values for metric_name
    history.append(new_value)
    if history.count > 30: history.removeFirst()
    
    baseline = mean(history)
    std_dev  = standardDeviation(history)
    
    persist baseline, std_dev for metric_name

// Deviation score (how unusual is today's value?):
function deviationScore(today_value, baseline, std_dev):
    if std_dev == 0: return 0
    return (today_value - baseline) / std_dev  // Z-score

// Interpretation:
// > +1.5 std dev: significantly above baseline
// -1.5 to +1.5:  normal range
// < -1.5 std dev: significantly below baseline
```

**Metrics to baseline:**
- HRV (RMSSD)
- Resting HR
- Sleep duration
- Sleep onset time
- Cardiovascular load (strain)

---

### 3.2 Recovery Score

**Concept**: A 0–100 score representing how recovered the body is. Higher = more capacity
for training. Computed fresh each morning after sleep data is available.

**Input signals:**

```
hrv_score      = normalize(today_hrv, hrv_baseline, hrv_std_dev)      // Z-score
rhr_score      = normalize(rhr_baseline - today_rhr, 0, rhr_std_dev)  // inverted: lower RHR = better
sleep_score    = normalize(today_sleep_hours, sleep_baseline, sleep_std_dev)
strain_score   = normalize(yesterday_strain, strain_baseline, strain_std_dev)
```

**Weighted model:**

```
raw_recovery =
    (hrv_score   * 0.40) +   // HRV is the strongest recovery signal
    (rhr_score   * 0.25) +   // RHR is a solid secondary signal
    (sleep_score * 0.25) +   // sleep duration matters significantly
    (strain_score * -0.10)   // yesterday's load slightly reduces today's recovery

// Normalize to 0–100:
recovery_score = clamp((raw_recovery * 25 + 50), 0, 100)
```

**Interpretation bands:**

```
0–33:   Red   — significant fatigue, prioritize rest
34–66:  Yellow — moderate recovery, maintain or light training
67–100: Green  — well recovered, ready for peak effort
```

**Note**: Requires minimum 7 days of history before the score is meaningful. Display a
"building baseline" state until sufficient data exists.

---

### 3.3 Strain Score

**Concept**: Daily cardiovascular load accumulated across all activities and general
movement. Analogous to Whoop's Strain metric. Scale: 0–21 (Whoop's scale).

**Algorithm:**

```
// Accumulate throughout the day:
every second during HR stream:
    zone = classify(current_bpm, max_hr)
    zone_contribution = zone_weight[zone] * (1/3600)
    daily_strain += zone_contribution

// Normalize to 0–21 scale:
MAX_REALISTIC_STRAIN = sum of 60 min Zone 5 + rest of day Zone 1
strain_score = (daily_strain / MAX_REALISTIC_STRAIN) * 21
strain_score = clamp(strain_score, 0, 21)
```

**Strain bands:**

```
0–9:    Light day
10–13:  Moderate
14–17:  Strenuous
18–21:  All out
```

---

### 3.4 Stress Indicator

**Concept**: Heuristic score combining HR elevation and HRV suppression. Not a clinical
stress measure — think of it as a "sympathetic nervous system load" indicator.

**Algorithm:**

```
// Compute every 5 minutes during waking hours:
hr_elevation  = (current_hr - rhr_baseline) / rhr_baseline   // 0–1 range typical
hrv_suppression = clamp(1 - (current_hrv / hrv_baseline), 0, 1)  // inverted HRV

stress_score = (hr_elevation * 0.5) + (hrv_suppression * 0.5)
stress_score = clamp(stress_score * 100, 0, 100)

// Interpretation:
// 0–30:  Low stress / parasympathetic dominance
// 31–60: Moderate stress
// 61–100: High stress / sympathetic dominance
```

**Requires**: HRV baseline from Phase 3.1 and RHR baseline from Phase 2.1.

---

### 3.5 Sleep Stages (Low Confidence — Experimental)

**Concept**: Attempt to infer light, deep, and REM sleep from HRV patterns and motion.
Without SpO2 or skin temperature data (which Whoop does not expose in BLE), accuracy is
fundamentally limited. Present with explicit confidence warnings.

**Heuristics (rule-based approximation):**

```
// Classify each 5-minute sleep epoch:
function classifySleepEpoch(hrv, hr, motion):
    
    if motion > MOTION_THRESHOLD:
        return AWAKE
    
    if hrv > hrv_baseline * 1.3 and hr < rhr * 0.92:
        return DEEP_SLEEP     // high HRV, very low HR = likely deep/slow-wave
    
    if hrv < hrv_baseline * 0.7 and motion > 0.01:
        return REM_SLEEP      // HRV suppression + minor motion = likely REM
    
    return LIGHT_SLEEP        // default: anything in between

// Apply smoothing: a single epoch can't flip stages alone
// Require 2 consecutive epochs to confirm a stage transition
```

**What to display**: Stage durations as approximate bands, not a precise hypnogram.
Always surface a "low confidence" label in the UI. Do not claim clinical accuracy.

**Future improvement**: If Apple Watch heart rate data is available via HealthKit, fusing
it with the Whoop BLE stream could improve accuracy via cross-sensor triangulation.

---

## 4. Data Architecture

### 4.1 Core Data Models

```
HRSample:
    timestamp: unix seconds
    bpm: int
    source: enum (standardBLE, dataFromStrap)

RRSample:
    timestamp: unix seconds
    interval_ms: int  // single RR value

ActivitySession:
    id: uuid
    start_time: unix seconds
    end_time: unix seconds
    hr_samples: [HRSample]
    rr_samples: [RRSample]
    strain_score: float
    calories: float
    time_in_zones: [int: seconds]  // zone number → seconds

SleepSession:
    id: uuid
    onset_time: unix seconds
    wake_time: unix seconds
    duration_minutes: int
    interruptions: int
    hrv_rmssd: float
    hrv_sdnn: float        // added — complement to RMSSD
    epochs: [SleepEpoch]  // Phase 3 only

DailyMetrics:
    date: calendar date
    rhr: float
    hrv_morning: float
    recovery_score: float  // nil until 7 days of history
    strain_score: float
    sleep_duration_minutes: int
    calories: float
    steps: int

Baseline:
    metric_name: string
    values: [float]  // last 30 days
    mean: float
    std_dev: float
    last_updated: unix seconds
```

---

### 4.2 Processing Pipeline

```
BLE Events
    │
    ├── 0x2A37 HR notification
    │       └── HRParser → HRSample → HRBuffer (ring buffer, 3600 samples)
    │
    ├── DATA_FROM_STRAP notification
    │       ├── HRParser → HRSample → HRBuffer
    │       └── RRParser → RRSample → RRBuffer (ring buffer, 300 samples)
    │
    └── CMD_FROM_STRAP notification
            └── ResponseParser → handle alarm ack, data retrieval ack

HRBuffer (every 30s trigger)
    ├── RHR computation → DailyMetrics.rhr
    ├── HR Zone classifier → ActivitySession.time_in_zones
    ├── Calorie estimator → DailyMetrics.calories
    └── Sleep detector state machine → SleepSession

RRBuffer (every 5min trigger, low motion gate)
    ├── HRV (RMSSD) → DailyMetrics.hrv_morning
    └── Stress indicator → real-time stress score

End of Day / After Sleep
    ├── Baseline updater → Baseline records
    ├── Recovery score → DailyMetrics.recovery_score
    └── Sleep stage classifier → SleepSession.epochs
```

---

## 5. Implementation Notes for Claude Code

### Priority order (MVP build sequence)

1. BLE connection + debug logging (Section 9.1 logging is mandatory from day one)
2. HR from standard BLE service (`0x2A37`) only — no custom protocol yet
3. Activity start/stop command — CRC verified, safe to implement
4. DATA_FROM_STRAP stream — enables RR and timestamped HR
5. RR parsing with two-stage filter (Section 9.5)
6. HRV (RMSSD + SDNN) with computation gate (Section 9.6)
7. Basic sleep detection with soft time prior (Section 9.7)
8. Historical sync with integrity guards (Section 9.10)
9. Advanced metrics: recovery score, strain, stress indicator

**Read Section 9 before implementing any module.** The safeguards there define the
defensive rules every module must follow — feature gating, validation, fallbacks, and
retry logic. They are not optional polish; they are part of the core architecture.

### Key constraints

- **Packet counter**: Keep a persistent counter (survives app restart via UserDefaults).
  Not validated by device but good practice.
- **Write timing**: Do not write commands faster than one per 200ms. The device queues
  them but rapid writes can cause connection instability.
- **Background BLE**: CoreBluetooth requires the `bluetooth-central` background mode to
  maintain connection when the app is backgrounded. HR stream will drop otherwise.
- **RR sanity filter**: Always apply the 200–3000 ms filter to RR values. The device
  occasionally emits `0x0000` as a placeholder when no beat was detected.
- **Motion data**: The BLE logs do not show a dedicated accelerometer stream. If motion
  data is needed for sleep detection and step counting, consider using CoreMotion
  (CMMotionManager) on the iPhone itself as a proxy, rather than waiting for device-side
  accelerometer data.

### Testing strategy

- Build a packet inspector first: log every raw byte received on all characteristics.
- Verify CRC on known packets before sending any write commands.
- Test activity start → observe DATA_FROM_STRAP notifications → stop.
- Validate RR decode against simultaneous HR BPM: if RR avg ≈ 60000/BPM, the decode is correct.
  Example: 70 BPM → expected avg RR ≈ 857 ms.

---

---

## 9. Safeguards & Graceful Degradation

This section defines the defensive rules that apply across all implementation phases.
The core principle: **the app must degrade gracefully rather than break**. If any data
source disappears, affected features disable themselves and clearly communicate why —
the app never crashes or shows corrupt data silently.

---

### 9.1 CRC Strategy — Retry with Alternate Variant

The device uses three confirmed XOR variants depending on packet header. If a future
packet type uses a fourth unknown variant, the device will silently ignore the command.
The write layer must handle this defensively.

```
function sendCommand(packet):
    primary_xor = lookupXOR(packet.header)
    crc = computeCRC(packet.message, primary_xor)
    packet.append(crc)
    
    write(packet)
    wait(responseTimeout: 500ms)
    
    if no_response:
        log("Primary XOR failed, trying alternates")
        for alternate_xor in [0xF43F44AC, 0x6971BE68, 0xE02CCD0E]:
            if alternate_xor == primary_xor: continue
            retry_packet = packet.message + computeCRC(packet.message, alternate_xor)
            write(retry_packet)
            wait(200ms)
            if response_received:
                log("Alternate XOR 0x{alternate_xor} worked — update lookup table")
                break
    
    if still_no_response after 3 attempts:
        trigger BLE reconnect
```

**Always log per attempt**: raw packet bytes, XOR value used, success/failure. Without
this the CRC variant bugs are nearly impossible to debug remotely.

---

### 9.2 Command Rate Limiting

```
MIN_COMMAND_INTERVAL = 200ms   // never write faster than this
MAX_RETRIES = 3                // per command before giving up
RECONNECT_THRESHOLD = 3        // failed commands in a row triggers reconnect

command_queue: FIFO queue of pending packets
last_write_time: timestamp

function processQueue():
    if now() - last_write_time < MIN_COMMAND_INTERVAL:
        wait remainder
    
    packet = command_queue.dequeue()
    sendCommand(packet)           // uses retry logic from 9.1
    last_write_time = now()
```

---

### 9.3 DATA Stream Fallback

If `DATA_FROM_STRAP` notifications stop arriving after activity start, the app must
fall back gracefully rather than showing stale or missing data.

```
DATA_STREAM_TIMEOUT = 5 seconds

on activity start:
    start DATA_STREAM watchdog timer
    set data_stream_active = false

on DATA_FROM_STRAP notification received:
    reset watchdog timer
    set data_stream_active = true

on watchdog timeout:
    log("DATA_FROM_STRAP timeout — falling back to 0x2A37 only")
    data_stream_active = false
    disable RR-dependent features:
        - HRV calculation
        - Stress indicator
        - Sleep stage classification
    continue showing HR from standard BLE service
    surface UI indicator: "Limited data — HRV unavailable"
```

---

### 9.4 BLE Reconnection During Active Session

If the connection drops mid-session, the gap must be recorded and the session marked
partial — not corrupted, not silently filled in.

```
on BLE disconnect during active session:
    record gap_start = now()
    pause all data collection
    attempt reconnect (exponential backoff: 1s, 2s, 4s, 8s... max 60s)

on reconnect:
    gap_end = now()
    gap_duration = gap_end - gap_start
    
    if gap_duration < 30 seconds:
        // Short gap — interpolate HR linearly, mark as estimated
        fill_hr_gap(gap_start, gap_end, method='linear_interpolation')
        mark_samples_as_estimated(gap_start, gap_end)
    else:
        // Long gap — do not fabricate data
        mark_session_as_partial(gap_start, gap_end)
        // Attempt to recover missing data via sync after reconnect
        trigger_sync_for_range(gap_start, gap_end)
    
    resume data collection
    re-send activity start command (category 0x03, value 0x01) to confirm state
```

---

### 9.5 RR Interval Filtering — Two-Stage

Stage 1 (range filter — already in decoder):
```
if rr_ms < 300 or rr_ms > 2000: discard
```

Stage 2 (deviation filter — catches artifacts that pass range):
```
if rr_buffer.count >= 5:
    rolling_mean = mean(rr_buffer.last(10))
    deviation = abs(rr_ms - rolling_mean) / rolling_mean
    if deviation > 0.20:   // more than 20% from recent mean
        discard            // likely double-beat or missed-beat artifact
```

Startup noise:
```
discard first 3 RR samples after any activity start or reconnect
```

---

### 9.6 HRV Computation Gate

```
// All conditions must be true to compute HRV:
can_compute_hrv =
    rr_buffer.count >= 10           AND   // minimum sample count
    motion_level < MOTION_THRESHOLD AND   // no movement artifact
    data_stream_active              AND   // DATA stream is live
    not in first 30s of session           // past startup noise window

if not can_compute_hrv:
    skip computation
    do not emit nil/zero — simply emit nothing this cycle

// Apply smoothing to avoid single-sample spikes in the UI:
hrv_display = movingAverage(last_3_hrv_values)
```

---

### 9.7 Sleep Detection — Soft Time Prior

The 21:00–11:00 window is a **soft prior** (increases detection sensitivity), not a hard
gate. Users with atypical schedules (night shifts, new parents) should not be blocked.

```
CORE_SLEEP_WINDOW_START = 21:00
CORE_SLEEP_WINDOW_END   = 11:00

function sleepCandidateProbability(time_of_day, hr_condition, motion_condition):
    base_probability = if (hr_condition AND motion_condition) then 1.0 else 0.0
    
    // Inside the soft window: no change needed
    // Outside the soft window: require longer sustained conditions
    if not in_sleep_window(time_of_day):
        CANDIDATE_DURATION = 1200 seconds   // 20 min required outside window
    else:
        CANDIDATE_DURATION = 600 seconds    // 10 min inside window
    
    return base_probability
```

---

### 9.8 Recovery Score — Z-Score Clamp

Without clamping, a single outlier day (illness, extreme workout) can produce a baseline
that makes every subsequent score look wrong for weeks.

```
function computeZScore(value, baseline_mean, baseline_std):
    if baseline_std == 0: return 0
    z = (value - baseline_mean) / baseline_std
    return clamp(z, -3.0, +3.0)   // hard clamp at ±3 sigma
```

Gate: do not show recovery score until 7 confirmed days of data exist:
```
if daily_metrics.count(where: hrv_morning != nil) < 7:
    recovery_score = nil
    ui: show "Building your baseline — {7 - count} days remaining"
```

---

### 9.9 Strain Model — Exponential Zone Weighting

The original linear zone weights understate the cardiovascular cost of high-intensity
zones. Replace with exponential weighting:

```
// Original (linear):
zone_weights = [0.5, 1.0, 2.0, 3.5, 5.0]

// Improved (exponential — more physiologically accurate):
zone_weights = [exp(0) * 0.5,    // Zone 1: 0.50
                exp(0.7) * 0.5,  // Zone 2: 1.01
                exp(1.4) * 0.5,  // Zone 3: 2.03
                exp(2.1) * 0.5,  // Zone 4: 4.08
                exp(2.8) * 0.5]  // Zone 5: 8.20

// Net effect: Zone 5 effort is weighted 16x Zone 1 (not 10x).
// Matches observed cardiovascular cost curves better.
```

---

### 9.10 Historical Sync — Integrity Guards

Duplicate prevention:
```
before inserting any synced session:
    check if session with overlapping time range already exists
    if exists AND source='live': skip (live data takes precedence)
    if exists AND source='synced': skip (already synced)
    otherwise: insert with source='synced'
```

Gap marking:
```
after sync completes:
    scan timeline for gaps > 2 hours with no data
    mark these as 'no_data' periods (not estimated, not synced)
    display as empty in the calendar view, not as zero
```

Partial data flag:
```
if batch handshake times out mid-sync:
    mark affected date range as 'partial_sync'
    do not recompute daily_metrics for partial dates
    retry on next sync
```

---

### 9.11 Feature Gating — Dynamic Capability Map

Maintain a live capability map that other modules read before attempting computation:

```
CapabilityMap:
    hr_available:          bool   // standard BLE HR stream active
    data_stream_available: bool   // DATA_FROM_STRAP stream active
    rr_available:          bool   // at least 10 valid RR in buffer
    motion_available:      bool   // CoreMotion accessible
    baseline_ready:        bool   // 7+ days of history
    session_active:        bool   // activity recording in progress

// Each feature checks before running:
HRVProcessor:
    requires: rr_available AND data_stream_available AND NOT session_active
    
SleepDetector:
    requires: hr_available
    degrades: motion_available = false → uses HR stability as motion proxy

RecoveryEngine:
    requires: baseline_ready
    
StressIndicator:
    requires: rr_available AND baseline_ready
    
SleepStageClassifier:
    requires: rr_available   // experimental, still gated
    confidence: always LOW
```

---

### 9.12 Data Validation Before Insert

Every row must pass validation before hitting the database:

```
function validateHRSample(sample):
    assert sample.timestamp > 0
    assert sample.timestamp < now() + 60   // not in the future
    assert 30 <= sample.bpm <= 220
    assert sample.source in ['ble_standard', 'data_from_strap', 'synced']

function validateRRSample(sample):
    assert 300 <= sample.interval_ms <= 2000
    assert sample.timestamp > 0

function validateSession(session):
    assert session.end_time > session.start_time
    assert (session.end_time - session.start_time) < 86400  // max 24h session
    assert session.type in ['activity', 'sleep', 'resting']
```

Reject and log any sample that fails. Never silently discard without logging.

---

## 10. Architecture Rules

These rules define how the system is structured at the code level. They are not optional
refinements — violating them creates technical debt that compounds quickly once real data
starts flowing and algorithms need to evolve.

---

### 10.1 Single Source of Truth (Cardinal Rule)

**All derived metrics MUST be computed from persisted raw data, never from live streams
directly.**

```
// FORBIDDEN:
on HR notification received:
    hrv = computeHRV(liveRRBuffer)
    display(hrv)                    // only exists in memory, never recoverable

// REQUIRED:
on RR notification received:
    persist RRSample to DB          // write first
    rr_buffer.append(sample)        // buffer mirrors DB
    hrv = computeHRV(rr_buffer)    // computed from buffer backed by DB
    display(hrv)
```

**Forbidden patterns:**
- Computing HRV only in memory without persisting the RR inputs first
- Computing strain during a live session without persisting HR inputs
- Any metric that cannot be reconstructed from raw data in the DB

**Why this matters:**
- Enables reprocessing with improved algorithms without losing history
- Makes debugging historical bugs possible — load raw data, replay it
- Guarantees consistency between live data and synced historical data
- Prevents the class of bug where live and historical metrics disagree for the same session

---

### 10.2 Deterministic Reprocessing

Any day's metrics must be fully recomputable from raw DB data alone.

```
function recomputeDay(date):
    // 1. Delete old derived metrics for this date
    DELETE FROM daily_metrics WHERE date = date

    // 2. Load all raw inputs
    sessions   = SELECT * FROM sessions   WHERE date(start_time, 'unixepoch') = date
    hr_samples = SELECT * FROM hr_samples WHERE date(timestamp,  'unixepoch') = date
    rr_samples = SELECT * FROM rr_samples WHERE date(timestamp,  'unixepoch') = date

    // 3. Recompute all metrics using current algorithm versions
    rhr      = computeRHR(hr_samples)
    hrv      = computeHRV(rr_samples)
    sleep    = detectSleep(hr_samples, sessions)
    strain   = computeStrain(hr_samples)
    calories = computeCalories(hr_samples, user_profile)

    // 4. Write with current algorithm version stamps
    INSERT INTO daily_metrics
        (date, rhr, hrv_morning, strain, calories,
         hrv_version, strain_version, sleep_version)
    VALUES
        (date, rhr, hrv, strain, calories,
         CURRENT_HRV_VERSION, CURRENT_STRAIN_VERSION, CURRENT_SLEEP_VERSION)

// Recompute triggers:
//   - After sync inserts historical data for a date
//   - On app launch when stored_version < current_version (see 10.3)
//   - Manual action via debug console
```

---

### 10.3 Algorithm Versioning

Every derived metric stores the algorithm version that produced it. Without this, a trend
in your data might be a real physiological change or an artifact of an algorithm update
made two weeks ago — you cannot tell which.

**Schema additions:**

```
TABLE algorithm_versions
    name        TEXT PRIMARY KEY   -- 'hrv' | 'sleep' | 'strain' | 'recovery' | 'rhr'
    version     INTEGER NOT NULL
    updated_at  INTEGER NOT NULL   -- unix seconds

-- Add version columns to daily_metrics:
daily_metrics.hrv_version      INTEGER DEFAULT 1
daily_metrics.strain_version   INTEGER DEFAULT 1
daily_metrics.sleep_version    INTEGER DEFAULT 1
daily_metrics.recovery_version INTEGER DEFAULT 1
```

**Auto-recompute on launch when version is stale:**

```
CURRENT_VERSIONS = {
    'hrv':      2,   // bumped when SDNN was added and window sizes changed
    'strain':   2,   // bumped when exponential weights replaced linear
    'sleep':    1,
    'recovery': 1,
}

on app launch:
    for (name, current_version) in CURRENT_VERSIONS:
        stored = SELECT version FROM algorithm_versions WHERE name = name

        if stored < current_version:
            affected_dates = SELECT DISTINCT date FROM daily_metrics
                             WHERE {name}_version < current_version

            for date in affected_dates:
                recompute_queue.enqueue(date)   // background, low priority

            UPDATE algorithm_versions
            SET version = current_version, updated_at = now()
            WHERE name = name
```

---

### 10.4 Strict Module Boundaries

Data flows in one direction only. No layer may reach into a layer above it or skip a layer.

```
┌─────────────────────────────────────────────┐
│  UI Layer                                   │
│  • Reads metrics only                       │
│  • Never computes anything                  │
│  • Never reads raw bytes                    │
└──────────────────┬──────────────────────────┘
                   │ metrics only
┌──────────────────▼──────────────────────────┐
│  Compute Layer                              │
│  • Input:  DB queries or in-memory buffers  │
│  • Output: derived metrics                  │
│  • Never touches BLE directly               │
└──────────────────┬──────────────────────────┘
                   │ typed models
┌──────────────────▼──────────────────────────┐
│  Storage Layer                              │
│  • Input:  typed models                     │
│  • Output: persisted rows + query results   │
│  • Never parses raw bytes                   │
└──────────────────┬──────────────────────────┘
                   │ typed models
┌──────────────────▼──────────────────────────┐
│  Parser Layer                               │
│  • Input:  raw bytes                        │
│  • Output: typed models (pure functions)    │
│  • No side effects                          │
└──────────────────┬──────────────────────────┘
                   │ raw bytes only
┌──────────────────▼──────────────────────────┐
│  BLE Layer                                  │
│  • connect / disconnect / reconnect         │
│  • read/write raw bytes only                │
│  • Never parses HR values                   │
│  • Never computes metrics                   │
└─────────────────────────────────────────────┘
```

The boundary test: if you find yourself calling a compute function from the BLE layer,
or reading a raw byte offset from the UI layer, a boundary has been crossed.

Simulation Mode (Section 10.9) is a drop-in replacement for the BLE layer only. The
Parser layer and above are completely unaware of whether data comes from a real device
or a log file — this is what makes simulation possible.

---

### 10.5 Module Decoupling

Modules must not hold direct references to each other. Use an event/observer pattern
appropriate to Swift (Combine publishers, NotificationCenter, or typed delegates).
The specific Swift pattern is left to implementation — what matters is the contract:

```
// Events emitted after persistence (any module may subscribe):
HR_SAMPLE_PERSISTED    (payload: HRSample)
RR_SAMPLE_PERSISTED    (payload: RRSample)
SESSION_STARTED        (payload: Session)
SESSION_ENDED          (payload: Session)
SYNC_COMPLETED         (payload: SyncResult)
CAPABILITY_CHANGED     (payload: CapabilityMap)
RECOMPUTE_REQUESTED    (payload: Date)

// Example subscriber wiring:
on HR_SAMPLE_PERSISTED:
    → HRBuffer.append()
    → ZoneClassifier.classify()
    → CalorieEstimator.update()
    → SleepDetector.observe()

on RR_SAMPLE_PERSISTED:
    → RRBuffer.append()
    → HRVProcessor.maybeCompute()
    → StressIndicator.update()

on SYNC_COMPLETED:
    → ReprocessingQueue.enqueueAffectedDates()
    → CapabilityMap.refresh()
```

Note: events are emitted **after** persistence (Section 10.1), never before.

---

### 10.6 Time Normalization Contract

All timestamps everywhere in the system are **Unix seconds UTC**. No exceptions.

```
// FORBIDDEN:
timestamp = Date()                                   // local timezone object
timestamp = Date().timeIntervalSince1970 * 1000      // milliseconds

// REQUIRED:
timestamp = Int(Date().timeIntervalSince1970)         // unix seconds UTC

// BLE timestamps:
//   Device emits unix seconds LE uint32 — use directly, no conversion needed.
//   Verified by testing: decoded timestamp matched 2024-06-09 10:53:33 UTC. ✓

// UI display only — convert to local timezone at the view layer only, never in
// storage or compute layers.
```

---

### 10.7 Unit Consistency Contract

Every numeric biometric has exactly one unit. Document it in every function signature
that accepts a numeric biometric parameter.

```
HR:        bpm         (Int)    — beats per minute
RR:        ms          (Int)    — milliseconds, uint16 LE from device
HRV:       ms          (Float)  — RMSSD and SDNN both in milliseconds
Timestamps: seconds    (Int)    — unix UTC; all durations also in seconds
Calories:  kcal        (Float)
Strain:    unitless    (Float)  — 0.0–21.0
Recovery:  unitless    (Float)  — 0.0–100.0
Stress:    unitless    (Float)  — 0.0–100.0
Motion:    g-force     (Float)  — from CoreMotion, normalized
```

---

### 10.8 No Silent Failure

Every dropped data point must be logged with a reason string. Aggregate counts are not
sufficient — individual drop reasons are what allow post-hoc debugging.

```
// Required log format for every discard or skip:
"[RR] discarded interval=2500ms reason=out_of_range(max=2000ms)"
"[RR] discarded interval=1850ms reason=deviation_filter(32%_from_mean=1400ms)"
"[HRV] skipped reason=insufficient_samples(count=7,min=10)"
"[HRV] skipped reason=motion_detected(level=0.42g,threshold=0.15g)"
"[Session] marked_partial gap_start=1717930413 gap_end=1717930535 duration=122s"
"[CRC] retry packet_type=short_cmd xor=0x6971BE68 attempt=2"
```

These log lines feed directly into the BLE Events debug console (Section 7.5).

---

### 10.9 Simulation Mode

Simulation mode replays recorded BLE log files through the full pipeline — enabling
features to be tested and bugs to be reproduced without the physical device.

```
SimulationMode:
    source:          exported .txt log file from debug console
    playback_speed:  1x | 10x | 60x | max

    replays:
        - raw BLE notifications on all characteristics
        - at correct relative timestamps
        - through the real Parser → Storage → Compute pipeline

    enables:
        - testing HRV without wearing the device
        - replaying 8 hours of sleep in minutes at 60x speed
        - reproducing a bug deterministically from the exact log that caused it
        - regression testing after algorithm changes (bump version, rerun log)
```

Implementation: SimulationMode is a drop-in replacement for the BLE layer only (enforced
by the boundary rule in Section 10.4). The Parser layer and above receive identical typed
bytes regardless of source.

---

### 10.10 Feature Flags

Two categories — capability flags (runtime, Section 9.11) and algorithm flags (explicit,
control which variant runs). Algorithm flags are persisted alongside algorithm versions
so reprocessing uses the same flags that were active when data was first computed.

```
AlgorithmFlags:
    use_exponential_strain  = true    // false = legacy linear weights
    enable_sleep_stages     = false   // experimental, off by default
    use_sdnn_in_recovery    = true    // include SDNN alongside RMSSD
    rr_filter_version       = 2       // 1 = range only | 2 = range + deviation
    hrv_window_stable_size  = 300     // RR count for stable morning HRV
    hrv_window_live_size    = 60      // RR count for live stress updates
```

Changing any flag must increment the version of the affected metric in `algorithm_versions`.

---

### 10.11 Cold Start Behavior

On every launch, buffers are pre-populated from the DB so the app is immediately
functional rather than blank until the device reconnects and 5 minutes of data accumulate.

```
on app launch (before connecting BLE):

    // 1. Restore HR buffer from last 5 minutes
    SELECT * FROM hr_samples
    WHERE timestamp > (now() - 300)
    ORDER BY timestamp ASC
    → hr_buffer.load()

    // 2. Restore RR buffer (last 300 values)
    SELECT * FROM rr_samples
    ORDER BY timestamp DESC LIMIT 300
    → rr_buffer.load(reversed)

    // 3. Restore interrupted session if one exists
    SELECT * FROM sessions WHERE end_time IS NULL LIMIT 1
    if found:
        session_manager.resume(session)
        log("Resumed interrupted session from \(session.start_time)")

    // 4. Rebuild capability map from buffer state
    capability_map.refresh()

    // 5. Process any pending algorithm recomputes
    recompute_queue.processPending()

    // 6. Connect BLE
    ble_manager.connect()
```

---

### 10.12 Backpressure Handling

On iPhone, BLE processing lag is unlikely during normal operation. During large syncs it
can occur. If it does, prioritize writes over computation:

```
if processing_lag > 2_seconds:
    suspend:  StressIndicator, LiveHRVProcessor
    continue: StorageLayer, SessionIntegrity, HRBuffer
    resume suspended modules when lag drops below 500ms
```

---

## 6. Further Investigation — Hidden & Undecoded Data

The reverse engineering repo leaves several high-value data sources undecoded or unexplored.
This section documents what they are, why they are likely valuable, and how to approach
decoding them. These are research tasks, not implementation tasks — each one requires
capturing raw BLE logs and analyzing them before any algorithm can be written.

---

### 6.1 The 65 Unknown Bytes in DATA_FROM_STRAP — Likely Raw PPG

**What the repo says**: Every activity packet and every sync packet ends with 65 bytes
that the author labeled "I have no idea what it is" and did not pursue.

**Why it matters**: The byte patterns visible in the repo logs look like repeating IEEE 754
32-bit floats — values like `f880c914`, `3cae47af`, `5ccf5b3e` are consistent with
normalized floating-point sensor readings. This structure strongly suggests raw PPG
(photoplethysmography) output — the optical signal the device uses to detect heartbeats.

If confirmed, these bytes could give you:
- **Respiratory rate** — PPG waveforms are amplitude-modulated by breathing. Extract the
  modulation frequency (typically 0.15–0.4 Hz) and you have breaths per minute, more
  reliably than the RR-interval method.
- **Better RR intervals** — compute your own beat detection from the raw waveform rather
  than trusting the device's pre-processed values, which can miss beats or add artifacts.
- **SpO2 estimates** — if both red and infrared LED channels are present in those 65 bytes
  (two interleaved float arrays), the ratio of their AC/DC components gives blood oxygen
  saturation. This would be a major unlock given Whoop's SpO2 is not exposed via BLE.

**How to decode:**

```
Step 1 — Isolate the bytes:
    Capture 60+ consecutive DATA_FROM_STRAP packets during a quiet rest period.
    Extract bytes 31–95 from each packet into a separate array.
    Plot each byte position across time as a time series.

Step 2 — Find the waveform:
    Look for byte positions that oscillate rhythmically at ~1 Hz (heart rate frequency).
    If found, those positions contain the PPG signal.
    Try interpreting as: uint8, int8, uint16 LE, int16 LE, float32 LE.
    The one that produces a clean sinusoidal-ish waveform at ~HR frequency is correct.

Step 3 — Identify channels:
    A green LED channel will pulse strongly at HR frequency.
    A red + infrared pair will have correlated waveforms with a DC offset difference.
    If you see two interleaved signals with the same frequency but different amplitude
    profiles, you likely have a dual-channel PPG (red + IR = SpO2 capable).

Step 4 — Confirm with known HR:
    If decoded_signal_frequency ≈ current_bpm / 60, the decode is correct.
    Cross-check by computing your own peak detection and comparing to byte 12 (device BPM).

Step 5 — Extract respiratory rate:
    Apply a bandpass filter to the PPG amplitude envelope: 0.15–0.4 Hz passband.
    The dominant frequency in this band is respiratory rate.
    Expected output: 12–20 breaths/min at rest.
```

---

### 6.2 The `enable_r19_packets` Command — May Unlock Additional Fields

**What the repo says**: During sync, the app sends a string command containing
`enable_r19_packets` alongside other strings like `sigproc_10_sec_dp` and `sigproc_pdaf`.
These are sent via category `0x78` and the author did not investigate what they change.

**Why it matters**: The name `enable_r19_packets` strongly implies it switches the device
into a richer packet format (revision 19 of an internal packet spec). If enabled, the
DATA_FROM_STRAP packets may contain additional fields — possibly the raw PPG data discussed
above in a more structured form, or additional sensor channels.

`sigproc_pdaf` is also notable — PDAF (Phase Detection) is a signal processing technique
used in optical sensors to improve accuracy. Enabling it may improve the quality of the
raw sensor data.

**How to investigate:**

```
Step 1 — Send the enable command:
    Build the packet structure observed in the repo:
    Header: aa 48 00 f3 23
    Byte 5-6: u16 counter (observed values: 47992, 18808 etc — try 0x0001)
    Byte 7: 78
    Byte 8: 01
    Bytes 9–40: ASCII string "enable_r19_packets" padded with 0x00 to 32 bytes
    Byte 41–42: 32 00 (observed constant)
    Final 4 bytes: CRC-32 of all preceding bytes

Step 2 — Observe changes:
    Before sending: log the exact byte length and structure of DATA_FROM_STRAP packets.
    After sending: check if packet length changes, or if new byte positions become active.
    Also send "sigproc_pdaf" and "sigproc_10_sec_dp" in sequence as the app does.

Step 3 — Compare packet structure:
    If packet length increases, the new bytes are the unlocked fields.
    If length stays the same but previously-zero bytes now carry data, decode those.
    Run the same waveform analysis from Section 6.1 on any newly active bytes.
```

---

### 6.3 EVENTS_FROM_STRAP — Possible Device-Side Step Count or Cumulative Strain

**What the repo says**: The author noted that packets on EVENTS_FROM_STRAP contain unix
timestamps that don't correspond to activity starts or ends, and left the content
unexplained. Two packet formats were observed — a 36-byte format and a 12-byte format.

**Why it matters**: Looking at the 36-byte format more carefully:

```
Observed packet:
aa2400fa30  b0  03 00  2e316966  901f  140002  e900 0000  e90e 0000  01 01 0f 03 01 00 2f 01 000000  699d4a60

Positions of interest:
Bytes 10-11: 901f → little-endian uint16 = 8080
Bytes 12-13: 1400 → 20
Bytes 16-17: e900 0000 → uint32 = 233
Bytes 20-21: e90e 0000 → uint32 = 3817
Byte 22:     01
Byte 23:     01
Byte 24:     0f → 15
```

The slowly-incrementing values at bytes 16–17 and 20–21, combined with the regular 5-minute
interval between packets, are consistent with cumulative step counts or cumulative strain
ticks maintained by the device firmware. If confirmed, this gives you:

- **Device-native step count** without CoreMotion
- **Continuous motion tracking** even when the app is not actively recording

**How to decode:**

```
Step 1 — Capture a full day:
    Log all EVENTS_FROM_STRAP packets for 8+ hours including a known walk.
    Record the exact time and duration of the walk (e.g. 10-minute, 1000-step walk).

Step 2 — Isolate candidates:
    For each uint16 and uint32 field in the packet, plot its value over time.
    Look for a field that:
        - Increases monotonically during the walk period
        - Increases roughly proportionally to duration/intensity
        - Resets at midnight or on device restart

Step 3 — Calibrate:
    If a field increases by X during a known-step walk, derive the steps-per-unit ratio.
    Repeat with different activity intensities to distinguish steps from strain.

Step 4 — Cross-check the 12-byte format:
    aa10005730  5b  21 00  3f326966  6854 0000  b0b2435b
    Bytes 6-7: 21 00 → category 0x21 — unknown
    Bytes 10-11: 6854 → uint16 = 21592
    These may be a lighter summary event — possibly epoch-level aggregates.
```

---

### 6.4 Historical Data Sync — Full Offline Reconstruction

**What the repo says**: Sending category `0x16` (value `0x00`) triggers the device to
stream stored historical data on DATA_FROM_STRAP in large batches. The sync process uses
a batch handshake — the app receives a batch ID and sends it back in a specific format to
request the next batch.

**Why it matters**: This means the device stores its own history internally. You can
reconstruct complete sessions from periods when the phone was not connected — overnight
sleep, workouts without the phone, travel. This makes your app resilient to gaps in
real-time connectivity.

**Sync handshake algorithm:**

```
Step 1 — Trigger sync:
    Send command: category 0x16, value 0x00

Step 2 — Receive batch header:
    The device sends a packet on DATA_FROM_STRAP with format:
    aa 1c 00 ab 31  [counter]  02  [unix ts]  [don't care 6 bytes]  [batch_id 4 bytes LE]  [04 00 00 00 00 00 00]  [checksum]

    Extract batch_id from bytes 18–21 (uint32 little-endian).

Step 3 — Request batch:
    Build packet:
    Header:   aa 10 00 57 23
    Counter:  current_counter
    Category: 17 01   (0x17 = sync request category)
    Batch ID: batch_id as 4 bytes little-endian
    Padding:  00 00 00 00
    Checksum: CRC32 of above

    Write to CMD_TO_STRAP.

Step 4 — Receive batch data:
    Device streams N packets on DATA_FROM_STRAP (96 bytes each).
    Parse each using the same decoder as live activity packets (Section 1.1).
    The unix timestamp in each packet is the original recording time.

Step 5 — Continue:
    After the batch completes, the device sends another batch header with the next batch_id.
    Repeat steps 2–4 until no more batch headers arrive (sync complete).

Step 6 — Persist:
    Store all received HRSamples and RRSamples with their original timestamps.
    Reconstruct ActivitySessions and SleepSessions from the historical data using
    the same algorithms as real-time processing.
```

---

### 6.5 Investigation Priority Order

```
Priority 1: enable_r19_packets command (Section 6.2)
    Why first: single command, immediate observable result, potentially unlocks everything else.
    Time estimate: 1–2 hours of experimentation.

Priority 2: Historical data sync (Section 6.4)
    Why second: handshake is partially documented, high practical value, not speculative.
    Time estimate: 2–4 hours to implement and validate.

Priority 3: 65-byte PPG decode (Section 6.1)
    Why third: highest potential value but requires signal analysis effort.
    Time estimate: 4–8 hours of data capture and analysis.
    Tool recommendation: export raw bytes to CSV and use Python + matplotlib to plot,
    before writing any Swift — visual inspection is faster than code iteration.

Priority 4: EVENTS_FROM_STRAP step/strain decode (Section 6.3)
    Why fourth: useful but replaceable by CoreMotion if decoding fails.
    Time estimate: 2–3 hours with a calibration walk.
```

---

---

## 7. History Tab — UI Feature Spec

### 7.1 Purpose

The History tab is a main navigation destination in the app. It shows the user all their
past sessions — activities, sleep, and recovered historical data pulled from the device —
in a unified chronological view. It also surfaces trends over time so the user can see
how their metrics evolve week over week.

There are two layers to this tab:
- **User-facing**: clean timeline and trend charts
- **Developer-facing**: a debug console showing raw BLE events and sync activity in real time

---

### 7.2 History Tab — Main UI

**Top level: Calendar / date selector**

```
Layout:
    Horizontal scrollable week strip at the top (Mon–Sun)
    Each day shows a colored dot indicating data availability:
        Green dot  = full data (live recorded)
        Amber dot  = partial data (some gaps, filled by sync)
        Gray dot   = no data
        Blue dot   = today

    Tapping a day loads that day's sessions below.
    Default view: today, or most recent day with data.
```

**Session list (per selected day)**

```
Each session is a card showing:
    Session type icon: Activity | Sleep | Resting
    Time range: "10:30 PM → 6:45 AM"
    Key metrics for that session type:

    Activity card:
        Duration | Avg HR | Peak HR | Strain score | Calories

    Sleep card:
        Duration | HRV (morning) | RHR | Recovery score | Interruptions

    Resting / daily summary card:
        Steps | Avg HR | Time in each HR zone (mini bar)

    Data source badge (subtle, small text):
        "Live"        — recorded in real time
        "Synced"      — recovered from device history
        "Estimated"   — gaps filled by interpolation
```

**Session detail view (tap a card)**

```
Full screen sheet:
    HR timeline chart — BPM over session duration
    HR zone breakdown — horizontal stacked bar (time in each zone)
    RR / HRV chart — if RR data available, plot RMSSD in 5-min windows
    Sleep stages — if sleep session, show light/deep/REM bands (with low-confidence label)
    Raw metrics table — all computed values with units
```

---

### 7.3 Trends Section (bottom of History tab or sub-tab)

**Time range selector**: 7 days | 30 days | 90 days

**Trend charts (one per metric, vertically stacked):**

```
Each chart:
    X axis: dates
    Y axis: metric value
    Line: daily value
    Shaded band: ±1 std dev of personal baseline (once 7 days exist)
    Dot highlight: today's value
    Tap a dot: show exact value and date

Metrics shown:
    1. HRV (RMSSD) — morning values only
    2. Resting Heart Rate
    3. Recovery Score (0–100, color-coded green/amber/red)
    4. Sleep Duration (hours)
    5. Daily Strain Score (0–21)
    6. Calories

Baseline band behavior:
    First 7 days: show line only, no band, show "Building baseline" label
    After 7 days: show rolling 30-day mean ± std dev as a shaded band
    Color: green band = metric is in normal range, amber/red = deviation
```

---

### 7.4 Sync Control

**Sync button** (top right of History tab):

```
States:
    Idle:      "Sync" button visible
    Syncing:   spinner + "Syncing… batch 3 of 12"
    Complete:  "Last synced: 2 min ago"
    Error:     "Sync failed — tap to retry"

On tap:
    1. Check BLE connection — if not connected, show "Connect device first"
    2. Send category 0x16 command to trigger device data retrieval
    3. Begin batch handshake loop (Section 6.4)
    4. As each batch arrives, insert sessions into local DB
    5. Refresh the calendar dots and session list in real time
    6. On completion, update "Last synced" timestamp
```

**Auto-sync behavior:**

```
Trigger auto-sync on:
    - App foreground after >30 min in background
    - BLE reconnect after disconnection
    - Manual pull-to-refresh on History tab

Do NOT auto-sync if:
    - Last sync was less than 5 minutes ago
    - A sync is already in progress
    - Device battery is below 10% (if readable)
```

---

### 7.5 Debug Console (Developer Layer)

The debug console is accessible via a long-press on the sync button, or via a hidden
gesture (e.g. triple-tap the tab bar icon). It does not appear in production builds by
default — use a build flag (`DEBUG_BLE_CONSOLE = true`) to enable it.

**Console layout:**

```
Full-screen sheet with two tabs:
    [BLE Events]    [Sync Log]
```

**BLE Events tab:**

```
Scrolling log of all raw BLE activity, newest at top.
Each entry shows:
    Timestamp (HH:mm:ss.SSS)
    Direction: → (write) or ← (notify)
    Characteristic: CMD_TO_STRAP | CMD_FROM_STRAP | DATA_FROM_STRAP | EVENTS_FROM_STRAP | HR
    Raw hex bytes (full packet)
    Parsed interpretation (if decoder exists for that packet type)

Example entries:
    10:32:14.221  →  CMD_TO_STRAP      aa0800a823 01 03 01 [crc]
                     [Parsed: Start activity]

    10:32:14.450  ←  DATA_FROM_STRAP   aa1800ff28 02 ad896566 f065 42 01 b902... [crc]
                     [Parsed: HR=66 BPM, unix=1737284013, RR=[441ms]]

    10:32:15.451  ←  DATA_FROM_STRAP   aa1800ff28 02 ae896566 f860 43 00 ... [crc]
                     [Parsed: HR=67 BPM, unix=1737284014, RR=none]

    10:32:20.100  ←  EVENTS_FROM_STRAP aa2400fa30 b0 03 00 2e316966 ...
                     [Parsed: UNKNOWN — raw bytes logged]

Filter bar at top:
    [All] [CMD_TO] [CMD_FROM] [DATA] [EVENTS] [HR]
    Search box — filter by hex string or keyword

Copy button: copies entire visible log to clipboard as plain text.
Export button: saves log as .txt file to Files app.
```

**Sync Log tab:**

```
Shows the state machine of the current or most recent sync:

    [12:01:03]  Sync triggered (manual)
    [12:01:03]  → Sent 0x16 command to CMD_TO_STRAP
    [12:01:04]  ← Received batch header: batch_id=0x00012e47, unix=1737284013
    [12:01:04]  → Sent batch request for batch_id=0x00012e47
    [12:01:04]  ← Received packet 1/48 (96 bytes) — HR=58, unix=1737270000
    [12:01:04]  ← Received packet 2/48 (96 bytes) — HR=57, unix=1737270001
    ...
    [12:01:08]  ← Batch complete: 48 packets, 2 sessions reconstructed
    [12:01:08]  ← Received next batch header: batch_id=0x00012e48
    ...
    [12:01:45]  Sync complete: 12 batches, 847 packets, 5 sessions added

Shows errors inline:
    [12:01:10]  ✗ CRC mismatch on packet 7 — discarded
    [12:01:11]  ✗ Batch timeout after 5s — retrying (attempt 2/3)
```

---

## 8. Data Persistence & Trends — Architecture

### 8.1 Storage Strategy

Use SQLite via a lightweight wrapper (e.g. GRDB for Swift). Do not use Core Data — the
schema needs to be readable and queryable directly for debugging, and SQLite gives full
control over indexes and rolling window queries.

**Why not CoreData**: CoreData's NSFetchRequest is cumbersome for time-series range
queries and rolling aggregations. Raw SQLite with GRDB gives the same persistence with
far simpler queries.

---

### 8.2 Database Schema

```
TABLE hr_samples
    id          INTEGER PRIMARY KEY
    timestamp   INTEGER NOT NULL   -- unix seconds
    bpm         INTEGER NOT NULL
    source      TEXT               -- 'ble_standard' | 'data_from_strap' | 'synced'
    session_id  TEXT               -- foreign key to sessions, nullable

INDEX ON hr_samples(timestamp)
INDEX ON hr_samples(session_id, timestamp)

---

TABLE rr_samples
    id          INTEGER PRIMARY KEY
    timestamp   INTEGER NOT NULL
    interval_ms INTEGER NOT NULL   -- single RR value in milliseconds
    session_id  TEXT

INDEX ON rr_samples(timestamp)

---

TABLE sessions
    id          TEXT PRIMARY KEY   -- UUID
    type        TEXT NOT NULL      -- 'activity' | 'sleep' | 'resting'
    start_time  INTEGER NOT NULL   -- unix seconds
    end_time    INTEGER            -- null if session still active
    source      TEXT               -- 'live' | 'synced' | 'estimated' | 'partial' | 'gap'
    strain      REAL
    calories    REAL
    avg_hr      INTEGER
    peak_hr     INTEGER
    hrv_rmssd   REAL
    rhr         REAL
    sleep_duration_min INTEGER
    interruptions      INTEGER
    recovery_score     REAL        -- null until baseline exists

INDEX ON sessions(start_time)
INDEX ON sessions(type, start_time)

---

TABLE daily_metrics
    date             TEXT PRIMARY KEY   -- ISO date string "2025-04-27"
    rhr              REAL
    hrv_morning      REAL
    recovery         REAL
    strain           REAL
    calories         REAL
    steps            INTEGER
    sleep_min        INTEGER
    baseline_ready   INTEGER            -- 0 or 1, set to 1 after 7 days
    hrv_version      INTEGER DEFAULT 1  -- algorithm version (see Section 10.3)
    strain_version   INTEGER DEFAULT 1
    sleep_version    INTEGER DEFAULT 1
    recovery_version INTEGER DEFAULT 1

---

TABLE algorithm_versions
    name        TEXT PRIMARY KEY   -- 'hrv' | 'sleep' | 'strain' | 'recovery' | 'rhr'
    version     INTEGER NOT NULL
    updated_at  INTEGER NOT NULL   -- unix seconds

---

TABLE baselines
    metric      TEXT PRIMARY KEY   -- 'hrv' | 'rhr' | 'sleep' | 'strain' | 'recovery'
    mean        REAL
    std_dev     REAL
    sample_count INTEGER
    updated_at  INTEGER            -- unix seconds

---

TABLE ble_debug_log                -- only written when DEBUG_BLE_CONSOLE = true
    id          INTEGER PRIMARY KEY
    timestamp   INTEGER NOT NULL
    direction   TEXT               -- 'write' | 'notify'
    characteristic TEXT
    raw_hex     TEXT
    parsed      TEXT               -- human-readable interpretation or null
```

---

### 8.3 Key Queries for Trends

```
// HR samples for a session (session detail chart):
SELECT timestamp, bpm FROM hr_samples
WHERE session_id = ? ORDER BY timestamp ASC

// Daily HRV trend (30 days):
SELECT date, hrv_morning FROM daily_metrics
WHERE date >= date('now', '-30 days')
ORDER BY date ASC

// Rolling 30-day baseline inputs:
SELECT hrv_morning FROM daily_metrics
WHERE hrv_morning IS NOT NULL
ORDER BY date DESC LIMIT 30

// Sessions in a date range (calendar view):
SELECT * FROM sessions
WHERE start_time >= ? AND start_time < ?
ORDER BY start_time DESC

// Check if baseline is ready:
SELECT COUNT(*) FROM daily_metrics
WHERE hrv_morning IS NOT NULL  -- count non-null days
```

---

### 8.4 Write Strategy

```
// Real-time HR: buffer in memory, flush to DB every 60 seconds
// Do not write every single sample to SQLite in real time —
// at 1 sample/sec that's 86,400 rows/day. Buffer first.

HR buffer flush (every 60s):
    bulk INSERT hr_samples (timestamp, bpm, source, session_id)
    using a single transaction for all buffered rows

RR samples: same pattern, flush every 60s

Session open:
    INSERT sessions (id, type, start_time, source='live') on activity start

Session close:
    UPDATE sessions SET end_time, strain, calories, avg_hr, peak_hr WHERE id=?

End of day (midnight trigger):
    aggregate hr_samples → compute daily_metrics row
    run baseline updater → update baselines table
    run recovery score → update daily_metrics.recovery

Synced data (from Section 6.4 batch sync):
    INSERT sessions with source='synced'
    bulk INSERT hr_samples and rr_samples with source='synced'
    backfill daily_metrics for affected dates
    re-run baseline updater if historical dates fall within the 30-day window
```

---

### 8.5 Data Retention Policy

```
hr_samples:     keep 90 days, then delete (too large to keep forever)
rr_samples:     keep 90 days
sessions:       keep forever (small, high value)
daily_metrics:  keep forever (tiny, essential for long-term trends)
baselines:      keep forever (single row per metric, updated in place)
ble_debug_log:  keep 7 days max, auto-purge older entries
```

**Purge job** (run on app launch, once per day):

```
DELETE FROM hr_samples WHERE timestamp < (now() - 90 days in seconds)
DELETE FROM rr_samples WHERE timestamp < (now() - 90 days in seconds)
DELETE FROM ble_debug_log WHERE timestamp < (now() - 7 days in seconds)
```

---

*End of plan. All algorithms above are protocol-agnostic pseudocode ready for Swift implementation.*
