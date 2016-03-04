# OpenLDAP Server

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

To access `cn=config`, set `cn=config` as root and use the administrator account for binding, here `cn=admin,dc=my-company,dc=com` and passwortd `1234567890`.
