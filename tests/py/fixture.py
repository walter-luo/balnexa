"""Synthetic household fixture built ONLY through production entry points:
installer step (migrator) -> authn_begin_session (bnx_authn) -> cmd_* (bnx_app). No t.* helpers, no superuser."""
import uuid
import psycopg
import harness as h

ISS = "https://accounts.google.com"


def claims(sub):
    return {"iss": ISS, "sub": sub, "email_verified": True, "aud": "test-client"}


class Household:
    def __init__(self, server, db=None):
        self.server = server
        self.db = db or h.fresh(server)
        self.app = h.Role(server, self.db, "bnx_app")
        self.authn = h.Role(server, self.db, "bnx_authn")
        self.worker = h.Role(server, self.db, "bnx_worker")
        self.owner_id = str(h.as_definer_via_migrator(server, self.db, "select bnx.install_household('Owner A', %s, 'g-owner')", (ISS,))[0][0])
        self.owner = self.login("g-owner")
        self.member_id = self.cmd(self.owner, "invite_member", display_name="Member B", role="member", google_sub="g-member")["member_id"]
        self.viewer_id = self.cmd(self.owner, "invite_member", display_name="Viewer C", role="viewer", google_sub="g-viewer")["member_id"]
        self.member = self.login("g-member")
        self.viewer = self.login("g-viewer")
        r = self.cmd(self.owner, "create_account", kind="bank_deposit", institution="Synthetic Bank", label="Joint chequing",
                     currencies=["CAD", "USD"])
        self.acc = r["account_id"]
        self.cad = next(x for x in r["account_currencies"] if x["currency"] == "CAD")
        self.usd = next(x for x in r["account_currencies"] if x["currency"] == "USD")
        self.groceries = self.cmd(self.owner, "create_category", kind="expense", currency="CAD", name_en="Groceries", name_zh="食品")["ledger_account_id"]
        self.salary = self.cmd(self.owner, "create_category", kind="income", currency="CAD", name_en="Salary", name_zh="工资")["ledger_account_id"]
        self.fees_usd = self.cmd(self.owner, "create_category", kind="expense", currency="USD", name_en="Fees", name_zh="手续费")["ledger_account_id"]
        self.cmd(self.owner, "set_opening", account_currency_id=self.cad["account_currency_id"], anchor_date="2026-01-01", amount="1000.00")
        self.cmd(self.owner, "set_opening", account_currency_id=self.usd["account_currency_id"], anchor_date="2026-01-01", amount="0")
        # member gets posting rights on the household account
        self.cmd(self.owner, "set_grant", member_id=self.member_id, account_id=self.acc, can_view=True, can_post=True)

    def login(self, sub):
        return {"kind": "session", "secret": self.authn.call("authn_begin_session", claims(sub))["session_token"]}

    def cmd(self, cred, _cmd, key=None, **body):
        body["idempotency_key"] = key or ("k-" + uuid.uuid4().hex)
        return self.app.call("cmd_" + _cmd, cred, body)

    def q(self, cred, _q, **body):
        return self.app.call("q_" + _q, cred, body)

    def expense(self, cred, amount, date="2026-02-10", key=None, ac=None, cat=None, desc="Synthetic grocery"):
        ac = ac or self.cad
        return self.cmd(cred, "post_transaction", key=key, economic_type="consumption_expense", transaction_date=date,
                        description=desc, lines=[
                            {"ledger_account_id": ac["ledger_account_id"], "currency": ac["currency"], "amount": f"-{amount}"},
                            {"ledger_account_id": cat or self.groceries, "currency": ac["currency"], "amount": f"{amount}"}])

    def balance(self, cred, ac=None, **kw):
        ac = ac or self.cad
        r = self.q(cred, "balances", account_currency_ids=[ac["account_currency_id"]], **kw)
        return r["balances"][0]["amount"] if r["balances"] else None

    def definer(self):
        cx = psycopg.connect(h.dsn(self.server, "bnx_migrator", self.db))
        cx.execute("set role bnx_definer")
        return cx

    def close(self):
        for r in (self.app, self.authn, self.worker):
            r.close()
