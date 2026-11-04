#!/bin/sh -x

# simple script to reset access token in Preferences

defaults delete co.rs3studio.app rs3.websocket.token
