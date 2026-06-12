#!/usr/bin/env bash
#
# Copyright 2002-present the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ----------------------------------------------------------------------------
# End-to-end smoke test for the spring-context-bootstrap module.
#
# This script:
#   1. Publishes the local Spring Framework build (including the new
#      spring-context-bootstrap module) to the local Maven repository.
#   2. Downloads the Spring Petclinic sample application.
#   3. Wires the parallel-bootstrap module into Petclinic and replaces the
#      normal (sequential) context bootstrap with the parallel mechanism by
#      registering ParallelBootstrapApplicationContextInitializer through the
#      Spring Boot 'context.initializer.classes' property.
#   4. Starts the application and verifies that it boots correctly.
#
# Environment variables (all optional):
#   WORK_DIR        Working directory for the Petclinic checkout
#                   (default: /tmp/petclinic-parallel-bootstrap)
#   PETCLINIC_GIT   Git URL of the Petclinic repository
#                   (default: https://github.com/spring-projects/spring-petclinic.git)
#   PETCLINIC_REF   Git ref/branch/tag to check out (default: main)
#   STARTUP_TIMEOUT Seconds to wait for the app to start (default: 180)
#   SKIP_PUBLISH    If set to "true", skip the publishToMavenLocal step
#   SERVER_PORT     HTTP port the app should listen on (default: 8089)
# ----------------------------------------------------------------------------

set -euo pipefail

# --- Resolve directories ----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ -> spring-context-bootstrap/ -> framework root
FRAMEWORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

WORK_DIR="${WORK_DIR:-/tmp/petclinic-parallel-bootstrap}"
PETCLINIC_GIT="${PETCLINIC_GIT:-https://github.com/spring-projects/spring-petclinic.git}"
PETCLINIC_REF="${PETCLINIC_REF:-main}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"
SKIP_PUBLISH="${SKIP_PUBLISH:-false}"
SERVER_PORT="${SERVER_PORT:-8089}"

INITIALIZER_CLASS="org.springframework.context.bootstrap.parallel.ParallelBootstrapApplicationContextInitializer"

# Spring Framework version produced by this build (e.g. 7.1.0-SNAPSHOT).
FRAMEWORK_VERSION="$(sed -n 's/^version=//p' "${FRAMEWORK_DIR}/gradle.properties")"
if [[ -z "${FRAMEWORK_VERSION}" ]]; then
	echo "ERROR: could not determine framework version from gradle.properties" >&2
	exit 1
fi

PETCLINIC_DIR="${WORK_DIR}/spring-petclinic"
APP_LOG="${WORK_DIR}/petclinic.log"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# --- Step 1: publish the framework (incl. the new module) to ~/.m2 ----------
if [[ "${SKIP_PUBLISH}" == "true" ]]; then
	log "Skipping publishToMavenLocal (SKIP_PUBLISH=true)"
else
	log "Publishing Spring Framework ${FRAMEWORK_VERSION} to the local Maven repository"
	# Skip tests and javadoc generation to keep the publish step fast; the
	# binary + sources artifacts are all that Petclinic needs to resolve.
	(cd "${FRAMEWORK_DIR}" && ./gradlew --no-daemon -x test -x javadoc publishToMavenLocal)
fi

# Confirm the new module landed in the local repository.
MODULE_POM="${HOME}/.m2/repository/org/springframework/spring-context-bootstrap/${FRAMEWORK_VERSION}/spring-context-bootstrap-${FRAMEWORK_VERSION}.pom"
if [[ ! -f "${MODULE_POM}" ]]; then
	echo "ERROR: spring-context-bootstrap was not published to ${MODULE_POM}" >&2
	exit 1
fi
log "spring-context-bootstrap-${FRAMEWORK_VERSION} is available in ~/.m2"

# --- Step 2: download Spring Petclinic --------------------------------------
mkdir -p "${WORK_DIR}"
if [[ -d "${PETCLINIC_DIR}/.git" ]]; then
	log "Reusing existing Petclinic checkout at ${PETCLINIC_DIR}"
	(cd "${PETCLINIC_DIR}" && git fetch --depth 1 origin "${PETCLINIC_REF}" && git checkout -f FETCH_HEAD)
else
	log "Cloning Spring Petclinic (${PETCLINIC_REF}) into ${PETCLINIC_DIR}"
	git clone --depth 1 --branch "${PETCLINIC_REF}" "${PETCLINIC_GIT}" "${PETCLINIC_DIR}"
fi

# --- Step 3: wire the new module into Petclinic -----------------------------
log "Aligning Petclinic on Spring Framework ${FRAMEWORK_VERSION} and adding the parallel-bootstrap dependency"
FRAMEWORK_VERSION="${FRAMEWORK_VERSION}" python3 - "${PETCLINIC_DIR}/pom.xml" <<'PY'
import os
import re
import sys

pom_path = sys.argv[1]
version = os.environ["FRAMEWORK_VERSION"]
with open(pom_path, encoding="utf-8") as fh:
    pom = fh.read()

# 1. Force every managed Spring Framework artifact onto our local build by
#    overriding the 'spring-framework.version' property defined by the
#    spring-boot-starter-parent.
prop = f"<spring-framework.version>{version}</spring-framework.version>"
if "<spring-framework.version>" in pom:
    pom = re.sub(r"<spring-framework\.version>.*?</spring-framework\.version>", prop, pom)
else:
    # Insert the property right after the <java.version> entry.
    pom = pom.replace(
        "<java.version>17</java.version>",
        "<java.version>17</java.version>\n    " + prop,
        1,
    )

# 2. Add the spring-context-bootstrap dependency (idempotent).
if "spring-context-bootstrap" not in pom:
    dependency = (
        "    <dependency>\n"
        "      <groupId>org.springframework</groupId>\n"
        "      <artifactId>spring-context-bootstrap</artifactId>\n"
        "      <version>${spring-framework.version}</version>\n"
        "    </dependency>\n"
        "  </dependencies>"
    )
    pom = pom.replace("\n  </dependencies>", "\n" + dependency, 1)

with open(pom_path, "w", encoding="utf-8") as fh:
    fh.write(pom)
print(f"Patched {pom_path}")
PY

log "Replacing the normal bootstrap mechanism with the parallel initializer"
APP_PROPS="${PETCLINIC_DIR}/src/main/resources/application.properties"
# Remove any previous entry to keep the script idempotent, then append ours.
sed -i '/^context.initializer.classes=/d' "${APP_PROPS}"
{
	echo ""
	echo "# Enabled by run-petclinic-parallel-bootstrap.sh: replace the normal"
	echo "# sequential bootstrap with parallel singleton instantiation."
	echo "context.initializer.classes=${INITIALIZER_CLASS}"
	echo "logging.level.org.springframework.context.bootstrap.parallel=DEBUG"
} >> "${APP_PROPS}"

# --- Step 4: build and start, then verify the app boots ---------------------
log "Building and starting Petclinic on port ${SERVER_PORT} (logs: ${APP_LOG})"
rm -f "${APP_LOG}"

# Run via the Spring Boot Maven plugin. The build resolves the 7.1.0-SNAPSHOT
# artifacts (including spring-context-bootstrap) from the local Maven repo.
(
	cd "${PETCLINIC_DIR}"
	./mvnw -q -DskipTests \
		-Dspring-boot.run.arguments="--server.port=${SERVER_PORT}" \
		spring-boot:run
) > "${APP_LOG}" 2>&1 &
APP_PID=$!

cleanup() {
	if kill -0 "${APP_PID}" 2>/dev/null; then
		log "Stopping Petclinic (pid ${APP_PID})"
		# Kill the whole process group spawned by Maven.
		pkill -TERM -P "${APP_PID}" 2>/dev/null || true
		kill -TERM "${APP_PID}" 2>/dev/null || true
		sleep 5
		pkill -KILL -P "${APP_PID}" 2>/dev/null || true
		kill -KILL "${APP_PID}" 2>/dev/null || true
	fi
}
trap cleanup EXIT

log "Waiting up to ${STARTUP_TIMEOUT}s for the application to start..."
STARTED=false
for ((i = 0; i < STARTUP_TIMEOUT; i++)); do
	if ! kill -0 "${APP_PID}" 2>/dev/null; then
		break
	fi
	if grep -q "Started PetClinicApplication" "${APP_LOG}" 2>/dev/null; then
		STARTED=true
		break
	fi
	sleep 1
done

echo "----------------------- application log (tail) -----------------------"
tail -n 40 "${APP_LOG}" || true
echo "----------------------------------------------------------------------"

if [[ "${STARTED}" != "true" ]]; then
	echo "FAILURE: Petclinic did not start within ${STARTUP_TIMEOUT}s." >&2
	exit 1
fi

# Confirm the parallel bootstrap mechanism was actually engaged.
if grep -qiE "parallel.bootstrap|ParallelBootstrap" "${APP_LOG}"; then
	log "Parallel bootstrap mechanism was active during startup."
else
	echo "WARNING: application started but no parallel-bootstrap activity was logged." >&2
fi

log "SUCCESS: Petclinic started correctly with the parallel bootstrap module."
