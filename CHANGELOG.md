# Changelog

- 2026-10-21 **1.31.1**
    - The image is rebuilt on the current Alpine and OpenLDAP and carries no shell any more: only the server, its tools, `ldapmodify` and the start program
    - The server runs as the user `ldap`, uid 102, never as root, and still listens on 389 and 636; the README describes the upgrade of an existing installation, with an export before and the way back
    - The default access rules apply as documented: anonymous clients may only log in, users read the directory and change their own entry; the old image had read access for everybody, because a typing error in its configuration dropped the rules
    - The certificate layout `/ssl/<domain>.pem`, `.key`, `-ca.crt` now serves LDAPS on 636 as well; TLS needs version 1.2 or newer
    - A restore that fails leaves the directory as it was and stops the start with a message, instead of starting on an empty directory; two files to restore are refused
    - Backup files carry the minute in their name, where the old ones repeated the month
    - The default log level is `stats` (every operation, without passwords) instead of the trace of every function call
    - The directory may grow to 10 GiB by default, configurable with `MAXSIZE`, where the old limit was 1 GiB
    - Every configuration value is checked before the server starts; a value that cannot be used stops the container with a message that names the variable
    - The image checks its own health, stops cleanly on `docker stop`, and is published for amd64 and arm64, rebuilt every week

- 2022-12-12 **1.31.0**
    - The container starts when the restore file lies on a read-only volume

- 2022-01-12 **1.30.0**
    - The database module loads again with the current Alpine packages

- 2021-10-22 **1.29.0**
    - The database backend is installed again

- 2019-10-19 **1.28.0**
    - Password generation works again

- 2019-07-20 **1.27.0**
    - The initial entries wait until the server accepts the administrator

- 2019-07-05 **1.26.0**
    - Additional indexes through `INDEXES`

- 2019-05-29 **1.25.0**
    - Initial entries from an LDIF file through `INIT_SCRIPT`, own schemas through `CUSTOM_SCHEMAS`

- 2018-12-18 **1.24.0**
    - No backup on a start that restores; smaller image

- 2018-09-25 **1.23.0**
    - Access rules configurable through `ACCESS_RULES`

- 2018-08-31 **1.22.0**
    - Schemas for SSH public keys and the LDAP name service; certificates also in the layout `/ssl/<domain>.*`

- 2018-05-22 **1.21.0**
    - Local socket access fixed

- 2018-04-13 **1.20.0**
    - Alpine instead of Ubuntu, about 15MB instead of 500MB; configuration in `slapd.conf`, database `mdb` instead of `hdb`: a database of an earlier version is migrated through backup and restore
    - Samba schema

- 2018-04-03 **1.19.0**
    - Restarts of an existing container work

- 2018-03-15 **1.18.0**
    - Group membership through `memberOf`; health check

- 2018-03-02 **1.17.0**
    - The first start creates the initial configuration

- 2018-02-05 **1.16.0**
    - Longer wait for the server on start

- 2018-02-03 **1.15.0**
    - An existing configuration is not overwritten on start

- 2018-01-30 **1.14.0**
    - Clearer start log, the start aborts when the server does not come up

- 2018-01-27 **1.13.0**
    - Variables for multi-master replication; the replication never worked

- 2018-01-24 **1.12.0**
    - No backup before a database recovery

- 2018-01-19 **1.11.0**
    - Database recovery only when no restore runs

- 2018-01-17 **1.10.0**
    - Restarts of an existing container work more reliably

- 2018-01-13 **1.9.0**
    - Restore of a backup from `/var/restore`, a backup in `/var/backups` on every start
    - Volumes work in Docker Swarm; the server may read the certificates
    - Password changes take effect

- 2017-12-15 **1.8.0**
    - More output during the start

- 2017-11-14 **1.7.0**
    - The administrator password is set correctly

- 2017-10-25 **1.6.0**
    - A generated password is kept in `/etc/ldap/password`; certificates in `/ssl`

- 2017-04-03 **1.5.0**
    - File permissions fixed, the password is remembered

- 2017-03-02 **1.4.0**
    - Based on `mwaeckerlin/ubuntu-base`

- 2016-03-22 **1.3.0**
    - Preparation to refuse anonymous binds

- 2016-03-07 **1.2.0**
    - The configuration is written on start from the environment

- 2016-03-04 **1.1.0**
    - The administrator password is generated when none is given

- 2015-10-22 **1.0.0**
    - OpenLDAP server on Ubuntu, configured through environment variables
