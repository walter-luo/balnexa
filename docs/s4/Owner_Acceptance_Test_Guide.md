# Balnexa — Owner acceptance test guide (synthetic test instance)

| Field | Value |
|---|---|
| Status | `DRAFT — AI-generated`; it becomes authoritative once the Owner confirms it |
| Instance | `https://balnexa-test.walter-luo.workers.dev` (synthetic data only; O-8 closed) |
| Release under test | The release named by `GET /api/v1/health` → `release`. This guide matches 0.8.8-p2 and later |
| Time | About 45 minutes for parts A–D; part E needs a second Google account; part F needs Claude |

Every step below is already covered by an automated test, named in the "Test" column, and the test records are in `EVIDENCE/regression/`. This guide checks the same behaviour on the real deployment, with your Google sign-in and your devices. Use **invented** names and amounts only.

When something differs from "Expect", note:
- the step number;
- the time;
- what you saw (a screenshot is fine).

The status line at the top of each screen shows the error code.

## A. Sign-in and home

| # | Do | Expect | Test |
|---|---|---|---|
| A1 | Open `/app/` and sign in with Google | Home: "Hello, <name> (Owner)". The status line is empty | AT-NOAI-01 |
| A2 | Open `/api/v1/health` | `bindings.ok: true`; `release` and `schema_head` as announced | BB-API, health |
| A3 | The header's language button (中文), then English | Every label switches; names and amounts stay the same | AT-UI-01 |

## B. Set up accounts (new screen)

| # | Do | Expect | Test |
|---|---|---|---|
| B1 | Home shows "No balances yet: set up your first account" → open it (also Menu › Accounts › Set up accounts) | Screen "Set up accounts" with steps 1–3 | AT-SETUP-01 |
| B2 | Step 1: search `CIBC` (or `EQ`, `PC`) → Find | A list of verified institutions; the first is selected | AT-SETUP-01 |
| B3 | Step 2: type Bank account, name "Test chequing", currency CAD, opening date the 1st of this month, amount `1000` → Create account | "Account "Test chequing" created"; it appears under "Your accounts" | AT-SETUP-01 |
| B4 | Step 2 again: type Credit card, name "Test Visa", CAD, opening `-250` | The card appears. Money owed is negative | AT-SETUP-01 |
| B5 | "Not in the list?": an invented institution name, country CA, evidence reference (any text you choose, e.g. a website address) → Propose and verify | "Institution ready", and it is selected. You can create an account with it | AT-SETUP-01 |
| B6 | Step 3: add expense categories "Groceries" / "食品杂货" and "Dining", and income "Salary", all in CAD | They are listed under Categories | AT-SETUP-01 |
| B7 | Home | The balances table shows Test chequing 1000 and Test Visa -250 | AT-NOAI-02 |

## C. Daily use

| # | Do | Expect | Test |
|---|---|---|---|
| C1 | Add: Expense, Test chequing, Groceries, `42.50`, today → Save | "Saved. Journal …" | AT-NOAI-03 |
| C2 | Add: Income, Salary, `3000` | Saved | AT-NOAI-03 |
| C3 | Add: Transfer from Test chequing to Test Visa, `100` | Saved; Home shows chequing −100 and Visa +100 | AT-NOAI-03 |
| C4 | Activity: this month; switch to Calendar; open a day | Counts and totals per day; the day lists its transactions | AT-CAL-01 |
| C5 | Activity: open the groceries entry → Reverse, reason "entered twice" | A reversal appears; Home returns to the earlier balance | AT-NOAI-03 |
| C6 | Reports: F1 balances → filter, then Export CSV | The CSV opens in a spreadsheet; no cell starts with `=`, `+`, `-` or `@` as a formula | AT-NOAI-06 |
| C7 | Phone: add the app to the home screen, turn on airplane mode, open it | The app says it is offline and shows no figures from cache | AT-UI-02 |

## D. Owner screens

| # | Do | Expect | Test |
|---|---|---|---|
| D1 | Menu › Onboarding: start a job, then Pause and Resume it | The job is listed and its state changes | AT-ONB-UI-01 |
| D2 | Menu › audit trail | Your actions from parts B and C, in order | AT-NOAI-07b |
| D3 | Menu › Documents; Menu › Upload | Empty redaction queue. Upload says uploads are not set up here (the R2 bucket is M0-B), and its button is disabled | AT-UP-01 |
| D4 | Menu › backup status | No verified backup yet (the Executor is not deployed) | AT-NOAI-07 |

## E. A second member (needs a second Google account)

To invite a member, you need that person's Google subject ID. Today it is shown only while the install probe is on (runbook step 6). Ask the AI to turn the probe on and redeploy, or see decision D-JOIN-1 below.

| # | Do | Expect | Test |
|---|---|---|---|
| E1 | The second account signs in | It sees "Installer setup … subject <number>" (probe on) | runbook step 6 |
| E2 | Menu › Identity › invite member: display name, role member, google_sub = that number; then set grant: can view Test chequing, cannot post | The member is listed | AT-NOAI-04 |
| E3 | The member signs in → Add an expense on Test chequing | "Sent for approval" with an "Open the draft" link | AT-NOAI-04 |
| E4 | You: Review → open the draft → Approve this exact version | It is posted and shows in Activity | AT-CONF-01…03 |
| E5 | Turn the probe off again (redeploy with probe 0) | Unknown accounts get a plain sign-in failure | runbook step 7 |

## F. AI assistant (Claude custom connector)

| # | Do | Expect | Test |
|---|---|---|---|
| F1 | Claude › Settings › Connectors › Add custom connector, URL `https://balnexa-test.walter-luo.workers.dev/mcp` | Claude opens the Balnexa consent screen in the app | AT-AIH-10 |
| F2 | On the consent screen: tick read and draft, and only Test chequing → Allow | Claude shows the connector as connected | AT-AIH-10 |
| F3 | Ask Claude: "What are my balances in Balnexa?" | It quotes Test chequing only, with the ledger version. Test Visa was not consented, so it must not appear | BB-OAUTH-01, AT-OUT-01 |
| F4 | Ask Claude: "Record a 12 dollar lunch yesterday on Test chequing" | Claude creates a **draft**, not a posting. It shows a card or a link "Review and approve this exact version in Balnexa", and never says it was posted | AT-CONF via AIH-4 card |
| F5 | Open the link → Approve | It is posted. Ask Claude to read the balance again: it is 12 lower | AT-CONF-01/02 |
| F6 | Ask Claude to post directly or change something without a draft | It refuses: only drafts are possible from Claude | BB-OAUTH-01 (FORBIDDEN_CHANNEL) |
| F7 | Menu › AI connections → Revoke | Claude's next Balnexa call fails and asks you to reconnect | AT-AIH-10 |

## G. Not testable on this instance yet

| Feature | Why | When |
|---|---|---|
| Evidence upload and the document pipeline (Drive Inbox, statement mail) | Needs the R2 bucket, a Drive identity and mail credentials | M0-B (OD-50) |
| Backups, report rendering and other Executor jobs | The Executor image builds in CI but is not deployed to Cloud Run | M0-A remainder / M0-E |
| Handoff between two Balnexa projects | Needs a second instance | M0 |
| Tax (CRA) module | Gate G-CRA-1 is closed | Owner |
| ChatGPT | POC-AUTH covers it, but this guide covers Claude first | after F |

## Owner decisions raised by this guide

| ID | Question | Recommendation |
|---|---|---|
| D-JOIN-1 | Should someone who is not yet a member always see their own Google subject ID ("join code") after signing in, so that the Owner can invite them without the install probe and a redeploy? | Yes. The ID is shown only to the person who just proved they hold that Google account, which is what the probe already does. The alternative is an email-based invite, which needs a mail provider |
