# CheckCheck API

Single-user. Every endpoint except `GET /api/health` and the `GET /api/events` WebSocket (which signs in with its first message, see Live updates) requires

```
Authorization: Bearer <token>
```

The token is `CHECKCHECK_TOKEN`, or, when that is unset, the one the server generated on first start and stored in `<data dir>/token`.

Clients send `X-Checkcheck-Client: <client id>` on every `/api` request, with a random id they make once per page load or app launch (at most 64 characters; a longer one is ignored). The server only uses it to say in a `changed` event who made the change.

All bodies are JSON. Errors are `{"error": "<message>"}` with status `400` (invalid input), `401` (missing/wrong token), `404` (unknown id), `409` (duplicate category name) or `500`.

## Types

```jsonc
// Category
{ "id": 1, "name": "Groceries", "created_at": "2026-10-01T15:04:05Z", "updated_at": "2026-10-01T15:04:05Z" }

// Item — category_id is null when the item has no category
{ "id": 7, "title": "Milk", "checked": false, "category_id": 1, "link": null, "preview": null, "created_at": "…", "updated_at": "…" }

// Item whose title holds a link the server has fetched (see Link previews)
{ "id": 8, "title": "Read https://example.com/post", "checked": false, "category_id": null,
  "link": "https://example.com/post",
  "preview": { "title": "A post", "description": "…", "image": "https://example.com/og.png", "site_name": "Example", "icon": "https://example.com/favicon.ico" },
  "created_at": "…", "updated_at": "…" }

// DeletedItem (see Recently deleted)
{ "id": 9, "title": "Bread", "checked": true, "created_at": "…", "updated_at": "…", "deleted_at": "2026-10-02T09:15:00Z" }
```

- Timestamps are RFC 3339, UTC.
- `name` and `title` are trimmed; empty after trimming is `400`. Max 100 chars for `name`, 500 for `title`.
- Category names are unique, case-insensitively.

## Endpoints

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/api/health` | – | `200 {"status":"ok"}` (no auth) |
| GET | `/api/categories` | – | `200 [Category]`, in the category order |
| POST | `/api/categories` | `{"name"}` | `201 Category`, placed after the last category (see below) |
| PATCH | `/api/categories/{id}` | `{"name"}` | `200 Category` |
| DELETE | `/api/categories/{id}` | – | `204`; its items become uncategorized |
| GET | `/api/categories/order` | – | `200 {"order": [3, null, 1]}` |
| PUT | `/api/categories/order` | `{"order": [3, null, 1]}` | `200 {"order": [3, null, 1]}` |
| GET | `/api/items` | – | `200 [Item]`, in list order |
| POST | `/api/items` | `{"title", "category_id"?: int\|null}` | `201 Item` (unchecked, at the end of the list order) |
| PATCH | `/api/items/{id}` | any of `{"title", "checked", "category_id", "before_id"}` | `200 Item` |
| DELETE | `/api/items/{id}` | – | `204`; kept 30 days in Recently deleted |
| GET | `/api/items/deleted` | – | `200 [DeletedItem]`, most recently deleted first |
| POST | `/api/items/{id}/restore` | – | `200 Item` (uncategorized, at the end of the list order) |
| GET | `/api/events` | – | `101` WebSocket (see Live updates) |

`POST /api/categories` and `POST /api/items` also take an `Idempotency-Key` header (see Retrying a create).

In `PATCH /api/items/{id}`, an omitted field is left unchanged; `"category_id": null` removes the category. A `category_id` that does not exist is `400`.

The category order is every category id once plus one `null`, which stands for **Uncategorized**: the user can move Uncategorized, but never rename or delete it. A `PUT` that doesn't list exactly that set is `400`. A new category goes directly before Uncategorized when Uncategorized is last, otherwise at the very end; deleting a category leaves the rest of the order as it was. Existing databases are migrated with categories by name, then Uncategorized last.

The list order is one order over all items; clients show each category's (and the checked/unchecked) items in that relative order. `"before_id": <id>` moves the item to directly before that item, `"before_id": null` moves it to the end. A `before_id` that does not exist, or equals the item's own id, is `400`. All fields of one PATCH are applied together, so a drag-and-drop that changes category, checked state and position is a single request. New databases start, and existing ones are migrated, with the order by `created_at`, then `id`.

## Recently deleted

`DELETE /api/items/{id}` keeps the item for 30 days as a deleted item. Nothing but the two endpoints below sees a deleted item: listing leaves it out, and updating it, deleting it again, or moving another item `before_id` it answers as for an id that doesn't exist. 30 days after its `deleted_at` the server erases it; its id is still never handed out again.

`GET /api/items/deleted` lists the items deleted in the last 30 days, most recently deleted first; items deleted in the same second come in list order. `deleted_at` is when it was deleted; the other fields are as they were then.

`POST /api/items/{id}/restore` takes no body and makes the deleted item a normal item again with its title and checked state, uncategorized, at the end of the list order. It is `404` when the id isn't in that list: unknown, not deleted, or erased.

## Link previews

`link` is the first `http://` or `https://` URL in the title (scheme matched case-insensitively), exactly as written there, or `null`. It runs up to the next whitespace, minus trailing `.,;:!?'"` and any closing `)`, `]` or `}` without a matching opener inside the URL, so `(see https://en.wikipedia.org/wiki/Go_(game)).` gives `https://en.wikipedia.org/wiki/Go_(game)`. It must parse as an absolute URL with a host, otherwise the title has no link.

`preview` is what the server found at `link`: `null` while it hasn't looked yet or is still looking, when the page had nothing to show, and whenever `link` is `null`. Each field is optional and omitted when not found; a non-null preview has at least one of `title`, `description` and `image`. `title`, `description` and `site_name` are plain text (entities decoded, whitespace collapsed, at most 300, 1000 and 100 characters); `image` and `icon` are absolute `http(s)` URLs.

Whenever a create, update or list returns an item whose `link` has no result yet, the server fetches it in the background; the response never waits for it. The fetch is a `GET` with a 10 s timeout, at most 5 redirects, and at most 2 MiB read from an HTML response. It takes the `og:` tags (`og:title`, `og:description`, `og:image`/`og:image:secure_url`/`og:image:url`, `og:site_name`), falling back to `twitter:` tags, `<title>` and `<meta name="description">`, and the icon from `<link rel="icon">`/`apple-touch-icon`, else `/favicon.ico`. Relative URLs resolve against the final URL. Results, "nothing found" included, are kept per URL, so the same link is fetched once. A fetch that fails (network error, timeout, non-2xx, not HTML) is retried no sooner than 10 minutes later. Hosts that resolve to loopback, private, link-local or other non-public addresses are never fetched.

When a fetch finds a preview, every connected client gets a `preview` event (see Live updates); a fetch that finds nothing sends none. Previews belong to the URL, not an item: a client shows it on every item whose `link` equals `link`, also when the event arrives before the response that gave that item its link.

## Retrying a create

`POST /api/items` and `POST /api/categories` take an optional `Idempotency-Key: <key>` header, 1 to 100 characters (otherwise `400`), so a client can resend a create whose response it never got without making it twice. The app makes one random key per create and keeps it with the queued change, so retries and restarts resend the same key.

- The first request with a key creates as usual and remembers the key together with what it made.
- A later request to the same endpoint with that key creates nothing and answers `201` with that item or category as it is now, whatever its body says, or `404` when it has been deleted since (Recently deleted included). It sends no `changed` event.
- A request that fails remembers nothing, so it can be resent with the same key, also with a different body.
- Two requests with the same key at the same time make one item: the second waits for the first and answers like a later request.
- Keys are per endpoint (the same key on both names two creates) and are remembered for 30 days.

## Live updates

`GET /api/events` is a WebSocket of JSON text messages. Browsers can't set headers on a WebSocket, so it signs in with its first message instead, which must arrive within 10 s:

```json
{"type":"auth","token":"<token>","client":"<client id>"}
```

`client` is optional and is the client's `X-Checkcheck-Client` id. The server answers `{"type":"ready"}` once it is subscribed, closes with code `4401` when the token is wrong, and with `1008` when the first message isn't a valid `auth` or doesn't arrive in time. The client sends nothing after `auth`; anything it does send closes the socket with `1008`.

The server then sends:

- `{"type":"ready"}`: from now on, every event reaches this socket. Events are never replayed, so a client reloads everything after every `ready`, the first one included: a change made between its last load and the subscription would otherwise go unseen.
- `{"type":"changed","client":"<client id>"}`: something a list endpoint returns changed: an item, a category, the category order or Recently deleted, through the REST API or MCP. A link preview being saved is a `preview` event, not a `changed`. The event has no details; the client reloads. `client` is the `X-Checkcheck-Client` of the request that made the change and is left out when there was none (MCP). A client ignores a `changed` with its own id, as it already has that response. Each write sends one, so **Move all to…** sends one per item: clients reload once no `changed` has come for 300 ms.
- `{"type":"preview","link":"https://example.com/post","preview":{"title":"A post","site_name":"Example"}}`: see Link previews.
- `{"type":"ping"}` every 15 s, so proxies keep an idle socket open and clients can tell a dead one: a client that has heard nothing for 40 s closes the socket and reconnects. A phone that moves from Wi-Fi to mobile data is the usual case.

A client that falls behind is disconnected, and the server closes every socket with `1001` when it shuts down. On any close but `4401`, or a connection that fails, the client reconnects after 1 s, doubling up to 30 s, back to 1 s after a `ready`. A `4401` signs the client out.

A reload must not overwrite the client's own writes with an older state: when one of its writes was in flight while the reload's requests ran, the web app drops that reload and runs it again once its writes are done. The app's fetch already waits for its queue of changes.

Behind a reverse proxy, `/api/events` needs WebSocket upgrades passed through (nginx: `proxy_http_version 1.1`, `proxy_set_header Upgrade $http_upgrade` and `proxy_set_header Connection "upgrade"`). Without them the clients still work, but only catch up when they come back to the foreground.

## MCP

Streamable HTTP at exactly `/mcp` (no trailing slash), same bearer token. For clients that can't send headers, such as Claude's custom connectors (claude.ai, Claude Desktop and the Claude mobile app) or ChatGPT, the same server is also at `/mcp/<percent-encoded token>` with no `Authorization` header. A wrong token there is `401` too. The token then ends up in URLs (and so in logs), so the header form is preferred where a client supports it. `/api` only accepts the header, apart from the WebSocket's `auth` message. A `notifications/initialized` POST is answered `200` with a `notifications/tools/list_changed` notification rather than an empty `202`, to get Claude's connectors to refresh their tool list. Tools:

`list_categories`, `create_category`, `rename_category`, `delete_category`, `list_items` (in list order; optional `category_id` filter), `add_items` (one or more items in one call, each with its own optional `category_id`, added in order at the end of the list; if one is invalid, none are added; sends one `changed`), `set_item_checked`, `rename_item`, `move_item` (omitted/null `category_id` = uncategorized), `delete_items` (one or more item ids in one call, into Recently deleted like the REST call; if one is unknown or already deleted, none are deleted; sends one `changed`).

The webapp's **Connect AI** dialog (web only) gives these steps with the server URL and token filled in:

- **Claude** (web, desktop and mobile): on claude.ai or in Claude Desktop, **Customize → Connectors → Add custom connector**, URL `https://<host>/mcp/<token>`, authentication **No sign-in**. It then also works in the Claude mobile app. Claude connects from Anthropic's cloud, so this needs a public HTTPS address.
- **Claude Desktop on a server that isn't public**: its config file only starts local commands, so it connects through the `mcp-remote` bridge, which needs Node.js. Add this to `claude_desktop_config.json` (**Settings → Developer → Edit Config**) and restart the app:
  ```json
  {
    "mcpServers": {
      "checkcheck": {
        "command": "npx",
        "args": ["-y", "mcp-remote@0.14.3", "https://<host>/mcp", "--header", "Authorization:${AUTH_HEADER}"],
        "env": { "AUTH_HEADER": "Bearer <token>" }
      }
    }
  }
  ```
  The header value goes in `env` because Claude Desktop on Windows splits args on spaces; mcp-remote expands `${AUTH_HEADER}` itself. A plain-`http` URL to anything but `localhost`/`127.0.0.1` also needs `"--allow-http"`.
- **Claude Code**: `claude mcp add --transport http --scope user checkcheck https://<host>/mcp --header "Authorization: Bearer <token>"`. Keep `--header` last; it takes several values.
- **Other clients** (Cursor, VS Code, Codex, Gemini CLI, …): the URL plus the `Authorization: Bearer <token>` header. Clients that can't set headers, such as ChatGPT, use `/mcp/<token>`.

## Client display conventions (web + mobile)

The webapp and the mobile app both follow these. Where the web differs between pointer and touch devices, the app follows touch.

- One page, no filters. Under the top bar a summary: `N to do · M done`.
- The top bar is the logo and **CheckCheck** wordmark, then **Connect phone**, **Connect AI** (web only) and **Sign out** (the app's **Disconnect**, which also deletes the offline copy). Both ask first. Narrower than 40rem they are icon buttons; narrower than 352px the wordmark is hidden too, so the icons stay on screen.
- One section per category, Uncategorized included, in the category order and nowhere else: a section never moves because it gained or lost items, only when the order is changed in the categories dialog. Empty sections still show, so they can be typed into. With no categories at all there is a single section without a heading.
- A section is its unchecked items, an **Add item** line, then a **Done** sub-list of its checked items (dimmed, not struck through), each in list order. The Done sub-list is hidden while empty, except during a drag.
- A section heading and a Done heading end in a ⋯ button in a darker purple than the headings, centred over the rows' drag handles, while they have items; it opens a menu. The section's menu has **Mark all as done** (disabled while nothing is open), **Move all to…** (only while there are categories) and **Delete all**, which deletes the whole section, Done included. The Done menu has **Unmark all as done** and **Delete all**. A Delete all that includes items not done yet first asks for confirmation and says how many aren't done; one of only done items doesn't ask. With no categories, the single section’s ⋯ sits at the right end of the summary line. The buttons hide during a drag.
- **Move all to…** opens the **Move all items** dialog. Its text is `Choose a category for the 5 items in “Groceries”.` (`for the item in` when there is one), then it lists every other section in the category order, Uncategorized included, as rows that look like the categories dialog's (the name with its item count, Uncategorized's name dimmed, no buttons or handle). Only that list scrolls; the title, text and **Cancel** stay put. Tapping a row closes the dialog and moves every item that is in the section at that moment, open and Done, into that category: they keep their checked state and their order, and land at the end of its open and Done lists. That is one `PATCH` per item, in list order, each with the new `category_id` and `"before_id": null`, and they must reach the server in that order. Cancel, Escape or the backdrop moves nothing. The menu icon is Material `drive_file_move` (outlined).
- Below the last section, a **Manage categories** button opens the categories dialog, and next to it (wrapping below it when there is no room) a **Recently deleted** button opens that page.
- An item's title is always an editable field that saves itself shortly after typing stops (and on blur/Enter); an empty title is never sent. The Add item line creates the item the same way, in that section's category.
- A list's titles and its Add item line are lines in a text editor. The phone keyboard shows a return key, not done. Enter in a title goes to the end of the line below (from the last open item, the Add item line), or leaves the field on the list's last line; in the Add item line it finishes the entry and stays put. Backspace in an empty line goes to the end of the line above (an empty title with none above leaves the field). ArrowUp at a line's start goes to the start of the line above, ArrowDown at its end to the end of the line below; either also works with all its text selected. Lines never cross into another list, and rows on their way out are skipped. Leaving a title empty deletes the item, like its delete button. iOS's own keyboard sends nothing for Backspace in an empty field, so the app does that only with a hardware keyboard.
- Checks and deletes within 500ms of each other play all motion at double speed, until 500ms pass without another.
- Pasting text with several lines into an item's title or an Add item line doesn't change that field; it opens the **Add items** page instead. The pasted lines are trimmed, empty ones are left out, and each is cut to the 500-character title limit; a paste with fewer than two lines left after that pastes as before (line breaks become spaces). Then duplicates are left out, ignoring case, keeping the first. The page is like Recently deleted: its own page under the same top bar (on the web at `/add`, with the lines, where they go and which are checked kept in the history entry, so reload keeps the page and back leaves it; in the app a pushed screen, so the iOS back swipe leaves it). It starts with a head line: a back button, then the title **Add items**. Under it, where the summary goes, says where the items go (`Choose the lines to add to “Groceries”.`, `Choose the lines to add.` without categories, `Choose the lines to add below “Milk”.` for an item's title), followed, when duplicates were left out, by `1 duplicate line was left out.` or `N duplicate lines were left out.` Then one list of the lines in paste order, as rows like the main list's (same background, corners, width and wrapping title text), each a checkbox and the line, all checked to start; tapping anywhere on a row toggles it. A bar pinned to the bottom of the screen, above the page as it scrolls, holds **Cancel** and **OK**, right-aligned. Cancel or back adds nothing; **OK**, disabled while nothing is checked, goes back to the list and adds the checked lines as items in their order, springing in. From an Add item line they go at the end of that section's open list. From an item's title they go directly after that item in the list order, with its category and checked state, so they land under it in the list it was pasted in; if that item is gone by then, they go at the end of the list it was in.
- A row is a checkbox, the title, delete and a drag handle at the right end; there is no category control, an item changes category by being dragged.
- An item with a `preview` shows it under its title, inside the row, from the title text's start to the row's right edge (under delete and the handle too), with no background of its own. It always shows one line that links to the page (a new tab on the web, the browser in the app): the site icon, the site name (or the link's host without `www.`) and then the page title, cut off with an ellipsis. When there is more, a description and/or an image, a chevron at the end of that line expands it, starting collapsed. Expanded, the description (at most 3 lines) goes below the line; with an image, the image takes the line's start position and the line and description sit to its right, unless the preview is too narrow for both side by side, in which case it is the line, then the image, then the description. Expanded stays per item until the page reloads (in the app, until it restarts). A preview that arrives springs in and pushes the rows below down; expanding and collapsing spring too. Images and icons that fail to load are hidden. A pasted title is saved right away instead of after the typing pause, so its preview starts loading at once.
- Items are dragged by that handle: within a list to reorder, between a section's open and Done lists to (un)check, and between sections to change category. While dragging, every section shows its Done list and room to drop into, and a circle pops up at the bottom left of the screen: dropping an item on it asks for a category name, then creates that category (or uses the existing one with that name, ignoring case) and moves the item into it. Cancelling puts the item back.
- Pointer devices reveal delete and the handle on hover/focus, and highlight the title field while the row is hovered; touch devices always show them and never highlight.
- The categories dialog lists the category order, Uncategorized included, each row draggable by a handle on the right to reorder. Uncategorized has no rename or delete. While a name is being edited, its delete button is replaced by an apply (check) button; Enter and leaving the field apply too, Escape cancels.
- Deleting a category asks for confirmation and says its items become uncategorized.
- **Recently deleted** is a page of its own under the same top bar: on the web at `/deleted`, so browser back and reload work; in the app a pushed screen, so the iOS back swipe works. It starts with a head line: a back button, then the title **Recently deleted**. Under it, where the summary goes on the main page, `Deleted items are kept for 30 days`. Then the deleted items grouped by the local calendar day they were deleted on, newest day first, each group headed `Today`, `Yesterday` or the date as `Monday 28 September` (`Monday 28 September 2025` when it isn't this year), in English on both clients. In a group the rows keep the server's order. A row is the title, read-only and wrapping, dimmed while checked like the Done list, and a restore button at the right end where the main rows have their handle. Restoring springs the row out like a deletion, the group heading with its last row, and the item is on the main page in Uncategorized (the one section, without categories) at once, at the end of its open or Done list. With nothing deleted the page says `Nothing deleted in the last 30 days`. Icons (Material, outlined): `auto_delete` on the Recently deleted button, `arrow_back` for back, `restore_from_trash` on the rows.
- The app's offline copy includes the deleted items: the page shows at once, an item deleted on the phone is on it before the server hears about it, and restoring is a change like any other (shown at once, queued, replayed). An item created and deleted before it reached the server never existed there, so it isn't kept.

## Home-screen widget (iOS 17+, app only)

- One widget, **CheckCheck**, in the small, medium and large sizes. Editing it offers **List**: **All lists** (the default) or one section, Uncategorized included, offered in the category order. A list that has since been deleted shows as all lists.
- It talks to the server itself, not through the app's offline copy, so ticks made on it need a connection. It signs in with a copy of the app's server URL and token in a keychain item shared through the app group `group.nl.mkopenga.checkcheck`; the app writes the copy on connect and on every start, and deletes it on Disconnect. It loads `GET /api/categories`, `GET /api/categories/order` and `GET /api/items`, and keeps its last load in the app group, so while the server can't be reached it shows the last list it saw.
- It looks like the app's main page scaled down, so that more items fit: the `surface` background with 12px margins (in place of iOS's own content margins) and no head line, logo or summary. It shows the open items only, in list order, as the app's rows (`surface-container`, 2px apart, 10px outer and 4px inner corners) but compact: 26px high, a 16px checkbox, then the title in 14px type on one line, cut off with an ellipsis. With all lists and categories, each section that has open items gets its heading over its rows (the app's section heading at 12px), in the category order; sections without open items are left out. One list gets its own name as that heading. Rows that don't fit are left out, and a last line says `+N more`. With nothing open: the logo and `Nothing to do`.
- Tapping a checkbox sends `PATCH /api/items/{id}` with `{"checked": true}`. Once that succeeds, the box springs into the checked circle and the title dims like a Done row; a second later the row springs out and the rows below move up. When it fails (no connection, server down) the row stays as it was. Tapping anywhere else opens the app.
- Not connected: the logo and `Open CheckCheck to connect`. Server unreachable with no kept list: the logo and `Couldn't load your checklist`.
- It reloads every 15 minutes (iOS may wait longer), after a tick, and when the app has sent its changes and loaded the list.

## Connect-a-phone QR code

The webapp and the app both show a QR code under **Connect phone**. The app's copy lets you set up a second phone from the first. The code encodes a single URI:

```
checkcheck://connect?server=<percent-encoded base URL>&token=<percent-encoded token>
```

e.g. `checkcheck://connect?server=https%3A%2F%2Fcheck.example.com&token=3f9c…`. `server` is the base URL with no trailing slash and no `/api`. The mobile app scans it (or accepts it pasted into the server field) and connects with both values. Pasting the token signs in at once: on the web's sign-in, and in the app once the server field is filled in.

## Shared look: Material 3 Expressive, purple

- Colors come from seed `#6750A4` with the **vibrant** scheme variant (the `expressive` variant would shift the seed to teal). Flutter: `ColorScheme.fromSeed(seedColor: Color(0xFF6750A4), dynamicSchemeVariant: DynamicSchemeVariant.vibrant, brightness: …)`. The web uses the same roles as `--md-sys-color-*` CSS tokens generated from that seed and variant.
- Light/dark follows the system setting only. There is no theme toggle anywhere in the UI.
- Type is Roboto Flex (variable: `wght`, `wdth`, `opsz`). The web loads it from Google Fonts; the app bundles it in `mobile/assets/fonts/`. Sizes, weights and widths follow `server/web/src/styles.css`, and `mobile/lib/theme.dart` mirrors them.
- The app mirrors the webapp's phone layout (see the display conventions above). Connect phone, categories and confirmations are dialogs.
- Motion is the same in both: the web's springs and drag constants (`server/web/src/motion.ts`, `drag.ts`) are ported one to one in `mobile/lib/screens/spring.dart`, `layout_motion.dart` and `list_drag.dart`. Change both together.
- The Connect phone QR code (ECC M) sits straight on a square, full-width `primary-fixed` panel (`#e9ddff`, 28px corners) with a 3-module quiet zone, its modules in `on-primary-fixed-variant` (`#5400cc`). Fixed roles keep it dark-on-light in both themes, which scanners need. While the server URL is invalid the same panel shows the placeholder text instead, so the dialog keeps its size. Modules merge with their side neighbours. At each grid corner, a dark module's corner is rounded (radius 0.35 module) only when the other three modules around it are light; a light module's corner gets an inverted fillet of the same radius when both its side neighbours at that corner are dark, which joins diagonal neighbours and smooths inside corners.
