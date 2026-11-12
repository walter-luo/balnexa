"""python -m bnx_exec run --kind KIND [--item ID ...]

Runs one job kind over the given items (no item = one item with item_id null: BACKUP, EVIDENCE_VERIFY). Exit codes:
0 every item staged, 2 configuration error, 3 at least one item not staged, 4 terminated (SIGTERM/SIGINT).
"""
import argparse
import sys

from . import gateway, restore, runner, store


def build(cfg):
    tokens = gateway.StaticTokenProvider(path=cfg.id_token_file) if cfg.id_token_file else gateway.MetadataTokenProvider(cfg.exec_audience)
    gw = gateway.GatewayClient(cfg.gateway_url, tokens)
    completer = gateway.StagerCompleter(cfg.stager_dsn) if cfg.complete_via == "stager" else gw
    ctx = runner.Context(cfg,
                         artifacts=store.LocalStore(cfg.artifact_root) if cfg.artifact_root else None,
                         vault=store.LocalStore(cfg.vault_root) if cfg.vault_root else None,
                         evidence=store.LocalStore(cfg.evidence_root) if cfg.evidence_root else None,
                         provisioner=restore.LocalProvisioner(cfg.drill_conninfo, cfg.drill_admin, cfg.db_dir, cfg.drill_prefix)
                         if cfg.drill_conninfo else None)
    return ctx, gw, completer


def main(argv=None):
    ap = argparse.ArgumentParser(prog="bnx_exec")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--kind", required=True)
    r.add_argument("--item", action="append", default=[])
    a = ap.parse_args(argv)
    cfg = runner.Config()
    missing = cfg.missing(a.kind)
    if missing:
        runner.Context(cfg).log("config_error", reason="MISSING", fields=sorted(missing))
        return runner.EXIT_CONFIG
    ctx, gw, completer = build(cfg)
    runner.install_signals(ctx)
    code, _ = runner.run_items(ctx, gw, completer, a.kind, a.item or [None])
    return code


if __name__ == "__main__":
    sys.exit(main())
