// Release manifest of this Worker (B3, Amendment 03 §5.2; IL V1.2 §4: supports_schema_from = N-1). The Gateway serves a
// database whose migration heads lie inside these ranges; otherwise it answers 503 BNX_BINDING_MISMATCH and only
// /api/v1/health responds. work_kinds: the work-item kinds this release processes (deploy rule UA §9.1: a release that
// understands a kind is deployed before the migration that can enqueue it; others are deferred, never dropped).
export const RELEASE = {
  version: '0.8.5-p2',
  supports_schema: { core: ['0109', '0109'], extension: ['9029', '9030'] },
  work_kinds: ['plan.execute', 'staging.promote'],
};
