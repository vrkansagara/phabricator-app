#!/bin/bash

set -eu -o pipefail

mkdir -p /run/phabricator/phd /run/sshd

if [[ -z "${SSH_PORT:-}" ]]; then
    echo "SSH Disabled"
    SSH_PORT=29418
fi

# Remove _ from the prefix since phabricator adds it anyway
sed -e "s/##MYSQL_DATABASE_PREFIX/${MYSQL_DATABASE_PREFIX%_}/" \
    -e "s/##MYSQL_USERNAME/${MYSQL_USERNAME}/" \
    -e "s/##MYSQL_PASSWORD/${MYSQL_PASSWORD}/" \
    -e "s/##MYSQL_HOST/${MYSQL_HOST}/" \
    -e "s/##MYSQL_PORT/${MYSQL_PORT}/" \
    -e "s,##APP_ORIGIN,${APP_ORIGIN}," \
    -e "s,##MAIL_SERVER,${MAIL_SMTP_SERVER}," \
    -e "s,##MAIL_PORT,${MAIL_SMTP_PORT}," \
    -e "s/##MAIL_FROM/${MAIL_FROM}/" \
    -e "s/##MAIL_USERNAME/${MAIL_SMTP_USERNAME}/" \
    -e "s/##MAIL_PASSWORD/${MAIL_SMTP_PASSWORD}/" \
    -e "s/##MAIL_DOMAIN/${MAIL_DOMAIN}/" \
    -e "s/##SSH_PORT/${SSH_PORT}/" \
    /app/code/phabricator/conf/local/local.json.template > /run/phabricator/local.json

# https://secure.phabricator.com/book/phabricator/article/configuring_file_storage/
mkdir -p /app/data/filestorage /app/data/repo
chown -R phd:phd /app/data/repo /run/phabricator/phd
chown -R www-data:www-data /app/data/filestorage

# import the database with default 'superadmin' user
if [ $# -gt 0 ] && [[ "$1" == "--no-import-db" ]]; then
    echo "Skipping initial db import for creating db seed file"
elif [[ ! -f /app/data/imported ]]; then
    echo "Importing initial data"
    sed -e "s/\`dbprefixgoeshere_/\`${MYSQL_DATABASE_PREFIX}/" /app/code/db_seed.sql | mysql -u"${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" -h "${MYSQL_HOST}" -P "${MYSQL_PORT}"
    touch /app/data/imported
else
    echo "Already initialized"
fi

echo "Upgrading database"
/app/code/phabricator/bin/storage upgrade --force

readonly ldap_config="{\"ldap:port\":\"${LDAP_PORT}\",\"ldap:version\":\"3\",\"ldap:host\":\"${LDAP_SERVER}\",\"ldap:dn\":\"${LDAP_USERS_BASE_DN}\",\"ldap:search-attribute\":\"(|(username=\${login})(mail=\${login}))\",\"ldap:anoynmous-username\":\"${LDAP_BIND_DN}\",\"ldap:anonymous-password\":\"${LDAP_BIND_PASSWORD}\",\"ldap:username-attribute\":\"username\",\"ldap:realname-attributes\":[\"displayname\"],\"ldap:activedirectory-domain\":\"\"}"

# update only on id 2 (id 1 is username/password). this allows the user to disable LDAP auth
if mysql -u"${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" --database="${MYSQL_DATABASE_PREFIX}auth" \
     -e "UPDATE \`auth_providerconfig\` SET properties='${ldap_config}' WHERE id=2 AND providerClass='PhabricatorLDAPAuthProvider';"; then
    echo "LDAP configuration auto setup successfully"
else
    echo "Failed to setup LDAP authentication"
fi

# TODO: roll this as a supervisor script (http://blog.spang.cc/posts/running_phd_under_supervisor/)
echo "Starting daemons"
/usr/local/bin/gosu phd:phd /app/code/phabricator/bin/phd restart

echo "Starting supervisor"
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon -i Phabricator

