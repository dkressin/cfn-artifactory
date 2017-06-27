#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2015
#
# Script to install and configure the Artifactory software
#
#################################################################
source /etc/cfn/AF.envs
AFRPM="${ARTIFACTORY_RPM:-UNDEF}"
S3BKUPDEST="${ARTIFACTORY_S3_BACKUPS:-UNDEF}"
AFHOMEDIR="${ARTIFACTORY_HOME:-UNDEF}"
AFETCDIR="${ARTIFACTORY_ETC:-UNDEF}"
AFLICENSE="${ARTIFACTORY_LICENSE:-UNDEF}"
AFLOGDIR="${ARTIFACTORY_LOGS:-UNDEF}"
AFVARDIR="${ARTIFACTORY_VARS:-UNDEF}"
AFTOMCATDIR="${ARTIFACTORY_TOMCAT_HOME:-UNDEF}"
CFNENDPOINT="${ARTIFACTORY_CFN_ENDPOINT:-UNDEF}"
DBPROPERTIES="${AFETCDIR}/db.properties"
FSBACKUPDIR="${ARTIFACTORY_BACKUPDIR:-UNDEF}"
FSCACHEDIR="${ARTIFACTORY_CACHEDIR:-UNDEF}"
PGSQLJDBC=postgresql-jdbc
PGSQLHOST="${ARTIFACTORY_DBHOST:-UNDEF}"
PGSQLPORT="${ARTIFACTORY_DBPORT:-UNDEF}"
PGSQLINST="${ARTIFACTORY_DBINST:-UNDEF}"
PGSQLUSER="${ARTIFACTORY_DBUSER:-UNDEF}"
PGSQLPASS="${ARTIFACTORY_DBPASS:-UNDEF}"
SELSRC=${ARTIFACTORY_ETC}/mimetypes.xml
STACKNAME="${ARTIFACTORY_CFN_STACKNAME:-UNDEF}"

##
## Set up an error logging and exit-state
function err_exit {
   local ERRSTR="${1}"
   local SCRIPTEXIT=${2:-1}

   # Our output channels
   echo "${ERRSTR}" > /dev/stderr
   logger -t "${PROGNAME}" -p kern.crit "${ERRSTR}"

   # Need our exit to be an integer
   if [[ ${SCRIPTEXIT} =~ ^[0-9]+$ ]]
   then
      exit "${SCRIPTEXIT}"
   else
      exit 1
   fi
}

##
## Prep for rebuild or setup rejoin as appropriate
function RebuildStuff {
   if [[ $(aws s3 ls s3://"${S3BKUPDEST}"/rebuild > /dev/null)$? -eq 0 ]]
   then
      echo "Found rebuild-file in s3://${S3BKUPDEST}/"

      if [[ ! -d "${AFHOMEDIR}"/access/etc/keys/ ]]
      then
         echo "Creating missing key-directories"
         install -d -m 0700 -o artifactory -g artifactory \
            "${AFHOMEDIR}"/access/{,etc/{,keys}}
      fi

      for KEY in root.crt private.key
      do
         printf "Attempting to pull down %s... " "${KEY}"
         aws s3 cp s3://"${S3BKUPDEST}"/creds/"${KEY}" \
            "${AFHOMEDIR}"/access/etc/keys/"${KEY}" && echo "Success!" || \
              err_exit "Failed to pull down ${KEY}"
         chown artifactory:artifactory "${AFHOMEDIR}"/access/etc/keys/"${KEY}"
      done
   else
      touch /tmp/rebuild
      aws s3 cp /tmp/rebuild s3://"${S3BKUPDEST}"/ || \
        err_exit 'Failed to set rebuild flag. Reinstantiations of EC2 will not happen without intervention.'
      export NOREBUILD=""
   fi
}


#######################
## Main Program Logic  
#######################

# Install the Artifactory RPM
echo "Attempt to install Artifactory RPM..."
yum install -y "${AFRPM}" && echo "Success!" || \
  err_exit 'Artifactory RPM install failed'

# Install the License file
printf 'Fetching license key... '
curl -o /tmp/artifactory.lic -skL "${AFLICENSE}" && echo "Success!" || \
  err_exit 'Failed fetching license key'
printf "Attempting to install the Artifactory license key... "
install -b -m 0640 -o artifactory -g artifactory /tmp/artifactory.lic \
  "${ARTIFACTORY_ETC}"/artifactory.lic && echo "Success!" || \
  err_exit 'License file installation failed.'

# Ensure that Artifactory's "extra" filesystems are properly-owned
for FIXPERM in  "${FSBACKUPDIR}" "${FSCACHEDIR}"
do
   printf "Setting ownership on %s..." "${FIXPERM}"
   chown artifactory:artifactory "${FIXPERM}" && echo "Success!" || \
     err_exit "Failed to set ownership on ${FIXPERM}"
done

##
## Ensure PGSQL JAR file installed and linked
if [[ $(rpm -q --quiet ${PGSQLJDBC})$? -eq 0 ]]
then
   echo "PostGreSQL JDBC installed"
else
   echo "Attempting to install PostGreSQL JDBC..."
   yum install -y ${PGSQLJDBC} || \
      err_exit "Failed to install ${PGSQLJDBC}"
fi

if [[ $(stat "${AFTOMCATDIR}/lib/*jdbc.jar" \
        > /dev/null 2>&1)$? -eq 0 ]]
then
   echo "Found a PGSQL JDBC JAR in ${AFTOMCATDIR}/lib"
else
   echo "Linking PostGreSQL JDBC into Artifactory..."
   ln -s "$(rpm -ql ${PGSQLJDBC} | grep jdbc.jar)" \
      "${AFTOMCATDIR}/lib/" || \
         err_exit "Failed to link PostGreSQL JDBC into Artifactory."
fi

##
## DB-setup for non-clustered nodes
if [[ -f ${DBPROPERTIES} ]]
then
   mv "${DBPROPERTIES}" "${DBPROPERTIES}.BAK-${DATE}" || \
     err_exit "Failed to preserve existing '${DBPROPERTIES}' file"
fi

# Locate example contents
# shellcheck disable=SC2086
SRCPGSQLCONF=$(rpm -ql ${ARTIFACTORY_RPM} | grep postgresql.properties)

# Grab header-content from RPM's example file
grep ^# "${SRCPGSQLCONF}" > "${DBPROPERTIES}" || \
   err_exit "Failed to create stub '${DBPROPERTIES}' content"

##
## Append db-connection info to db.properties file
printf "Crerating new '%s' file... " "${DBPROPERTIES}"
cat << EOF >> "${DBPROPERTIES}"

type=postgresql
driver=org.postgresql.Driver
url=jdbc:postgresql://${PGSQLHOST}:${PGSQLPORT}/${PGSQLINST}
username=${PGSQLUSER}
password=${PGSQLPASS}
EOF

# Make sure the properites file actually got created/updated
if [[ $? -eq 0 ]]
then
   echo "Success!"
   chown artifactory:artifactory "${DBPROPERTIES}" || \
      err_exit "Failed to set ownership on ${DBPROPERTIES}"
else
   err_exit "Error creating new '${DBPROPERTIES}' file. Aborting."
fi

# Clean up /etc/rc.d/rc.local
chmod a-x /etc/rc.d/rc.local || err_exit 'Failed to deactivate rc.local'
sed -i '/Artifactory config-tasks/,$d' "$(readlink -f /etc/rc.d/rc.local)"

# Pull down key-files if we're rebuilding
RebuildStuff

# Start it up...
printf "Start Artifactory... "
systemctl start artifactory && echo "Success!" || \
  err_exit 'Failed to start Artifactory service'
echo "Enable Artifactory service"
systemctl enable artifactory

# Prep S3 for future rebuilds
if [[ ! -z ${NOREBUILD+xxx} ]]
then
   echo "Push creds to S3 to support future rebuilds"
   aws s3 sync "${AFHOMEDIR}"/access/etc/keys/ s3://"${S3BKUPDEST}"/creds/
fi

# Signal completion to CFn
printf "Send success signal to CFn... "
/opt/aws/bin/cfn-signal -e 0 --stack "${STACKNAME}" --resource ArtifactoryEC2 \
--url "${CFNENDPOINT}" || err_exit 'Failed sending CFn signal'
