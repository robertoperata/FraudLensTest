# claude.md — FraudLens Agent Instructions

You are building FraudLens, a full-stack fraud analysis application.
Read SPEC.md first. This file contains agent-specific instructions, conventions,
and traps to avoid. Always follow these instructions precisely.

---

## Project Structure

```
fraudlens/
├── claude.md
├── SPEC.md
├── AC.md
├── README.md
├── docker-compose.yml
├── backend/                  ← Spring Boot 3.3, Java 25, Maven
│   ├── pom.xml
│   └── src/
│       ├── main/java/com/fraudlens/
│       │   ├── FraudLensApplication.java
│       │   ├── config/
│       │   │   ├── SecurityConfig.java
│       │   │   └── CorsConfig.java
│       │   ├── auth/
│       │   │   ├── AuthController.java
│       │   │   ├── JwtService.java
│       │   │   └── JwtAuthenticationFilter.java
│       │   ├── session/
│       │   │   ├── Session.java
│       │   │   ├── SessionRepository.java
│       │   │   ├── SessionService.java
│       │   │   └── SessionController.java
│       │   ├── event/
│       │   │   ├── Event.java
│       │   │   ├── EventRepository.java
│       │   │   ├── EventService.java
│       │   │   └── EventController.java
│       │   ├── risk/
│       │   │   ├── RiskScoreService.java
│       │   │   └── RiskScoreResult.java
│       │   └── ai/
│       │       └── AiSummaryService.java
│       └── test/java/com/fraudlens/
│           ├── risk/RiskScoreServiceTest.java
│           └── session/SessionControllerTest.java
├── frontend/                 ← React 18, Vite, Tailwind, React Query v5
│   ├── package.json
│   └── src/
│       ├── main.jsx
│       ├── App.jsx
│       ├── api/              ← axios client + all API calls
│       ├── auth/             ← AuthContext, ProtectedRoute
│       ├── pages/
│       │   ├── Login.jsx
│       │   ├── SessionList.jsx
│       │   ├── SessionDetail.jsx
│       │   └── SessionForm.jsx
│       └── components/
│           ├── RiskBadge.jsx
│           ├── RiskBar.jsx
│           ├── RiskBreakdown.jsx
│           ├── EventTimeline.jsx
│           ├── AiSummaryPanel.jsx
│           └── ConfirmDialog.jsx
└── seed/
    └── seed.py
```

---

## Tech Stack — Exact Versions

### Backend
```xml
Java 21
Spring Boot 3.3.x
spring-boot-starter-web
spring-boot-starter-data-jpa
spring-boot-starter-security
spring-boot-starter-validation
spring-boot-starter-actuator
spring-ai-starter-model-anthropic 1.0.0          ← renamed in 1.0.0 GA (was spring-ai-anthropic-spring-boot-starter)
io.jsonwebtoken:jjwt-api:0.12.6
io.jsonwebtoken:jjwt-impl:0.12.6
io.jsonwebtoken:jjwt-jackson:0.12.6
com.bucket4j:bucket4j-core:8.10.1
org.postgresql:postgresql (runtime)
org.liquibase:liquibase-core
springdoc-openapi-starter-webmvc-ui:2.x
```

### Frontend
```json
react: 18.x
react-dom: 18.x
react-router-dom: 6.x
@tanstack/react-query: 5.x
axios: 1.x
tailwindcss: 3.x
lucide-react: latest
```

---

## Critical Implementation Rules

### RULE 1 — Spring Security 6 Syntax (IMPORTANT)
This project uses Spring Boot 3.3 which includes Spring Security 6.
NEVER use deprecated Spring Security 5 patterns:

```java
// WRONG — Spring Security 5, will not compile
.antMatchers("/auth/login").permitAll()
http.authorizeRequests()
extends WebSecurityConfigurerAdapter

// CORRECT — Spring Security 6
.requestMatchers("/auth/login").permitAll()
http.authorizeHttpRequests()
@Bean SecurityFilterChain
```

### RULE 2 — PostgreSQL Datasource Configuration
Use PostgreSQL 16. Configure via environment variables so the same
application.properties works locally and in Docker:

```properties
# application.properties
spring.datasource.url=${POSTGRES_URL:jdbc:postgresql://localhost:5432/fraudlens}
spring.datasource.username=${POSTGRES_USER:fraudlens}
spring.datasource.password=${POSTGRES_PASSWORD:fraudlens}
spring.datasource.driver-class-name=org.postgresql.Driver
spring.jpa.database-platform=org.hibernate.dialect.PostgreSQLDialect
spring.jpa.hibernate.ddl-auto=validate
spring.liquibase.change-log=classpath:db/changelog/db.changelog-master.yaml
```

NEVER use `spring.jpa.hibernate.ddl-auto=create` or `update` — Liquibase owns the schema.

NEVER use `spring.jpa.hibernate.ddl-auto=create` or `update` — Liquibase owns the schema.

### RULE 3 — Cascade Delete at Both Levels
Enforce cascade delete at JPA level AND schema level:

```java
// Session.java — JPA level
@OneToMany(mappedBy = "session", cascade = CascadeType.ALL, orphanRemoval = true)
private List<Event> events = new ArrayList<>();
```

```sql
-- Schema level (in schema.sql or via ddl)
CONSTRAINT fk_session FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
```

### RULE 4 — POST /sessions/search Accepts JSON Body
This endpoint receives filters as a JSON request body, NOT query parameters:

```java
@PostMapping("/sessions/search")
public ResponseEntity<List<SessionDto>> search(@RequestBody SearchRequest request) { ... }
```

```java
// SearchRequest.java
public class SearchRequest {
    private Map<String, String> filters; // any Session field → value
    private String sortBy = "timestamp"; // "timestamp" | "id"
    private String sortDir = "desc";     // "asc" | "desc"
}
```

### RULE 5 — Risk Score Returned on Every Session Response
Every endpoint that returns a Session (GET /sessions, GET /sessions/:id, POST /sessions/search)
MUST include the riskScore and triggeredRules in the response.
Compute in SessionService by calling RiskScoreService before returning the DTO.

### RULE 6 — JWT Secret from Environment Variable
NEVER hardcode the JWT secret:

```java
// WRONG
private static final String SECRET = "mysecretkey";

// CORRECT
@Value("${jwt.secret}")
private String secret;
```

```properties
# application.properties
jwt.secret=${JWT_SECRET:dev-secret-change-in-production}
jwt.expiration=3600000
```

### RULE 7 — Spring AI ChatClient Fluent API (1.0.x style)
Use the current Spring AI 1.0.x API. Do NOT use deprecated patterns:

```java
// CORRECT — Spring AI 1.0.x
@Autowired
private ChatClient chatClient;

String response = chatClient.prompt()
    .user(promptText)
    .call()
    .content();

// WRONG — older style, do not use
chatModel.call(new Prompt(...))
aiClient.generate(...)
```

Anthropic requires `max-tokens` to be set explicitly — always include this in `application.properties`:
```properties
spring.ai.anthropic.chat.options.model=claude-haiku-4-5-20251001
spring.ai.anthropic.chat.options.max-tokens=1024
```

### RULE 8 — CORS Restricted to Frontend Origin
```java
// CorsConfig.java
configuration.setAllowedOrigins(List.of("http://localhost:5173"));
configuration.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "OPTIONS"));
configuration.setAllowedHeaders(List.of("*"));
configuration.setAllowCredentials(true);
```

### RULE 9 — JWT Stored in Memory on Frontend (NOT localStorage)
Store the JWT in React context/state only. Never use localStorage or sessionStorage.
This prevents XSS token theft.

```jsx
// AuthContext.jsx
const [token, setToken] = useState(null); // in-memory only
```

### RULE 10 — Global Exception Handler
Create a `@RestControllerAdvice` that handles:
- `EntityNotFoundException` → 404
- `MethodArgumentNotValidException` → 400 with field errors
- `RateLimitExceededException` → 429
- `AnthropicApiException` → 503
- Generic `Exception` → 500 (no stack trace in response body)

### RULE 11 — Session Entity Convenience Methods
The Session entity MUST include convenience methods for managing the
bidirectional relationship with Event. Never manipulate the events
collection directly from outside the entity:

```java
// Session.java
public void addEvent(Event event) {
    events.add(event);
    event.setSession(this);
}

public void removeEvent(Event event) {
    events.remove(event);
    event.setSession(null);
}
```

Always call these methods from EventService — never call
`session.getEvents().add(event)` directly from outside the entity.
This ensures bidirectional sync and correct orphanRemoval behaviour.

### RULE 12 — Swagger / SpringDoc (IMPORTANT)
Use springdoc-openapi-starter-webmvc-ui 2.x — NOT springfox.
Springfox is abandoned and does not work with Spring Boot 3.

Permit Swagger endpoints in SecurityFilterChain WITHOUT JWT:
```java
.requestMatchers(
    "/swagger-ui.html",
    "/swagger-ui/**",
    "/v3/api-docs/**"
).permitAll()
```

Add `@OpenAPIDefinition` + `@SecurityScheme(name = "bearerAuth")` to a
dedicated `OpenApiConfig.java` class so the Swagger UI "Authorize" button
works with the JWT token.

Annotate every controller with `@Tag` and every method with
`@Operation(summary = "...")` and `@ApiResponse` for each HTTP status code
the method can return. Annotate all request/response DTOs with `@Schema`.

### RULE 13 — Actuator: Health Endpoint Only
Include spring-boot-starter-actuator but expose ONLY the health endpoint.
Never rely on default Actuator configuration — it exposes sensitive internals.

```properties
# application.properties
management.endpoints.web.exposure.include=health
management.endpoints.web.exposure.exclude=*
management.endpoint.health.show-details=when-authorized
management.health.livenessstate.enabled=true
management.health.readinessstate.enabled=true
```

Permit health endpoints WITHOUT JWT in SecurityFilterChain (alongside Swagger):
```java
.requestMatchers(
    "/actuator/health",
    "/actuator/health/**",
    "/swagger-ui.html",
    "/swagger-ui/**",
    "/v3/api-docs/**"
).permitAll()
```

Add a Docker healthcheck in docker-compose.yml using the health endpoint:
```yaml
backend:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
    interval: 30s
    timeout: 10s
    retries: 3
```

NEVER expose these endpoints — they leak secrets and internal state:
env, heapdump, beans, mappings, loggers, threaddump, configprops.

### RULE 14 — Database Schema and User Seeding
Use Liquibase for schema management. Do NOT use
`spring.jpa.hibernate.ddl-auto=create` or `update` in production config.

```
Liquibase changelog location: src/main/resources/db/changelog/
Master file:      db.changelog-master.yaml
First changeset:  001-create-schema.sql  (tables + FK with ON DELETE CASCADE)
```

Use a Spring `ApplicationRunner` bean for initial user seeding — NOT a
Liquibase INSERT — because password hashing requires BCryptPasswordEncoder
to be available at runtime:

```java
@Bean
ApplicationRunner seedUsers(UserRepository repo, PasswordEncoder encoder) {
    return args -> {
        if (repo.count() == 0) {
            repo.save(new User("admin", encoder.encode("admin"), "ADMIN"));
        }
    };
}
```

The `repo.count() == 0` guard makes it idempotent across restarts.
Never store plaintext passwords — always hash with BCryptPasswordEncoder.

---

## Risk Score Implementation Guide

Implement `RiskScoreService.calculate(Session session, List<Event> events)`:

```
Input:  Session + List<Event>
Output: RiskScoreResult { int score, String band, List<TriggeredRule> triggeredRules }
```

Rules in order (see SPEC.md Section 4 for full table):
1. Check country against LOW_RISK_WHITELIST = {IT, DE, FR, GB, US, CA, AU, JP, NL, CH}
2. Check IP reuse — query SessionRepository.countByIp(session.getIp()) > 1
3. Check timestamp hour (parse UTC, check 1 <= hour <= 5)
4. Check status SUSPICIOUS / DANGEROUS
5. Count LOGIN_ATTEMPT events (R06 vs R07 — do not double count)
6. Check LOGIN_ATTEMPT → FORM_SUBMIT within 5000ms (sort events by timestamp, find pairs)
7. Check FORM_SUBMIT metadata for sensitive field names
8. Count total events > 10
9. Check all durationMs < 500
10. Check PAGE_VISIT urls against {/checkout, /payment, /transfer}

Cap final score at 100.
Map score to band: 0-25=LOW, 26-55=MEDIUM, 56-100=HIGH.

---

## AI Summary Prompt Template

Build this prompt in `AiSummaryService`:

```
System: You are a fraud analyst assistant. Analyze the session data provided and return
a JSON object only — no preamble, no markdown, no explanation outside the JSON.

User:
Analyze this user session for fraud risk.

SESSION:
- User: {userId}
- IP: {ip}
- Country: {country}
- Device: {device}
- Time: {timestamp} UTC
- Current Status: {status}
- Risk Score: {score}/100 ({band})

TRIGGERED RISK RULES:
{triggeredRules as bullet list}

EVENTS (chronological):
{events as numbered list: index. [TYPE] url — durationMs ms — metadata}

Return exactly this JSON structure:
{
  "summary": "2-3 sentence natural language assessment",
  "riskLevel": "LOW|MEDIUM|HIGH",
  "recommendation": "one actionable sentence for the analyst"
}
```

Parse the response as JSON. If parsing fails, return the raw text in the summary field
with riskLevel derived from the session's score band.

---

## Frontend Component Conventions

### API Client (src/api/client.js)
- Axios instance with baseURL from `import.meta.env.VITE_API_URL` (default: `http://localhost:8080`)
- Request interceptor: attach `Authorization: Bearer <token>` from AuthContext
- Response interceptor: on 401 → clear token, redirect to /login

### React Query Keys
Use consistent query keys:
```js
['sessions']                    // session list
['sessions', id]                // single session with events
['sessions', id, 'events']      // events only
```

### Risk Score Display
- Score 0-25: green (`text-green-600`, `bg-green-100`)
- Score 26-55: amber (`text-amber-600`, `bg-amber-100`)
- Score 56-100: red (`text-red-600`, `bg-red-100`)

Progress bar width: `style={{ width: `${score}%` }}`

### Status Badge Colors
- SAFE: green
- SUSPICIOUS: amber
- DANGEROUS: red

---

## Environment Variables

### Backend (.env or system)
```
JWT_SECRET=change-this-in-production-min-32-chars
ANTHROPIC_API_KEY=sk-ant-...
CORS_ORIGIN=http://localhost:5173
POSTGRES_URL=jdbc:postgresql://localhost:5432/fraudlens
POSTGRES_USER=fraudlens
POSTGRES_PASSWORD=fraudlens
```

### Frontend (.env)
```
VITE_API_URL=http://localhost:8080
```

---

## Test Coverage Targets

### RiskScoreServiceTest.java (unit tests — required)
Write tests for every rule in the table. Key cases:
- `givenCredentialStuffer_scoreAbove55`
- `givenLoginFollowedByFormSubmitWithin5s_adds30Points`
- `givenSensitiveFormFields_adds20Points`
- `givenOffHoursTimestamp_adds10Points`
- `givenScoreWouldExceed100_capsAt100`
- `givenSafeSession_scoreBelow25`
- `givenThreeLoginAttempts_usesR07NotR06` (no double counting)

### SessionControllerTest.java (integration tests — required)
Use `@SpringBootTest` + `MockMvc` + `@WithMockUser`:
- `deleteSession_cascadesEvents`
- `searchWithStatusFilter_returnsOnlyMatchingSessions`
- `requestWithoutJwt_returns401`
- `createSessionWithInvalidBody_returns400WithFieldErrors`

---

## Docker Setup

### backend/Dockerfile
Multi-stage Maven build:
1. Stage 1: `maven:3.9-eclipse-temurin-21` — run `mvn package -DskipTests`
2. Stage 2: `eclipse-temurin:21-jre` — copy JAR, expose 8080

### frontend/Dockerfile
1. Stage 1: `node:20-alpine` — run `npm ci && npm run build`
2. Stage 2: `nginx:alpine` — copy dist/, expose 80

### docker-compose.yml
- Services: `postgres`, `backend`, `frontend`
- postgres: image `postgres:16-alpine`, env `POSTGRES_DB=fraudlens`, `POSTGRES_USER=fraudlens`, `POSTGRES_PASSWORD=fraudlens`, port 5432:5432, named volume `postgres_data`
- backend: port 8080:8080, depends_on postgres (with condition `service_healthy`), env vars:
  - `POSTGRES_URL=jdbc:postgresql://postgres:5432/fraudlens`
  - `POSTGRES_USER=fraudlens`
  - `POSTGRES_PASSWORD=fraudlens`
  - `JWT_SECRET` and `ANTHROPIC_API_KEY` from host env
- frontend: port 3000:80, depends_on backend
- postgres healthcheck: `pg_isready -U fraudlens`
- backend healthcheck: `curl -f http://localhost:8080/actuator/health`

```yaml
volumes:
  postgres_data:
```

---

## Seed Script — User Personas

Define these personas at the top of `seed/seed.py`.
Do not use random userIds — use this fixed cast so that:
- The IP reuse rule (R02) fires correctly across repeat offender sessions
- The UI shows all three risk bands during the demo
- The filter bar is demonstrably useful (enough SAFE sessions to filter out)

```python
USERS = {
    "legit_it":  "usr_legit_001",    # Normal IT user        → SAFE
    "legit_us":  "usr_legit_002",    # Normal US user        → SAFE
    "stuffer":   "usr_attacker_001", # Credential stuffer    → DANGEROUS
    "skimmer":   "usr_attacker_002", # Card skimmer          → DANGEROUS
    "bot":       "usr_bot_001",      # Automated bot         → DANGEROUS
    "suspect":   "usr_suspect_001",  # Ambiguous signals     → SUSPICIOUS
    "night":     "usr_night_001",    # Off-hours attacker    → DANGEROUS
    "repeat":    "usr_repeat_001",   # Repeat offender       → DANGEROUS (3 sessions)
}

# Reused across all 3 repeat offender sessions — triggers R02 (+20)
REPEAT_OFFENDER_IP = "185.220.101.45"
```

These are session subject identifiers — NOT application login users.
The `admin` user (created by ApplicationRunner) is who logs into FraudLens.
The `usr_*` strings are monitored subjects stored as plain strings on the
Session entity, never as rows in the users table.

At the end of the script print a summary table:

```
User              Sessions  Expected Score  Expected Status
────────────────────────────────────────────────────────────
usr_legit_001     1         ~8              SAFE
usr_legit_002     1         ~12             SAFE
usr_attacker_001  1         ~85             DANGEROUS
usr_attacker_002  1         ~75             DANGEROUS
usr_bot_001       1         ~70             DANGEROUS
usr_suspect_001   1         ~45             SUSPICIOUS
usr_night_001     1         ~65             DANGEROUS
usr_repeat_001    3         ~72             DANGEROUS

Total: 10 sessions created across 8 users
```

---

## README Sections to Generate

When writing README.md, include these sections in this order:
1. **Overview** — what FraudLens does, one paragraph
2. **Quick Start** — local setup commands (backend, frontend, seed script)
3. **Docker** — single command startup
4. **Architecture Decisions** — data layer, auth, AI integration, risk engine
5. **Risk Score Rules** — full table with reasoning column
6. **Security Considerations** — min 4 items, each with concern + mitigation
7. **Known Limitations & Future Improvements** — honest, specific

The README is graded. Write it like a lightweight design document, not a setup guide.
