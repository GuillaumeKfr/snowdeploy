#! /bin/bash

declare -A MSG_HEADER

MSG_HEADER["INFO"]=""
MSG_HEADER["SUCCESS"]="✔ "
MSG_HEADER["WARN"]="⚠ Warning: "
MSG_HEADER["ERROR"]="❌ Error: "

readonly MSG_HEADER

# 1: Error level (SUCCESS|INFO|WARN|ERROR)
# 2: Message
__log() {
    local level message result

    level=$1
    message=$2

    result=${MSG_HEADER[$level]}$message

    if [[ ${level} == "ERROR" ]]; then
        echo "$result" >&2
    else
        echo "$result"
    fi
}

# 1: Message
logging::success() {
    __log "SUCCESS" "$1"
    exit 0
}

# 1: Message
logging::info() {
    __log "INFO" "$1"
}

# 1: Message
logging::warn() {
    __log "WARN" "$1"
}

# 1: Message
logging::error() {
    __log "ERROR" "$1"
}

# 1: Message
# 2: Exit code (optional - defaults to 1)
logging::die() {
    logging::error "$1"
    exit "${2:-1}"
}
