# Tests

Register of all tests, sorted by the [FEATURES.md](FEATURES.md) number each test covers. `npm test` runs everything; the guard `tests/docs-contract.sh` fails when a feature has no test entry here.

## E2E (`tests/run.sh` against `tests/docker-compose.yml`)

- **F1** `tests/run.sh` › admin_adds_entries_with_default_schemas, admin_reads_entry — the server of `DOMAIN=example.com` takes the base `dc=example,dc=com` with its entries and returns them.
- **F2** `tests/run.sh` › admin_adds_entries_with_default_schemas, admin_wrong_password_refused — `cn=admin,dc=example,dc=com` writes with `PASSWORD`, a bind with a wrong password is refused.
- **F3** `tests/run.sh` › data_survives_restart — an entry is still there after a container restart.
- **F4** `tests/run.sh` › generated_password_logged_and_valid, generated_password_stored, generated_password_survives_restart, healthcheck_with_stored_password — without `PASSWORD` the logged password binds, equals `/etc/ldap/password`, still binds after a restart, and the health check finds it.
- **F5** `tests/run.sh` › anonymous_reads_nothing, user_reads_other_entries, user_writes_own_entry, user_cannot_write_other_entry — the default rules: anonymous search finds nothing, a user reads other entries, changes his own and is refused with «Insufficient access» on another one.
- **F5** `tests/run.sh` › custom_access_rules_and_schema — `ACCESS_RULES="access to * by * read"` lets an anonymous client read.
- **F6** `tests/run.sh` › indexes_configured, substring_search_over_index — `INDEXES=" index uid eq index cn eq,sub"` with its leading space reaches the configuration as two lines, and a substring search over `cn` answers.
- **F7** `tests/run.sh` › memberof_shows_group, refint_removes_deleted_member — a member of `cn=staff` carries `memberOf`, a deleted member disappears from the group.
- **F8** `tests/run.sh` › admin_adds_entries_with_default_schemas — the default schemas take an entry with `posixAccount` and `sambaSamAccount`.
- **F8** `tests/run.sh` › custom_access_rules_and_schema, schema_not_listed_is_not_loaded — `SCHEMAS` with `openssh-lpk` takes an `ldapPublicKey` entry and, without `samba`, refuses a `sambaSamAccount` entry.
- **F9** `tests/run.sh` › database_written_by_uid_102, ldap_user_uid_102 — the database file belongs to uid 102, and `/etc/passwd` of the image gives the user `ldap` uid 102.
- **F10** `tests/run.sh` › startup_backup_written, backup_name_carries_date_and_time — after a restart `/var/backups` holds `<YYYYMMDDHHMM>-startup-data.ldif` with the entries (regression: the old name carried the month where the minute belongs).
- **F11** `tests/run.sh` › restore_from_backup, restored_file_moved_to_backups — the startup backup of one server, put into `/var/restore` of a fresh one, gives the same entries, and the file moves to `/var/backups/<date>-restored-data.ldif`.
- **F11** `tests/run.sh` › broken_restore_refused, database_kept_after_broken_restore, two_restore_files_refused — a broken file stops the start and leaves the directory as it was, two files are refused (regression: the old image deleted the directory before it tried the restore).
- **F12** `tests/run.sh` › init_script_with_custom_schema, init_script_again_on_restart — `example/init.ldif` and `example/schemas/custom.schema` give `uid=user1` with `userAccountControl`, and a restart that applies the file again keeps the server running.
- **F13** `tests/run.sh` › debug_default_logs_operations — the default level logs the bind of the administrator.
- **F14** `tests/run.sh` › ldaps_tls, starttls_tls, ldaps_tls-flat, starttls_tls-flat, no_ldaps_without_certificate, tls_1_2_minimum, unreadable_key_named — both certificate layouts serve verified LDAPS on 636 and StartTLS on 389, a server without a certificate serves no LDAPS, TLS 1.2 is verified and TLS 1.1 not negotiated, and an unreadable key stops the container with a message that names it (regression: the old image served no LDAPS for the layout `/ssl/<domain>.*`).
- **F15** `tests/run.sh` › image_healthcheck_healthy, healthcheck_refuses_wrong_password, healthcheck_with_stored_password — a service without a compose healthcheck turns healthy, a wrong password reports unhealthy.
- **F16** `tests/run.sh` › stops_cleanly — `docker stop` ends the container with exit status 0.
- **F20** `tests/run.sh` › maxsize_default — the configuration carries `maxsize 10737418240`.
- **F21** `tests/run.sh` › build_argument_overlays — an image built with `overlays=openldap-overlay-unique` carries `unique.so`.

## Config validation (`tests/config-validation.sh`)

- **F1** reject_domain_missing, reject_domain_bad, reject_domain_injection, reject_domain_empty_label — a missing or malformed `DOMAIN` stops the container.
- **F17** reject_password_line_break, reject_debug_bad, reject_maxsize_bad, reject_access_rules_injection, reject_access_rules_bad, reject_indexes_injection, reject_indexes_bad, reject_memberof_bad, reject_schemas_unknown, reject_schemas_path, reject_custom_schemas_relative, reject_init_script_relative — every unusable value stops the container with `invalid <VARIABLE>`.
- **F17** accept_defaults, accept_explicit_values, accept_every_shipped_schema — the defaults, a password with spaces, quotes and backslash, the old README form of `INDEXES` and every schema the image ships pass.

## Image contract

- **F18** `tests/image-contract.sh` › no sh, no bash, no busybox, no perl — the image is headless.

## Workflow contract

- **F19** `tests/workflow-contract.sh` of `mwaeckerlin/scratch` — the reusable workflow selects exactly the images a repository publishes; this repository calls it from `.github/workflows/docker.yml`.
