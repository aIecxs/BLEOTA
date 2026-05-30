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


# Function: openssl_python_wrapper()
# Emulates the 'openssl' command using Python
openssl_python_wrapper() {
  python -c '
import sys
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.serialization import load_pem_private_key

args = sys.argv[1:]

if "dgst" in args and "-sign" in args:
    try:
        # 1. Dynamically locate flags regardless of their position/order
        private_key_path = args[args.index("-sign") + 1]
        output_path = args[args.index("-out") + 1]
        
        # 2. Determine the hash algorithm dynamically
        hash_algo = hashes.SHA256()  # Default fallback
        for arg in args:
            if arg.startswith("-sha"):
                bits = arg.replace("-sha", "")
                if bits == "256": hash_algo = hashes.SHA256()
                elif bits == "384": hash_algo = hashes.SHA384()
                elif bits == "512": hash_algo = hashes.SHA512()
                elif bits == "224": hash_algo = hashes.SHA224()
            elif arg == "-md5": hash_algo = hashes.MD5()
            elif arg == "-sha1": hash_algo = hashes.SHA1()

        # 3. Find the input file (the only positional argument that is not a flag or value)
        input_path = None
        skip_next = False
        for i, arg in enumerate(args):
            if skip_next:
                skip_next = False
                continue
            if arg in ["-sign", "-out", "-keyform", "-passin"]:
                skip_next = True
                continue
            if arg.startswith("-") or arg == "dgst":
                continue
            input_path = arg

        if not input_path:
            raise ValueError("No input file specified in arguments.")

        # 4. Cryptographic execution
        with open(private_key_path, "rb") as f:
            private_key = load_pem_private_key(f.read(), password=None)
            
        with open(input_path, "rb") as f:
            data = f.read()
            
        signature = private_key.sign(data, padding.PKCS1v15(), hash_algo)
        
        with open(output_path, "wb") as f:
            f.write(signature)
            
        sys.exit(0)
    except Exception as e:
        print(f"Python Signer Error: {e}", file=sys.stderr)
        sys.exit(1)
else:
    print(f"Python Signer Error: Unsupported OpenSSL arguments. Args: {args}", file=sys.stderr)
    sys.exit(1)
' "$@"
}

# ==============================================================================

# 1. Determine absolute paths
SCRIPT_PATH=$(realpath "${0}")
build_source_path=${SCRIPT_PATH%/*}     # Strips the filename from the back (equivalent to dirname)
build_project_name=${build_source_path##*/}    # Deletes everything up to the last / from the front (equivalent to basename)

if [ -z "$(find "$build_source_path" -maxdepth 1 -iname "$build_project_name.ino" 2>/dev/null)" ]; then
  echo "Error: copy $(cygpath -w "$SCRIPT_PATH") -> into Sketch Directory!" >&2
  exit 1
fi

LOG_DIR="$APPDATA/Arduino IDE"
LOG_LINE=""

while IFS= read -r log_file; do
  if [ -f "$log_file" ]; then
    # Searches bottom-up for the most recent entry matching Sketch Name
    LOG_LINE=$(tac "$log_file" | grep -E -m 1 "20[0-9]{2}-[0-9]{2}-[0-9]{2}.*root.INFO.Received.port.after.upload.*$build_project_name")
    
    # If we found a match, exit the loop
    if [ -n "$LOG_LINE" ]; then
      echo "Using COM Port found in upload log: ${log_file##*/}"
      break
    fi
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -iname "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_log.log" | sort -r)

# Convert to Windows format for JSON path matching
WINDOWS_PATH=$(cygpath -w "$build_source_path")
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
  echo "Error: No build directory found for $build_project_name sketch." >&2
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
build_path=$(realpath "$NEWEST_TEMP_DIR")

# 6. Extract and format the user library folder and hardware folder paths
HARDWARE_WIN_PATH=$(grep -m 1 '"hardwareFolders"' "$build_path/build.options.json" | sed -n 's/.*"hardwareFolders":\s*"\([^,",]*\).*/\1/p')
USER_LIB_WIN_PATH=$(grep -m 1 '"otherLibrariesFolders"' "$build_path/build.options.json" | sed -n 's/.*"otherLibrariesFolders":\s*"\([^,",]*\).*/\1/p')

# Converts the Windows backslash paths to clean Git Bash Unix paths
runtime_platform_path=$(cygpath -u "$HARDWARE_WIN_PATH")
USER_LIB=$(cygpath -u "$USER_LIB_WIN_PATH")

# Extract {build.fqbn} from build.options.json
FQBN=$(grep '"fqbn"' "$build_path/build.options.json" | sed -n 's/.*"fqbn":\s*"\(.*\)",.*/\1/p')

# Extract {build.chip_variant} from build.options.json
board_id="$(echo "$FQBN" | sed -nE 's/^[^:]+:[^:]+:([^:,]+).*/\1/p')"
build_mcu="$(echo "$FQBN" | sed -nE 's/^([^:]+:[^:]+:[^:]+:).*MCU=([^,]+).*/\2/p')"
if [ -n "$build_mcu" ]; then
  build_chip_variant="$build_mcu"
else
  build_chip_variant="$board_id"
fi

# 7. Define output directory inside the build directory
DUMP_DIR="$build_path/${SCRIPT_PATH##*/}"
DUMP_DIR="${DUMP_DIR%.*}"
mkdir -p "$DUMP_DIR"

# 8. Find the newest version of esptool.exe and mklittlefs.exe
ESPTOOL_EXE=$(find "$runtime_platform_path/../../../tools/esptool_py" -iname "esptool.exe" 2>/dev/null | sort -V | tail -n 1)
MKLITTLEFS_EXE=$(find "$runtime_platform_path/../../../tools/mklittlefs" -iname "mklittlefs.exe" 2>/dev/null | sort -V | tail -n 1)
PIGZ_EXE="$DUMP_DIR/pigz.exe"
unzip -o "$USER_LIB/BLEOTA/tools/pigz.zip" -d "$DUMP_DIR" > /dev/null

if [ $? -ne 0 ] || [ -z "$ESPTOOL_EXE" ] || [ -z "$MKLITTLEFS_EXE" ]; then
  echo "Error: Required tools (esptool, mklittlefs or pigz) not found." >&2
  exit 1
fi

# 9. Extract LittleFS/SPIFFS Partition Offset and Size from partitions.csv
PARTITION_CSV="$build_path/partitions.csv"

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
RAW_LITTLEFS_BIN="$DUMP_DIR/littlefs_new.bin"
EXTRACT_DIR="$build_path/data"
mkdir -p "$EXTRACT_DIR"

echo -n "Dumping LittleFS partition... press any key..."
read -s -t 30 -n 1 KEY_PRESSED
SKIP_DUMP=false
if [[ "$KEY_PRESSED" == $'\e' ]]; then
  SKIP_DUMP=true
  echo " aborted. Using local keys."
  KEY_SEARCH_DIR="$build_source_path/data"
else
  KEY_SEARCH_DIR="$EXTRACT_DIR"
fi

if [ "$SKIP_DUMP" = false ]; then
  if [ -z "$LOG_LINE" ]; then
    echo "Error: COM Port not found. Restart Arduino IDE and Upload Sketch first." >&2
    exit 1
  fi

  # Extracts the COM port directly from the "arduino+serial://..." block
  COM_PORT=$(echo "$LOG_LINE" | sed -n 's/.*arduino+serial:\/\/\([^,]*\),.*/\1/p')

  "$ESPTOOL_EXE" --chip "$build_chip_variant" --port "$COM_PORT" --baud 921600 read-flash "$LITTLEFS_OFFSET" "$LITTLEFS_SIZE" "$IMAGE_BIN"

  if [ $? -ne 0 ]; then
    echo "Error: Close Serial Monitor on $COM_PORT and try again." >&2
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
fi

# 12. Compare OpenSSL versions and store the newest path/command
PYTHON_OPENSSL=$(python -c "import ssl; print(ssl.OPENSSL_VERSION)" | sed -n 's/.*OpenSSL \([0-9.]*\).*/\1/p')
SYSTEM_OPENSSL=$(openssl --version 2>/dev/null | sed -n 's/.*OpenSSL \([0-9.]*\).*/\1/p')

# Use sort -V to find the highest version string
NEWEST_VERSION=$(printf '%s\n%s\n' "$PYTHON_OPENSSL" "$SYSTEM_OPENSSL" | sort -V | tail -n 1)

if [ "$NEWEST_VERSION" == "$SYSTEM_OPENSSL" ]; then
  openssl="openssl"
else
  if ! python -c "import cryptography" >/dev/null 2>&1; then
    python -m pip install --user cryptography >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      echo "Please update OpenSSL or run: pip install cryptography" >&2
      exit 1
    fi
  fi
  openssl="openssl_python_wrapper"
fi

# 13. Locate public and private keys inside the determined directory checking headers
PRIVATE_KEY_FILE=$(grep -l -m 1 -r "^-----BEGIN RSA PRIVATE KEY-----" "$KEY_SEARCH_DIR" 2>/dev/null | head -n 1)
PUBLIC_KEY_FILE=$(grep -l -m 1 -r "^-----BEGIN PUBLIC KEY-----" "$KEY_SEARCH_DIR" 2>/dev/null | head -n 1)
if [ -z "$PRIVATE_KEY_FILE" ] || [ -z "$PUBLIC_KEY_FILE" ]; then
  if [ "$SKIP_DUMP" = true ]; then
    PRIVATE_KEY_FILE=$(grep -l -m 1 -r "^-----BEGIN RSA PRIVATE KEY-----" "$EXTRACT_DIR" 2>/dev/null | head -n 1)
    PUBLIC_KEY_FILE=$(grep -l -m 1 -r "^-----BEGIN PUBLIC KEY-----" "$EXTRACT_DIR" 2>/dev/null | head -n 1)
  fi
  # Verify both keys were found
  if [ -z "$PRIVATE_KEY_FILE" ] || [ -z "$PUBLIC_KEY_FILE" ]; then
    echo "Error: Could not find both private and public PEM keys in $(cygpath -w "$KEY_SEARCH_DIR")" >&2
    exit 1
  fi
fi

# Prepare Sketch data directory with keys
echo "Signing binary images..."
cp "$PRIVATE_KEY_FILE" "$DUMP_DIR"
cp "$PUBLIC_KEY_FILE" "$DUMP_DIR"
rm -r "$EXTRACT_DIR"
cp -a "$build_source_path/data" "$build_path" 2>/dev/null || mkdir -p "$EXTRACT_DIR"
cp "$DUMP_DIR/${PRIVATE_KEY_FILE##*/}" "$EXTRACT_DIR"
cp "$DUMP_DIR/${PUBLIC_KEY_FILE##*/}" "$EXTRACT_DIR"

# Processing Firmware (App) and Filesystem (LittleFS) loop
INPUT_APP_BIN="$build_path/${build_project_name}.ino.bin"
FINAL_APP_OTA="$DUMP_DIR/${build_project_name}-ota_${build_chip_variant}-signed.bin"
FINAL_LFS_OTA="$DUMP_DIR/${build_project_name}-littlefs_${build_chip_variant}-signed.bin"

# Arrays to map the inputs to their targeted OTA outputs
TARGET_INPUTS=("$INPUT_APP_BIN" "$RAW_LITTLEFS_BIN")
TARGET_OUTPUTS=("$FINAL_APP_OTA" "$FINAL_LFS_OTA")

# 14. Build clean LittleFS binary image directly from data directory
"$MKLITTLEFS_EXE" -c "$EXTRACT_DIR" -p 256 -b 4096 -s "$LITTLEFS_SIZE" "$RAW_LITTLEFS_BIN"

if [ $? -ne 0 ] || [ ! -s "$RAW_LITTLEFS_BIN" ]; then
  echo "Error: Failed to build LittleFS binary image, using Dump." >&2
  TARGET_INPUTS=("$INPUT_APP_BIN" "$IMAGE_BIN")
fi

# 15. Compress images: loop over App + LittleFS binaries
for ((i = 0 ; i < 2 ; i++)); do
  CURRENT_IN="${TARGET_INPUTS[$i]}"
  CURRENT_OUT="${TARGET_OUTPUTS[$i]}"

  if [ ! -f "$CURRENT_IN" ]; then
    echo "Warning: file '${CURRENT_IN##*/}' not found. Skipping."
    continue
  fi
  
  TMP_ZLIB="$DUMP_DIR/${CURRENT_IN##*/}.z"
  TMP_SIGN="$DUMP_DIR/signature.sign"
  
  # Compress with pigz (-9 = max, -k = keep, -z = zlib format, -c = stdout)
  "$PIGZ_EXE" -9kzc "$CURRENT_IN" > "$TMP_ZLIB" 2>/dev/null
  
  # Check if pigz successfully created a Zlib file (Magic byte 0x78)
  if [ "$(od -An -tx1 -N1 "$TMP_ZLIB" | tr -d '[:space:]')" == "78" ]; then
    $openssl dgst -sign "$PRIVATE_KEY_FILE" -keyform PEM -sha256 -out "$TMP_SIGN" -binary "$TMP_ZLIB"
    if [ $? -eq 0 ]; then
      cat "$TMP_ZLIB" "$TMP_SIGN" > "$CURRENT_OUT"
      echo "-> ${CURRENT_OUT##*/}"
    else
      echo "Error: OpenSSL signing failed: ${CURRENT_OUT##*/}" >&2
    fi
  else
    # 16. Fallback if compression failed
    $openssl dgst -sign "$PRIVATE_KEY_FILE" -keyform PEM -sha256 -out "$TMP_SIGN" -binary "$CURRENT_IN"
    if [ $? -eq 0 ]; then
      cat "$CURRENT_IN" "$TMP_SIGN" > "$CURRENT_OUT"
      echo "-> ${CURRENT_OUT##*/}"
    else
      echo "Error: OpenSSL signing failed: ${CURRENT_OUT##*/}" >&2
    fi
  fi
  
  # Clean up loop assets
  rm -f "$TMP_ZLIB" "$TMP_SIGN"
done

# Clean up littlefs build artifact
rm -f "$RAW_LITTLEFS_BIN"

# 17. Open Windows Explorer in the dump directory
explorer.exe "$(cygpath -w "$DUMP_DIR")"
