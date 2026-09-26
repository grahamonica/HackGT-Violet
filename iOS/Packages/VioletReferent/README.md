# VioletReferent

Given the frames captured after "Hey Violet", decide **which enrolled person
the user was looking at**, or say clearly why it can't.

Self-contained Swift package; it does not touch the app's capture, audio or
UI code. The app feeds it frames and switches on the outcome.

```
frames ─→ face detection + landmarks ─→ local quality model ─→ Rekognition ─→ referent scoring ─→ outcome
          WHERE are faces?              WORTH a call?          WHO is it?      WHICH one was meant?
```

## Usage contract

```swift
import ReferentCore

let pipeline = ReferentPipeline(config: ReferentConfig(), analyzer: analyzer, identifier: identifier)

await pipeline.begin()                                    // on "Hey Violet"
// As frames arrive (the first one is the reference frame):
await pipeline.consider(ReferentFrame(jpegData: jpeg, timestamp: seconds))

// Answer as soon as it's confident (not before 2 s), and never after 5 s:
let result = await pipeline.resolve(earliest: .seconds(2), deadline: .seconds(5))
switch result.outcome {
case .identified(let person):   // person.userID = Rekognition UserId
case .ambiguous(let people):    // several people equally plausible, best first
case .notRecognized:            // good crops, no enrolled person matched
case .poorQuality:              // faces seen, none clear enough; no AWS calls made
case .noFace:                   // no faces in any frame
case .failed(let error):        // no identification succeeded: network errors or timeout
}
```

The caller decides what to say for each case. `result.diagnostics` has counts
(frames, faces, tracks, calls, failures), `secondsToAnswer`, `answeredEarly`,
and every accepted identity with its evidence, for logging and tuning.

- **Capture:** runs from `begin()` until `resolve` answers. Frames outside a
  capture are ignored, so the camera can keep streaming after an early answer.
- **`resolve(earliest:deadline:)`** (both measured from `begin()`): identification
  starts during capture as new people appear. From `earliest` on it returns
  as soon as the outcome is `.identified` and no open request could still change
  it; otherwise it keeps capturing. `deadline` is a hard limit, network included:
  in-flight calls are cancelled and the answer uses the results received so far
  (`.failed(ReferentError.identificationTimedOut)` if none arrived).
- **`resolve()`** ends the capture now and answers from the frames so far.
- `ReferentFrame.timestamp`: seconds on any monotonic clock. Only differences matter.
- `consider` returns immediately; frames are analyzed one at a time in the
  background, and only detected faces are kept.
- One resolution at a time; `begin()`/`reset()` cancel a running one.

### Plug-in points

| protocol | job | implementation |
|---|---|---|
| `FaceAnalyzing` | frame → faces: box, quality score, crop to send | Vision + Core ML (planned, `ReferentApple`) |
| `FaceIdentifying` | crop → `[IdentityMatch]` (UserId, similarity 0-100) | Rekognition `SearchUsersByImage` (planned) |

Both are plain protocols: the decision logic is tested with fakes, and the
identifier can later move behind a backend without changing anything else.

## How it decides

1. **Tracking.** Detections of the same face in consecutive frames are linked
   by box overlap into tracks, so a person seen in 40 frames is one candidate,
   not 40.
2. **Quality gate.** Crops scoring below `minQuality` are never sent. Each track
   sends its best crop(s) (`cropsPerTrack`); a track already identified is only
   re-sent if a new crop is clearly sharper (`requalityMargin`). Every track gets
   one crop before any gets a second, tracks most likely to be the referent
   first, and `maxIdentificationCalls` bounds the whole capture, so repeated
   checks never multiply calls.
3. **Referent score** per track: best over its sightings of
   `temporal weight × geometry`.
   - Temporal: 1 at the first frame, falling linearly to `temporalFloor` at the
     last, on normalized capture time (same weighting for any buffer length).
   - Geometry: centrality (Gaussian falloff from the frame center), reduced by
     up to `sizeWeight` for small faces. Centrality dominates; a large face
     slightly off-center beats a tiny centered one.
4. **Identity.** A crop's top match counts only if its similarity is at least
   `minSimilarity`. An identity's score is its best supporting track's
   referent score, plus a small capped bonus for each additional agreeing crop.
   The local quality score plays no part here: once Rekognition has answered,
   its result is what counts.
5. **Outcome.** If the runner-up scores within `ambiguityMargin` of the best,
   the result is `ambiguous`; otherwise `identified`.

## Configuration (`ReferentConfig`)

| setting | default | meaning |
|---|---|---|
| `minQuality` | 0.15 | local quality gate (on data: rejects ~2% of crops Rekognition gets right, ~59% of those it gets wrong) |
| `maxIdentificationCalls` | 6 | cap on Rekognition calls per capture |
| `cropsPerTrack` | 1 | crops sent per face track |
| `requalityMargin` | 0.15 | quality gain needed to re-send an identified track |
| `maxIdentificationsPerSecond` | 45 | rate limit: calls started in any one-second window, across captures; extra calls wait for a slot. Rekognition's default quota for `SearchUsersByImage` is 50/s per account in us-east-1 (5 in most other regions) |
| `maxConcurrentIdentifications` | 6 | calls in flight at once (separate from the rate limit) |
| `identificationTimeout` | 3 s | a single call taking longer counts as failed |
| `pollInterval` | 100 ms | how often `resolve(earliest:deadline:)` re-checks |
| `trackMinIoU`, `trackMaxGap` | 0.3, 0.5 s | linking faces across frames |
| `temporalFloor` | 0.3 | temporal weight of the last frame |
| `centralitySigma` | 0.35 | centrality falloff (fraction of the half-diagonal) |
| `sizeWeight`, `minFaceHeight`, `maxFaceHeight` | 0.4, 0.05, 0.4 | size signal |
| `minSimilarity` | 80 | Rekognition acceptance (on data: keeps ~97.5% of correct matches, accepts ~0.7% of wrong ones) |
| `agreementBonus`, `maxAgreementBonus` | 0.05, 0.15 | support from repeated agreement |
| `ambiguityMargin` | 0.15 | relative score gap needed to name one person |

The two data-derived defaults come from the face-quality dataset
(`ml/facequality/training/RESULTS.md`). Glasses footage and on-device landmarks
differ from that data, so log `diagnostics` on real sessions and re-check
`minQuality` and `minSimilarity`.

## Rekognition access

The app calls Rekognition directly with credentials baked in at build time,
like its other API keys. Because anything in the app bundle can be extracted,
**use a dedicated IAM user that can do exactly one thing**: search the one
collection.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "rekognition:SearchUsersByImage",
    "Resource": "arn:aws:rekognition:<region>:<account-id>:collection/<collection-id>"
  }]
}
```

- Never reuse broader credentials (e.g. the dataset builder's, which can create
  collections and index faces).
- Set an AWS billing alarm, and delete or rotate the key after the event and
  before any build leaves the team's devices.
- Moving to Cognito or a backend later only replaces the `FaceIdentifying`
  implementation.

Enrollment (creating the collection's users from each person's photos) is out
of scope here. The returned `userID` is the Rekognition `UserId`.

## Development

| target | contents | builds on |
|---|---|---|
| `ReferentCore` | contract, config, tracking, scoring, resolution, pipeline | any platform (Linux included) |
| `ReferentApple` (planned) | Vision landmarks, alignment, Core ML quality model, Rekognition | iOS / macOS |

```bash
swift test                         # on a Mac, from this directory
```

On Linux/WSL, keep build output out of the repo:
`swift test --scratch-path ~/.cache/violet-referent-build`.

Status: `ReferentCore` implemented and tested (43 tests). `ReferentApple` and
the Core ML export of the quality model are next; the Rekognition identifier
adds retry with backoff on throttling on top of the concurrency cap.
