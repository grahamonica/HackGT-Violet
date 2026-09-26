# Violet for iOS

Violet is the patient-facing iOS companion for Meta AI glasses. While the app is active, the glasses listen for the word “Violet.” A trigger starts a five-second, 15 FPS glasses-camera stream. The current frame selector intentionally chooses the first usable frame; it is isolated behind `FrameSelecting` so an on-device quality model can replace it later.

## What is implemented

- Meta Wearables Device Access Toolkit 1.0.0 registration, session, speech, camera, and voice-invocation plumbing
- “Violet” on-glasses speech trigger and “Hey Meta, start Violet” launch fallback
- Five-second `.raw` camera capture at 15 FPS, with immediate stream teardown afterward
- Local relationship and recognition-log cache with one-minute incremental sync, ETag support, offline upload retry, and no patient-side delete action
- OpenAI Responses API vision request with structured output and conservative `HIGHLY_LIKELY` handling
- ElevenLabs speech routed through the active iOS audio output (including connected glasses)
- One-page family grid and a dismissible add-person sheet for the three required photos, name, relationship, bio, and year met

## Run

1. Open `Violet.xcodeproj` in Xcode 26.4 or newer.
2. Select your development team and a physical iPhone running iOS 17.2 or newer.
3. Enable Developer Mode for the glasses in the Meta AI app.
4. Keep the repository-root `.env` populated. The build phase reads it and writes a temporary `Secrets.json` into the built app; it never copies the file into source control.
5. Build and run, then tap **Set up glasses** once to complete registration and grant camera/microphone access.

Supported `.env` keys:

```text
OPENAI_API_KEY=
OPENAI_MODEL=gpt-4.1-mini
ELEVEN_LABS_API_KEY=
ELEVEN_LABS_VOICE_ID=
MONGO_DB_ENDPOINT=
MONGO_DB_API_KEY=
MONGO_RELATIONSHIPS_PATH=relationships
MONGO_LOGS_PATH=logs
META_APP_ID=
META_CLIENT_TOKEN=
```

The two Mongo paths are optional and default to `relationships` and `logs`. The relationship endpoint should support `GET ?updatedAfter=<ISO-8601>` and `POST`; the log endpoint should support `POST`. `GET` may return either an array or `{ "items": [...], "nextCursor": "..." }`.

## Important prototype boundaries

- Meta’s Speech and Voice Invocations capabilities are experimental and, in SDK 1.0.0, are available for development/beta but not production release channels.
- iOS cannot guarantee an arbitrary custom wake word while the app process is suspended. “Violet” works through the active device session; the supported cold/background fallback is “Hey Meta, start Violet,” after approval in Wearables Developer Center.
- Shipping third-party API keys inside a client app is not production-safe. The `.env` bridge is appropriate for this prototype only. Move OpenAI, ElevenLabs, and Mongo writes behind an authenticated backend before distribution.
- Face matching is assistive and fallible. The app only announces a person for `HIGHLY_LIKELY`; all other outcomes use the explicit unknown-person response. A production system needs consent, retention controls, human evaluation, and a purpose-built biometric model rather than relying on a general vision model.

## Data contract

Relationship payloads use the seven requested domain fields:

```json
{
  "name": "Jordan Lee",
  "frontPhoto": "<base64 JPEG or HTTPS URL>",
  "leftPhoto": "<base64 JPEG or HTTPS URL>",
  "rightPhoto": "<base64 JPEG or HTTPS URL>",
  "relation": "daughter",
  "bio": "Jordan loves gardening and calls every Sunday.",
  "yearMet": 1998
}
```

`_id` and `updatedAt` are treated as server metadata for incremental sync. Recognition logs use `{ "timestamp": "<ISO-8601>", "identifiedPerson": "<name or Unknown>" }`.

