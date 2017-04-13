#!/bin/sh
#
# Script to configure the GitLab installation
#
#################################################################
PROGNAME=$(basename ${0})
GLCONFIG="/etc/gitlab/gitlab.rb"
RUNDATE=$(date "+%Y%m%d%H%M")
GITLAB_EXTERNURL=${GITLAB_EXTERNURL:-UNDEF}
GITLAB_DATABASE=${GITLAB_DATABASE:-UNDEF}
GITLAB_DBUSER=${GITLAB_DBUSER:-UNDEF}
GITLAB_PASSWORD=${GITLAB_PASSWORD:-UNDEF}
GITLAB_DBHOST=${GITLAB_DBHOST:-UNDEF}


#
# Log errors and exit
#####
function err_exit {
   echo "${1}" > /dev/stderr
   logger -t ${PROGNAME} -p kern.crit "${1}"
   exit 1
}


#
# Ensure we've passed an external URL
#####
if [[ ${GITLAB_EXTERNURL} = UNDEF ]] ||
   [[ ${GITLAB_DATABASE} = UNDEF ]] ||
   [[ ${GITLAB_DBUSER} = UNDEF ]] ||
   [[ ${GITLAB_PASSWORD} = UNDEF ]] ||
   [[ ${GITLAB_DBHOST} = UNDEF ]]
then
   err_exit "Required env var(s) not defined. Aborting!"
fi


#
# Preserve the existing gitlab.rb file
#####
printf "Preserving ${GLCONFIG} as ${GLCONFIG}.bak-${RUNDATE}... "
mv ${GLCONFIG} ${GLCONFIG}.bak-${RUNDATE} && \
   echo "Success!" || \
      err_exit "Failed to preserve ${GLCONFIG}: aborting"


#
# Localize the GitLab installation
#####
printf "Localizing gitlab config files... "

install -b -m 0600 /dev/null ${GLCONFIG} || \
   err_exit "Failed to create new/null config file"

chcon --reference=${GLCONFIG}.bak-${RUNDATE} ${GLCONFIG} || \
   err_exit "Failed to set SELinx label on new/null config file"

cat << EOF > ${GLCONFIG}
external_url 'https://${GITLAB_EXTERNURL}'
nginx['listen_addresses'] = ["0.0.0.0", "[::]"]
nginx['listen_port'] = 80
nginx['listen_https'] = false
gitlab_rails['db_adapter'] = "postgresql"
gitlab_rails['db_encoding'] = "unicode"
gitlab_rails['db_database'] = "${GITLAB_DATABASE}"
gitlab_rails['db_username'] = "${GITLAB_DBUSER}"
gitlab_rails['db_password'] = "${GITLAB_PASSWORD}"
gitlab_rails['db_host'] = "${GITLAB_DBHOST}"
EOF

if [[ $? -eq 0 ]]
then
   echo "Success!" 
else
   err_exit "Failed to localize GitLab installation. Aborting!"
fi


#
# Configure the GitLab pieces-parts
#####
printf "###\n# Localizing GitLab service elements...\n###\n"
export CHEF_FIPS=""
gitlab-ctl reconfigure && \
   echo "Localization successful." || \
      err_exit "Localization did not succeed. Aborting."

printf "###\n# Restarting GitLab to finalize settings...\n###\n"
gitlab-ctl restart
   echo "Restart successful." || \
      err_exit "Restart did not succeed. Check the logs."
