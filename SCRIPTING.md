# Scripting Irctell

> **Status: implemented,** protocol version 1. Scripts are set up in
> Network › Scripts…. Where the implementation differs from or fills in
> this text, [§18](#18-implementation-notes) says how.

Irctell can start programs of your own — a bash script, a Python program,
anything executable — when something happens on IRC, and let them answer.
They talk to Irctell through their standard input and output, so any language
works.

- [1. Concepts](#1-concepts)
- [2. Defining a script](#2-defining-a-script)
- [3. Triggers](#3-triggers)
- [4. The text protocol](#4-the-text-protocol)
- [5. The JSON Lines protocol](#5-the-json-lines-protocol)
- [6. Events: Irctell → script](#6-events-irctell--script)
- [7. Commands: script → Irctell](#7-commands-script--irctell)
- [8. Queries: script asks, Irctell answers](#8-queries-script-asks-irctell-answers)
- [9. Permissions](#9-permissions)
- [10. Limits](#10-limits)
- [11. Lifecycle](#11-lifecycle)
- [12. Environment variables](#12-environment-variables)
- [13. Logging and debugging](#13-logging-and-debugging)
- [14. Security](#14-security)
- [15. Examples](#15-examples)
- [16. Mac App Store edition](#16-mac-app-store-edition)
- [17. Versioning](#17-versioning)
- [18. Implementation notes](#18-implementation-notes)

---

## 1. Concepts

A **script** is a program you register in Irctell's **Scripts** window
(Network › Scripts…). Each one has:

|                 |                                                                                                                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Triggers**    | What starts it, or what it is told about: a private message, a line in certain channels, a timer, `/run`… ([§3](#3-triggers))                                                              |
| **Mode**        | **One-shot**: started for each event, answers, exits. **Service**: started once, keeps running, gets every matching event and answers whenever it likes. ([§11](#11-lifecycle))            |
| **Protocol**    | **Text**: plain lines, for the simplest scripts ([§4](#4-the-text-protocol)). **JSON Lines**: one JSON object per line, with everything Irctell offers ([§5](#5-the-json-lines-protocol)). |
| **Permissions** | What it may do: everything by default, restricted as you choose ([§9](#9-permissions)).                                                                                                    |

```
 IRC ──▶ Irctell ──event──▶ trigger matches? ──▶ script (stdin)
                                                     │
 IRC ◀── Irctell ◀──────── command / reply ◀──── script (stdout)
                                                 script (stderr) ──▶ Irctell Log
```

Two simple rules hold everywhere:

1. **Output goes back where the event came from**, unless the script names
   another target.
2. **IRC text is data, never code.** It reaches a script on standard input or
   in an environment variable, never inside a command line Irctell builds. A
   message reading `; rm -rf ~` stays harmless text.

---

## 2. Defining a script

Scripts are defined in the Scripts window and kept in Irctell's settings; the
programs themselves usually live in `~/.irctell/scripts/`. Each profile has
its own scripts: in another profile the folder is
`~/.irctell/profiles/NAME/scripts/`, and so are the other paths below. A
definition, as stored:

```json
{
  "id": "3F2C…",
  "name": "Dice",
  "enabled": true,
  "command": ["/usr/bin/python3", "~/.irctell/scripts/dice.py"],
  "directory": "~/.irctell/scripts",
  "environment": {"DICE_MAX": "100"},
  "mode": "one-shot",
  "protocol": "text",
  "triggers": [
    {"on": "message", "networks": ["Libera.Chat"], "channels": "#delta*", "text": "^!roll\\b"}
  ],
  "permissions": {},
  "timeout": 10
}
```

| Field           | Meaning                                                                                                                   | Default              |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `name`          | Shown in the Scripts window, menus, logs; used by `/run`. Unique.                                                         | —                    |
| `enabled`       | Off: no trigger starts it, a running service is stopped.                                                                  | `true`               |
| `command`       | The program and its arguments. Not run through a shell: use `["/bin/bash", "-c", "…"]` for shell syntax. `~` is expanded. | —                    |
| `directory`     | The working directory.                                                                                                    | the profile's `scripts` folder |
| `environment`   | Variables added to those of [§12](#12-environment-variables).                                                             | none                 |
| `mode`          | `one-shot` or `service`.                                                                                                  | `one-shot`           |
| `protocol`      | `text` or `json`.                                                                                                         | `text`               |
| `triggers`      | A list of triggers ([§3](#3-triggers)); any one of them matching is enough.                                               | none                 |
| `permissions`   | Restrictions ([§9](#9-permissions)); empty: everything allowed.                                                           | none                 |
| `timeout`       | One-shot only: seconds before it is stopped.                                                                              | `10`                 |
| `max_instances` | One-shot only: how many may run at once; further events wait.                                                             | `4`                  |
| `restart`       | Service only: `always`, `on-failure`, `never`.                                                                            | `on-failure`         |

---

## 3. Triggers

A trigger names an event (`on`) and optional **filters**; an event starts or
reaches the script when every filter given matches.

### 3.1 Filters, common to all triggers

| Filter      | Matches                                                                                                                 | Example                                |
| ----------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `networks`  | Network names, or their IDs.                                                                                            | `["Libera.Chat", "OFTC"]`              |
| `channels`  | Channel patterns: `*` anything, `?` one character, several separated by commas; the `#` may be left out. Ignoring case. | `"#delta*, #echo"`                     |
| `nicks`     | Patterns for the nick the event is from.                                                                                | `"bob, alice*"`                        |
| `text`      | A regular expression on the line's text, formatting codes removed, ignoring case.                                       | `"^!roll\\s+(\\d+)d(\\d+)"`            |
| `not_nicks` | Patterns for nicks to leave out.                                                                                        | `"*bot, ChanServ"`                     |
| `lines`     | Whose lines: `"others"`, `"mine"` or `"all"`. Lines a script sends never trigger scripts, so a script cannot answer itself. | `"others"` for text events, `"all"` for the rest |
| `self`      | The older form of `lines`: `true` for `"mine"`, `false` for `"others"`.                                                  | —                                      |
| `ignored`   | Also lines from nicks you ignore.                                                                                       | `false`                                |

### 3.2 Events that can trigger a script

| `on`                   | When                                                                                                              | Filters that apply                                                  |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `message`              | A message in a channel.                                                                                           | all                                                                 |
| `action`               | A `/me` in a channel.                                                                                             | all                                                                 |
| `notice`               | A notice in a channel, or from a user or service to you.                                                          | all                                                                 |
| `private_message`      | A message or `/me` to you in a private chat.                                                                      | `networks`, `nicks`, `text`, `not_nicks`, `ignored`                 |
| `new_private_chat`     | The first message of a private conversation: none before, or none for 30 minutes (the same rule as auto replies). | as `private_message`                                                |
| `mention`              | A line mentioning you or a highlight word, in a channel.                                                          | all                                                                 |
| `join`                 | Someone joins a channel.                                                                                          | `networks`, `channels`, `nicks`, `self`                             |
| `part`                 | Someone leaves a channel.                                                                                         | as `join`                                                           |
| `quit`                 | Someone quits IRC (in a channel you share).                                                                       | `networks`, `nicks`                                                 |
| `kick`                 | Someone is kicked from a channel.                                                                                 | `networks`, `channels`, `nicks` (the kicked one)                    |
| `nick`                 | Someone changes nick.                                                                                             | `networks`, `nicks` (the old nick)                                  |
| `topic`                | A channel's topic is set or changed.                                                                              | `networks`, `channels`, `nicks`, `text`                             |
| `mode`                 | A channel or user mode changes.                                                                                   | `networks`, `channels`, `nicks`, `text` (the mode string)           |
| `invite`               | You are invited to a channel.                                                                                     | `networks`, `channels`, `nicks`                                     |
| `ctcp`                 | A CTCP query to you, other than `ACTION` (Irctell answers VERSION, PING, TIME itself).                            | `networks`, `nicks`, `text` (the CTCP command and argument)         |
| `memo`                 | A new memo arrives in your MemoServ inbox.                                                                        | `networks`, `nicks` (the sender)                                    |
| `connect`              | Logged in to a network.                                                                                           | `networks`                                                          |
| `disconnect`           | A network's connection is lost or closed.                                                                         | `networks`                                                          |
| `away` / `back`        | You are marked away, or back, on a network.                                                                       | `networks`                                                          |
| `timer`                | On a schedule: `"every": "10m"` (s, m, h, d), or `"at": "08:30"` daily, local time.                               | `networks` (the event is sent once, without one when none is given) |
| `startup` / `shutdown` | Irctell starts, or is quitting (a short time to answer).                                                          | —                                                                   |
| `run`                  | You type `/run NAME [arguments]` in a conversation.                                                               | —                                                                   |
| `nick_action`          | You pick it in a nick's Actions menu (it is listed there when it has this trigger).                               | `channels` (where it is offered)                                    |
| `menu`                 | You pick it in the Scripts menu or the Scripts window's Run button.                                               | —                                                                   |

A **service** usually has no trigger to start it: it is started when Irctell
starts (or when the first network connects, with a `connect` trigger), and its
triggers say which events it is sent.

---

## 4. The text protocol

For scripts that should not have to deal with JSON. A one-shot text script is
started once per event:

### 4.1 Input

- **Environment variables** with the event's details ([§12](#12-environment-variables)):
  `IRCTELL_EVENT`, `IRCTELL_NICK`, `IRCTELL_CHANNEL`, `IRCTELL_TEXT`, …
- **Arguments**: for `run`, the words typed after the name (`/run dice 2d6`
  gives `2d6`); for `text` triggers with groups, the groups of the regular
  expression, in order. Otherwise none.
- **Standard input**: the event's text, one line, then closed. A service in
  text mode gets each event's text as one line, as `NICK CHANNEL TEXT`
  separated by tabs.

### 4.2 Output

Each line the script writes is one of:

| The line       | Does                                                                                                                                               |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `text`         | Sent as a message to where the event came from: the channel, or the private chat. For `run`, `menu` and `timer` events: the conversation in front. |
| `/command …`   | Run as if typed in that conversation: `/msg Data !view bob`, `/me waves`, `/notice bob hi`, `/join #x`.                                            |
| `//text`       | A message starting with `/` (the second slash is removed).                                                                                         |
| *(empty line)* | Nothing.                                                                                                                                           |

Lines are sent in order, through Irctell's flood control. When a one-shot
script exits, its exit status is logged; a non-zero status with no output
shows its standard error in the Irctell Log and, for `run`, in the
conversation.

### 4.3 The smallest example

```bash
#!/bin/bash
# Trigger: message in #delta*, text ^!roll
echo "$IRCTELL_NICK rolled $((RANDOM % 6 + 1))"
```

---

## 5. The JSON Lines protocol

Every message is **one JSON object on one line**, ended by `\n`, in UTF-8, in
both directions. Scripts must flush their output after each line (Python:
`print(…, flush=True)`; with `sys.stdout.reconfigure(line_buffering=True)` once).

Every object has a `type`. Irctell ignores fields it does not know, so scripts
may add their own; a line that is not valid JSON, or has an unknown `type`, is
answered with an `error` ([§5.3](#53-errors)) and otherwise ignored.

### 5.1 Common fields

| Field     | In               | Meaning                                                                                               |
| --------- | ---------------- | ----------------------------------------------------------------------------------------------------- |
| `type`    | all              | What the message is.                                                                                  |
| `id`      | events, queries  | A unique string, to refer to it.                                                                      |
| `re`      | replies, results | The `id` it answers. A reply with `re` goes where that event came from: no `network`/`target` needed. |
| `network` | most             | The network's name as shown in Irctell (`"Libera.Chat"`). Scripts may also use `network_id`.          |
| `time`    | events           | ISO 8601 UTC with milliseconds: `"2026-10-16T13:21:59.123Z"`.                                         |

### 5.2 Conversation at a glance

```
Irctell → {"type":"hello","version":1,"script":"Dice","mode":"service","me":{"Libera.Chat":"verhas"}}
script  → {"type":"subscribe","events":["message"],"channels":"#delta"}
Irctell → {"type":"event","id":"e1","event":"message","network":"Libera.Chat","channel":"#delta","nick":"bob","text":"!roll 2d6",…}
script  → {"type":"reply","re":"e1","text":"bob rolled 7"}
script  → {"type":"query","id":"q1","what":"members","network":"Libera.Chat","channel":"#delta"}
Irctell → {"type":"result","re":"q1","members":[{"nick":"bob","prefixes":"@"},…]}
Irctell → {"type":"stop","reason":"quitting"}
```

### 5.3 Errors

Irctell answers anything it cannot do with:

```json
{"type":"error","re":"q1","code":"not_permitted","message":"This script may not send to #ops"}
```

| `code`                        | When                                                       |
| ----------------------------- | ---------------------------------------------------------- |
| `bad_json`                    | The line is not a JSON object.                             |
| `unknown_type`                | Unknown `type`.                                            |
| `missing_field` / `bad_field` | A required field is missing or wrong.                      |
| `not_permitted`               | A permission ([§9](#9-permissions)) forbids it.            |
| `not_connected`               | The network is not connected.                              |
| `unknown_target`              | No such network, channel or conversation.                  |
| `rate_limited`                | Over a limit ([§10](#10-limits)); the message was dropped. |
| `failed`                      | It was tried and failed; `message` says why.               |

---

## 6. Events: Irctell → script

### 6.1 Session messages

| `type`   | When                                                                            | Fields                                                                                                                                                                                   |
| -------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hello`  | First line, always.                                                             | `version` (protocol, [§17](#17-versioning)), `script`, `mode`, `app` (`"Irctell 0.2.0"`), `me` (your nick per connected network), `networks` (a list: `name`, `id`, `connected`, `nick`) |
| `event`  | An event matching a trigger.                                                    | below                                                                                                                                                                                    |
| `result` | The answer to a `query`.                                                        | `re`, and the query's fields ([§8](#8-queries-script-asks-irctell-answers))                                                                                                              |
| `error`  | Something could not be done.                                                    | `re`, `code`, `message`                                                                                                                                                                  |
| `ack`    | A command was done, when asked with `"ack": true`.                              | `re`                                                                                                                                                                                     |
| `stop`   | The script should finish: quitting, disabled, or the trigger's timeout reached. | `reason` (`quitting`, `disabled`, `timeout`, `restart`)                                                                                                                                  |

### 6.2 The `event` object

Common fields of every event:

```json
{"type":"event", "id":"e42", "event":"message", "time":"2026-10-16T13:21:59.123Z",
 "network":"Libera.Chat", "network_id":"5A1B…"}
```

Per event, the further fields:

| `event`                               | Fields                                                                                                                                                                 |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `message`, `action`, `notice`         | `channel`, `nick`, `user`, `host`, `account` (when known), `text` (formatting removed), `raw_text` (with mIRC codes), `self`, `highlight`, `tags` (IRCv3 message tags) |
| `private_message`, `new_private_chat` | `nick`, `user`, `host`, `account`, `text`, `raw_text`, `is_action`, `self`; for `new_private_chat` also `previous` (time of the last message before, or `null`)        |
| `mention`                             | as `message`, plus `words` (the highlight words that matched)                                                                                                          |
| `join`                                | `channel`, `nick`, `user`, `host`, `account`, `real_name`, `self`                                                                                                      |
| `part`                                | `channel`, `nick`, `reason`, `self`                                                                                                                                    |
| `quit`                                | `nick`, `reason`, `channels` (the shared channels they were in)                                                                                                        |
| `kick`                                | `channel`, `nick` (who kicked), `target` (who was kicked), `reason`, `self` (you were kicked)                                                                          |
| `nick`                                | `old`, `new`, `self`                                                                                                                                                   |
| `topic`                               | `channel`, `nick`, `text`                                                                                                                                              |
| `mode`                                | `target` (channel or nick), `nick` (who set it), `modes` (`"+o"`), `arguments`                                                                                         |
| `invite`                              | `channel`, `nick`                                                                                                                                                      |
| `ctcp`                                | `nick`, `command`, `argument`                                                                                                                                          |
| `memo`                                | `from`, `number`, `date`                                                                                                                                               |
| `connect`                             | `nick`, `server`                                                                                                                                                       |
| `disconnect`                          | `reason`                                                                                                                                                               |
| `away`, `back`                        | `message` (for `away`)                                                                                                                                                 |
| `timer`                               | `schedule` (`"every 10m"`, `"at 08:30"`)                                                                                                                               |
| `startup`, `shutdown`                 | —                                                                                                                                                                      |
| `run`                                 | `conversation` (`channel` or `nick` it was typed in, `kind`: `channel`, `query`, `server`), `arguments` (a list of words), `text` (all of them)                        |
| `nick_action`                         | `conversation` (as for `run`), `nick` (the one picked)                                                                                                                 |
| `menu`                                | —                                                                                                                                                                      |
| text triggers                         | `groups`: the regular expression's groups, when the trigger had `text`                                                                                                 |

---

## 7. Commands: script → Irctell

### 7.1 Talking

| `type`    | Does                                  | Fields                                                                               |
| --------- | ------------------------------------- | ------------------------------------------------------------------------------------ |
| `reply`   | Answers an event, where it came from. | `re`, `text`; optional `as`: `message` (default), `action`, `notice`                 |
| `say`     | A message to a channel or nick.       | `network`, `target`, `text`                                                          |
| `act`     | A `/me`.                              | `network`, `target`, `text`                                                          |
| `notice`  | A notice.                             | `network`, `target`, `text`                                                          |
| `command` | A line run as if typed, `/` included. | `network`, `line`; optional `conversation` (where it runs, for commands that use it) |
| `raw`     | A raw IRC protocol line, sent as is.  | `network`, `line` (`"PRIVMSG #x :hi"`)                                               |

Long text is split as when you type it; newlines in `text` send several
lines. Every command may carry `"id"` and `"ack": true` to be answered with an
`ack` when done.

### 7.2 Channels and conversations

| `type`  | Does                                                                 | Fields                                          |
| ------- | -------------------------------------------------------------------- | ----------------------------------------------- |
| `join`  | Joins channels.                                                      | `network`, `channels` (a list), optional `keys` |
| `part`  | Leaves a channel.                                                    | `network`, `channel`, optional `reason`         |
| `open`  | Opens a conversation in the sidebar.                                 | `network`, `target`, optional `select`          |
| `close` | Closes a private chat, or leaves and closes a channel.               | `network`, `target`                             |
| `topic` | Sets a channel topic.                                                | `network`, `channel`, `text`                    |
| `whois` | Asks for a WHOIS; the result comes as a `result` when `id` is given. | `network`, `nick`                               |

### 7.3 For you, in Irctell

| `type`    | Does                                                                                                                 | Fields                                                                    |
| --------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `show`    | A line in a conversation, seen by you only, never sent.                                                              | `network`, `target` (or `re`), `text`, optional `level` (`info`, `error`) |
| `notify`  | A macOS notification.                                                                                                | `title`, `text`; optional `network`, `target` (clicking it opens there)   |
| `speak`   | Read aloud, through Irctell's voices and mute.                                                                       | `text`; optional `voice`, `nick` (in that nick's voice)                   |
| `suggest` | Puts a reply into the empty input field of a conversation, as the Apple Intelligence suggestions are (Tab takes it). | `network`, `target` (or `re`), `text`                                     |
| `away`    | Away on networks, or back.                                                                                           | `message` (`null` for back); optional `networks` (all when left out)      |
| `log`     | A line in the Irctell Log.                                                                                           | `level` (`debug`, `info`, `notice`, `warning`, `error`), `text`           |

### 7.4 The script's own business

| `type`         | Does                                                                                                                     | Fields                                                                                         |
| -------------- | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| `subscribe`    | A service narrows or widens the events it gets, beyond its triggers' (never past its permissions).                       | `events` (a list of `on` names), and the filters of [§3.1](#31-filters-common-to-all-triggers) |
| `unsubscribe`  | Stops those events.                                                                                                      | `events`                                                                                       |
| `timer`        | A timer of its own: `{"type":"timer","id":"t1","after":"30s"}`, or `"every":"5m"`; a `timer` event with `id` comes then. | `id`, `after` or `every`                                                                       |
| `cancel_timer` | Cancels one.                                                                                                             | `id`                                                                                           |
| `store`        | Keeps a value between runs, in Irctell's data for this script.                                                           | `key`, `value` (any JSON)                                                                      |
| `done`         | A one-shot is finished: Irctell closes it now instead of waiting for it to exit.                                         | —                                                                                              |

---

## 8. Queries: script asks, Irctell answers

A query is `{"type":"query","id":"q1","what":"…", …}`; the answer is
`{"type":"result","re":"q1", …}` or an `error`.

| `what`     | Asks                                                     | Fields                                                                                                | Result                                                                                                                                    |
| ---------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `networks` | The networks open in Irctell.                            | —                                                                                                     | `networks`: `name`, `id`, `connected`, `nick`, `away`                                                                                     |
| `channels` | The channels on a network.                               | `network`                                                                                             | `channels`: `name`, `joined`, `topic`, `members` (count)                                                                                  |
| `members`  | A channel's members.                                     | `network`, `channel`                                                                                  | `members`: `nick`, `prefixes`, `away`, `account`                                                                                          |
| `user`     | What is known of a nick: WHOIS, nick database, activity. | `network`, `nick`; optional `fresh: true` (sends a WHOIS first)                                       | `nick`, `user`, `host`, `real_name`, `account`, `channels`, `away`, `online`, `first_seen`, `last_seen`, `had_private_chat`, `last_spoke` |
| `nicks`    | Nicks from the network's nick database.                  | `network`; optional `starting_with`, `limit`                                                          | `nicks`: `nick`, `last_seen`, `had_private_chat`, `online`                                                                                |
| `history`  | Lines of a conversation from the log.                    | `network`, `target`; optional `limit` (default 50, at most 1000), `before`, `since` (times), `search` | `lines`: `time`, `kind`, `nick`, `text`, `self`                                                                                           |
| `mentions` | Recent mentions and private messages.                    | optional `limit`, `since`                                                                             | `lines`, with `network` and `target`                                                                                                      |
| `memos`    | The MemoServ inbox.                                      | `network`                                                                                             | `memos`: `number`, `from`, `date`, `unread`, `text`                                                                                       |
| `me`       | Your nick, away state and identity.                      | `network`                                                                                             | `nick`, `away`, `account`                                                                                                                 |
| `store`    | Values kept with `store`.                                | optional `key`                                                                                        | `value`, or `values` (all)                                                                                                                |

---

## 9. Permissions

A new script **may do everything** a user can. Restrictions are set per script
in the Scripts window and stored in `permissions`:

| Permission        | Restricts                                                                                                              | Example                   |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| `networks`        | The networks it hears from and may act on.                                                                             | `["Libera.Chat"]`         |
| `send_to`         | Where it may send: `"origin"` (only back where an event came from), `"channels"`, `"private"`, `"none"`, or patterns.  | `"#delta*"`               |
| `commands`        | IRC commands it may run with `command`/`raw`; `"none"` for none.                                                       | `["msg", "me", "notice"]` |
| `raw`             | Whether `raw` lines are allowed.                                                                                       | `false`                   |
| `channels_joined` | Whether it may join, part, close.                                                                                      | `false`                   |
| `read_log`        | Whether `history`, `mentions`, `memos` queries are answered.                                                           | `false`                   |
| `ignored`         | Whether it gets lines from ignored nicks.                                                                              | `false`                   |
| `dry_run`         | Nothing it sends reaches IRC: each would-be line is shown to you in the conversation instead. For trying a script out. | `true`                    |

---

## 10. Limits

Even a permitted script is held to these, adjustable per script:

| Limit                        | Default                           | When exceeded                                                                         |
| ---------------------------- | --------------------------------- | ------------------------------------------------------------------------------------- |
| Timeout of a one-shot        | 10 s                              | `stop`, then terminated 2 s later, then killed.                                       |
| Running copies of a one-shot | 4                                 | Further events wait, at most 20; older ones are dropped.                              |
| Lines to IRC per minute      | 30 (and Irctell's flood control)  | Dropped, `rate_limited`; after a minute of it the script is stopped and you are told. |
| Line length from a script    | 64 KB                             | The line is dropped, `bad_json` / logged.                                             |
| Service restarts             | after 1 s, 2 s, 4 s … up to 5 min | After 5 failures in 10 minutes: stopped, shown as failed.                             |
| Standard error kept          | the last 200 lines                | Older ones only in the log file.                                                      |

---

## 11. Lifecycle

### One-shot

1. An event matches a trigger; a copy is started (or waits, [§10](#10-limits)).
2. **Text**: environment and arguments are set, the event's text is written to
   stdin, stdin is closed. **JSON**: `hello`, then the `event`, then stdin is
   closed.
3. Output is read and acted on as it comes.
4. The script exits, or sends `done`, or reaches its timeout (`stop`, then
   SIGTERM, then SIGKILL).

### Service

1. Started when Irctell starts, or — with a `connect` trigger — when the first
   matching network connects. Started again when its definition changes.
2. Gets `hello`, then events as they match, for as long as it runs. Stdin
   stays open.
3. Stopped with `stop`, then closed stdin, then SIGTERM after 5 s and SIGKILL
   after 10 s: when Irctell quits, the script is disabled, or it is restarted.
4. If it exits on its own, it is restarted per `restart` ([§2](#2-defining-a-script)).

Events reach a service in the order they happened. While a service is
starting, events are kept for it (up to 100) and sent after `hello`.

---

## 12. Environment variables

Set for every script, both protocols:

| Variable           | Value                                                   |
| ------------------ | ------------------------------------------------------- |
| `IRCTELL_VERSION`  | Irctell's version.                                      |
| `IRCTELL_PROTOCOL` | `text` or `json`, and `IRCTELL_PROTOCOL_VERSION` (`1`). |
| `IRCTELL_SCRIPT`   | The script's name.                                      |
| `IRCTELL_HOME`     | The profile's folder: `~/.irctell` for the main one, `~/.irctell/profiles/NAME` for another. |
| `IRCTELL_PROFILE`  | The profile's name, `Main` for the main one.            |
| `IRCTELL_DATA`     | A folder of the script's own, kept between runs.        |

Set for one-shot scripts from the event (empty when not part of it):

| Variable                                          | Value                                                                   |
| ------------------------------------------------- | ----------------------------------------------------------------------- |
| `IRCTELL_EVENT`                                   | The event: `message`, `private_message`, `run`, …                       |
| `IRCTELL_NETWORK`, `IRCTELL_NETWORK_ID`           | The network.                                                            |
| `IRCTELL_ME`                                      | Your nick there.                                                        |
| `IRCTELL_CHANNEL`                                 | The channel; for private events, the nick; for `run`, the conversation. |
| `IRCTELL_NICK`                                    | Who the event is from (for `nick_action`: the nick picked).             |
| `IRCTELL_USER`, `IRCTELL_HOST`, `IRCTELL_ACCOUNT` | What is known of them.                                                  |
| `IRCTELL_TEXT`                                    | The text, formatting removed.                                           |
| `IRCTELL_RAW_TEXT`                                | The text with mIRC formatting codes.                                    |
| `IRCTELL_TIME`                                    | ISO 8601 UTC.                                                           |
| `IRCTELL_GROUP_1` …                               | The text trigger's regular expression groups.                           |
| `IRCTELL_ARGS`                                    | For `run`: everything typed after the name.                             |

---

## 13. Logging and debugging

- Everything a script writes to **standard error** goes to the Irctell Log
  (⌥⌘L), category `scripts`, one entry per line, at level `info`; a script can
  choose the level with the `log` command instead.
- Every start, exit (with status), stop, restart, refused command and dropped
  line is logged there too.
- The **Scripts window** lists the scripts with their state (stopped, running,
  failed), the last run, the last lines of output and errors, and buttons to
  Run, Stop, Restart and Edit.
- **Dry run** ([§9](#9-permissions)) shows what a script would send, without
  sending it.
- A script can be tried from Terminal: run it, type the JSON lines Irctell
  would send, and read what it answers.

---

## 14. Security

- **Only your scripts run.** Scripts are defined in the Scripts window only.
  Nothing that comes from IRC can define, change or start a script, except
  through the triggers you set.
- **IRC text is never part of a command line.** Irctell starts the program
  given in `command` directly, without a shell, with fixed arguments. Event
  details arrive as data on stdin, in environment variables, or as separate
  arguments (`run` arguments, regex groups), never pasted into shell syntax.
  A script that itself passes such text to a shell (`eval`, `os.system`) is
  open to injection: handle it as untrusted input.
- **Scripts run as you**, with all your access to your files and network.
  Run only scripts you wrote or trust.
- Passwords from Irctell's keychain are never given to scripts.

---

## 15. Examples

### 15.1 Text, one-shot: dice

`~/.irctell/scripts/dice.sh`:

```bash
#!/bin/bash
# Trigger: message, channels "#delta*", text "^!roll(\s+(\d+))?"
sides=${IRCTELL_GROUP_2:-6}
echo "$IRCTELL_NICK rolled $((RANDOM % sides + 1)) (d$sides)"
```

### 15.2 Text, one-shot: run from a conversation

`/run weather Budapest` in a channel:

```bash
#!/bin/bash
# Trigger: run
curl -s "https://wttr.in/${1// /+}?format=3"
```

### 15.3 Text, one-shot: a nick action that runs commands

```bash
#!/bin/bash
# Trigger: nick_action, channels "#room*"
echo "/msg Data !view $IRCTELL_NICK"
echo "/msg Data !stats $IRCTELL_NICK"
```

### 15.4 JSON, service: a greeter with memory

```python
#!/usr/bin/env python3
# Mode: service. Triggers: join, channels "#lobby"; new_private_chat.
import json, sys

def send(**message):
    print(json.dumps(message), flush=True)

greeted = set()
for line in sys.stdin:
    message = json.loads(line)
    if message["type"] == "hello":
        send(type="log", level="info", text="greeter ready")
    elif message["type"] == "event":
        nick = message.get("nick", "")
        if message["event"] == "join" and not message["self"] and nick not in greeted:
            greeted.add(nick)
            send(type="reply", re=message["id"], text=f"Welcome, {nick}!")
        elif message["event"] == "new_private_chat":
            send(type="notify", title="New private chat", text=f"{nick}: {message['text']}",
                 network=message["network"], target=nick)
    elif message["type"] == "stop":
        break
```

### 15.5 JSON, service: asking Irctell

```python
#!/usr/bin/env python3
# Mode: service. Trigger: message, channels "#delta", text "^!who$"
import json, sys, itertools

ids = (f"q{n}" for n in itertools.count())
waiting = {}

for line in sys.stdin:
    message = json.loads(line)
    if message["type"] == "event":
        query = next(ids)
        waiting[query] = message
        print(json.dumps({"type": "query", "id": query, "what": "members",
                          "network": message["network"], "channel": message["channel"]}), flush=True)
    elif message["type"] == "result" and message["re"] in waiting:
        event = waiting.pop(message["re"])
        nicks = ", ".join(member["nick"] for member in message["members"])
        print(json.dumps({"type": "reply", "re": event["id"], "text": f"Here: {nicks}"}), flush=True)
```

---

## 16. Mac App Store edition

A sandboxed app may not start programs from anywhere. In the App Store
edition, scripts must be placed in
`~/Library/Application Scripts/dev.verhas.Irctell/`, which the user creates
and fills, and are started through `NSUserUnixTask`. Everything else in this
document applies unchanged; the `command` names a file in that folder.

---

## 17. Versioning

- The protocol has a version, `1`, sent in `hello` and in
  `IRCTELL_PROTOCOL_VERSION`.
- Within a version, Irctell only **adds**: new events, commands, queries and
  fields. Scripts must ignore fields and event types they do not know.
- A change that would break scripts raises the version. A script may state the
  version it was written for in its definition (`"protocol_version": 1`), and
  is then spoken to in that version for as long as Irctell supports it.

---

## 18. Implementation notes

What the first implementation does where this document leaves room, or
does a little differently:

- **Where things live.** Definitions are kept in Irctell's settings, under
  `scripts`. A script's own folder, `IRCTELL_DATA`, is
  `~/.irctell/script-data/NAME/`; the `store` command keeps its values in
  `store.json` there.
- **Finding the program.** A `command` without a path is looked up in the
  `PATH` Irctell was started with, then in `/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin` and `/bin`: an app started from the Dock has
  a short `PATH`.
- **WHOIS answers.** `whois` with an `id`, and the `user` query with
  `fresh: true`, answer 3 seconds after the WHOIS is sent, with what is known
  by then.
- **Mentions.** An event's `words` lists the highlight words found in the
  line; highlight patterns are not listed.
- **Own lines.** Triggers on text events leave your own lines out unless they
  say `"lines": "all"` or `"mine"` (in the Scripts window: *Whose lines*);
  other events include them. Lines you type count as yours whether or not the
  server echoes them back; lines a script sends never trigger scripts, also
  when the server echoes them.
- **Ignored nicks.** A line from an ignored nick reaches a script only when
  both its trigger (`ignored`) and its permissions (`ignored`) allow it.
- **One-shot timeout.** At its time limit a one-shot script's input is
  closed, it is terminated 2 seconds later and killed 2 seconds after that.
- **Starting services.** A service with a `connect` trigger starts with the
  first matching connection; other services start with Irctell, or when
  enabled. A changed definition restarts it.
- **Not yet.** `protocol_version` in a definition (§17) is not read: there is
  only version 1. The App Store edition's `NSUserUnixTask` (§16) is not
  built, as there is no App Store edition yet.
