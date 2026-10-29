# CalDAV Tasks — agent handover

DMS/Quickshell plugin, QML UI and Python CalDAV backend. No build step.

## Project map

| File | Responsibility |
|---|---|
| `plugin.json` | Plugin manifest; keep ID/name consistent with the registry entry |
| `CalDAVTasks.qml` | Grouped view, counts, priority sorting, folds, explicit action targets, refresh and IPC |
| `UI/TaskCard.qml`, `UI/IconAction.qml` | Reusable themed cards and accessible icon actions |
| `Settings.qml` | Direct CalDAV / Evolution connection editor |
| `Backend.qml` | One asynchronous Python process per JSON request, stdin/stdout protocol |
| `backend.py` | Private connection store, CalDAV discovery and mutations, provider dispatch |
| `evolution_provider.py` | EDS Source Registry / ECal TASKS integration |
| `task_model.py` | Shared validation, stable scoped IDs and VTODO mapping |
| `tests/` | Unit tests, disposable Radicale/EDS integrations, guarded real-DMS QML smoke |
| `assets/screenshot.jpg` | User-supplied screenshot embedded in the README |

## Runtime and data

- Python 3.10+ with `caldav>=3.6,<4` is required. The QML bridge invokes `python3`
  from the shell's PATH; installing into an unrelated venv does not configure DMS.
- Evolution is optional: system Python needs PyGObject and introspection namespaces
  `EDataServer-1.2`, `ECal-2.0`, `ICalGLib-3.0`, plus the user D-Bus EDS services.
- Connections: `$XDG_CONFIG_HOME/dms-caldav-tasks/connections.json` (0600, atomic
  writes). Direct passwords are unencrypted; Evolution connections save metadata only.
- Presentation folds: DMS PluginService state, key `collapsedGroups`, arrays of
  stable source/list IDs. Do not store this state in the source repository.
- CalDAV lists are collections advertising VTODO; EDS lists are enabled task
  sources. EDS owns credentials, cached data and remote/offline synchronization.
- Remote data can take about two seconds to populate. Use `caldavTasks status`
  and wait for `loading: false`; do not assess an initial empty popout as data loss.

## Commands and verification

```sh
python3 -m unittest discover -s tests -v
python3 tests/smoke.py
dms ipc call caldavTasks status
dms ipc call plugins reload caldavTasks
```

- For all integrations, use a disposable venv with `--system-site-packages` (so
  native GI remains visible), install `requirements.txt` and `radicale`, then run
  unittest with that venv's interpreter. Radicale/EDS tests skip when unavailable.
- QML smoke requires installed DMS and a running Wayland session. It uses synthetic
  data and mocked plugin-state persistence, tests grouped rendering, action target
  isolation, independent/persistent folds, drafts and open-task priority sorting.
- Read-only IPC: `refresh`, `list`, `count`, `status`. `list` includes all sources,
  not only groups currently expanded or visible in the filter.
- Adding new implicit QML files to a running engine can hit a directory-type cache.
  Keep reusable UI in the explicitly imported `UI/` directory. If reload fails,
  inspect DMS logs and preserve the user's existing shell/configuration.

## Behavior and safety invariants

- Plugin ID and IPC target are `caldavTasks`, distinct from `tasks` and `dankTodo`.
- UI derives from Dank Todo; retain MIT attribution. Use DMS Theme and widget primitives.
- Use DankListView's built-in scrollbar, DankToggle's controlled `toggled` signal,
  and DankTooltipV2's `show(text, item)` / `hide()` API. Do not reintroduce raw Qt
  checkbox/tooltip/scrollbar styling. Derive UI dimensions from Theme icon/font/spacing
  tokens and content implicit sizes, not fixed pixel constants.
- Credentials must not enter argv, logs, git or `plugin_settings.json`.
- Config is `~/.config/dms-caldav-tasks/connections.json`, atomically written mode 0600.
- Only operate on VTODO resources. Never delete mixed event/task collections.
- `evolution_provider.py` uses EDS/ECal TASKS clients, never extracts GOA secrets.
  EDS owns auth/cache/offline sync; only provider metadata is saved in our config.
- EDS list-management operations are intentionally rejected: do not equate removing
  an ESource with deleting a remote list. Honor ECal read-only status for task writes.
- EDS integration tests MUST use a private D-Bus session and disposable HOME/XDG
  directories. Never run `tests/worker_eds.py` in the live user session.
- Do not exercise CRUD against the user's remote accounts without authorization;
  use the disposable Radicale integration tests.
- `get_icalendar_component()` returns a COPY in current caldav versions. Use
  `edit_icalendar_component()` and then save for changes.
- Do not fake local-only success for remote mutations. Refresh after successful writes.
- Backend tests: `python3 -m unittest discover -s tests -v` (Radicale optional).
- QML smoke: `python3 tests/smoke.py` (requires Wayland and installed DMS).
- Keep existing installed widgets untouched unless the user asks to replace them.
- All enabled connections/lists are displayed together in a flat grouped ListView.
  Do not reintroduce a globally active source/list. Every mutation and transient
  composer must carry its own explicit sourceId/listId; counts/filters span all lists.
- Connection/list folds are independent presentation state, saved with DMS's plugin
  state API under `collapsedGroups` using stable IDs. Never let collapsing affect
  synchronization, counts, filters, credentials, or transient drafts. Preserve child
  folds on parent expansion; explicit compose actions may expand their target.
- Sort providers by TOTAL incomplete tasks across their lists, and lists by their
  own incomplete counts, descending. Use alphabetical/stable-ID tie breakers.
  Sorting must ignore display filters and collapse state and must not mutate raw arrays.
- Previews/screenshots MUST use light mode, DMS_DISABLE_MATUGEN=1, private D-Bus,
  GSETTINGS_BACKEND=memory, and temporary HOME/XDG/runtime paths. Temporary config
  alone is NOT isolation: a second DMS instance can change the live desktop theme.
  Use the guarded smoke launcher, never a default-theme secondary shell on the live bus.

## Known scope limits

- Title edits only; due dates and unknown iCalendar metadata must survive edits.
- Direct CalDAV recurring completion is blocked. EDS blocks all recurring-task
  mutations. Do not implement approximate month/year recurrence arithmetic.
- EDS source creation/rename/removal is not remote list CRUD. Those list-management
  actions stay disabled until backend-specific semantics are safely implemented.
- No drag ordering, cross-list moves, direct OAuth/keyring integration or push sync.
- The helper is request-based, not a persistent daemon. Failed sources/lists keep
  last-good data in QML memory; unavailable lists must not silently allow writes.
- ECal `connect_sync` uses `0xFFFFFFFF` (guint32(-1)) to skip waiting for remote
  authentication. `0` is not equivalent; individual calls have cancellable timeouts.

## Publication

- Repository: `https://github.com/brunofin/dms-caldav-tasks`, MIT, with Dank Todo UI
  attribution retained. `registry-entry.json` mirrors the registry submission.
- DMS's old registry URL redirects to `duxlabs-dev/dux-plugin-registry`; submit
  `plugins/brunofin-caldav-tasks.json`, not generated README/index files.
- Run upstream schema/link validators. Its contribution rules require a human-
  written PR description and meaningful AI-assistance disclosure: ask the maintainer
  for their own PR text instead of generating it. Use their requested GitHub account.
