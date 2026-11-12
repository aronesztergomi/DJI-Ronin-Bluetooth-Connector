#!/bin/sh -x

# simple script to excercise the gimball
# install websocat with "brew install websocat"
# change auth:XXX to your access token in Preferences (or disable access tokens)

{
  # echo 'auth:XXX'
  # sleep 1
  echo 'pan:0.5 tilt:0.5'
  sleep 1
  echo 'pan:-0.33 tilt:-0.5'
  sleep 1
  echo 'pan:0.4 tilt:-1'
  sleep 1
  echo 'pan:-0.53 tilt:0.50'
  sleep 1
  echo 'pan:0.6304 tilt:0.47'
} | websocat -t ws://localhost:81
