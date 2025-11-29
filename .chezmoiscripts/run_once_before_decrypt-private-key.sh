#!/bin/sh

if [ ! -f "${HOME}/key.txt" ]; then
    age --decrypt --output "${HOME}/key.txt" "${CHEZMOI_SOURCE_DIR}/key.txt.age"
    chmod 600 "${HOME}/key.txt"
fi
