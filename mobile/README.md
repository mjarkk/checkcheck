# CheckCheck mobile

Flutter client for the CheckCheck server. It speaks the REST contract in
[`../API.md`](../API.md) and follows its display conventions and shared look.
For now the project has iOS only.

## Run on the iOS simulator

1. Start the dev server (port 8181, token `dev`):

   ```sh
   mise run dev:server
   ```

2. Boot a simulator and run the app:

   ```sh
   open -a Simulator
   mise run mobile:run    # or: flutter run -d <simulator id from `flutter devices`>
   ```

3. On the setup screen, enter `http://localhost:8181` as the server URL and
   `dev` as the token, then tap **Connect**. You can also paste a
   `checkcheck://connect?server=…&token=…` link into the URL field and both
   fields fill in.

The simulator has no camera, so **Scan QR code** shows a "Can't use the
camera" message there. Use a real device to scan the QR code from the web app.

If you type a URL without a scheme, the app uses `https://`. Plain `http://`
works for `localhost` and LAN hosts: `Info.plist` sets
`NSAllowsLocalNetworking`, and it has the local-network and camera usage
strings.

## Install a release build on your iPhone

Debug builds (`flutter run`) are unoptimised and much slower than what you
ship. To try real performance, run:

```sh
mise run mobile:install
```

It builds the release app and installs it on a paired iPhone, over USB or
Wi-Fi. With several phones paired it asks which one to use. To skip the
question, copy the id from `xcrun devicectl list devices` and run
`CHECKCHECK_DEVICE=<phone id> mise run mobile:install`. The install updates
the app in place, so it stays connected. `flutter run --release -d <phone id>`
also builds and installs, and it streams the app's logs. Hot reload doesn't
work in release mode.

Signing uses team `N65XC23LP9` (set in the Xcode project) and the Apple
Development identity in your keychain. The app keeps working until the team
provisioning profile expires. Rerun the task after that, or whenever you
change the code. If iOS refuses to open the app, turn on Settings → Privacy &
Security → Developer Mode.

On a fresh install, scan the QR code from the web app. The phone can't reach
`localhost`, so before scanning, set the dialog's server field to an address
the phone can reach. With the dev server, that's your Mac's LAN IP on port
8181, or on 5173 through Vite. To find the IP:

```sh
ipconfig getifaddr en0
```

## Checks

```sh
flutter analyze
flutter test
```

## Layout

- `lib/api/`: models, `ApiClient` (typed exceptions, 10 s timeout, the
  `/api/events` stream) and `link.dart`, the server's link rule
- `lib/connect.dart`: connect-link parser and the setup validation
  (`/api/health`, then `/api/categories` with the token)
- `lib/settings.dart`: server URL in shared preferences, token in the
  Keychain, URL normalisation
- `lib/state/`: `ChecklistModel` (a `ChangeNotifier`) with its queue of
  unsent changes (`changes.dart`) and offline copy (`checklist_cache.dart`),
  and the pure sections, counts and drop planning in `sections.dart`
- `lib/screens/`: setup, scanner and checklist screens, the categories,
  new-category and connect-phone dialogs, and the controls that copy the
  webapp's look (item row, title field, Add item line, link preview, ⋯ menu,
  checkbox, logo)
- `lib/screens/spring.dart`, `layout_motion.dart`, `list_drag.dart`: the
  webapp's springs, its layout animation (rows spring to wherever a change
  puts them) and its drag and drop, ported from `server/web/src/motion.ts`
  and `drag.ts`
- `lib/theme.dart`: Material 3 colours from seed `#6750A4` with the vibrant
  variant, and the webapp's type scale in the bundled Roboto Flex
  (`assets/fonts/`, OFL). Light or dark follows the system.
- `lib/home_widget.dart`, `ios/CheckcheckWidget/`, `ios/Shared/`: the iOS
  home-screen widget (see below)

## Offline

The app keeps the last list the server sent, plus every change it hasn't
sent yet, in shared preferences. It opens on that copy and fetches in the
background, also whenever it comes back to the foreground. Changes show at
once and go to the server in order, retrying with backoff while it can't be
reached. A fetch replaces the server copy and replays the unsent changes on
top. Each change sends only the fields it sets, so it doesn't undo edits made
elsewhere in the meantime.

- A change the server rejects is dropped and shown as an error. A 5xx or a
  response that isn't CheckCheck's own JSON (a proxy's error page while the
  server restarts) is retried instead.
- An item added offline to a category that was deleted elsewhere is created
  uncategorized. A category added offline whose name was taken elsewhere
  merges into that one.
- **Disconnect** deletes the copy. A rejected token keeps it, so signing in to
  the same server again sends what was left.
- A create whose response got lost (a timeout, or the app killed mid-request)
  is sent again with the `Idempotency-Key` it was queued with, so the server
  makes it once. If it was deleted elsewhere meanwhile, the retry is dropped
  without an error, together with the changes waiting for it.
- Moves (`before_id`) and the category order are queued like any other
  change. A move whose anchor item is gone, or that names a category deleted
  elsewhere, is retried without that part; an order is refitted to the
  categories the server has.
- While the app is in the foreground it follows the `/api/events`
  WebSocket, so changes made elsewhere (the web app, MCP) show up live. It
  fetches again after every connect, since missed events aren't replayed,
  and 300 ms after the last change event. A dropped socket, or one silent
  for 40 s, reconnects with backoff. Link previews come from it and from
  responses, and are kept with the copy. While a row is dragged, what the
  server sends waits until the drop.

## Home-screen widget

`ios/CheckcheckWidget/` is a WidgetKit extension (iOS 17+, SwiftUI, since
Flutter can't draw widgets) that shows the open items and checks them off. Its
behaviour and look are specified in "Home-screen widget" in
[`../API.md`](../API.md). `Theme.swift` copies `lib/theme.dart`, the checkbox
and the logo by hand, so a look change in the app has to be made there too.

- It talks to the server itself, through the same four REST calls, and never
  through the app's offline queue, so a tick made on it needs a connection.
- The app copies its server URL and token into a keychain item shared through
  the app group `group.nl.mkopenga.checkcheck` (`ios/Shared/`), over the
  `checkcheck/widget` method channel in `lib/home_widget.dart`. It writes the
  copy on connect and on every start, and deletes it on Disconnect. It also
  asks the widget to reload once a sync has finished.
- The first signed build (`mise run mobile:install`) registers the widget's
  App ID `nl.mkopenga.checkcheck.widget` and the app group in team
  `N65XC23LP9`. Xcode's automatic signing does this, which needs the team's
  Apple account in Xcode → Settings → Accounts.
- To add it on the phone: long-press the home screen, **Edit → Add Widget**,
  then search for CheckCheck. Long-press the widget and choose **Edit Widget**
  to pick a list.

## Adding Android later

The Dart code doesn't branch on `dart:io` `Platform`. Adaptive widgets switch
on `Theme.of(context).platform`, so you don't need to change any Dart code.

```sh
flutter create --platforms=android .
```

Then:

- Add `<uses-permission android:name="android.permission.INTERNET"/>` to
  `android/app/src/main/AndroidManifest.xml`. The template only adds it to
  the debug and profile manifests, so release builds can't reach the server
  without it.
- `flutter_secure_storage` needs `minSdk` 24 or higher, which is Flutter's
  current default.
- The Android emulator reaches the host machine at `http://10.0.2.2:8181`,
  not `localhost`.
