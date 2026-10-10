# MotoGrid MXGP 26 Series — Windows Desktop App

Standalone Tauri desktop app project. It is isolated under `mxgp26-desktop/` on the `mxgp26-desktop-app` branch and has not been merged into the website's main branch.

## Included
- Supabase email/password registration and sign-in
- Rider profile editing and directory
- Championship standings (points, wins, races)
- Separate Ranked ladder with Bronze, Silver, Gold, Platinum, Diamond, and Elite tiers
- Admin-only result publishing through a database-verified role
- Server-side Elo-style Ranked rating recalculation and championship points
- Windows NSIS installer build through GitHub Actions

## Configure the shared database
1. Create a Supabase project dedicated to the desktop app.
2. Run `supabase/schema.sql` in the Supabase SQL Editor.
3. Copy the project URL and publishable/anon key from Project Settings → API.
4. Copy `.env.example` to `.env` at the project root and fill in the URL/key. Never put a service-role key in the app.
5. Create an account in the app. Promote your own account to admin from the trusted Supabase SQL Editor:
   ```sql
   update public.profiles set role='admin' where lower(email)=lower('YOUR-EMAIL');
   ```
   Do not expose admin promotion to users or add the service-role key to the desktop app. Database RLS and the server-side RPC check admin role.

## Run and build locally on Windows
Install Node.js 22 LTS and Rust stable with the MSVC build tools. From this directory:
```powershell
npm install
npm run tauri -- dev
npm run tauri -- build --bundles nsis
``
The installer is expected at `src-tauri/target/release/bundle/nsis/`.

## Download the automated Windows installer
The repository-root workflow `.github/workflows/build-mxgp26-windows.yml` runs on pushes to the `mxgp26-desktop-app` branch. Open the repository's Actions tab, select **Build MotoGrid MXGP 26 Windows installer**, open a successful run, and download the **MotoGrid-MXGP26-Windows-Installer** artifact. GitHub provides the .exe as an artifact after the build finishes; it is not a permanent public release link yet.

## Initial ranked / championship rules
- New riders start at 1000 Ranked rating.
- Tiers: Bronze (<900), Silver (900–1099), Gold (1100–1299), Platinum (1300–1499), Diamond (1500–1699), Elite (1700+).
- Each race compares each rider's finishing position against the other riders in that race and applies Elo-style rating changes (K=32).
- Ratings are replayed chronologically from 1000 whenever an event is published/edited, so corrections do not compound old rating changes.
- Championship points for places 1–20: 25, 22, 20, 18, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1. No points after 20th.

## Before inviting the league
This is an initial implementation and needs a successful Windows build plus live Supabase testing before broad use. Test signup, admin-only publishing, duplicate event correction, standings, and Ranked changes with test accounts first. The installer is unsigned by default, so SmartScreen may warn until code-signing is configured. Keep `.env`, service-role keys, and signing credentials private.
