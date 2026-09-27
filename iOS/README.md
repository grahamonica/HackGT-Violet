# Violet for iOS

Violet is the patient-facing iOS companion for Meta AI glasses. While the app is active, the glasses listen for the word “Violet.” A trigger starts a glasses-camera stream at 15 FPS for up to five seconds, ending early once the answer is known.

Frames go to [`Packages/VioletReferent`](Packages/VioletReferent/README.md): on-device face detection and quality scoring (Apple Vision and a Core ML model), AWS Rekognition search and enrollment, and choosing which person the user meant. The app uses it whenever the `AWS_REKOGNITION_*` keys are set. Without them it falls back to sending the first frame to OpenAI.

Violet handles one request at a time: a trigger (“Violet”, the capture button, or “Hey Meta, start Violet”) while it is capturing, recognizing, or speaking is ignored. If the answer takes more than three seconds, Violet says a short filler line (“One moment.”, “Just a second.”, “Let me take a look.”, in turn), and the answer plays right after it.

### Follow-up questions

When the wearer says “Violet” followed by a question (“Violet, what's she been up to?”) and the person is identified, Violet answers the question after the identity line. The words after “Violet” are collected while the camera runs. A language model (Grok by default, or Meta's Muse Spark) decides whether they were a real question about this person and, if so, writes a short reply from the person's bio and notes. The reply hints rather than telling everything, so the wearer can recall the rest.

- Only for the spoken wake word, never for the capture button or “Hey Meta”, and never when no one was identified.
- On those requests the identity line starts no earlier than two seconds after “Violet”, so a quick recognition doesn't cut the question short. Slower answers aren't delayed further.
- The model answers in a fixed structure: not a question (Violet says nothing more), no information (Violet says the fixed line “I don't have anything about that yet.”), or an answer. A model error, including output that doesn't match the structure, also gets the fixed line; there are no retries.
- The model gets five seconds; otherwise Violet says nothing more. A filler line plays only once a reply is certain and its voice is slow to generate.
- Configured in the root `.env`: `FOLLOW_UP_PROVIDER=grok` (default, uses `XAI_API_KEY`, model `grok-4.3` with reasoning off) or `FOLLOW_UP_PROVIDER=muse` (uses `META_API_KEY`, model `muse-spark-1.3` at minimal reasoning, since Muse can't turn reasoning off). `FOLLOW_UP_MODEL` optionally overrides the model. Without the chosen provider's key, follow-ups are off and everything else works as before.
- Notes are an optional field next to the bio when adding someone. Older records without notes work unchanged.

### Latency

To see where the time goes, tick `-VioletLatency YES` under **Product › Scheme › Edit Scheme › Run › Arguments**. After each answer, the Xcode console prints one block: a timeline from the trigger (camera start, first frame, first face, first Rekognition reply, voice start and end) and per-stage timings (frame conversion, Apple Vision, Core ML quality model, Rekognition calls). Type `[Latency]` in the console's filter field to hide everything else. With the argument off, nothing is measured.

## What is implemented

- Meta Wearables Device Access Toolkit 1.0.0 registration, session, speech, camera, and voice-invocation plumbing
- “Violet” on-glasses speech trigger, the glasses capture button, and “Hey Meta, start Violet” launch fallback
- Up-to-five-second `.raw` camera capture at 15 FPS, with immediate stream teardown afterward
- On-device face detection and quality scoring, Rekognition search, and automatic Rekognition enrollment of the people on the phone
- Distinct spoken answers for an identified person, someone not in the family, no visible face, and an uncertain result
- Local relationship and recognition-log cache with one-minute incremental sync straight to MongoDB Atlas, offline upload retry, and no patient-side delete action
- OpenAI Responses API vision request with structured output and conservative `HIGHLY_LIKELY` handling
- ElevenLabs speech routed through the active iOS audio output (including connected glasses)
- One-page family grid and a dismissible add-person sheet for the three required photos, name, relationship, bio, and year met

## Run

1. Open `Violet.xcodeproj` in Xcode 26.4 or newer.
2. Select your development team and a physical iPhone running iOS 17.2 or newer.
3. Enable Developer Mode for the glasses in the Meta AI app.
4. Keep the repository-root `.env` populated and downloaded locally. If Finder shows a cloud icon, choose **Download Now** first. The build phase reads it and writes a temporary `Secrets.json` into the built app; it never copies the file into source control.
5. Build and run, then tap **Set up glasses** once to complete registration and grant camera/microphone access.

Supported `.env` keys:

```text
OPENAI_API_KEY=
OPENAI_MODEL=gpt-4.1-mini
ELEVEN_LABS_API_KEY=
ELEVEN_LABS_VOICE_ID=
MONGO_URI=mongodb+srv://...
MONGO_DB_NAME=violet
MONGO_RELATIONSHIPS_PATH=relationships
MONGO_LOGS_PATH=logs
FOLLOW_UP_PROVIDER=grok
XAI_API_KEY=
META_API_KEY=
FOLLOW_UP_MODEL=
```

The app connects to Atlas directly with `MONGO_URI` through [MongoKitten](https://github.com/orlandos-nl/MongoKitten), the same URI the provider portal uses. `MONGO_DB_NAME` and the two collection names are optional and match the portal's defaults. The older `MONGO_DB_ENDPOINT`/`MONGO_DB_API_KEY` Data API keys are no longer read. Atlas **Network Access** must allow the phone's IP address.

Developer Mode intentionally uses `META_APP_ID = 0` and no client token, as supported by the SDK. For a production channel, set the `META_APP_ID` and `META_CLIENT_TOKEN` Xcode build settings from the app registered in Wearables Developer Center.

## Important prototype boundaries

- Meta’s Speech and Voice Invocations capabilities are experimental and, in SDK 1.0.0, are available for development/beta but not production release channels.
- iOS cannot guarantee an arbitrary custom wake word while the app process is suspended. “Violet” works through the active device session; the supported cold/background fallback is “Hey Meta, start Violet,” after approval in Wearables Developer Center.
- Shipping third-party API keys inside a client app is not production-safe. The `.env` bridge is appropriate for this prototype only. The bundled `MONGO_URI` carries database credentials, so move OpenAI, ElevenLabs, and Mongo access behind an authenticated backend before distribution.
- Face matching is assistive and fallible. The app only announces a person for `HIGHLY_LIKELY`; all other outcomes use the explicit unknown-person response. A production system needs consent, retention controls, human evaluation, and a purpose-built biometric model rather than relying on a general vision model.

## Data contract

Relationship documents use the seven requested domain fields in camelCase, matching the Atlas collection validator and the provider portal:

```json
{
  "name": "Jordan Lee",
  "frontPhoto": "<base64 JPEG>",
  "leftPhoto": "<base64 JPEG>",
  "rightPhoto": "<base64 JPEG>",
  "relation": "daughter",
  "bio": "Jordan loves gardening and calls every Sunday.",
  "yearMet": 1998,
  "createdAt": "<BSON date>",
  "updatedAt": "<BSON date>"
}
```

Incremental sync queries `updatedAt > last sync`. Recognition logs are `{ "timestamp": <BSON date>, "identifiedPerson": "<name or Unknown>" }`.
