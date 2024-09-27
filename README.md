OpenLDAP Server
===============

See also: https://marc.wäckerlin.ch/computer/setup-openldap-server-in-docker


Configuration
-------------

OpenLDAP server in Ubuntu default configuration. Initial setup is
configured though environment variables.

Environment Variables:
- `DOMAIN` (mandatory) 
    Your domain name, e.g. `example.org`. The distinguish name is created from this domain, e.g. as `cn=example,cn=org`.
- `PASSWORD` (optional) 
    Administrator password, account is derieved from DOMAIN, e.g. `cn=admin,dc=example,dc=org`.
    If not given, a password is generated and written to docker logs.
- `DEBUG` (optional) 
    Specifies the debug level, defaults to 0 (no debug output)
- `INDEXES` (optional) 
    A list of indexes that the LDAP server should maintain, separated by spaces, e.g.: ` index uid eq index cn eq`.
- `PASSWORD_HASH` (optional) 
    A password hashing scheme for the openldap server when storing passwords (see [the docs](https://openldap.org/doc/admin24/security.html#Password%20Storage) for more info). Options are:
    * `SSHA`
    * `CRYPT`
    * `MD5`
    * `SMD5`
    * `SHA`

Ports:
- 389 (LDAP and LDAP+startTLS)
- 636 (LDAP+SSL)

Volumes:
- `/var/lib/ldap` the database
- `/ssl` mount from let's encrypt configuration `/etc/letsencrypt` to enable tls and ssl
- `/etc/ldap` config file
- `/var/backups` backups
- `/var/restore` copy one backup file here to start restore on next restart


Example
-------

Start your openLDAP server:
```
docker run -it --rm --name openldap \
           -p 389:389 \
           -e DEBUG_LEVEL=1 \
           -e DOMAIN=my-company.com \
           -e ORGANIZATION="My Company" \
           -e PASSWORD=1234567890 \
           mwaeckerlin/openldap
```

Now you can access your LDAP, e.g. through apache directory studio.

To access `cn=config`, set `cn=config` as root and use the administrator account for binding, here `cn=admin,dc=my-company,dc=com` and password `1234567890`.


Restore a Backup
----------------

You can create backups easily in `data.ldif`:

    slapcat -l data.ldif

To restore the backup file, copy a file named to match `*data.ldif` in the volume `/var/restore`, then restart the container.

After successful restore, the file will be moved to volume `/var/backups/<date>-restored-data.ldif`.

Before every restart, a backup is generated in `/var/backups/<date>-startup-data.ldif`.


Note to Upgrades after 2018-04-13
---------------------------------

The base image has been replaced from [ubutnu](https://ubuntu.com) to [alpine](https://alpine-linux.org). This way, the image size has been reduced from ~500MB to ~15MB. But at the same time, some changes were made, i.e.:
 - configuration is now in a slapd.conf file
 - database is no more `hdb`, but `mdb`

This means: Your database from previous versions cannot be used anymore. You need to create a backup and restore it after migration.
