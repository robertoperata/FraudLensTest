# FraudLens — Product Specification

## 1. Overview

FraudLens is a full-stack web application for managing and analyzing user session data
collected by a network appliance. Sessions are enriched with navigation events and assessed
for fraud risk via a deterministic rule engine and an AI-powered narrative summary.

**Stack**:
- Backend: Java 25, Spring Boot 3.3, Spring Security 6, Spring AI 1.0, JPA/Hibernate, PostgreSQL 16
- Frontend: React 18, Vite, Tailwind CSS, React Query v5, React Router v6
- Auth: JWT (jjwt 0.12.x), stateless
- AI: Anthropic Claude via Spring AI (`claude-haiku-4-5-20251001`)
- Containerization: Docker + docker-compose

---

## 2. Data Model

### Session

| Field     | Type   | Constraints                                  |
|-----------|--------|----------------------------------------------|
| id        | String | Primary key, provided by client (e.g. abc-123) |
| userId    | String | Required, non-blank                          |
| ip        | String | Required, valid IPv4 format                  |
| country   | String | Required, ISO 3166-1 alpha-2 (2 chars)       |
| device    | String | Required, non-blank                          |
| timestamp | String | Required, ISO 8601 UTC                       |
| status    | Enum   | SAFE \| SUSPICIOUS \| DANGEROUS              |

### Event

| Field      | Type   | Constraints                                        |
|------------|--------|----------------------------------------------------|
| id         | String | Primary key, provided by client (e.g. evt_001)    |
| sessionId  | String | FK → Session.id, required                         |
| type       | Enum   | PAGE_VISIT \| FORM_SUBMIT \| LOGIN_ATTEMPT         |
| url        | String | Required, non-blank                               |
| durationMs | Long   | Required, >= 0                                    |
| metadata   | JSON   | Optional, stored as TEXT in DB                    |

### Data Integrity Constraint

Deleting a Session MUST cascade-delete all associated Events.
Enforced at two levels:
1. JPA: `@OneToMany(cascade = CascadeType.ALL, orphanRemoval = true)` on Session entity
2. Schema: `ON DELETE CASCADE` on the events.session_id foreign key

---

## 3. REST API Contract

### Authentication

```
POST /auth/login
Body: { "username": "admin", "password": "admin" }
Response 200: { "token": "<jwt>" }
Response 401: { "error": "Invalid credentials" }
```

All other endpoints require `Authorization: Bearer <token>` header.
Missing or invalid token → 401.

### Sessions

```
GET    /sessions
       Response 200: Session[] (each includes riskScore and triggeredRules)

GET    /sessions/:id
       Response 200: Session + events[] + riskScore + triggeredRules
       Response 404: { "error": "Session not found" }

POST   /sessions
       Body: { userId, ip, country, device, timestamp, status }
       Response 201: Session
       Response 400: validation errors

PUT    /sessions/:id
       Body: partial or full session fields
       Response 200: updated Session
       Response 404: not found

DELETE /sessions/:id
       Response 204: no content (events also deleted)
       Response 404: not found

POST   /sessions/search
       Body: {
         "filters": { "status": "DANGEROUS", "country": "CN" },  // all optional
         "sortBy": "timestamp",   // "timestamp" | "id" — default: "timestamp"
         "sortDir": "desc"        // "asc" | "desc" — default: "desc"
       }
       Response 200: Session[] matching filters
```

> Note: POST is used for search (not GET) because the filter payload may be complex
> and grow over time. GET with query params does not scale well for structured filters.

### Events

```
GET    /sessions/:id/events
       Response 200: Event[]
       Response 404: session not found

POST   /sessions/:id/events
       Body: { id, type, url, durationMs, metadata }
       Response 201: Event
       Response 400: validation errors
       Response 404: session not found

DELETE /sessions/:id/events/:eventId
       Response 204: no content
       Response 404: session or event not found
```

### AI Summary

```
POST   /sessions/:id/ai-summary
       Response 200: {
         "summary": "...",
         "riskLevel": "HIGH",
         "recommendation": "...",
         "generatedAt": "2025-03-03T10:00:00Z"
       }
       Response 429: { "error": "Rate limit exceeded", "retryAfter": 60 }
       Response 503: { "error": "AI service temporarily unavailable" }
```

Rate limit: 5 requests per user per minute (Bucket4j, in-memory, per JWT subject).

---

## 4. Risk Score Rules

The risk score is a numeric value 0–100, computed server-side in `RiskScoreService`.
It is **deterministic and rule-based** — no AI involved.
The service returns both the numeric score and the list of triggered rules (for display in the UI).

### Rule Table

| Rule ID | Description | Points | Category |
|---------|-------------|--------|----------|
| R01 | Country not in low-risk whitelist | +15 | Session |
| R02 | Same IP appears in more than 1 session | +20 | Session |
| R03 | Session timestamp between 01:00–05:00 UTC | +10 | Session |
| R04 | Status is SUSPICIOUS | +10 | Session |
| R05 | Status is DANGEROUS | +25 | Session |
| R06 | At least one LOGIN_ATTEMPT event | +10 | Event |
| R07 | 3 or more LOGIN_ATTEMPT events (replaces R06) | +25 | Event |
| R08 | LOGIN_ATTEMPT followed by FORM_SUBMIT within 5 seconds | +30 | Event |
| R09 | FORM_SUBMIT metadata contains sensitive fields (card_number, cvv, password, ssn) | +20 | Event |
| R10 | Total events in session > 10 | +15 | Event |
| R11 | All events have durationMs < 500 (bot-speed navigation) | +15 | Event |
| R12 | PAGE_VISIT to sensitive URLs (/checkout, /payment, /transfer) | +10 | Event |

**Low-risk country whitelist**: IT, DE, FR, GB, US, CA, AU, JP, NL, CH

**Score cap**: 100 (scores are clamped, never exceed 100)

**Score bands**:
- 0–25: LOW → SAFE
- 26–55: MEDIUM → SUSPICIOUS
- 56–100: HIGH → DANGEROUS

### RiskScoreResult DTO

```json
{
  "score": 72,
  "band": "HIGH",
  "triggeredRules": [
    { "ruleId": "R01", "description": "Unusual country", "points": 15 },
    { "ruleId": "R08", "description": "LOGIN_ATTEMPT followed by FORM_SUBMIT < 5s", "points": 30 },
    { "ruleId": "R09", "description": "Sensitive fields in form submission", "points": 20 },
    { "ruleId": "R03", "description": "Off-hours activity (01:00–05:00 UTC)", "points": 10 }
  ]
}
```

---

## 5. AI Risk Summary

### Endpoint behaviour
- Called from `POST /sessions/:id/ai-summary`
- Backend fetches session + events + RiskScoreResult
- Builds a structured prompt
- Calls Anthropic API via Spring AI ChatClient
- Returns parsed JSON response

### Prompt strategy
The prompt includes:
1. Session metadata (country, IP, device, timestamp, status)
2. Ordered event list with type, url, durationMs, metadata
3. **Already-computed triggered rules** — the model explains, not re-derives
4. Computed score and band

Instruction to model: return JSON only, no preamble, no markdown fences.

### AI role
The deterministic rule engine acts as **analyst**.
The AI model acts as **narrator** — it explains in human language what the rules found.
This separation ensures consistency and reduces hallucination risk.

---

## 6. Frontend Pages

### Login Screen
- Username + password form
- On success: store JWT in memory (not localStorage), redirect to sessions list
- On failure: show inline error

### Sessions List View
- Table: status dot | userId | IP | country | risk bar + score | timestamp
- Inline risk progress bar under each row (green/amber/red by band)
- Filter bar: by status (multi-select) and country (text input)
- "+ New Session" button → create form
- Click row → session detail

### Session Detail View
Two-column layout:
- Left: session metadata, status (inline editable dropdown), "Generate AI Summary" button
- Right: RiskScoreResult — score gauge + triggered rules breakdown with points

Event Timeline (below columns):
- Vertical CSS timeline, chronological order
- Each event: timestamp | type badge | url | durationMs
- Flag events that triggered rules (e.g. ⚠ proximity to LOGIN_ATTEMPT)
- "+ Add Event" button at bottom

AI Summary Panel (inline expansion, below the button):
- Appears after clicking "Generate AI Summary"
- Shows summary, riskLevel badge, recommendation
- Typewriter animation if streaming, spinner if synchronous

### Create / Edit Session Form
- Fields: userId, ip, country, device, timestamp, status
- Validation feedback inline
- Save → POST or PUT → redirect to detail

### Delete Session
- Confirmation dialog ("This will also delete N events. Are you sure?")
- On confirm → DELETE → redirect to sessions list

---

## 7. Seed Script

Location: `seed/seed.py`

Archetypes to generate:

| Archetype | Sessions | Key Pattern |
|-----------|----------|-------------|
| Credential Stuffer | 1 | 5 LOGIN_ATTEMPTs < 300ms each |
| Card Skimmer | 1 | LOGIN → FORM_SUBMIT (card_number, cvv) within 3s |
| Bot Crawler | 1 | 15 PAGE_VISITs all < 200ms, unusual country |
| Legitimate User | 1 | Normal PAGE_VISITs, 2000ms+, safe country |
| Suspicious Unclear | 1 | Mixed signals, medium score |
| Night Owl Attacker | 1 | 02:00 UTC, unusual country, FORM_SUBMIT |
| Repeat Offender | 3 | Same IP across 3 sessions |

Script behaviour:
1. POST /auth/login → get JWT
2. For each archetype: POST /sessions, then POST /sessions/:id/events per event
3. Print summary table with archetype name, expected score, expected status

---

## 8. Acceptance Criteria

### AC-01: Cascade Delete
Given a session with 3 events exists
When DELETE /sessions/:id is called
Then response is 204
And GET /sessions/:id returns 404
And events table has zero rows for that sessionId

### AC-02: Risk Score — Login + Form Submit Proximity
Given a session with LOGIN_ATTEMPT at T and FORM_SUBMIT at T+3s
When risk score is calculated
Then score includes +30
And triggeredRules contains R08

### AC-03: Risk Score Cap
Given rules that would sum to 130
When risk score is calculated
Then score == 100

### AC-04: Search Filter
Given sessions with SAFE, SUSPICIOUS, DANGEROUS statuses
When POST /sessions/search with { "filters": { "status": "DANGEROUS" } }
Then only DANGEROUS sessions are returned

### AC-05: JWT Protection
Given no Authorization header
When GET /sessions is called
Then response is 401

### AC-06: AI Rate Limit
Given a user has called POST /sessions/:id/ai-summary 5 times in one minute
When the 6th call is made
Then response is 429 with Retry-After header

### AC-07: POST Search Default Sort
Given multiple sessions exist
When POST /sessions/search with empty body {}
Then sessions are returned sorted by timestamp descending

---

## 9. Security Considerations

| Concern | Mitigation |
|---------|------------|
| JWT secret exposure | Read from `JWT_SECRET` env var, fail fast if missing |
| Anthropic API key exposure | Read from `ANTHROPIC_API_KEY` env var, never logged, never returned to client |
| CORS misconfiguration | Restrict to `http://localhost:5173` in dev, configurable via env var in prod |
| Input validation | Bean Validation (`@Valid`) on all request bodies, global exception handler returns 400 |
| AI endpoint abuse | Per-user rate limiting via Bucket4j, 5 req/min |
| Client-supplied country | Document as known limitation; production mitigation is server-side GeoIP lookup |

---

## 10. What Would Be Improved With More Time

- Refresh token support + logout blacklist (Redis)
- Server-side GeoIP enrichment (MaxMind GeoLite2) — remove trust on client-supplied country
- Streaming AI response via SSE → typewriter effect on frontend
- Frontend tests with React Testing Library (risk score component, filter bar)
- Pagination on GET /sessions and POST /sessions/search
- Distributed rate limiting (move from in-memory Bucket4j to Redis-backed)
