#!/bin/sh
set -eu

# simple script to excercise the gimball
# Install oscsend with: brew install liblo
# Enable the OSC listener in Preferences; change the port below if needed.

send() {
  oscsend localhost 8000 /panTilt ff "$1" "$2"
}

send 0.50 0.50
sleep 1
send -0.33 -0.50
sleep 1
send 0.40 -1.00
sleep 1
send -0.53 0.50
sleep 1
send 0.63 1.50
sleep 1
send -0.54 0.00
