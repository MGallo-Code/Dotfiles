---
name: contact
description: Add, update, or look up a contact. Activate when the user says contact, add contact, new contact, or look up contact.
---

# Contact

Manage contacts via Nexus MCP tools.

## Arguments

`/contact <name> [type] [details...]`

Types: `customer`, `network`, `personal`, `other`

## Flow

1. Use `contact_list` with search term to check if name already exists.
2. If looking up: use `contact_get` and show the record.
3. If updating: use `contact_get`, show current record, ask what to change, then `contact_update`.
4. If new: prompt for missing fields (email, phone, address, company, notes). Use `contact_create`.
5. Confirm with the full record.
