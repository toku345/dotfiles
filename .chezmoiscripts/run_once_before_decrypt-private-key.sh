#!/bin/sh

if [ ! -f "${HOME}/key.txt" ]; then
    age --decrypt --output "${HOME}/key.txt" "${CHEZMOI_SOURCE_DIR}/key.txt.age" || {
        echo "Error: Failed to decrypt key.txt.age. Ensure age is installed and the file exists." >&2
        exit 1
    }
    chmod 600 "${HOME}/key.txt"
fi
