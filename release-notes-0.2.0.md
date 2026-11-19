# Irctell 0.2.0

## Typing

- The input field grows with the text, up to a number of lines set in Settings, and then scrolls.
- Text too long for one IRC message is shown the way it will be sent: each message after the first starts on a new line, under a thin line.
- Settings chooses what Return does: send, send unless the text is already several messages, or never send. ⌥Return always starts a new message.
- ↑ and ↓ go through the history only at the first and last line of the text; elsewhere they move the cursor.
- Tab completes nicks with whoever wrote last in the conversation first.
- ⌘W closes the channel or private chat in front, never the window.

## Nicks and members

- Nicks in the conversation can be clicked: the sender's name, and words of the text that are nicks of members, also inside marks such as `[bob]`.
- The member list can be ordered alphabetically, by who wrote most recently, or voiced and operators first, with buttons under the list.
- The sidebar shows channels without the leading #, next to their # icon.

## Connections

- Reconnecting gives up after 10 failed attempts in a row, about 18 minutes, instead of trying forever. /reconnect starts again.
- A server that accepts the login and drops the connection at once no longer gets a new connection every few seconds: a login has to last a minute to start the attempts afresh.

## Fixes

- Only one Irctell runs at a time on the same data. A second copy says so and quits, instead of logging in with the same nicks and pushing the first one off the networks.
- The input field no longer jumps between one and two lines many times a second when the text ends right at the edge of a line, with scroll bars shown always (a mouse attached).
