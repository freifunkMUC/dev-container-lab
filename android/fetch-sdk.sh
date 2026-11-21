#!/usr/bin/env bash
# Download the Android emulator, platform-tools and one x86_64 system image
# to android/sdk. You must read and accept the Android SDK licenses: the
# script shows them. It runs the SDK tools in a container, so the host
# needs only docker.
# Usage: [ANDROID_API=35] [ANDROID_TAG=default] android/fetch-sdk.sh
set -eu
cd "$(dirname "$0")"
API="${ANDROID_API:-35}"
TAG="${ANDROID_TAG:-default}"
TOOLS="${ANDROID_CMDLINE_TOOLS:-13114758}"
SDK="${ANDROID_SDK:-$(pwd)/sdk}"
mkdir -p "${SDK}"

docker run --rm -it -v "${SDK}:/sdk" -e API="${API}" -e TAG="${TAG}" -e TOOLS="${TOOLS}" \
	-e OWNER="$(id -u):$(id -g)" eclipse-temurin:17-jdk bash -ec '
apt-get update -qq && apt-get install -qq -y unzip > /dev/null
if [ ! -x /sdk/cmdline-tools/latest/bin/sdkmanager ]; then
	curl -fsSLo /tmp/tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-${TOOLS}_latest.zip"
	unzip -q /tmp/tools.zip -d /tmp/tools
	mkdir -p /sdk/cmdline-tools
	mv /tmp/tools/cmdline-tools /sdk/cmdline-tools/latest
fi
sm="/sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/sdk"
$sm --licenses
$sm emulator platform-tools "system-images;android-${API};${TAG};x86_64"
chown -R "${OWNER}" /sdk'
echo "Android SDK with API ${API} (${TAG}) is in ${SDK}"
