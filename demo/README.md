# Demo diagrams

Presentation visuals for Violet, generated from code so they are easy to edit and regenearate programmatically"

| file | what it shows |
|---|---|
| `architecture.svg` / `.png` | The whole system: patient and Meta AI glasses, the iOS app and its parts, AWS Rekognition, ElevenLabs, MongoDB Atlas, Google Calendar, the provider portal, and the offline ML pipeline that produces the on-device FaceQuality model. |
| `user-flow-patient.svg` / `.png` | The patient's journey from one-time setup to hearing who is in front of them, including the four spoken outcomes. |
| `user-flow-provider.svg` / `.png` | What a clinician or caregiver does in the provider portal and where each action ends up. |

Boxes carry a title only; the diagrams are meant to support a spoken walkthrough. White boxes are built in this repository, tinted boxes are third-party services, devices or data.

## Regenerate

```bash
python3 demo/generate_diagrams.py            # SVGs plus 2x PNGs
python3 demo/generate_diagrams.py --svg-only
```

Needs Python 3 with `fonttools` (the fonts in `webapp/public/fonts` are subset and embedded, so each SVG is self-contained). PNGs are rasterized with headless Google Chrome when it is installed, otherwise with macOS Quick Look and Pillow.

## Style

Follows the repository `style_guide.md`: accent `#9b82e8`, deep accent `#3b267a`, ink `#232324`, white background, 3 px corner radius, no gradients, Sansation for headings and Mukta Malar Light for everything else. Layout, colours and text live in `generate_diagrams.py`; edit that file rather than the SVGs.

## Demo data

`seed_demo_data.mjs` fills the portal with a history from January 1 to today for seven familiar people: Josh, Conrad, Monica, Andrew, Bob, David and Michael. It writes their visits to Google Calendar (varied week to week, through December 31), Violet recognitions during those visits (95% name the person on the calendar), provider notes, and the patient details. The recognitions rise through the year and cluster in the evening, showing sundowning that gets worse over time. Violet uses per person seen climb from about 0.1 in January to 0.75 now, and rise every week in the portal's default six weeks as of the day the script runs, so rerun it with `--only logs,patient` on the day you present. People missing from the database are added with placeholder photos to replace in the app; existing people are never changed.

```bash
node demo/seed_demo_data.mjs                        # dry run: writes demo/synthetic_data/ for review
node demo/seed_demo_data.mjs --apply                # write the calendar, people, logs, notes and patient details
node demo/seed_demo_data.mjs --apply --only logs,patient   # extend the logs to now, e.g. just before presenting
```

`--apply` needs the portal open in Chrome at `http://localhost:3000` and connected to Google Calendar, with View > Developer > Allow JavaScript from Apple Events turned on. It reads the Google token from that tab, draws the placeholder photos there, saves the patient details and clears the tab's cached logs and notes. Everything it writes is tagged, so a rerun replaces only its own calendar events, logs and notes, and recognitions from the glasses are kept. Anything it deletes is backed up to `demo/synthetic_data/backup/` first. Other browsers keep their cached logs and notes until their site data is cleared.

`--replace-template` and `--clear-test-data` were for the first run only: they replaced the recurring weekly calendar the team started with, made Bob the nurse from those events, removed people outside the seven, and removed the test logs and notes.
