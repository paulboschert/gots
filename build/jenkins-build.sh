#!/bin/bash
#
# This script automates the build process (currenly only doing coverage reports for unit tests)
#
# It may be called inside and outside of a container.
# If called outside a container, it will create a new build container for CentOS 7 and then run
# all these things inside that container.  Then once outside the container, it will scrape the test artifacts
#

set -o posix

#
# Show a help/usage message
#
printHelp() {
  printf "Usage: %s [OPTION]...\n" "$0"
  echo "Options:"
  echo "  -h, -?    Show this help message"
  echo ""
  echo "  -l        Run locally only, don't bother with containers, just run all the build functions"
  echo "            (except RPM publishing to a remote server and creating the release container) locally"
  echo "            Default: unset"
  echo ""
}

# process the program options
OPTIND=1 # reset this in case getops has been previously used in this bash instance
RUN_LOCALLY=false # assume running locally was not requested
while getopts "h?l" OPTION; do
  case "$OPTION" in
  h|\?) # print a help message
    printHelp
    exit 0;;
  l) # set the run locally flag
    RUN_LOCALLY=true;;
  esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift

# enter one directory up from where this script lives
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR/.."

# source in some helpful build functions
. "$DIR/build-functions.sh"

# print out the processed program options
echo Building with the following settings
printf "        RUN_LOCALLY: '%s'\n" "$RUN_LOCALLY"

# check to see if we're inside a docker container by examining the control groups of the init process.
# if we're in a docker container, we'll see a reference to docker in these control groups
cat /proc/1/cgroup | cut -d':' -f3 | cut -d'/' -f2 | grep -i 'docker' > /dev/null 2>&1
RET_CODE="$?"
INSIDE_CONTAINER=false
if [ "$RET_CODE" -eq 0 ]; then
  INSIDE_CONTAINER=true
fi

# if we're inside a container call all the build functions
if $RUN_LOCALLY || $INSIDE_CONTAINER; then

  unitTestsWithCoverage linux # unit tests with code coverage for the linux GOOS

# else, we're not inside a container and not running locally so start up the containers
# and publish the result of those container builds
else

  # Attach a UUID to the container name so we don't conflict with parallel builds
  CONTAINER_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

  # start by cleaning up any existing containers
  cleanupContainers

  # build the CentOS 7 container
  buildContainer "centos7-$CONTAINER_UUID" "build/centos7/Dockerfile"

  # trap the container removal on any exit condition
  trap "removeContainer "centos7-$CONTAINER_UUID"" EXIT HUP INT QUIT PIPE TERM

  # get the test artifacts so we can publish them for Jenkins
  # (e.g. code coverage reports, unit test output)
  getContainerTestArtifacts "centos7-$CONTAINER_UUID"

  # cleanup the containers
  cleanupContainers
fi

exit 0

