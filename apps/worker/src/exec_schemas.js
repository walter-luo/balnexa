// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// Completion payload schemas per (job kind, staging kind) (UA V1.2 §9.2: "a staging payload (JSON Schema per job kind;
// size-capped); the Gateway validates"). CORE-8: the kinds whose promoters exist in 9016/9018. Shapes only: the promoters
// (wrk_render_done, wrk_backup_recorded, wrk_evidence_state, wrk_restore_drill_recorded) stay the validators of record and
// re-check every value against the database. A pair not listed here is passed to the database unchanged (document and mail
// kinds keep their 9010/9011 contracts).
const HEX = { type: 'string', pattern: '^[0-9a-f]{64}$' };
const TS = { type: 'string', format: 'date-time' };
const UUIDS = { type: 'string', format: 'uuid' };
const KIB = { type: 'integer', minimum: 0 };
const OBJ = { type: 'object' };
const USAGE = OBJ;

export const EXEC_SCHEMAS = {
  'REPORT_RENDER/render_done': {
    type: 'object', additionalProperties: false,
    required: ['snapshot_id', 'artifact_sha256', 'rendered_at', 'renderer_version', 'projection_sha256', 'source_revision', 'ownership_revision', 'size_kib'],
    properties: {
      snapshot_id: UUIDS, artifact_sha256: HEX, rendered_at: TS, renderer_version: { type: 'string', pattern: '^[A-Za-z0-9._-]{1,40}$' },
      projection_sha256: HEX, source_revision: { type: 'integer', minimum: 0 }, ownership_revision: { type: 'integer', minimum: 0 },
      size_kib: KIB, coverage: OBJ, warnings: { type: 'array', maxItems: 50, items: { type: 'string', maxLength: 80 } }, usage: USAGE,
    },
  },
  'BACKUP/backup_recorded': {
    type: 'object', additionalProperties: false,
    required: ['run_id', 'started_at', 'ended_at', 'outcome'],
    properties: {
      run_id: UUIDS, started_at: TS, ended_at: TS, local_date: { type: 'string', format: 'date' },
      tier: { enum: ['DAILY', 'WEEKLY', 'MONTHLY'] }, retain_until: TS, destination: { enum: ['OFF_PROVIDER'] },
      outcome: { enum: ['VERIFIED', 'FAILED'] }, failure_reason: { type: 'string', maxLength: 200 },
      object: { type: 'object', additionalProperties: false, properties: { generation: { type: 'string', pattern: '^[0-9]{1,24}$' } } },
      sizes: { type: 'object', additionalProperties: false, properties: { compressed_kib: KIB, wire_kib: KIB } },
      dump_sha256: HEX, plaintext_sha256: HEX, header_sha256: HEX, tools: OBJ, verify: OBJ, recipients: OBJ, header: OBJ, usage: USAGE,
    },
  },
  'EVIDENCE_VERIFY/backup_recorded': {
    type: 'object', additionalProperties: false, required: ['items'],
    properties: {
      items: { type: 'array', minItems: 1, maxItems: 500, items: { type: 'object', additionalProperties: false,
        required: ['evidence_object_id', 'copy', 'observed_sha256'],
        properties: { evidence_object_id: UUIDS, copy: { enum: ['R2', 'DRIVE'] }, observed_sha256: HEX } } },
      started_at: TS, ended_at: TS, usage: USAGE,
    },
  },
  'RESTORE_DRILL/restore_drill_recorded': {
    type: 'object', additionalProperties: false,
    required: ['drill_id', 'backup_run_id', 'decrypt_key_id', 'started_at', 'ended_at', 'outcome', 'cleanup_verified'],
    properties: {
      drill_id: UUIDS, backup_run_id: UUIDS, kind: { enum: ['DRILL', 'RESTORE_SAME_IDENTITY', 'RESTORE_AS_NEW'] },
      target: { enum: ['ISOLATED_DRILL', 'NEW_PROJECT', 'PRODUCTION'] }, decrypt_key_id: { type: 'string', minLength: 1, maxLength: 80 },
      started_at: TS, ended_at: TS, outcome: { enum: ['PASS', 'FAIL'] }, restored_header: OBJ, cleanup_verified: { type: 'boolean' },
      tools: OBJ, failure_reason: { type: 'string', maxLength: 200 }, authorization_id: UUIDS, usage: USAGE,
    },
  },
};

export const schemaFor = (jobKind, stgKind) => EXEC_SCHEMAS[`${jobKind}/${stgKind}`] || null;
