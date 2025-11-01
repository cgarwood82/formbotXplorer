#!/usr/bin/env bash
KLIPPERCONFIG="$HOME/printer_data/config"
VERSIONCONTROLHOME="$HOME/src/formbotXplorer"

# Copy working configuration files over to version control
cp -R "$KLIPPERCONFIG"/01__User_Custom__CFG "$VERSIONCONTROLHOME"/ 
cp -R "$KLIPPERCONFIG"/02__Boards_Serials "$VERSIONCONTROLHOME"/ 

