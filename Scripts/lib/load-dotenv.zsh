#!/bin/zsh

# Load only explicitly named keys without evaluating the .env file as shell code.
macscope_load_dotenv() {
  if (( $# < 2 )); then
    echo "Usage: macscope_load_dotenv /path/to/.env KEY [KEY ...]" >&2
    return 64
  fi

  local env_path="$1"
  shift
  if [[ ! -f "$env_path" ]]; then
    echo "Environment file not found: $env_path" >&2
    return 66
  fi

  setopt local_options extended_glob
  local key line value
  for key in "$@"; do
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$env_path" | tail -n 1 || true)"
    [[ -n "$line" ]] || continue
    value="${line#*=}"
    value="${value##[[:space:]]#}"
    value="${value%%[[:space:]]#}"
    if [[ ( "$value" == \"*\" && "$value" == *\" ) || ( "$value" == \'*\' && "$value" == *\' ) ]]; then
      value="${value:1:-1}"
    fi
    export "${key}=${value}"
  done
}
