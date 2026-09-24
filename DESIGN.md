# DESIGN — WhatsApp AI Receptionist

**Status:** ✅ System architecture & design + reference implementation — a complete, documented build you can deploy on your own stack (see setup in README). No live database, model call, or WhatsApp account was used in authoring.

This document is the build spec: the data model, the workflow node-by-node, the LLM contract, and the swap-points. It's written so the workflow can be read and understood without running it.

---

## 1. Goal

A customer messages a salon on WhatsApp at any hour; a friendly receptionist replies instantly — answers questions, quotes services and prices from the real menu, captures a booking (owner confirms), collects customer details, and remembers the conversation. The reasoning runs on a **local** model so customer data never leaves the owner's infrastructure.

## 2. Stack

- **n8n** (Docker) — orchestration, one linear workflow.
- **PostgreSQL** (mock) — CRM + conversation memory (4 tables).
- **Ollama `gemma3:4b`** (local) — the reasoning step, called over HTTP with `format: json`.
- **WhatsApp** — Meta WhatsApp Cloud API, represented as **swap-points** (mock inbound webhook + mock send). No real WhatsApp account or credentials.

## 3. Data model (`schema.sql`)

Idempotent (`DROP … CASCADE` inside `BEGIN/COMMIT`). Four tables:

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `services` | The menu the receptionist quotes from | `name`, `price numeric`, `duration_min int` |
| `customers` | One row per phone, upserted each message | `phone unique`, `name`, `email`, `notes` |
| `appointments` | Booking requests (agent writes `pending` only) | `phone`, `service_id`, `requested_time text`, `status ['pending'|'confirmed'|'declined']` |
| `messages` | Conversation memory (load last N) | `phone`, `role ['user'|'assistant']`, `text`, `created_at` |

**Seed:** 8 realistic salon services (cut, color, balayage, blow-dry, mani, pedi, …) with prices + durations; 2 sample customers; a short sample thread so context is visible on first read. The prompt is built **only** from `services`, so the model cannot invent a service or a price.

## 4. Workflow (`whatsapp-receptionist.workflow.json`)

13 nodes, one linear path with a single branch. `meta.templateId = sc-agentic-whatsapp-receptionist-v1`. Postgres nodes carry the placeholder credential id `PLACEHOLDER_SELECT_IN_UI` (the real credential is selected in the n8n UI).

| # | Node | Type | Role |
|---|------|------|------|
| 1 | WhatsApp inbound (MOCK webhook) | `webhook` | **SWAP** — entry point; sample payload in the node note |
| 2 | Normalize inbound | `code` | → `{ phone, text, name }` |
| 3 | Upsert customer (phone) | `postgres` | remember the customer (`ON CONFLICT (phone)`) |
| 4 | Load recent messages (context) | `postgres` | last 10 messages for this phone |
| 5 | Log inbound message | `postgres` | store the user turn (`role='user'`) |
| 6 | Build prompt | `code` | persona + menu + history + new message |
| 7 | Receptionist (Ollama gemma3:4b) | `httpRequest` | **SWAP (LLM)** — `format:json`, temp 0.2, `onError: continueRegularOutput` |
| 8 | Parse LLM reply + Fallback | `code` | strict JSON parse; safe reply on any failure |
| 9 | Booking ready? | `if` | branch on `booking.ready` |
| 10 | Book appointment (pending) | `postgres` | true-branch: write `pending` appointment |
| 11 | Notify owner (MOCK) | `noOp` | **SWAP** — owner confirm ping; Calendly/Acuity on confirm |
| 12 | Log assistant reply | `postgres` | store the assistant turn (`role='assistant'`) |
| 13 | WhatsApp send (MOCK) | `noOp` | **SWAP** — send the reply back |

**Control flow.** Nodes 1→8 run linearly. Node 9 (`If`) splits on `booking.ready`: **true** → Book appointment → Notify owner → Log assistant reply; **false** → straight to Log assistant reply. Both paths converge and finish at WhatsApp send. Downstream Code/Postgres nodes read upstream context by node reference (e.g. `$('Parse LLM reply + Fallback').first().json`), so the Postgres query results in between don't clobber the data being carried.

## 5. LLM contract

**Input:** persona (friendly salon receptionist; use ONLY the provided services/prices; never invent availability; to book, gather **service + preferred time + name + email**, then mark ready) + the services menu + the last N messages + the new message.

**Output — JSON only:**

```json
{ "reply": "text to send back",
  "intent": "faq|services|booking|smalltalk|other",
  "booking": { "service": null, "requested_time": null,
               "name": null, "email": null, "ready": false },
  "missing": ["fields still needed"] }
```

**Fallback (node 8):** if the response isn't valid JSON or is missing `reply`, the node synthesizes a safe generic reply plus one clarifying question and continues. Combined with `onError: continueRegularOutput` on the HTTP node, a model hiccup never breaks the run — the customer always gets an answer.

## 6. Booking behavior (locked)

Capture → write a **`pending`** appointment → **notify the owner to confirm**. The customer is told *"request received, we'll confirm shortly."* The owner confirming is out-of-band; **Calendly/Acuity is the documented swap-point** where a confirmed booking would sync (not built in this reference implementation).

## 7. Swap-points

1. **WhatsApp Cloud API** — inbound webhook + outbound send (Meta).
2. **Owner notification** — WhatsApp / email / Slack.
3. **Calendly / Acuity** — booking sync on confirmation.
4. **LLM** — local Ollama here; swappable for a cloud model.

## 8. Adaptability

Only the **`services` seed** and the **persona line** carry the salon identity. Swap those two to re-skin the agent for a barbershop, clinic, restaurant, cleaning service, or real-estate office. Memory, booking capture, owner confirmation, and the safe-fallback are all vertical-agnostic.

## 9. Non-goals (v1)

Reminders, follow-ups, real calendar/booking-tool sync, payments, multi-language, multi-location — noted as the roadmap.

## 10. Provenance

Inspired by the *concept* of a clinic n8n agent (`Scheeza-Ahmad/Clinic-Agent-Using-n8n`). That repo has **no license → no files were cloned or copied**. The workflow, schema, and docs here are original, built from this spec. The clean n8n export shape (node/connection JSON, Postgres placeholder-credential pattern, HTTP-Ollama config) follows the structural pattern of our own public `revops-deal-review` template.
