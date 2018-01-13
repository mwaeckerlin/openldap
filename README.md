# OpenLDAP Server

See also: https://marc.wäckerlin.ch/computer/setup-openldap-server-in-docker

## Configuration

OpenLDAP serve in Ubuntu default configuration. Initial setup is configured though environment variables.

Environment Variables:
- DOMAIN (mandatory) 
    Your domain name, e.g. `example.org`. The distinguish name is created from this domain, e.g. as `cn=example,cn=org`.
- ORGANIZATION (mandatory) 
    The name of your organization, e.g. `Example Organization`.
- PASSWORD (optional) 
    Administrator password, account is derieved from DOMAIN, e.g. `cn=admin,dc=example,dc=org`.
    If not given, a password is generated and written to docker logs.
- DEBUG (optional) 
    Specifies the debug level, defaults to 0 (no debug output)

Ports:
- 389 (LDAP and LDAP+startTLS)
- 636 (LDAP+SSL)

Volumes:
- /certs
- /var/backups
- /etc/ldap
- /var/lib/ldap

## Example

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

You can create backups easily, to generate config in `config.ldif` and data in `data.ldif`:

    slapcat -n 0 -l config.ldif
    slapcat -n 1 -l data.ldif

To restore the backup file, copy a file named `config.ldif` that contains the configuration and a file named `data.ldif` in the volume `/var/restore`, then restart the container.

After successful restore, the file will be moved to volume `/var/backups/<date>-restored-<config|data>.ldif`.

At every restart, a backup is generated, i.e. before restore in `/var/backups/<date>-startup-<config|data>.ldif`.
