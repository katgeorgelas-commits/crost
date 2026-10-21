# Crossings

Where and when Kat and Max were in the same place at about the same time, with both photos side by side.

**How it works:** Max's phone exports a file with every photo's location, exact time and a small preview. Kat's phone compares that file with her own camera roll and lists each crossing.

## Set up on Kat's Mac (once, ~10 min)

1. Xcode → **File → New → Project → iOS App**. Name: `Crossings`. Interface: SwiftUI.
2. Delete the two `.swift` files Xcode made. Drag `Crossings.swift` from this repo into the project.
3. Click the blue project icon → **Crossings** target → **Info** tab → **+** → `Privacy - Photo Library Usage Description` → value: `Finds where we crossed paths`.
4. **Signing & Capabilities** tab → Team: **(your name) Personal Team**. Not listed? Xcode → Settings → Accounts → **+** → your Apple ID.

## Install on a phone

1. Plug the iPhone into the Mac. Pick it at the top of Xcode. Press **▶︎**.
2. iPhone, first time only:
   - **Settings → Privacy & Security → Developer Mode** → on, then restart.
   - **Settings → General → VPN & Device Management** → trust your Apple ID.
3. Open the app. When it asks about Photos, choose **Allow Full Access**.

The free account makes the app stop opening after 7 days. Press ▶︎ again to renew it. Your crossings stay saved.

## Use it

**Max's phone** (in person, after installing):
1. Tap **1. Export my photos**. Wait. Big camera rolls take a few minutes.
2. Tap **Send file** → AirDrop to Kat.

**Kat's phone:**
1. The AirDropped file goes to **Files → Downloads**.
2. Tap **2. Open their file** → pick `my-photos.json`.
3. Scroll the crossings.

You can test this now: export your own photos, then open that same file. Every photo will match itself.

## Tweak

At the top of `Crossings.swift`:
- `maxMeters = 300`: how close the two photos have to be.
- `maxHours = 3`: how close in time.

Change a number, then press ▶︎ again.
