# Violet Provider Portal

## Run

```bash
cd webapp
npm install
npm run dev
```

Open <http://localhost:3000>.

The portal reads the repository-root `.env`:

```text
MONGO_URI=
MONGO_DB_NAME=violet
MONGO_RELATIONSHIPS_PATH=relationships
MONGO_LOGS_PATH=logs
GOOGLE_CLIENT_ID=
```

`GOOGLE_CLIENT_ID` must be a web OAuth client with `http://localhost:3000` as an authorized JavaScript origin. The Connect Google Calendar button opens Google’s account popup and requests `calendar.events`, `profile`, and `email` scopes. The selected Google profile name initializes the patient name; the doctor can then edit patient details and calendar events.

Relationships and recognition logs come directly from MongoDB. They are cached in IndexedDB and checked for changes every minute while the portal is visible. Calendar events are cached locally and refreshed every minute while the Google access token is active. No sample records are generated.
