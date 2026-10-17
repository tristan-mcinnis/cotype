# Cotype Privacy & Data

Cotype is a local completion app for macOS. It runs an on-device model and
reads the focused editor text to offer inline completions. This document
describes exactly what Cotype reads, what it stores, where it stores it, and
how it behaves on the network. It reflects the current implementation.

## What Cotype reads

- After you pause while typing, or when you use the manual trigger, Cotype reads
  the text in the focused editor around the caret through the macOS
  **Accessibility** API. It captures the text before the caret (prefix) and,
  when available, the text after the caret (suffix). If you enable "include
  selected text", it also captures the selected text. Accessibility provides
  this through a read of the **focused editor's value**. Cotype then bounds the
  prefix and suffix to the text nearest the caret before building the local
  model prompt.
- Only if you turn on **Visible active-window text** (Settings, Context; off
  by default), Cotype also reads up to 800 characters of visible, non-editable
  text from the same active window through Accessibility. This lets a short reply use
  nearby names, dates, identifiers, and conversation/document context. Editable
  fields are excluded, secure/protected subtrees are skipped, and the bounded
  window context exists only in memory for the current prompt: it is never
  written to feedback samples, metrics, logs, or exports.
- Cotype also captures a short, non-content **identity fingerprint** of the
  focused element and its window, the caret/selection range, and the app's
  bundle identifier. Immediately before rendering or insertion, it uses this
  identity to detect a changed app, window, field, caret, or selection. The
  fingerprint holds no text and is used only for this safety check.
- Cotype reads only what is needed from the current field and active window to
  predict the next few words and keep insertion safe. It does not read your
  whole disk, background apps, or screenshots, and it
  does not use your clipboard as completion context. The single clipboard
  interaction is the pasteboard fallback below, which reads/snapshots the
  current clipboard contents **solely to restore them afterward** — no content
  from your clipboard is ever read for context, stored, or sent anywhere.

## How Cotype inserts a completion

Cotype never auto-inserts: it always previews a candidate first, and Accept
inserts once into the app that was focused when you triggered it.

- **Direct Accessibility insertion (preferred).** For a normal, short
  completion, Cotype writes the text directly into the focused editor through
  the Accessibility API by replacing the editor's **selected text** at the caret
  (it sets only the selected-text range, never the entire document value), so it
  does not rewrite or re-format the rest of the buffer. No clipboard is
  involved. The focused field/window/app identity is re-verified immediately
  before this write; if it cannot be re-read, or you switched to another field,
  window, or app, Cotype cancels and writes nothing.
- **Clipboard fallback (incompatible or long fields).** When the focused editor
  cannot accept a direct Accessibility write, or the completion is long, Cotype
  temporarily places the completion on the clipboard and posts a **Command-V**
  keypress into the focused app, then restores your previous clipboard contents.
  It restores the clipboard only if you did **not** copy anything while the
  keypress was landing; if you copied during that brief window, your new copy is
  kept and the completion text is discarded, so you never lose something you
  copied. In the rare case an insertion is cancelled after clearing the
  clipboard, Cotype restores it immediately.
- Because the clipboard is restored only when it is safe, a small residual risk
  remains: if Cotype quits or macOS suspends in the tiny window between placing
  the completion on the clipboard and restoring it, the completion text could
  remain on the clipboard. Cotype prefers direct insertion precisely to avoid
  this path, and it never leaves a stale completion on the clipboard when it can
  avoid it.

## What Cotype never reads or completes

Cotype **fails closed** and never completes or logs in these cases:

- **Secure text fields** (a field with the Accessibility secure subrole, e.g. a
  password field).
- **Protected content** (elements that declare they contain protected content).
- The **built-in sensitive-app denylist** (keychain/password-manager and
  security apps). This list is not user-overridable — even if you toggle an app
  on in App Settings, Cotype will still refuse.
- Apps you explicitly **exclude** in Privacy & Data.
- When the focused text **cannot be read** (Accessibility permission missing or
  no focused element), Cotype declines rather than guessing.
- When the focused editor **cannot be identified** (so Cotype cannot re-verify
  the exact insertion target immediately before rendering or inserting), Cotype
  also declines rather than risk completing or inserting into the wrong field.

If a context is gated, no completion is offered and nothing is written about it.

## What Cotype stores and where

Cotype stores its data in your per-user Application Support folder:

```
~/Library/Application Support/Cotype/
```

### Content samples — `personalization.json`

Prefix + completion text for accepted and dismissed completions, capped to a
strict length (2000 prefix chars, 500 completion chars). These are written
**only when you turn on "Store accepted and dismissed completions"** in
Privacy & Data (off by default). They are newline-delimited and versioned
(schema v2, migrating the legacy `accepted` boolean automatically).

### Aggregate usage metrics — `privacy-metrics.json`

Content-free counts of shown / accepted / dismissed / canceled / failed
completions. These carry **no prefix and no completion text** and are always
kept — even when content logging is off — so the usage summary reflects real
usage without persisting any sensitive content. Counters are bounded (a fixed
number of distinct apps is tracked) and versioned.

### Not-shown reasons — `not-shown.json`

Content-free counts of why a requested completion never appeared (for example
no caret position from the app, or an app turned off), per app bundle
identifier, with the time each reason was last seen. No prefix, completion
text, or window title is stored. "Delete All Data" clears it.

### Privacy config — `privacy-config.json`

Retention choice and your excluded-app list. This is not content; it survives
"Delete All Data" so your preferences are not wiped.

### App overrides — `app-overrides.json`

Per-app enable/disable choices and system-prompt overrides. This file can
contain instructions you write for a specific app.

Cotype restricts all five privacy-data files above to the current macOS account
(owner read/write only, POSIX mode `0600`).

## Retention

You choose one of **Off**, **7 days**, **30 days**, or **Keep until deleted** in
Privacy & Data. Cotype prunes content samples older than the cutoff (when it
records a new sample and on launch). Off removes stored content; aggregate
usage metrics are kept.

## Export

Privacy & Data → **Export stored data** writes a versioned JSON envelope
containing the bounded aggregate metrics and the content-capped samples, so you
can back them up or inspect them.

## Delete All

Privacy & Data → **Delete All Data** permanently removes every content sample
and resets the usage counters, then verifies the files are empty. It does not
reset your retention/exclusion preferences.

## Network behavior

- In normal Local Models mode, Cotype sends the completion prompt over local
  loopback HTTP to the warm model endpoint advertised by the Local Models daemon.
  The control plane defaults to `http://127.0.0.1:8078`; the current `gemma-it`
  endpoint is `http://127.0.0.1:8079`. Cotype rejects non-loopback endpoints, so
  editor content does not leave this Mac.
- Cotype has no analytics or telemetry and makes no internet request containing
  editor, completion, clipboard, or personalization content.
- Local Models owns normal model acquisition. A model download from Cotype occurs
  only if you explicitly select the legacy standalone lane and start it in Setup;
  Cotype verifies that file's SHA-256 digest locally before use.
- If the installed release has an update feed, **Check for Updates** contacts
  that feed. Automatic update checks occur only when you enable them. Cotype
  disables Sparkle's system-profile reporting and automatic downloads. Sparkle
  downloads a signed app archive only after you approve it. Update requests
  contain no editor, completion, clipboard, or personalization data.

## Permissions

- **Accessibility** lets Cotype read the focused editor and bounded visible text
  from its active window, and insert the
  accepted completion (directly, by setting the focused element's value, or via
  the clipboard fallback).
- **Input Monitoring** lets Cotype observe the trigger, accept, and cancel keys.
  Cotype never auto-inserts: it always previews a candidate first, and Accept
  inserts once into the original app.

## Contacts / questions

For privacy concerns, open Cotype → Preferences → About & Updates.
