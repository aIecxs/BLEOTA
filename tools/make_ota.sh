#!/usr/bin/env bash

# ==============================================================================
# ENVIRONMENT & PREREQUISITES NOTICE
# ==============================================================================
# This script is specifically designed and intended to run on Windows systems
# using the Git for Windows (MINGW64) Bash shell environment. It leverages
# MSYS2-specific utilities such as 'cygpath' to seamlessly bridge the gap
# between Unix-style paths and the Windows host filesystem.
#
# Requirements:
#   1. Arduino IDE v2.x (installed in standard environment paths so that logs
#      and temporary build assets are available under %APPDATA% / %LOCALAPPDATA%).
#   2. Git for Windows. If not already installed, the official environment
#      can be downloaded and installed from: https://git-scm.com
#
# Execution Rule:
#   This script MUST be executed entirely from within the respective Arduino
#   sketch directory. It uses dynamic shell expansion based on its own location
#   to resolve variables, find compiled binaries, parse partition schemes, 
#   and target the automated firmware extraction process.
#
# Note:
#   There is no Linux version of this script because Linux users are smart :)
# ==============================================================================
#
# Copyright 2026
# Powered by Gemini (Gemini 1.5 Pro Engine - May 2026 Edition)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ==============================================================================

# 1. Determine absolute paths
SCRIPT_PATH=$(realpath "${0}")
SKETCH_DIR=${SCRIPT_PATH%/*}     # Strips the filename from the back (equivalent to dirname)
SKETCH_NAME=${SKETCH_DIR##*/}    # Deletes everything up to the last / from the front (equivalent to basename)

#{build.source.path}=SKETCH_DIR
#{build.project_name}=SKETCH_NAME
#{build.path}=SKETCH_TEMP
#{runtime.platform.path}=HARDWARE_DIR

#{build.chip_variant}=

LOG_DIR="$APPDATA/Arduino IDE"
LOG_LINE=""

while IFS= read -r log_file; do
  if [ -f "$log_file" ]; then
    # Searches bottom-up for the most recent entry matching Sketch Name
    LOG_LINE=$(tac "$log_file" | grep -E -m 1 "20[0-9]{2}-[0-9]{2}-[0-9]{2}.*root.INFO.Received.port.after.upload.*$SKETCH_NAME")
    
    # If we found a match, exit the loop
    if [ -n "$LOG_LINE" ]; then
      echo "Using COM Port found in upload log: ${log_file##*/}"
      break
    fi
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -iname "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_log.log" | sort -r)

if [ -z "$LOG_LINE" ]; then
  echo "Error: COM Port not found. Restart Arduino IDE and Upload Sketch first." >&2
  exit 1
fi

# Extracts the COM port directly from the "arduino+serial://..." block
COM_PORT=$(echo "$LOG_LINE" | sed -n 's/.*arduino+serial:\/\/\([^,]*\),.*/\1/p')

# Convert to Windows format for JSON path matching
WINDOWS_PATH=$(cygpath -w "$SKETCH_DIR")
TARGET_LOCATION=$(echo "$WINDOWS_PATH" | sed 's/\\/\\\\/g' | tr '[:upper:]' '[:lower:]')

# 2. Define search paths for both possible temp directories
TEMP_SEARCH_PATHS=(
  "$TEMP/arduino/sketches"
  "$LOCALAPPDATA/arduino/sketches"
)

MATCHING_DIRS=()

# 3. Search through all potential 'build.options.json' files
for search_path in "${TEMP_SEARCH_PATHS[@]}"; do
  if [ -d "$search_path" ]; then
    while IFS= read -r json_file; do
      SKETCH_LOC_LINE=$(grep -i '"sketchLocation"' "$json_file" | tr '[:upper:]' '[:lower:]')
      
      if [[ "$SKETCH_LOC_LINE" == *"$TARGET_LOCATION"* ]]; then
        MATCHING_DIRS+=("${json_file%/*}")
      fi
    done < <(find "$search_path" -maxdepth 2 -iname "build.options.json" 2>/dev/null)
  fi
done

# Safety check
if [ ${#MATCHING_DIRS[@]} -eq 0 ]; then
  echo "Error: No build directory found for $SKETCH_NAME sketch." >&2
  exit 1
fi

# 4. Search for '.last-used' and sort by newest modification time (mtime)
NEWEST_TEMP_DIR=""
NEWEST_TIME=0

for dir in "${MATCHING_DIRS[@]}"; do
  LAST_USED_FILE="$dir/.last-used"
  if [ -f "$LAST_USED_FILE" ]; then
    MOD_TIME=$(stat -c %Y "$LAST_USED_FILE")
    if [ "$MOD_TIME" -gt "$NEWEST_TIME" ]; then
      NEWEST_TIME=$MOD_TIME
      NEWEST_TEMP_DIR=$dir
    fi
  fi
done

if [ -z "$NEWEST_TEMP_DIR" ]; then
  NEWEST_TEMP_DIR="${MATCHING_DIRS[0]}"
fi

# 5. Finalize output: Run through realpath to unify slashes
SKETCH_TEMP=$(realpath "$NEWEST_TEMP_DIR")

# 6. Extract and format the hardware folder path
# Grabs the content inside the quotes, splits at the comma to take only the first path
HARDWARE_WIN_PATH=$(grep -m 1 '"hardwareFolders"' "$SKETCH_TEMP/build.options.json" | sed -n 's/.*"hardwareFolders":\s*"\([^,"]*\).*/\1/p')

# Converts the Windows backslash path to a clean Git Bash Unix path
HARDWARE_DIR=$(cygpath -u "$HARDWARE_WIN_PATH")

# 7. Define output directory inside the build directory
DUMP_DIR="$SKETCH_TEMP/${SCRIPT_PATH##*/}"
DUMP_DIR="${DUMP_DIR%.*}"
mkdir -p "$DUMP_DIR"

# 8. Find the newest version of esptool.exe and mklittlefs.exe
# Using sort -V (version sort) to reliably pick the highest version number
ESPTOOL_EXE=$(find "$HARDWARE_DIR/../../../tools/esptool_py" -name "esptool.exe" 2>/dev/null | sort -V | tail -n 1)
MKLITTLEFS_EXE=$(find "$HARDWARE_DIR/../../../tools/mklittlefs" -name "mklittlefs.exe" 2>/dev/null | sort -V | tail -n 1)

if [ -z "$ESPTOOL_EXE" ] || [ -z "$MKLITTLEFS_EXE" ]; then
  echo "Error: Required tools (esptool or mklittlefs) not found." >&2
  exit 1
fi

# 9. Extract LittleFS/SPIFFS Partition Offset and Size from partitions.csv
PARTITION_CSV="$SKETCH_TEMP/partitions.csv"

if [ ! -f "$PARTITION_CSV" ]; then
  echo "Error: partitions.csv not found." >&2
  exit 1
fi

# Parse the row starting with 'spiffs', remove spaces, and grab offset (field 4) and size (field 5)
SPIFFS_ROW=$(grep -i "^spiffs" "$PARTITION_CSV" | sed 's/ //g')

if [ -z "$SPIFFS_ROW" ]; then
  echo "Error: No 'spiffs' partition found in partitions.csv." >&2
  exit 1
fi

LITTLEFS_OFFSET=$(echo "$SPIFFS_ROW" | cut -d',' -f4)
LITTLEFS_SIZE=$(echo "$SPIFFS_ROW" | cut -d',' -f5)

# 10. Dump the LittleFS partition from ESP32 flash memory
IMAGE_BIN="$DUMP_DIR/littlefs_dump.bin"
EXTRACT_DIR="$SKETCH_TEMP/data"
mkdir -p "$EXTRACT_DIR"

read -p "Dumping LittleFS partition at Offset: $LITTLEFS_OFFSET with Size: $LITTLEFS_SIZE from $COM_PORT... press any key..." -n 1 -r
echo "" # New line after key press

#from build.options.json {fqbn}
#{board_id} echo "esp32:esp32:esp32s3" | sed -E 's/^[^:]+:[^:]+:([^:,]+).*/\1/'
#{build.mcu} echo "esp32:esp32:lilygo_t_display_s3:MCU=esp32s3,FlashSize=16M" | sed -E 's/^([^:]+:[^:]+:[^:]+:).*MCU=([^,]+).*/\2/'
"$ESPTOOL_EXE" --chip esp32 --port "$COM_PORT" --baud 921600 read-flash "$LITTLEFS_OFFSET" "$LITTLEFS_SIZE" "$IMAGE_BIN"

if [ $? -ne 0 ]; then
  echo "Error: Close Serial Monitor on $COM_PORT." >&2
  exit 1
fi

# 11. Extract files from the dumped binary image using mklittlefs
echo "Extracting files from dump image via mklittlefs..."
"$MKLITTLEFS_EXE" -u "$EXTRACT_DIR" "$IMAGE_BIN"

if [ $? -eq 0 ]; then
  echo "Success! All files extracted to: $EXTRACT_DIR"
else
  echo "Error: Failed to unpack the LittleFS image." >&2
  exit 1
fi

# 12. Compare OpenSSL versions and store the newest path/command
PYTHON_OPENSSL=$(python -c "import ssl; print(ssl.OPENSSL_VERSION)" | sed -n 's/.*OpenSSL \([0-9.]*\).*/\1/p')
SYSTEM_OPENSSL=$(openssl --version 2>/dev/null | sed -n 's/.*OpenSSL \([0-9.]*\).*/\1/p')

# Use sort -V to find the highest version string
NEWEST_VERSION=$(printf '%s\n%s\n' "$PYTHON_OPENSSL" "$SYSTEM_OPENSSL" | sort -V | tail -n 1)

if [ "$NEWEST_VERSION" == "$SYSTEM_OPENSSL" ]; then
  openssl="openssl"
else
  openssl="python -c \"import ssl; ...\""
fi

# 13. Locate public and private keys inside the extracted directory by checking headers
PRIVATE_KEY_FILE=$(grep -l -m 1 "^-----BEGIN RSA PRIVATE KEY-----" "$EXTRACT_DIR"/* 2>/dev/null | head -n 1)
PUBLIC_KEY_FILE=$(grep -l -m 1 "^-----BEGIN PUBLIC KEY-----" "$EXTRACT_DIR"/* 2>/dev/null | head -n 1)

# Verify both keys were found
if [ -z "$PRIVATE_KEY_FILE" ] || [ -z "$PUBLIC_KEY_FILE" ]; then
  echo "Error: Could not find both private and public PEM keys in the extracted files." >&2
  exit 1
fi

echo "Found Private Key: ${PRIVATE_KEY_FILE##*/}"
echo "Found Public Key:  ${PUBLIC_KEY_FILE##*/}"

# 14. Define file paths for signing
INPUT_BIN="$SKETCH_TEMP/$SKETCH_NAME.ino.bin"
SIGNATURE_FILE="$DUMP_DIR/signature.sign"
FINAL_OTA_BIN="$DUMP_DIR/ota.bin"

if [ ! -f "$INPUT_BIN" ]; then
  echo "Error: Source binary '${INPUT_BIN##*/}' not found." >&2
  exit 1
fi

# 15. Sign the binary using the determined openssl command
echo "Signing binary with SHA256..."
$openssl dgst -sign "$PRIVATE_KEY_FILE" -keyform PEM -sha256 -out "$SIGNATURE_FILE" -binary "$INPUT_BIN"

if [ $? -ne 0 ]; then
  echo "Error: OpenSSL signing failed." >&2
  exit 1
fi

# 16. Concatenate the original binary and the signature into the final OTA file
echo "Creating final combined OTA binary..."
cat "$INPUT_BIN" "$SIGNATURE_FILE" > "$FINAL_OTA_BIN"

if [ $? -eq 0 ]; then
  echo "Success! Combined signed update file created at: $FINAL_OTA_BIN"
else
  echo "Error: Failed to combine binary and signature." >&2
  exit 1
fi

cp "$PRIVATE_KEY_FILE" "$DUMP_DIR"
cp "$PUBLIC_KEY_FILE" "$DUMP_DIR"

# 17. Open Windows Explorer in the dump directory
explorer.exe "$(cygpath -w "$DUMP_DIR")"
