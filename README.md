# OpenLDAP Server

Headless OpenLDAP server for one domain, configured through environment variables, on `mwaeckerlin/scratch`: no shell, no package manager, never root.

The container is a directory for user accounts and groups that Nextcloud, mail servers, Samba, SSH and an administration front end such as [mwaeckerlin/lam](https://github.com/mwaeckerlin/lam) read. It needs one variable to start, saves the whole directory on every start, restores a backup that is dropped into a volume, and carries nothing an attacker could use after breaking into the server: only `slapd`, its tools, `ldapmodify` and the start program.

The feature list is [FEATURES.md](FEATURES.md), the tests are listed in [TESTS.md](TESTS.md), the changes in [CHANGELOG.md](CHANGELOG.md).

## Quick start

```bash
docker run -d --name openldap \
    -p 127.0.0.1:389:389 \
    -e DOMAIN=my-company.com \
    -e PASSWORD=1234567890 \
    -v openldap-config:/etc/ldap \
    -v openldap-data:/var/lib/ldap \
    -v openldap-backups:/var/backups \
    -v openldap-restore:/var/restore \
    mwaeckerlin/openldap
```

The administrator is `cn=admin,dc=my-company,dc=com` with the password `1234567890`; Apache Directory Studio, `ldapsearch` or LAM connect to `ldap://localhost:389`. The server does not create the base entry `dc=my-company,dc=com`: add it with the administrator, with `INIT_LDIF` or `INIT_SCRIPT`, or let LAM create it on its first login.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `DOMAIN` | *(mandatory)* | Domain of the directory; `my-company.com` gives the base `dc=my-company,dc=com` and the administrator `cn=admin,dc=my-company,dc=com`. |
| `PASSWORD` | *(empty)* | Password of the administrator. Empty: the first start generates 20 letters and digits, writes them once to the log as `password: …` and keeps them in `/etc/ldap/password`. |
| `ACCESS_RULES` | `access to * by self write by users read by anonymous auth` | The slapd access rules on one line, every rule starting with `access to`; replaces the default completely. The default lets users read the directory and change their own entry, anonymous clients may only log in. |
| `SCHEMAS` | `cosine inetorgperson nis samba` | Schemas besides `core`, which is always loaded. The default is what the default configuration of LAM needs. |
| `INDEXES` | *(empty)* | Indexes besides `index objectClass eq`, written as `index uid eq index cn eq,sub`. |
| `MEMBEROF` | `0` | `1` maintains `memberOf` on every member of a `groupOfNames` and removes deleted entries from every group. |
| `CUSTOM_SCHEMAS` | *(empty)* | Directory whose `*.schema` files, also in subdirectories, are loaded after `SCHEMAS`. |
| `CUSTOM_SCHEMA` | *(empty)* | Schema text, loaded after `CUSTOM_SCHEMAS`: lines starting with `attributetype`, `objectclass`, `objectidentifier` or `ldapsyntax`, indented continuation lines and `#` comments. |
| `INIT_SCRIPT` | *(empty)* | LDIF file applied as the administrator on every start; existing entries are reported and skipped. |
| `INIT_LDIF` | *(empty)* | LDIF text applied as the administrator on every start, after `INIT_SCRIPT`; existing entries are reported and skipped. |
| `DEBUG` | `256` | slapd log level, a number or a name: `256` (`stats`) logs every connection and operation with DN and result, `0` logs nothing, `-1` everything. |
| `MAXSIZE` | `10737418240` | Largest size of the database in bytes (10 GiB). The file is sparse and only takes the space its data needs. |

Every value is checked before the configuration is written: `DOMAIN` takes letters, digits, `-` and `.`; `PASSWORD` takes every character but a line break; `ACCESS_RULES` must start with `access to` and stay on one line; `INDEXES` must start with `index`; `MEMBEROF` is `0` or `1`; `SCHEMAS` names files the image carries; `CUSTOM_SCHEMAS` and `INIT_SCRIPT` are absolute paths of letters, digits and `/._-`; `INIT_LDIF` and `CUSTOM_SCHEMA` take text without control characters but tab and line break, and `CUSTOM_SCHEMA` only schema definitions, so it cannot add a directive such as `include` or `rootpw` to the configuration; `MAXSIZE` is a number. Any other value stops the container with `invalid <VARIABLE>` and the reason.

Schemas in the image: those of OpenLDAP in `/etc/openldap/schema` (`cosine`, `inetorgperson`, `nis`, `misc`, `openldap`, `collective`, `corba`, `duaconf`, `dyngroup`, `java` and more) and three of this image: `samba` (Samba accounts and group maps), `openssh-lpk` (SSH public keys), `ldapns` (LDAP name service).

`INIT_LDIF` and `CUSTOM_SCHEMA` carry the entries and the schema in the compose file itself, as a YAML block; a literal `$` is written `$$` there:

```yaml
services:
  openldap:
    image: mwaeckerlin/openldap
    environment:
      DOMAIN: example.com
      CUSTOM_SCHEMA: |
        attributetype ( 1.2.840.113556.1.4.8
          NAME 'userAccountControl'
          SYNTAX '1.3.6.1.4.1.1466.115.121.1.27'
          SINGLE-VALUE )
      INIT_LDIF: |
        dn: dc=example,dc=com
        dc: example
        objectClass: top
        objectClass: domain
```

[example/docker-compose.yaml](example/docker-compose.yaml) is a complete stack in this form. `INIT_SCRIPT` and `CUSTOM_SCHEMAS` read files that a derived image puts into the container instead, as the test stack builds one with [example/init.ldif](example/init.ldif) and [example/schemas/](example/schemas/):

```dockerfile
FROM mwaeckerlin/openldap
COPY init.ldif /var/init/init.ldif
COPY schemas /var/schemas
```

Where both forms are set, the files are loaded first: the schemas of `CUSTOM_SCHEMAS` before `CUSTOM_SCHEMA`, the entries of `INIT_SCRIPT` before `INIT_LDIF`.

## Ports

- `389` — LDAP, and StartTLS when a certificate is present
- `636` — LDAPS, only when a certificate is present

The server runs as uid 102 and still listens on these ports: Docker 20.10 and newer allow every port to an unprivileged process in a container network. With `network_mode: host`, or a runtime that does not do this, set the sysctl `net.ipv4.ip_unprivileged_port_start=0` for the container.

## Volumes

- `/var/lib/ldap` — the database
- `/etc/ldap` — the generated `slapd.conf` (written anew on every start) and the generated password
- `/var/backups` — the backups of every start and every restored file
- `/var/restore` — a file `*data.ldif` here is restored on the next start
- `/ssl` — certificates

Every volume belongs to uid 102, the user `ldap`. Named volumes take that owner from the image; a host directory or a volume of the old image is handed over with `chown -R 102:102`.

## TLS

The server takes the certificate of `DOMAIN` from `/ssl` in one of two layouts:

- `/ssl/live/<DOMAIN>/cert.pem`, `privkey.pem`, `chain.pem`: mount the directory `/etc/letsencrypt` of certbot as `/ssl`
- `/ssl/<DOMAIN>.pem`, `/ssl/<DOMAIN>.key`, `/ssl/<DOMAIN>-ca.crt`

Then it serves LDAPS on 636 and StartTLS on 389, with TLS 1.2 or newer and the ciphers `HIGH:!aNULL:!MD5:!RC4`. The user `ldap` must read the files: certbot writes the private key for root alone, so give it to uid 102 or to the group `shared-access`, gid 500, which the user belongs to. A file the server cannot read stops the container with a message that names the file.

## Backup and restore

Every start saves the existing directory to `/var/backups/<YYYYMMDDHHMM>-startup-data.ldif` before the server starts. A backup while the server runs:

```bash
docker exec openldap slapcat -f /etc/ldap/slapd.conf -l /var/backups/manual-data.ldif
```

To restore, copy one file whose name ends in `data.ldif` into `/var/restore` and restart the container:

```bash
docker cp backup-data.ldif openldap:/var/restore/backup-data.ldif
docker restart openldap
```

The file replaces the whole directory and is then moved to `/var/backups/<YYYYMMDDHHMM>-restored-data.ldif`. The restore is written into a separate directory first; only when it succeeds does it replace the database. A file that cannot be restored stops the container with «restore of <file> failed, the database stays as it was»; remove or correct it, and the next start runs on the old directory. Two or more files stop the start until one is left. On a read-only `/var/restore` the file stays and is restored again on every start. A file restored with `MEMBEROF=1` in the backup needs `MEMBEROF=1` on the restoring server as well, because the attribute `memberOf` belongs to that module.

## Health check

The image carries a `HEALTHCHECK` (every 30s, timeout 5s, three retries, 60s to start): `/usr/bin/init --healthcheck` binds as the administrator on `127.0.0.1:389` with `PASSWORD` or the stored password and reports healthy only on success. To check by hand:

```bash
docker exec openldap /usr/bin/init --healthcheck
```

## Client access

The image carries `ldapmodify` and the slapd tools `slapadd`, `slapcat`, `slapindex`, `slappasswd` and `slaptest`, and no shell, so `docker exec openldap sh` does not work. A search runs in another container:

```bash
docker run --rm --network <your-net> alpine sh -c 'apk add -q openldap-clients && ldapsearch -x -H ldap://openldap -D cn=admin,dc=my-company,dc=com -W -b dc=my-company,dc=com'
```

## Upgrade

The image was last built in 2022, on Alpine with OpenLDAP 2.4 or 2.6 depending on the build, and ran its start script as root. The new image keeps the image name, every variable listed above, the ports, the volume paths, both certificate layouts, the administrator `cn=admin,<base>`, `/etc/ldap/password`, `/etc/ldap/slapd.conf` and the names of the backup files. What changes:

- **uid 102 instead of root.** The old script ran as root and changed the owner of `/var/lib/ldap` and `/etc/ldap` on every start; the new server cannot. Volumes of the old image belong to the uid its user `ldap` had there, and certificates must be readable for uid 102 or gid 500.
- **Access rules.** A typing error in the old image (`ENV ACCESS RULES`) dropped the default rules, so wherever `ACCESS_RULES` was not set, every anonymous client could read the whole directory, password hashes included. The new image applies the documented default: anonymous clients may only log in. A client that searched anonymously needs a bind DN, or `ACCESS_RULES` opens the directory on purpose.
- **Log level.** `DEBUG` was `1` (a trace of every function call), now `256` (`stats`).
- **TLS.** TLS 1.2 or newer. The layout `/ssl/<DOMAIN>.*` now serves LDAPS on 636 too, where the old image offered only StartTLS for it.
- **Database size.** The old limit was 1 GiB, the new default 10 GiB (`MAXSIZE`).
- **Restore.** A failed restore stops the start and keeps the directory, where the old image deleted it first and started empty.
- **No shell.** `docker exec openldap sh` and `ldapsearch` inside the container are gone; `slapcat`, `slapadd` and `ldapmodify` are still there.
- **Variables without effect.** `USER` and `GROUP` no longer exist. `MULTI_MASTER_REPLICATION` and `SERVER_NAME` have had no effect since the image moved to Alpine on 2018-04-13, and `ORGANIZATION` and `DEBUG_LEVEL` from the old examples none either; the new image ignores all four.
- **Database format.** The database is read again through an export: the OpenLDAP version of the old image differs from build to build, and an image from before 2018-04-13 used `hdb`, which OpenLDAP no longer has.

The upgrade, with an export first and the old volumes kept for the way back:

1. Keep the old image under a name of its own, so a later pull does not replace it:

    ```bash
    docker image tag mwaeckerlin/openldap mwaeckerlin/openldap:before-upgrade
    ```

2. Export the directory with the old container still running, and copy the file out:

    ```bash
    docker exec openldap slapcat -f /etc/ldap/slapd.conf -l /var/backups/upgrade-data.ldif
    docker cp openldap:/var/backups/upgrade-data.ldif upgrade-data.ldif
    ```

    An image from before 2018-04-13 (Ubuntu, `cn=config`) exports the data with `docker exec openldap slapcat -n 1 -l /var/backups/upgrade-data.ldif`; its configuration export `*config.ldif` is not used any more.

3. Stop and remove the old container, and keep its volumes.

4. Create the new container on new volumes, put the export into `/var/restore`, and start it. With the variables of the old container and the same `PASSWORD` (an empty `PASSWORD` generates a new one, because the new server cannot read the old `/etc/ldap/password`):

    ```bash
    docker compose pull openldap
    docker compose create openldap
    docker compose cp upgrade-data.ldif openldap:/var/restore/upgrade-data.ldif
    docker compose start openldap
    ```

5. Check the log for «restored, the file is now /var/backups/…-restored-data.ldif» and the directory with a client. Where `MEMBEROF=1` was set before, it must be set now as well.

To run on the old volumes instead of new ones, hand them to uid 102 first, for every volume:

```bash
docker run --rm -u 0 -v <volume>:/volume alpine chown -R 102:102 /volume
```

The way back: stop the new container and start `mwaeckerlin/openldap:before-upgrade` on the old volumes, which the upgrade has not touched. A later state of the directory goes back the same way as before: the old image restores a `*data.ldif` from `/var/restore` as well, so a `slapcat` export of the new server, copied there, moves it into the old one.

## Development

```bash
npm test
```

runs four suites and fails on any single error:

1. **Docs contract** (`tests/docs-contract.sh`) — every feature of [FEATURES.md](FEATURES.md) has a test in [TESTS.md](TESTS.md).
2. **Image contract** (`tests/image-contract.sh`) — the image is headless: no `/bin/sh`, no bash, no busybox, no perl.
3. **Config validation** (`tests/config-validation.sh`) — every unusable value is refused, every usable one accepted.
4. **Functional e2e** (`tests/run.sh`, via `tests/docker-compose.yml`) — servers for every documented use against a client container with the OpenLDAP client tools: writing and reading, access rules, memberOf, schemas, indexes, persistence, backup and restore with its failure cases, the generated password, `INIT_SCRIPT` with the files of [example/](example/), `INIT_LDIF` and `CUSTOM_SCHEMA` from [example/docker-compose.yaml](example/docker-compose.yaml), both TLS layouts, the health check and the clean stop.

The image is built in three stages, as `mwaeckerlin/redis` and the images of `mwaeckerlin/mailservice`:

1. **`init`** — compiles `init.cpp` statically. The program validates the environment, writes `/etc/ldap/slapd.conf`, writes `CUSTOM_SCHEMA` and `INIT_LDIF` to `/run/openldap/custom.schema` and `/run/openldap/init.ldif`, runs the backup or the restore with `slapcat` and `slapadd`, starts `slapd`, applies `INIT_SCRIPT` and `INIT_LDIF` with `ldapmodify` once the administrator can bind, passes `SIGTERM` and `SIGINT` to `slapd`, and with `--healthcheck` binds as the administrator.
2. **`build`** — creates the user `ldap` (uid 102, group `shared-access`) on `mwaeckerlin/very-base`, installs the Alpine packages of OpenLDAP with the backend `mdb` and the overlays `memberof` and `refint`, and collects `slapd`, `ldapmodify`, the modules and their libraries. The build arguments `backend` (default `mdb`) and `overlays` (further Alpine packages) select more packages.
3. **runtime** — `FROM mwaeckerlin/scratch` with the collected files, `USER ldap`, `ENTRYPOINT ["/usr/bin/init"]`.
