# Cotype manual check (2026-09-25)

Two minutes. You run this yourself, because it needs your keyboard and a real
app in front. The automatic checks (T1 to T5) are in `scripts/acceptance.sh`.

**What changed today:** Cotype now asks the model to keep writing your text
(plain continuation) instead of chatting about it. Suggestions stop at the end
of the line or sentence. Cotype also asks Local Models to load `gemma-it` when
it is cold, and keeps it loaded while you type.

## Before you start (15 s)

1. Look for the Cotype I-beam icon in the menu bar. Click it. The panel says
   completions are on.
2. If the Local Models icon shows `gemma-it` cold, do nothing. Your first pause
   in typing loads it. Suggestions start about 3 s later.

## Notes (45 s)

Make a new note. Type each line, then stop typing for a moment.

| Type this | You should see |
|---|---|
| `Let me get back to you by` | Grey text right after the caret, starting with a space, for example ` the end of the day`. Never `bythe`. |
| press **Tab** | One word goes in (` the `). The rest stays grey. |
| press **Option+Tab** | The rest goes in. The grey text is gone. |
| `Thanks for the quick turnar` | Grey `ound` and maybe a few more words, joined to `turnar`. |
| `See you tomorrow.` | Nothing. Cotype waits until you type a space after a full stop. |
| type a space | A new suggestion can appear. |
| `I'll send it` then type ` s` | If the grey text started with ` s`, it gets shorter as you type (type-through). If not, it goes away. |
| any suggestion, then **Esc** | The grey text goes away. Nothing is inserted. |

## Helium (30 s)

Open any page with a text box (a GitHub comment box or a Gmail draft works).

1. Type `Could you send me the` and pause. Grey text appears at the caret, in
   the page's own font size.
2. Press **Tab**. The word goes into the page, not somewhere else.
3. Click into the page's address bar. Any grey text disappears.

## Slack (30 s)

Open a DM to yourself. Do not send anything.

1. Type `I'll have the deck ready by` and pause. Grey text appears.
2. Press **Tab**. One word goes in. Slack does not jump focus.
3. Press **Esc**, then delete the draft.

## If you see nothing

Open Terminal and run:

```
log stream --level info --predicate 'subsystem == "com.tristan.cotype"'
```

Type in the app again. Every time Cotype shows nothing, it prints one reason
line (no text content). The common reasons:

| Reason line | Meaning | Fix |
|---|---|---|
| `fail: gemma-it is loading in Local Models...` | The model was cold; Cotype asked for it. | Wait 3 s, type again. |
| `fail: Local Models is not reachable...` | The daemon is down. | Start Local Models. |
| `skip: disabled for <app>` | Cotype is off for this app. | Cotype Settings, Apps. |
| `gate: gated(...)` | Password field or excluded app. | Expected. |
| `hide: no usable caret geometry` | The app did not report where the caret is. | Note the app name; tell Claude. |
| `none: no usable suggestion` | The model had nothing that fit. | Expected sometimes. |
| `dismiss: typed text did not match the ghost` | You typed past the suggestion. | Expected. |

## Record the result

For each app, write pass or fail and the reason line if it failed. That is the
input for the next fix.

Note: your settings turn Cotype on for Ghostty (Apps settings). In the saved
metrics, Ghostty caused 11,448 of 16,971 failed suggestions. Terminals are off
by default for a reason; consider turning Ghostty off again.
