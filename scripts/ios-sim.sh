#!/bin/sh
# Prints the name of the first available iPhone simulator on this Mac, or "iPhone 17" when there
# is none: the names of simulators change with Xcode releases, so the Makefile asks instead of
# naming one.
name="$(xcrun simctl list devices available 2> /dev/null |
  sed -nE 's/^ +(iPhone[^(]*[^ (]) \(.*/\1/p' | head -n 1)"
echo "${name:-iPhone 17}"
