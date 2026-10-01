---
name: calendar
description: Create, view, or manage Google Calendar events via the first-party calendar MCP. Activate when the user says calendar, schedule, book, event, meeting, availability, or asks what's on the calendar.
---

# Calendar

Manage Google Calendar events via the first-party `calendar` MCP.

## Tools

- `calendar` (sibling of `nexus`, lives in `~/Documents/EA/calendar/`) wraps the Google Calendar API directly. It is the canonical path for all Google Calendar reads and writes via the `mcp__calendar__*` tools. (The old Claude-hosted `/calendar` connector has been removed.)
- The canonical Google account is `michaelgallo.va@gmail.com`. `calendar_status` should report that account before making changes.
- Calendar tools return object envelopes like `{ok: true, events: [...]}` or `{ok: false, error: "..."}`. Never expect a top-level array.
- `calendar_delete_event` is destructive and requires `confirm=true`.
- If the `calendar` MCP tools are unavailable, there is no managed fallback. Recover the first-party server: run `calendar_status`, and if unauthenticated re-run login with `cd ~/Documents/EA/calendar && PYTHONPATH=src uv run --no-sync python -m ea_calendar.cli login`. Otherwise print event details for manual entry.
- `himalaya` is email IMAP/SMTP only. It can help parse `.ics` invite emails, but it is not the source of truth for calendar state.
- OAuth client secrets, refresh tokens, keychain entries, and fallback token files are machine-local. Do not sync or commit them.

## Calendars

Default working calendars: Personal, Work, Networking, and Health. Query all four unless Michael asks for a specific calendar. Skip Holidays unless asked.

Route events to the correct calendar based on context:

| Calendar | ID | Use for |
|----------|----|---------|
| Work | `d49fd0a02ca97e96b451cc8550b6d2277fd7cd5a3f6ac1b6d8e96c79e99bdf85@group.calendar.google.com` | IT/freelance sessions, client work |
| Networking | `bca761420ca9bc019dc4157623bb21cec4e98993ea01a1f7dd0335051aa23077@group.calendar.google.com` | Meetings, lunches, events, intros |
| Health | `416b03cd05e1045c37ccff3ddb3faf5ff9415241e2b4b74d77edf05f42405f31@group.calendar.google.com` | Appointments, wellness |
| Personal | `michaelgallo.va@gmail.com` | Everything else |

When creating events, pick the calendar from context. If ambiguous, ask.

## Arguments

`/calendar <action> [details...]`

Actions: `create`, `today`, `week`, `next`

## Flow

### Create

1. Parse: contact/title, datetime (natural language OK), description.
2. If a contact name is given, use `contact_get` MCP tool for context.
3. Pick the correct calendar based on event type.
4. Create the event with `calendar_create_event`.
5. Confirm with event details and which calendar it was added to.

### View (today/week/next)

1. Query all four working calendars for upcoming events.
2. Display formatted list grouped by day, with time, title, calendar, and description.

## Notes

- Timezone: America/New_York
