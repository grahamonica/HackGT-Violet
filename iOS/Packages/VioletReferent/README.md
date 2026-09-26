# VioletReferent

Given the frames captured after "Hey Violet", decide **which enrolled person
the user was looking at**, or say clearly why it can't.

Self-contained Swift package; it does not touch the app's capture, audio or
UI code. The app feeds it frames and switches on the outcome. It also enrolls
people into the Rekognition collection it searches.

**Integrating into the app: see [INTEGRATION.md](INTEGRATION.md).**

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
| `FaceAnalyzing` | frame → faces: box, quality score, crop to send | `VisionFaceAnalyzer` (`ReferentApple`) |
| `FaceIdentifying` | crop → `[IdentityMatch]` (UserId, similarity 0-100) | `RekognitionIdentifier` (`ReferentRekognition`) |

Both are plain protocols: the decision logic is tested with fakes, and the
identifier can later move behind a backend without changing anything else.

### Wiring it up in the app

```swift
import ReferentApple
import ReferentCore
import ReferentRekognition

let model = try await FaceQualityModel.bundled()          // bundled model, compiled on first use
guard let aws = RekognitionConfig(values: secrets) else { … }  // AWS_REKOGNITION_* keys
let pipeline = ReferentPipeline(
  analyzer: VisionFaceAnalyzer(model: model),
  identifier: RekognitionIdentifier(config: aws))

// Enrollment, from the same config (so search and enrollment share a collection):
let enroller = RekognitionEnroller(config: aws)
try await enroller.ensureCollection()
try await enroller.enroll(personID: person.id, photos: [person.frontPhoto, person.leftPhoto, person.rightPhoto])
try await enroller.remove(personID: person.id)
```

- **`VisionFaceAnalyzer`**: Vision face + landmark detection; the Rekognition crop
  is the face box plus 20% on each side (as in training), JPEG-encoded; the 5
  training landmarks are derived from Vision's (pupils, lowest nose-crest point,
  outer-lip extremes); the face is aligned with `FaceAlignment` and scored.
  Frames are assumed upright (JPEG orientation metadata is ignored).
- **`RekognitionIdentifier`**: `SearchUsersByImage` with the same parameters the
  training labels used (`MaxUsers` 5, threshold 0, `QualityFilter` NONE),
  signed with SigV4 (no AWS SDK). "No face in crop" returns no matches;
  throttling and 5xx errors are retried with jittered exponential backoff
  (`maxAttempts` 3).
- **`RekognitionEnroller`**: one Rekognition user per person, UserId = the app's
  person ID (so a match *is* the person's ID). `enroll` indexes the largest face
  of each photo (Rekognition keeps face vectors, not images), creates the user
  and associates the faces, replacing any earlier enrollment; photos without a
  face are skipped and reported. `remove` deletes the user and their faces.
- **`FaceAlignment`** (in `ReferentCore`): pure-Swift port of the training
  alignment; matches Python on the reference set to within 1 intensity level.

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
| `temporalWeighting` | true | favor faces seen early in the capture; false = all frames count equally |
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
like its other API keys (keys: see INTEGRATION.md, step 2).

**Demo setup:** one IAM user with full Rekognition access
(`AmazonRekognitionFullAccess`), used for both search and enrollment. Anything in
the app bundle can be extracted, and this key can use every Rekognition API in
the account, so:

- Set an AWS billing alarm, and delete the key after the event and before any
  build leaves the team's devices.
- Beyond the demo: scope the user to the one collection
  (`rekognition:SearchUsersByImage`, plus `CreateCollection`, `CreateUser`,
  `DeleteUser`, `IndexFaces`, `AssociateFaces`, `ListFaces`, `DeleteFaces` for
  enrollment, on `arn:aws:rekognition:<region>:<account>:collection/<id>`), or
  move the calls behind a backend; only the `RekognitionConfig`/transport change.

## Development

| target | contents | builds on |
|---|---|---|
| `ReferentCore` | contract, config, tracking, scoring, resolution, pipeline, rate limiting, alignment | any platform (Linux included) |
| `ReferentRekognition` | SigV4 signing, search (identifier) and enrollment clients | any platform (swift-crypto on Linux) |
| `ReferentApple` | Vision analyzer, Core ML model (`Resources/FaceQuality.mlpackage`) | iOS / macOS only |

The model file is produced by `ml/facequality/training/export.py` (see the
training README) and copied into `Sources/ReferentApple/Resources/`.

```bash
swift test                                   # Mac, from this directory: all targets
swift test --scratch-path ~/.cache/violet-referent-build   # Linux/WSL: Core + Rekognition
```

Optional test inputs (tests skip without them):

| variable | enables |
|---|---|
| `VIOLET_REFERENCE_DIR=<repo>/ml/facequality/training/exports/FaceQuality_reference` | alignment parity (any platform); Core ML, Vision-landmark and end-to-end parity (Mac) |
| `VIOLET_REKOGNITION_LIVE=1` (+ `.env` filled in, + the reference dir) | live round trip on a throwaway `<collection>-livetest` collection: enroll, search, remove |

The reference set contains CelebA faces: it stays in the gitignored `exports/`
folder and is shared out of band, not committed.

### Verification status

| check | where | result |
|---|---|---|
| decision logic, pipeline, deadlines, rate limit | WSL | all tests pass |
| Swift alignment vs Python | WSL | max difference 1/255 over 24 faces |
| SigV4 signing | WSL | matches AWS's published test vector |
| Rekognition search and enrollment requests, responses, retries | WSL | fake-AWS tests pass |
| live Rekognition round trip | needs the key in `.env` | not yet run |
| `ReferentApple` compiles | **Mac** | not yet run |
| Core ML vs PyTorch, Vision landmarks vs CelebA, end-to-end score | **Mac** | not yet run |

On the Mac, `testVisionLandmarksAgreeWithCelebA` prints how far Vision's
derived points sit from CelebA's annotations. If the error is large or
systematic (e.g. the nose point), the mapping in `VisionFaceAnalyzer.fivePoints`
is the thing to adjust.
