FROM mwaeckerlin/very-base AS init
RUN $PKG_INSTALL g++
COPY init.cpp .
RUN g++ -static -Os -flto=auto -fno-rtti -ffunction-sections -fdata-sections \
        -Wl,--gc-sections -Wl,-s -std=c++20 -o init init.cpp
RUN strip -s -R .comment -R .gnu.version --strip-unneeded init

FROM mwaeckerlin/very-base AS build
ARG backend="mdb"
ARG overlays=""
RUN addgroup -S ldap \
    && adduser -S -D -H -h /var/lib/ldap -u 102 -G ldap ldap \
    && adduser ldap $SHARED_GROUP_NAME
RUN $PKG_INSTALL openldap openldap-back-$backend openldap-clients \
        openldap-overlay-memberof openldap-overlay-refint ${overlays}
COPY samba.schema openssh-lpk.schema ldapns.schema /etc/openldap/schema/
RUN mkdir -p /var/lib/ldap /etc/ldap /var/backups /var/restore /ssl /run/openldap \
    && chown ldap:ldap /var/lib/ldap /etc/ldap /var/backups /var/restore /ssl /run/openldap \
    && chmod 700 /var/lib/ldap /etc/ldap /run/openldap
COPY --from=init init /usr/bin/init

# musl's ldd takes one file per call, hence the loop over slapd, the client and every module
RUN tar cph \
        /var/lib/ldap /etc/ldap /var/backups /var/restore /ssl /run/openldap \
        /etc/passwd /etc/group /etc/nsswitch.conf \
        /etc/openldap/schema /usr/lib/openldap \
        /usr/sbin/slapd /usr/bin/ldapmodify /usr/bin/init \
        /lib/ld-musl-*.so.1 \
        $(for f in /usr/sbin/slapd /usr/bin/ldapmodify /usr/lib/openldap/*.so*; do \
              ldd "$f" 2>/dev/null | sed -n 's,.* => \([^ ]*\) .*,\1,p'; \
          done | sort -u) \
    | tar xpC /root/
RUN for tool in slapadd slapcat slapindex slappasswd slaptest; do \
        ln -s slapd /root/usr/sbin/$tool; \
    done

FROM mwaeckerlin/scratch
ENV CONTAINERNAME="openldap" \
    DOMAIN="" \
    PASSWORD="" \
    DEBUG="256" \
    ACCESS_RULES="access to * by self write by users read by anonymous auth" \
    SCHEMAS="cosine inetorgperson nis samba" \
    INDEXES="" \
    MEMBEROF="0" \
    MAXSIZE="10737418240" \
    CUSTOM_SCHEMAS="" \
    INIT_SCRIPT=""
EXPOSE 389 636
VOLUME /ssl /etc/ldap /var/lib/ldap /var/backups /var/restore
USER ldap
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/usr/bin/init", "--healthcheck"]
ENTRYPOINT ["/usr/bin/init"]
COPY --from=build /root/ /
