# NULL-guard sweep (L-R2-1)

Migration head: 9040. Undisposed pairs: 0; must_refuse pairs still accepted: 0 []; JSON-argument functions neither swept nor reviewed by reading: 0; reviewed by reading: cmd_confirm_posting_date, cmd_revoke_session, wrk_ack_index_record, wrk_audit_sin_refusal, wrk_onboarding_step.

Functions exercised: 89; calls swept: 2823; (function, key path) pairs tried: 455; accepted with a key absent, null or empty: 155.

| Function | Key path | Accepted modes | Disposition | Reason |
|---|---|---|---|---|
| `cmd_accept_instance_config` | `reason` | absent 1, empty 1, null 1 | optional | reason is a free-text note; the decision is carried by the other fields |
| `cmd_approve_ai_connection` | `resource` | absent 2, empty 2, null 2 | limitation | L-NULL-1: no resource stores NULL and the B7 resource check is skipped (legacy connections by design); Owner review |
| `cmd_correct_transaction` | `reason` | absent 8, empty 8, null 8 | optional | reason is optional text; no replacement means reverse only |
| `cmd_correct_transaction` | `replacement` | absent 6 | optional | reason is optional text; no replacement means reverse only |
| `cmd_create_account` | `region_scope` | absent 1, empty 1, null 1 | optional | region_scope and visibility have documented defaults |
| `cmd_create_account` | `visibility` | absent 52, null 52 | optional | region_scope and visibility have documented defaults |
| `cmd_create_category` | `name_zh` | absent 129, empty 129, null 129 | optional | name_zh is optional (name_en is required) |
| `cmd_create_import_plan` | `evidence_file_ids` | absent 1, empty 1 | optional | optional plan or item keys (evidence_file_ids, statement, require_fingerprints, needs_review, source_fingerprint; V-06 holds a plan without fingerprints when they are required); kind defaults to import; the item currency is the plan account's |
| `cmd_create_import_plan` | `items[0].amount` | absent 1, null 1 | optional | a typed item's amount is replaced by its plan account line (never the caller's figure) |
| `cmd_create_import_plan` | `items[0].currency` | absent 1, null 1 | optional | optional plan or item keys (evidence_file_ids, statement, require_fingerprints, needs_review, source_fingerprint; V-06 holds a plan without fingerprints when they are required); kind defaults to import; the item currency is the plan account's |
| `cmd_create_import_plan` | `items[0].needs_review` | absent 1, null 1 | optional | optional plan or item keys (evidence_file_ids, statement, require_fingerprints, needs_review, source_fingerprint; V-06 holds a plan without fingerprints when they are required); kind defaults to import; the item currency is the plan account's |
| `cmd_create_import_plan` | `items[0].source_fingerprint` | absent 1, null 1 | optional | optional plan or item keys (evidence_file_ids, statement, require_fingerprints, needs_review, source_fingerprint; V-06 holds a plan without fingerprints when they are required); kind defaults to import; the item currency is the plan account's |
| `cmd_create_import_plan` | `kind` | absent 1, null 1 | optional | optional plan or item keys (evidence_file_ids, statement, require_fingerprints, needs_review, source_fingerprint; V-06 holds a plan without fingerprints when they are required); kind defaults to import; the item currency is the plan account's |
| `cmd_create_import_plan` | `require_fingerprints` | absent 1, null 1 | optional | optional plan or item keys (evidence_file_ids, statement, require_fingerprints, needs_review, source_fingerprint; V-06 holds a plan without fingerprints when they are required); kind defaults to import; the item currency is the plan account's |
| `cmd_create_import_plan` | `statement` | absent 3, null 3 | optional | optional plan or item keys (evidence_file_ids, statement, require_fingerprints, needs_review, source_fingerprint; V-06 holds a plan without fingerprints when they are required); kind defaults to import; the item currency is the plan account's |
| `cmd_create_report_snapshot` | `account_currency_ids` | absent 7, empty 7 | optional | as_of defaults to today; no account_currency_ids means all visible |
| `cmd_create_report_snapshot` | `as_of` | absent 20, null 20 | optional | as_of defaults to today; no account_currency_ids means all visible |
| `cmd_declare_financial_policy` | `household_timezone` | absent 1, null 1 | optional | an absent key keeps the current policy value |
| `cmd_declare_financial_policy` | `reporting_currency` | absent 1, null 1 | optional | an absent key keeps the current policy value |
| `cmd_declare_loan` | `due_date` | absent 1, null 1 | optional | due_date and the counterpart account currencies are optional by loan kind; the required ones are checked per kind |
| `cmd_declare_loan` | `payable_account_currency_id` | absent 35, null 35 | optional | due_date and the counterpart account currencies are optional by loan kind; the required ones are checked per kind |
| `cmd_declare_loan` | `receivable_account_currency_id` | absent 35, null 35 | optional | due_date and the counterpart account currencies are optional by loan kind; the required ones are checked per kind |
| `cmd_draft_create_transaction` | `amount` | absent 2, empty 2, null 2 | optional | typed drafts take the amount from the lines (never the caller's figure) |
| `cmd_draft_create_transaction` | `description` | absent 6, null 6 | optional | description defaults to the economic type |
| `cmd_handoff_import` | `account_currency_id` | absent 2, empty 2, null 2 | optional | account_currency_id is needed only for PROPOSAL and REVERSAL blocks, which check it |
| `cmd_handoff_prepare` | `note` | absent 1, empty 1, null 1 | optional | note is optional text |
| `cmd_link_loan_payment` | `event` | absent 3, null 3 | optional | event defaults to the payment event |
| `cmd_post_transaction` | `settled_rate` | absent 1, null 1 | optional | settled_rate is optional (cross-currency postings only) |
| `cmd_prepare_config_draft` | `deployment_mode` | absent 1, empty 1, null 1 | optional | deployment_mode defaults to the current mode |
| `cmd_propose_institution_candidate` | `evidence` | absent 126, empty 126, null 126 | optional | evidence and jurisdiction are optional; a name in either language is required and checked |
| `cmd_propose_institution_candidate` | `evidence[0].doc` | absent 1, null 1 | optional | evidence and jurisdiction are optional; a name in either language is required and checked |
| `cmd_propose_institution_candidate` | `evidence[0].kind` | absent 125, null 125 | optional | evidence and jurisdiction are optional; a name in either language is required and checked |
| `cmd_propose_institution_candidate` | `jurisdiction` | absent 130, null 130 | optional | evidence and jurisdiction are optional; a name in either language is required and checked |
| `cmd_propose_institution_candidate` | `name_en` | absent 1 | optional | evidence and jurisdiction are optional; a name in either language is required and checked |
| `cmd_reassign_account_institution` | `reason` | absent 1, null 1 | optional | reason is optional text |
| `cmd_record_card_fee_event` | `as_of` | absent 1, null 1 | optional | as_of defaults to today |
| `cmd_record_investment_lot` | `source_journal_id` | absent 2, null 2 | optional | source_journal_id is an optional link |
| `cmd_record_lot_disposal` | `supersedes_disposal_id` | absent 1 | optional | supersedes_disposal_id is set only on a correction |
| `cmd_record_observation` | `revision_of` | absent 1, null 1 | optional | revision_of is set only on a revision |
| `cmd_register_evidence` | `name` | absent 5, empty 5, null 5 | optional | name is optional (withheld names are allowed) |
| `cmd_register_index_source` | `enabled` | absent 7, null 7 | optional | enabled defaults to true |
| `cmd_register_mail_source` | `credential_state` | absent 2, null 2 | optional | credential_state defaults to pending |
| `cmd_run_reconciliation` | `accept_stage1_fail` | absent 1, null 1 | optional | accept_stage1_fail defaults to false |
| `cmd_set_cost_policy` | `exec_allocation` | absent 1 | optional | merge semantics: an absent key keeps the current policy value |
| `cmd_set_cost_policy` | `spend_cap_variant` | absent 1 | optional | merge semantics: an absent key keeps the current policy value |
| `cmd_set_cost_policy` | `vault_allocation` | absent 1 | optional | merge semantics: an absent key keeps the current policy value |
| `cmd_set_grant` | `can_post` | absent 76, null 76 | optional | can_view and can_post default to false |
| `cmd_set_grant` | `can_view` | absent 21, null 21 | optional | can_view and can_post default to false |
| `cmd_set_import_mapping` | `mapping_id` | absent 1, null 1 | optional | no mapping_id creates a new mapping |
| `cmd_set_mail_route` | `effective_from` | absent 1, null 1 | optional | effective_from defaults to now |
| `cmd_set_payment_attribute` | `payment_method` | absent 1, null 1 | optional | either payment_method or payment_network is enough (the table CHECK requires one) |
| `cmd_set_payment_attribute` | `payment_network` | absent 1, null 1 | optional | either payment_method or payment_network is enough (the table CHECK requires one) |
| `cmd_set_reconciliation_exception_state` | `note` | absent 1 | optional | note is optional text |
| `cmd_verify_institution` | `kind` | absent 126, null 126 | optional | kind defaults to bank |
| `wrk_admission_decide` | `estimated_instance_seconds` | absent 21, null 21 | limitation | L-NULL-2: absent sizing inputs default to zero (worker-trusted, no app callers); Owner review before admission is enforced |
| `wrk_admission_decide` | `gib` | absent 21, null 21 | limitation | L-NULL-2: absent sizing inputs default to zero (worker-trusted, no app callers); Owner review before admission is enforced |
| `wrk_admission_decide` | `now` | absent 21, null 21 | limitation | L-NULL-2: absent sizing inputs default to zero (worker-trusted, no app callers); Owner review before admission is enforced |
| `wrk_admission_decide` | `planned_items` | absent 21, null 21 | limitation | L-NULL-2: absent sizing inputs default to zero (worker-trusted, no app callers); Owner review before admission is enforced |
| `wrk_audit_verified` | `anchor_hash` | absent 2, empty 2, null 2 | fail_closed | absent fields record the audit verification as failed |
| `wrk_audit_verified` | `anchor_seq` | absent 2, null 2 | fail_closed | absent fields record the audit verification as failed |
| `wrk_audit_verified` | `result` | absent 2, empty 2, null 2 | fail_closed | absent fields record the audit verification as failed |
| `wrk_audit_verified` | `source` | absent 2, null 2 | fail_closed | absent fields record the audit verification as failed |
| `wrk_audit_verified` | `tool_version` | absent 1, empty 1, null 1 | fail_closed | absent fields record the audit verification as failed |
| `wrk_backup_due` | `now` | absent 5, null 5 | optional | now defaults to now() |
| `wrk_backup_key_pruned` | `now` | absent 1, null 1 | optional | now defaults to now() |
| `wrk_capacity_update` | `now` | absent 6, null 6 | optional | now defaults to now(); ok absent means a failed probe (provider_capped) |
| `wrk_capacity_update` | `ok` | absent 2, null 2 | optional | now defaults to now(); ok absent means a failed probe (provider_capped) |
| `wrk_cloud_usage_record` | `cu_hours` | absent 1, null 1 | optional | usage measures default to 0 or NULL by meter; started_at and the identity are required |
| `wrk_cloud_usage_record` | `egress_bytes` | absent 1, null 1 | optional | usage measures default to 0 or NULL by meter; started_at and the identity are required |
| `wrk_cloud_usage_record` | `gross_estimate` | absent 7, null 7 | optional | usage measures default to 0 or NULL by meter; started_at and the identity are required |
| `wrk_cloud_usage_record` | `phase` | absent 8, null 8 | optional | usage measures default to 0 or NULL by meter; started_at and the identity are required |
| `wrk_cloud_usage_record` | `storage_bytes` | absent 1, null 1 | optional | usage measures default to 0 or NULL by meter; started_at and the identity are required |
| `wrk_exec_due` | `limit` | absent 9, null 9 | optional | limit defaults to 50 |
| `wrk_issue_exec_lease` | `item_id` | absent 252, empty 39, null 42 | optional | item_id is optional per job kind; exec_work_order refuses an order that needs one |
| `wrk_record_identity_signal` | `closing_balance` | absent 2, null 2 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `holder_names` | absent 11, empty 11 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `institution_id` | absent 9, null 9 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `masked_reference` | absent 5, empty 5, null 5 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `opening_balance` | absent 2, null 2 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `period_end` | absent 6, null 6 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `period_start` | absent 11, null 11 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `reference_fingerprint` | absent 4, null 4 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_record_identity_signal` | `uploaded_by` | absent 1, null 1 | optional | a statement may show any subset of identity facts; columns are nullable by design; the masked reference keeps at most 4 digits |
| `wrk_snapshot_artifact` | `warnings` | absent 2 | optional | warnings default to none |
| `wrk_stage_completion:backup_recorded` | `destination` | absent 2, empty 2, null 2 | optional | refused at promotion for BACKUP leases; the accepted calls are EVIDENCE_VERIFY leases, which do not read the field |
| `wrk_stage_completion:backup_recorded` | `ended_at` | absent 1, empty 1, null 1 | optional | refused at promotion for BACKUP leases; the accepted calls are EVIDENCE_VERIFY leases, which do not read the field |
| `wrk_stage_completion:backup_recorded` | `header` | absent 1, null 1 | optional | refused at promotion for BACKUP leases; the accepted calls are EVIDENCE_VERIFY leases, which do not read the field |
| `wrk_stage_completion:backup_recorded` | `retain_until` | absent 2, null 2 | optional | read only for a VERIFIED result: since 9040 a VERIFIED result without it is REJECTED (RETENTION; AT-BKP-REC case 'retention absent'); a FAILED result does not read it (the 9039 sweep's accepted VERIFIED calls are gone) |
| `wrk_stage_completion:backup_recorded` | `sizes` | absent 24 | optional | sizes are optional facts |
| `wrk_stage_completion:backup_recorded` | `started_at` | absent 1, empty 1, null 1 | optional | refused at promotion for BACKUP leases; the accepted calls are EVIDENCE_VERIFY leases, which do not read the field |
| `wrk_stage_completion:backup_recorded` | `tools` | absent 1, null 1 | optional | refused at promotion for BACKUP leases; the accepted calls are EVIDENCE_VERIFY leases, which do not read the field |
| `wrk_stage_completion:doc_archived` | `head_revision_id` | absent 14, empty 14, null 14 | fail_closed | identity is compared with IS DISTINCT FROM: a missing field returns the document to DISCOVERED (IDENTITY_CHANGED) |
| `wrk_stage_completion:doc_archived` | `mail_message_id` | absent 1, empty 1, null 1 | fail_closed | identity is compared with IS DISTINCT FROM: a missing field returns the document to DISCOVERED (IDENTITY_CHANGED) |
| `wrk_stage_completion:doc_archived` | `md5` | absent 14, empty 14, null 14 | fail_closed | identity is compared with IS DISTINCT FROM: a missing field returns the document to DISCOVERED (IDENTITY_CHANGED) |
| `wrk_stage_completion:doc_archived` | `mime_part` | absent 1, empty 1, null 1 | fail_closed | identity is compared with IS DISTINCT FROM: a missing field returns the document to DISCOVERED (IDENTITY_CHANGED) |
| `wrk_stage_completion:doc_archived` | `source_file_id` | absent 14, empty 14, null 14 | fail_closed | identity is compared with IS DISTINCT FROM: a missing field returns the document to DISCOVERED (IDENTITY_CHANGED) |
| `wrk_stage_completion:doc_discovered` | `module` | absent 3, empty 3, null 3 | optional | size, mtime, period and name are optional facts; the name is withheld when absent |
| `wrk_stage_completion:doc_discovered` | `original_name` | absent 55, empty 54, null 55 | optional | size, mtime, period and name are optional facts; the name is withheld when absent |
| `wrk_stage_completion:doc_discovered` | `period_key` | absent 39, empty 39, null 39 | optional | size, mtime, period and name are optional facts; the name is withheld when absent |
| `wrk_stage_completion:doc_discovered` | `size_bytes` | absent 55, null 55 | optional | size, mtime, period and name are optional facts; the name is withheld when absent |
| `wrk_stage_completion:doc_discovered` | `source_mtime` | absent 53, empty 3, null 53 | optional | size, mtime, period and name are optional facts; the name is withheld when absent |
| `wrk_stage_completion:doc_validated` | `class_uncertain` | absent 49, null 49 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `doc_class` | absent 49, empty 37, null 37 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `locators` | absent 49, empty 11 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `locators[0].kind` | absent 11 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `locators[0].length` | absent 11 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `locators[0].offset` | absent 11 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `locators[0].page` | absent 10 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `locators[0].part` | absent 11 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `locators[0].revision` | absent 3 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `rule_codes` | absent 49, empty 14 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:doc_validated` | `sin_bearing` | absent 49, null 49 | fail_closed | absent class means uncertain; absent rule codes and locators mean none; sin_bearing absent falls back to doc_needs_declaration |
| `wrk_stage_completion:index_consumed` | `availability` | absent 3, null 3 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `coverage` | absent 2, null 2 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `header` | absent 1, empty 1 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `open_items` | absent 3, empty 3 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `open_items[0].key` | absent 3, null 3 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records` | absent 12, empty 12, null 1 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Current Name` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Document Date` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Domain` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].File ID` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Notes` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Original Name` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Processed Date` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Record Path` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Related Open Item` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Sensitivity` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Source` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Status` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Summary` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Tags` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `records[0].Type` | absent 12, null 12 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:index_consumed` | `run_log` | absent 2, null 2 | optional | an absent list consumes nothing; a sparse record is weak or blocked by the consumer |
| `wrk_stage_completion:mail_fetched` | `attachments_expected` | absent 5, null 5 | limitation | L-NULL-4: absent counts mean 0, so a result without counts is FETCHED; Owner review |
| `wrk_stage_completion:mail_fetched` | `attachments_fetched` | absent 5, null 5 | limitation | L-NULL-4: absent counts mean 0; Owner review |
| `wrk_stage_completion:mail_fetched` | `canonical_key_sha256` | absent 2, empty 2, null 2 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `content_class` | absent 1, empty 1, null 1 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `evidence_sha256` | absent 5, empty 5, null 5 | limitation | L-NULL-4: a FETCHED mail item may be recorded without a body evidence hash (the column is nullable); Owner review |
| `wrk_stage_completion:mail_fetched` | `folder_ref` | absent 3, empty 3, null 3 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `message_id` | absent 1, empty 5, null 1 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `ok` | absent 2, null 2 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `op` | absent 1, empty 1, null 1 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `provider_message_id` | absent 1, empty 1, null 1 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `received_at` | absent 1, null 1 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:mail_fetched` | `sender_domain` | absent 5, empty 5, null 5 | optional | an absent sender domain is unverified (EXCEPTION); folder, provider id, received_at, class and ok are informational |
| `wrk_stage_completion:render_done` | `coverage` | absent 2 | optional | rendered_at, coverage and warnings are informational |
| `wrk_stage_completion:render_done` | `rendered_at` | absent 2, null 2 | optional | rendered_at, coverage and warnings are informational |
| `wrk_stage_completion:render_done` | `warnings` | absent 2 | optional | rendered_at, coverage and warnings are informational |
| `wrk_stage_completion:restore_drill_recorded` | `cleanup_verified` | absent 27, null 27 | fail_closed | absent cleanup_verified or restored_header records the drill as FAIL; tools and failure_reason are informational |
| `wrk_stage_completion:restore_drill_recorded` | `failure_reason` | absent 3, empty 3, null 3 | fail_closed | absent cleanup_verified or restored_header records the drill as FAIL; tools and failure_reason are informational |
| `wrk_stage_completion:restore_drill_recorded` | `kind` | absent 26, null 26 | fail_closed | absent cleanup_verified or restored_header records the drill as FAIL; tools and failure_reason are informational |
| `wrk_stage_completion:restore_drill_recorded` | `restored_header` | absent 24, null 24 | fail_closed | absent cleanup_verified or restored_header records the drill as FAIL; tools and failure_reason are informational |
| `wrk_stage_completion:restore_drill_recorded` | `target` | absent 26, null 26 | fail_closed | absent cleanup_verified or restored_header records the drill as FAIL; tools and failure_reason are informational |
| `wrk_stage_completion:restore_drill_recorded` | `tools` | absent 27, null 27 | fail_closed | absent cleanup_verified or restored_header records the drill as FAIL; tools and failure_reason are informational |
