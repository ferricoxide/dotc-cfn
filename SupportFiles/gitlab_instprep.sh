#!/bin/sh
#
# Script to handle preparation of the instance for installing
# and configuring GitLab
#################################################################
PROGNAME=$(basename "${0}")
LOGFACIL="user.err"
KERNVERS=$(uname -r)
if [[ ${KERNVERS} == *el7* ]]
then
  OSDIST="os=el&dist=7"
elif [[ ${KERNVERS} == *el6* ]]
then
  OSDIST="os=el&dist=7"
fi
REPOSRC=${REPOSRC:-https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/config_file.repo?${OSDIST}}
GITLAB_EFS_HOST=${GITLAB_EFS_HOST:-UNDEF}
INSTRPMS=()
DEPRPMS=(
          curl
          policycoreutils
          openssh-server
          openssh-clients
          nfs-utils
        )
FWPORTS=(
          80
          443
        )


# Log failures and exit
function error_exit {
   echo "${1}"
   logger -t "${PROGNAME}" -p ${LOGFACIL} "${1}"
   exit 1
}


# Open firewall ports
function FwStuff {
   # Temp-disable SELinux (need when used in cloud-init context)
   setenforce 0 && echo "Temp-disabled SELinux" || \
      error_exit "Failed to temp-disable SELinux"

   if [[ $(systemctl --quiet is-active firewalld)$? -eq 0 ]]
   then
      local FWCMD='firewall-cmd'
   else
      local FWCMD='firewall-offline-cmd'
      ${FWCMD} --enabled
   fi

   for PORT in ${FWPORTS[@]}
   do
      printf "Add firewall exception for port ${PORT}... "
      ${FWCMD} --permanent --add-port=${PORT}/tcp || \
         error_exit "Failed to add port ${PORT} to firewalld"
   done

   # Restart firewalld with new rules loaded
   printf "Reloading firewalld rules... "
   ${FWCMD} --reload || \
      error_exit "Failed to reload firewalld rules"

   # Restart SELinux
   setenforce 1 && echo "Re-enabled SELinux" || \
      error_exit "Failed to reactivate SELinux"

}


# Handle any requested EFS-mounts
function EfsMount {
   local MNTOPT="rw,relatime,vers=4.0,rsize=1048576,wsize=1048576,hard,proto=tcp,timeo=600,retrans=2,sec=sys,local_lock=none"
   local EFSDIR="${1}"
   local MNTDIR="${2}"

   printf "%s:%s\t%s\tnfs4\t%s\t0 0\n" ${GITLAB_EFS_HOST} ${EFSDIR} ${MNTDIR} ${MNTOPT} >> /etc/fstab

   # Create mount-dir as necessary
   if [[ ! -d ${MNTDIR} ]]
   then
      mkdir -p ${MNTDIR} || \
         error_exit "Failed to create ${MNTDIR}"
   fi

   mount ${MNTDIR} || error_exit "Failed to mount EFS-resource to ${MNTDIR}"
}


###
# Main
###

# Check if we're missing any vendor-enumerated RPMs
for RPM in ${DEPRPMS[@]}
do
   printf "Cheking for presence of ${RPM}... "
   if [[ $(rpm --quiet -q $RPM)$? -eq 0 ]]
   then
      echo "Already installed."
   else
      echo "Selecting for install"
      INSTRPMS+=(${RPM})
   fi
done

# Install any missing vendor-enumerated RPMs
if [[ ${#INSTRPMS[@]} -ne 0 ]]
then
   echo "Will attempt to install the following RPMS: ${INSTRPMS[@]}"
   yum install -y ${INSTRPMS[@]} || \
      error_exit "Install of RPM-dependencies experienced failures"
else
   echo "No RPM-dependencies to satisfy"
fi

# Ensure vendor-enumerated services are in proper state
for MGSVC in sshd postfix
do
   if [[ $(systemctl --quiet is-active ${MGSVC})$? -ne 0 ]]
   then
      printf "Starting ${MGSVC}... "
      systemctl start ${MGSVC} && \
         echo "Success!" || \
         error_exit "Failed to start ${MGSVC}!"
   fi
   if [[ $(systemctl --quiet is-enabled ${MGSVC})$? -ne 0 ]]
   then
      printf "Enabling ${MGSVC}... "
      systemctl enable ${MGSVC} && \
         echo "Success!" || \
         error_exit "Failed to enable ${MGSVC}!"
   fi
done

# Call to firewall exceptions function
FwStuff

# Install repo-def for repository hosting the GitLab RPM(s)
curl -skL "${REPOSRC}" -o /etc/yum.repos.d/GitLab.repo
# Ensure SCL repositories are available
RELEASE=$(rpm -qf /etc/redhat-release --qf '%{name}')
if [[ $(yum repolist all | grep -q scl)$? -ne 0 ]]
then
   yum install -y ${RELEASE}-scl
fi

# Install a Ruby version that is FIPS compatible
yum --enablerepo=*scl* install -y rh-ruby23

# Permanently eable the SCL version of Ruby
cat << EOF > /etc/profile.d/scl-ruby.sh
source /opt/rh/rh-ruby23/enable
export X_SCLS="\$(scl enable rh-ruby23 'echo \$X_SCLS')"
EOF

# Disable Chef's FIPS stuff
cat << EOF > /etc/profile.d/chef.sh
export CHEF_FIPS=""
EOF


# Install (but don't configure) GitLab
if [[ ${GITLAB_EFS_HOST} = UNDEF ]]
then
   echo "No EFS host was declared in the template."
   echo "Assuming alternate method for persisting repository data in use..."
else
   EfsMount "/git-data" "/var/opt/gitlab/git-data"
fi
yum install -y gitlab-ce
