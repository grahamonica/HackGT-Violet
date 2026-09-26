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
