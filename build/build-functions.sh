#!/bin/bash

set -o posix

#
# Exit with a failure message
#
# $1 The error message to display
# $2 The return code, if undefined or if 0, it will be set to 1
# return: non-zero meaning failure
#
die() {
  local MSG=$1
  local RETURN_CODE=$2

  if [ -z $RETURN_CODE ]; then
    RETURN_CODE="1"
  fi

  printf "ERROR: %s\n" "$MSG" >&2
  exit $RETURN_CODE
}

#
# Show a warning message
#
# $1 The warning message to display
# return: 0
#
warn() {
  local MSG=$1

  printf "WARNING: %s\n" "$MSG" >&2

  return 0
}

#
# Build and run the unit tests and get the coverage profile simultaneously
#
# $1 GOOS: A potentially different operating system specification, see https://golang.org/doc/install/source#environment
#
unitTestsWithCoverage() {
  local GOOS=$1
  printf "INFO Running unit tests and collecting code coverage report"
  if [ ! -z $GOOS ]; then
    printf " in %s..." "$GOOS"
  fi
  printf "\n"

  # allow some number of test failures without actually failing completely
  local MAX_FAILURES=0

  local GOTEST_OUTPUT_FILE="gotest.out" # go test output file
  local COVERAGE_OUTPUT_FILE="coverage.out" # coverage report from go test

  >"$COVERAGE_OUTPUT_FILE" # start by clearing the file

  # loop through all the package tests, excluding vendored code, integration tests, and anything currently leftover in
  # rpm from the build
  local FAILED_TEST_COUNT=0
  for PACKAGE in $(go list ./... | grep -v -e vendor -e itests -e rpm); do
    printf "Running tests in %s\n" "$PACKAGE"

    GOOS=$GOOS GOARCH=$GOARCH go test -timeout=60s -v -short -p 1 -coverprofile="$COVERAGE_OUTPUT_FILE.tmp" "$PACKAGE" | tee "$GOTEST_OUTPUT_FILE" 2>&1
    RET=$?
    if [ "$RET" -ne 0 ]; then
      printf "Package '%s' returned failure code %s\n" "$PACKAGE" "$RET"
      FAILED_TEST_COUNT=$((FAILED_TEST_COUNT+1))
    fi

    if [ -e "$COVERAGE_OUTPUT_FILE.tmp" ]; then
      tail -n +2 "$COVERAGE_OUTPUT_FILE.tmp" >> "$COVERAGE_OUTPUT_FILE"
    fi
  done

  # replace incompatible text in $COVERAGE_OUTPUT_FILE, and convert to XML
  sed -i '1s/^/mode: set\n/' "$COVERAGE_OUTPUT_FILE"
  gocov convert "$COVERAGE_OUTPUT_FILE" | gocov-xml > coverage.xml || \
      warn "failed to convert code coverage report to XML"

  # convert the test output to XML
  go2xunit -input "$GOTEST_OUTPUT_FILE" -output junit.xml || \
      warn "failed to convert test output to XML"

  # remove temporary files
  rm -f "$GOTEST_OUTPUT_FILE" "$COVERAGE_OUTPUT_FILE.tmp"

  # fail with an apropriate error message if we've exceeded our maximum error count
  if [ "$FAILED_TEST_COUNT" -gt "$MAX_FAILURES" ]; then
    die "$(printf "Package failures (%s) exceeded maximum failures of %s\n" "$FAILED_TEST_COUNT" \
      "$MAX_FAILURES")" "$FAILED_TEST_COUNT"
  fi
}

#
# Check if docker is installed and that is at least the minimum version.
#
# return: true if installed, false otherwise
#
dockerCheck() {
  local MIN_VER="17"
  # check if the docker command is present
  command -v docker > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    local INST_VER=$(docker --version 2>&1 | cut -f3 -d ' ' | cut -f1,2 -d'.')

    # rely on sort -V for our version comparison
    if [ "$(printf "%s\n%s\n" "$INST_VER" "$MIN_VER" | sort -V | tail -n1)" == "$INST_VER" ]; then
      return 0
    else
      return 1
    fi
  else
    return $?
  fi
}

#
# Build a container given a docker file and a name
# Pass in the BUILD_TAG environment variable if it's defined
#
# $1 The name to append to the build tag and the container name
# $2 The docker file to use
#
buildContainer() {
  dockerCheck || \
    die "cannot find docker, install docker and and re-run."

  local NAME=$1
  local DOCKER_FILE=$2

  # remove any potential container with the same name first
  removeContainer "$NAME"

  docker build -t "$NAME-img" \
               -f "$DOCKER_FILE" . || \
    die "failed to build container"

  docker run -itd --name "$NAME-cont" "$NAME-img" || \
    die "failed to create and start the container image"

  printf "INFO Created container sucessfully for '%s' from '%s'\n" "$NAME" "$DOCKER_FILE"
}

#
# Get the test artifacts of a container given it's name
#
# Test artifacts include:
# a) Coverity code coverage report
# b) Go test output
#
# $1 The name to append to the container name
#
getContainerTestArtifacts() {
  dockerCheck || \
    die "cannot find docker, install docker and and re-run."

  local NAME=$1

  # get the build path defined in the container
  local GOTS_PATH=$(docker exec "$NAME-cont" bash -c 'printf "%s" "$GOTS_PATH"')

  # Coverity coverage report
  docker cp "$NAME-cont":"$GOTS_PATH/coverage.xml" . || \
    die "failed to retrieve Coverity build artifact from container"
  printf "INFO Retrieved Coverity build artifact successfully from container '%s'\n" "$NAME"

  # Go test output
  docker cp "$NAME-cont":"$GOTS_PATH/junit.xml" . || \
    die "failed to retrieve go test output build artifact from container"
  printf "INFO Retrieved go test output build artifact successfully from container '%s'\n" "$NAME"
}

#
# Remove a container and cleanup
#
# $1 The name to append to the container name
#
removeContainer() {
  dockerCheck || \
    die "cannot find docker, install docker and and re-run."

  local NAME=$1

  printf "Removing container and associated image for %s...\n" "$NAME"

  # only attempt removal if it exists
  docker inspect "$NAME-cont" > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    docker rm --force "$NAME-cont" || \
      warn "failed to remove container"
  fi

  # only attempt removal if it exists
  docker inspect "$NAME-img" > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    docker rmi --force "$NAME-img" || \
      warn "failed to remove image"
  fi
}

#
# Cleanup container disk space
#
cleanupContainers() {
  dockerCheck || \
    die "cannot find docker, install docker and and re-run."

  # remove containers that have exited
  docker ps -a -q -f status=exited | xargs -r docker rm -v || \
    warn "failed to cleanup containers that have exited"

  # remove containers that are dangling
  docker volume ls -qf dangling=true | xargs -r docker volume rm || \
    warn "failed to cleanup containers that are dangling"

  docker run -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker:/var/lib/docker --rm martin/docker-cleanup-volumes || \
    warn "failed to run the docker cleanup container"

  docker images -f "dangling=true" -q | xargs -r docker rmi || \
    warn "failed to cleanup additional dangling containers"
}

# Allows one to call a function based on arguments passed to this script
$*
