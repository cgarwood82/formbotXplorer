#!/bin/bash

# Paths
CONFIG_FILE="/home/biqu/printer_data/config/variables.cfg"

# Extract file path and name from variables.cfg
filepath=$(sed -n "s/.*filepath *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")
last_file=$(sed -n "s/.*last_file *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")

# Validate G-code file
if [ ! -f "$filepath" ]; then
  echo "Error: G-code file not found at $filepath"
  exit 1
fi

# Extract the last matching layer height metadata from the G-code file
first_layer_height=$(grep -E '^;[ ]*first_layer_height[ ]*=' "$filepath" | tail -1 | sed -n 's/^;[ ]*first_layer_height[ ]*=[ ]*\(.*\)/\1/p')
layer_height=$(grep -E '^;[ ]*layer_height[ ]*=' "$filepath" | tail -1 | sed -n 's/^;[ ]*layer_height[ ]*=[ ]*\(.*\)/\1/p')

# Validate extracted values
if [ -z "$first_layer_height" ] || [ -z "$layer_height" ]; then
  echo "Error: Failed to extract one or both layer height values."
  exit 1
fi

# Function to update and verify config
update_config_file() {
  # Remove previous entries
  sed -i '/^first_layer_height *=/d' "$CONFIG_FILE"
  sed -i '/^layer_height *=/d' "$CONFIG_FILE"

  # Append new values
  echo "first_layer_height = $first_layer_height" >> "$CONFIG_FILE"
  echo "layer_height = $layer_height" >> "$CONFIG_FILE"
}

# Function to verify values in config
verify_config_file() {
  grep -q "^first_layer_height *= *$first_layer_height" "$CONFIG_FILE" && \
  grep -q "^layer_height *= *$layer_height" "$CONFIG_FILE"
}

# Retry loop
MAX_RETRIES=5
SLEEP_SECONDS=1
attempt=1
success=0

while [ $attempt -le $MAX_RETRIES ]; do
  update_config_file

  if verify_config_file; then
    success=1
    break
  fi

  echo "Attempt $attempt failed to verify saved values. Retrying..."
  sleep $SLEEP_SECONDS
  attempt=$((attempt + 1))
done

if [ "$success" -eq 1 ]; then
  echo "Extracted from: $last_file"
  echo "Saved to variables.cfg:"
  echo "  first_layer_height = $first_layer_height"
  echo "  layer_height = $layer_height"
else
  echo "Error: first_layer_height and layer_height could not be extracted after $MAX_RETRIES attempts."
  exit 1
fi
