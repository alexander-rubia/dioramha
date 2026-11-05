# DioramHA

Your home in 3D for [Home Assistant](https://www.home-assistant.io/). A native iOS app that shows
your floors as a scale model: tap a room and control only what matters, without the hundreds of
options of a full dashboard.

> Early-stage community project. Not affiliated with Home Assistant or Nabu Casa.

## Features

- 3D model generated from a JSON file: floors, rooms, furniture, garden and roof.
- Lights, blinds, heating, vacuum and plugs, with live state.
- Daily solar production with an hourly chart.
- A sky that follows the real time and weather.
- Doors and alarms ask for confirmation before acting.

## Getting started

You need a Mac with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and iOS 17 or later.

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your Apple Team ID
xcodegen generate
open DioramHA.xcodeproj
```

When the app opens, enter your Home Assistant address and a long-lived access token (Profile >
Security). The token is stored in the iPhone Keychain and never leaves it, except to reach your
Home Assistant.

## Your home

The app ships with an example home in `DioramHA/Resources/house.json`. To use your own:

```sh
cp DioramHA/Resources/house.json DioramHA/Resources/house.local.json
xcodegen generate
```

Edit `house.local.json` with your rooms, measurements and entities. If it exists, the app uses it
instead of the example. **Git ignores it on purpose:** it describes your home and should not be
published.

Measurements are in meters from the center of the house: `x` to the right seen from the street and
`z` toward the street. Floors go in `building.levels`: `0` is the ground floor, `-1` a basement, `1`
the floor above. Sides shared with a neighbor go in `building.partyWalls` (`left`, `right`, `back`),
or leave it empty for a detached house. Each room sets its floor with `level`. Rooms must be
rectangular for now.

## AI assistant (work in progress)

`worker/` is a Cloudflare Worker that drafts a house file from your Home Assistant areas and a few
answers, using Workers AI. The model only proposes the layout: which devices appear and which ones
ask for confirmation is decided by plain code. To run your own:

```sh
cd worker
npx wrangler deploy
npx wrangler secret put ASSISTANT_KEY   # any long random value
```

The app does not call it yet.

## Tests

```sh
xcodebuild test -project DioramHA.xcodeproj -scheme DioramHA \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Security

- Do not publish your token, your `house.local.json`, or screenshots that reveal details of your home.
- Unencrypted HTTP is only allowed on the local network; everything else requires HTTPS.

## License

[MIT](LICENSE)
