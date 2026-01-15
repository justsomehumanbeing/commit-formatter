#!/usr/bin/env bash
#
# commit-fmt v1 — interactive Git commit message formatter
#
# Intended usage: Git hook `prepare-commit-msg`.
#
# Repo layout (project-local config):
#   <repo>/.repo-config/commit-fmt/
#     actions.list
#     scopes.list
#     sections.list
#     settings.conf
#
# Hook example:
#   .git/hooks/prepare-commit-msg
#     #!/usr/bin/env bash
#     exec "$PWD/.repo-config/commit-fmt/commit-fmt.sh" "$@"
#
# Dependencies (kept minimal):
#   - bash
#   - rofi
#   - git
#   - mktemp, sed, awk, wc, cat
#   - $EDITOR (falls back to vi)
#
# Editor behavior:
#   - If a TTY is available, launches the configured editor normally.
#   - If no TTY is available, tries (in order) a GUI editor (settings
#     `editor-command`, $GIT_EDITOR, $VISUAL, $EDITOR), then a terminal
#     emulator (${TERMINAL:-xterm} -e <editor>), and finally falls back to
#     rofi -dmenu for single-line subject/section input.
#

set -euo pipefail

MSG_FILE="${1:-}"
COMMIT_SOURCE="${2:-}"
SHA1="${3:-}"

if [[ -z "${MSG_FILE}" ]]; then
  echo "commit-fmt: missing commit message file argument" >&2
  exit 2
fi

# Safety: If commit message is provided non-interactively (e.g. `git commit -m`),
# don't override it.
# (You can remove this block later if you *want* to override -m messages.)
if [[ "${COMMIT_SOURCE}" == "message" ]]; then
  exit 0
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "commit-fmt: required command not found: $1" >&2
    exit 2
  }
}

require_cmd git
require_cmd rofi
require_cmd mktemp

EDITOR_CMD=""

# Locate repo root (for project-local config)
REPO_ROOT=""
if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  echo "commit-fmt: not inside a git repository" >&2
  exit 2
fi

CONFIG_DIR="${REPO_ROOT}/.repo-config/commit-fmt"
USER_FALLBACK_DIR="${HOME}/.repo-config/commit-fmt"

if [[ ! -d "${CONFIG_DIR}" ]]; then
  # Fallback to user config, if present.
  if [[ -d "${USER_FALLBACK_DIR}" ]]; then
    CONFIG_DIR="${USER_FALLBACK_DIR}"
  fi
fi

ACTIONS_FILE="${CONFIG_DIR}/actions.list"
SCOPES_FILE="${CONFIG_DIR}/scopes.list"
SECTIONS_FILE="${CONFIG_DIR}/sections.list"
SETTINGS_FILE="${CONFIG_DIR}/settings.conf"

if [[ ! -f "${ACTIONS_FILE}" || ! -f "${SCOPES_FILE}" || ! -f "${SECTIONS_FILE}" ]]; then
  echo "commit-fmt: missing config files in ${CONFIG_DIR}" >&2
  echo "Expected: actions.list, scopes.list, sections.list" >&2
  exit 2
fi

# Defaults
ENFORCEMENT="warn"         # ignore|warn|strict
ALLOW_EMPTY="no"           # yes|no
ALLOW_FREETEXT_ROFI="yes"  # yes|no
SCOPE_NEEDED="no"          # yes|no
HEADER_LIMIT="50"          # conventional default
GIT_INFO_RAW="status,diff" # comma/space list, or bracket list [ status, diff ]

trim() {
  # trims leading/trailing whitespace
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

# Read settings.conf in a very simple way:
#   key = value
# ignores lines starting with # and blank lines
load_settings() {
  [[ -f "${SETTINGS_FILE}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # strip comments (only if line starts with #; keep inline # as value content)
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue

    # split at first '='
    if [[ "${line}" != *"="* ]]; then
      continue
    fi

    local key="${line%%=*}"
    local val="${line#*=}"
    key="$(trim "$key")"
    val="$(trim "$val")"

    case "${key}" in
      enforcement) ENFORCEMENT="${val}" ;;
      allow-empty) ALLOW_EMPTY="${val}" ;;
      allow-freetext-rofi) ALLOW_FREETEXT_ROFI="${val}" ;;
      scope-needed) SCOPE_NEEDED="${val}" ;;
      header-limit) HEADER_LIMIT="${val}" ;;
      git_info|list_of_git_info) GIT_INFO_RAW="${val}" ;;
      editor-command) EDITOR_CMD="${val}" ;;
      *) : ;;
    esac
  done < "${SETTINGS_FILE}"
}

load_settings

pick_editor_cmd() {
  if [[ -n "${EDITOR_CMD}" ]]; then
    printf '%s' "${EDITOR_CMD}"
    return 0
  fi
  if [[ -n "${GIT_EDITOR:-}" ]]; then
    printf '%s' "${GIT_EDITOR}"
    return 0
  fi
  if [[ -n "${VISUAL:-}" ]]; then
    printf '%s' "${VISUAL}"
    return 0
  fi
  if [[ -n "${EDITOR:-}" ]]; then
    printf '%s' "${EDITOR}"
    return 0
  fi
  printf '%s' "vi"
}

has_tty() {
  [[ -t 0 && -t 1 ]]
}

is_gui_editor() {
  local cmd="$1"
  local bin="${cmd%% *}"
  bin="${bin##*/}"
  case "${bin}" in
    code|code-insiders|codium|gvim|vim-gtk|vim-gnome|gedit|kate|subl|subl3|mate|emacsclient)
      return 0
      ;;
  esac
  return 1
}

edit_message_file() {
  local editor_cmd
  local terminal_bin
  editor_cmd="$(pick_editor_cmd)"

  if has_tty; then
    ${editor_cmd} "${MSG_FILE}"
  else
    if is_gui_editor "${editor_cmd}"; then
      ${editor_cmd} "${MSG_FILE}"
    else
      terminal_bin="${TERMINAL:-xterm}"
      if command -v "${terminal_bin}" >/dev/null 2>&1; then
        "${terminal_bin}" -e bash -c "${editor_cmd} \"${MSG_FILE}\""
      else
        ${editor_cmd} "${MSG_FILE}"
      fi
    fi
  fi
}

if awk '$0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { found=1; exit } END { exit !found }' "${MSG_FILE}"; then
  edit_message_file
  exit 0
fi

rofi_single_line_capture() {
  local initial_content="$1"
  local first_line prompt reply
  first_line="${initial_content%%$'\n'*}"
  if [[ "${first_line}" == \#* ]]; then
    prompt="$(trim "${first_line#\#}")"
  else
    prompt="$(trim "${first_line}")"
  fi
  prompt="${prompt:-commit message}"
  reply="$(rofi -dmenu -p "${prompt}")" || return 1
  printf '%s%s\n' "${initial_content}" "${reply}"
}

# Normalize a yes/no value
is_yes() {
  [[ "${1,,}" == "yes" || "${1,,}" == "true" || "${1,,}" == "1" ]]
}

# Read list files, ignoring empty lines and comment lines.
read_list_file() {
  local file="$1"
  # Print lines as-is except: ignore blank lines and lines starting with '#'
  # We keep spaces inside entries.
  sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$file"
}

# Rofi prompt with optional freetext enforcement.
# Args: prompt, candidates_text (newline separated), allow_none_label (optional)
rofi_pick() {
  local prompt="$1"
  local candidates="$2"
  local chosen=""

  while true; do
    chosen="$(printf '%s\n' "${candidates}" | rofi -dmenu -p "${prompt}" )" || {
      # user cancelled
      return 1
    }

    chosen="$(trim "$chosen")"

    if [[ -z "${chosen}" ]]; then
      if is_yes "${ALLOW_EMPTY}"; then
        printf '%s' "${chosen}"
        return 0
      else
        rofi -e "Empty input is not allowed." || true
        continue
      fi
    fi

    if is_yes "${ALLOW_FREETEXT_ROFI}"; then
      printf '%s' "${chosen}"
      return 0
    else
      # enforce that chosen is exactly one of the candidates
      if printf '%s\n' "${candidates}" | grep -Fxq -- "${chosen}"; then
        printf '%s' "${chosen}"
        return 0
      else
        rofi -e "Please choose one of the listed entries (free text disabled)." || true
        continue
      fi
    fi
  done
}

# Open editor on a temp file, then return its contents.
# The file is created with initial content.
editor_capture() {
  local initial_content="$1"
  local tmp
  local editor_cmd
  local terminal_bin
  tmp="$(mktemp -t commit-fmt.XXXXXX)"

  # Ensure file has initial content
  printf '%s' "${initial_content}" > "${tmp}"

  editor_cmd="$(pick_editor_cmd)"

  if has_tty; then
    ${editor_cmd} "${tmp}"
  else
    if is_gui_editor "${editor_cmd}"; then
      ${editor_cmd} "${tmp}"
    else
      terminal_bin="${TERMINAL:-xterm}"
      if command -v "${terminal_bin}" >/dev/null 2>&1; then
        "${terminal_bin}" -e bash -c "${editor_cmd} \"${tmp}\""
      else
        rofi_single_line_capture "${initial_content}" > "${tmp}"
      fi
    fi
  fi

  cat "${tmp}"
  rm -f "${tmp}"
}

# Subject length check
subject_check_or_loop() {
  local intro="$1"
  local short_msg="$2"
  local limit="$3"

  local subject
  if [[ -z "${short_msg}" ]]; then
    subject="${intro}"
  else
    subject="${intro} ${short_msg}"
  fi

  local len
  len="$(printf '%s' "${subject}" | wc -m | awk '{print $1}')"

  if (( len <= limit )); then
    printf '%s\n' "${short_msg}"
    return 0
  fi

  local over=$(( len - limit ))

  case "${ENFORCEMENT}" in
    ignore)
      printf '%s\n' "${short_msg}"
      return 0
      ;;
    warn)
      rofi -e "Subject is ${len} chars (limit ${limit}), over by ${over}. Continuing." || true
      printf '%s\n' "${short_msg}"
      return 0
      ;;
    strict)
      rofi -e "Subject is ${len} chars (limit ${limit}), over by ${over}. Please shorten." || true
      return 1
      ;;
    *)
      # Unknown -> warn behavior
      rofi -e "Unknown enforcement='${ENFORCEMENT}'. Treating as warn." || true
      printf '%s\n' "${short_msg}"
      return 0
      ;;
  esac
}

# Convert arbitrary command output into git-comment lines.
comment_prefix_lines() {
  # Prefix each line with '# '
  sed 's/^/# /'
}

# Parse git_info list.
# Accepts formats like:
#   status,diff
#   status diff
#   [ status, diff ]
#   [status, diff --cached]
# The result is a list of "command strings".
# v1 simplification:
#   - Split on commas when inside [ ... ] or plain.
#   - Also accept whitespace-separated tokens if no commas.
parse_git_info() {
  local raw="$1"
  raw="$(trim "$raw")"

  # Strip surrounding brackets if present
  if [[ "${raw}" =~ ^\[.*\]$ ]]; then
    raw="${raw#[}"
    raw="${raw%]}"
    raw="$(trim "$raw")"
  fi

  # If commas are present, split on commas; otherwise split on whitespace.
  if [[ "${raw}" == *","* ]]; then
    # Replace commas with newlines
    printf '%s' "${raw}" | tr ',' '\n' | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e '/^$/d'
  else
    # Split on whitespace
    printf '%s\n' "${raw}" | awk '{for (i=1;i<=NF;i++) print $i}'
  fi
}

# Backup existing commit message file so we can restore it on abort.
ORIG_BAK="$(mktemp -t commit-fmt.orig.XXXXXX)"
cp -f -- "${MSG_FILE}" "${ORIG_BAK}" 2>/dev/null || true

abort_commit() {
  # Restore original message file
  if [[ -f "${ORIG_BAK}" ]]; then
    cp -f -- "${ORIG_BAK}" "${MSG_FILE}" 2>/dev/null || true
    rm -f -- "${ORIG_BAK}" 2>/dev/null || true
  fi
  exit 1
}

# Read list contents
ACTIONS_LIST="$(read_list_file "${ACTIONS_FILE}")"
SCOPES_LIST="$(read_list_file "${SCOPES_FILE}")"
SECTIONS_LIST="$(read_list_file "${SECTIONS_FILE}")"

# 1) action
ACTION="$(rofi_pick "action" "${ACTIONS_LIST}")" || abort_commit

# 2) scope (with NONE)
SCOPES_WITH_NONE=$'NONE\n'
SCOPES_WITH_NONE+="${SCOPES_LIST}"

SCOPE=""
while true; do
  SCOPE="$(rofi_pick "scope" "${SCOPES_WITH_NONE}")" || abort_commit

  if is_yes "${SCOPE_NEEDED}"; then
    if [[ -z "${SCOPE}" || "${SCOPE}" == "NONE" ]]; then
      rofi -e "Scope is required (scope-needed=yes)." || true
      continue
    fi
  fi
  break
done

# 3) intro
INTRO=""
if [[ "${SCOPE}" == "NONE" || -z "${SCOPE}" ]]; then
  INTRO="${ACTION}:"
else
  INTRO="${ACTION}(${SCOPE}):"
fi

# 4) short message via editor, with optional strict loop
SHORT_MSG=""
while true; do
  # Provide context in comments, capture first non-comment line.
  # (Users can ignore comments; we only take the first non-comment line.)
  initial=$'# Commit subject (one line).\n'
  initial+="# Prefix: ${INTRO}\n"
  initial+="# Limit: ${HEADER_LIMIT} characters (prefix + subject).\n"
  initial+=$'# Write the short message on the next line.\n\n'

  edited="$(editor_capture "${initial}")"

  # Extract the first non-comment, non-empty line as short message
  SHORT_MSG="$(printf '%s\n' "${edited}" | sed -e 's/\r$//' | awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {print; exit}
  ')"
  SHORT_MSG="$(trim "${SHORT_MSG}")"

  if [[ -z "${SHORT_MSG}" ]] && ! is_yes "${ALLOW_EMPTY}"; then
    rofi -e "Short message cannot be empty (allow-empty=no)." || true
    continue
  fi

  if subject_check_or_loop "${INTRO}" "${SHORT_MSG}" "${HEADER_LIMIT}"; then
    break
  else
    # strict mode asked for a re-edit
    continue
  fi
done

# 5) sections
# We'll keep a simple in-memory representation: two arrays (names, contents)
SECTION_NAMES=()
SECTION_CONTENTS=()

# Iterate sections line-by-line safely
while IFS= read -r sec || [[ -n "${sec}" ]]; do
  sec="$(trim "$sec")"
  [[ -z "${sec}" ]] && continue

  # First line is a comment header (ignored by git), as requested.
  initial=$"#${sec}\n"
  initial+="# Write section content below.\n"
  initial+="# Lines starting with '#' are ignored by git.\n\n"

  edited="$(editor_capture "${initial}")"

  # Drop only the first line (the #SectionName prompt line).
  content="$(printf '%s' "${edited}" | sed '1d')"

  # Trim leading/trailing blank lines (keep internal newlines)
  content="$(printf '%s\n' "${content}" | sed -e ':a' -e '/^\n*$/{$d;N;ba}' -e '1{/^\n*$/d}')"

  # If empty, skip the section in final message.
  if [[ -n "$(trim "${content}")" ]]; then
    SECTION_NAMES+=("${sec}")
    SECTION_CONTENTS+=("${content}")
  fi

done <<< "${SECTIONS_LIST}"

# Build subject line
SUBJECT=""
if [[ -z "${SHORT_MSG}" ]]; then
  SUBJECT="${INTRO}"
else
  SUBJECT="${INTRO} ${SHORT_MSG}"
fi

# 6) compose final message
FINAL_TMP="$(mktemp -t commit-fmt.final.XXXXXX)"

{
  printf '%s\n' "${SUBJECT}"
  printf '\n'

  # Structured sections
  for i in "${!SECTION_NAMES[@]}"; do
    printf '%s\n' "${SECTION_NAMES[$i]}"
    printf '%s\n' "${SECTION_CONTENTS[$i]}"
    printf '\n'
  done

  # Comment tail (git ignores these lines)
  printf '# ----------------------------------------------------------------\n'
  printf '# Please enter the commit message for your changes.\n'
  printf '# Lines starting with "#" will be ignored, and an empty message aborts the commit.\n'
  printf '#\n'
  printf '# Repo: %s\n' "${REPO_ROOT}" | comment_prefix_lines
  printf '# Source: %s\n' "${COMMIT_SOURCE}" | comment_prefix_lines
  [[ -n "${SHA1}" ]] && printf '# SHA1: %s\n' "${SHA1}" | comment_prefix_lines
  printf '#\n'

  # Standard-ish changed-files info
  printf '%s\n' "# On branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')" | comment_prefix_lines
  printf '%s\n' "#" | comment_prefix_lines

  # A brief status summary
  {
    printf '%s\n' "--- git status (short) ---"
    git status --short --branch 2>/dev/null || true
  } | comment_prefix_lines

  printf '#\n' | comment_prefix_lines

  # Additional info blocks from config
  while IFS= read -r cmd || [[ -n "${cmd}" ]]; do
    cmd="$(trim "$cmd")"
    [[ -z "${cmd}" ]] && continue

    # Map common short names to safe defaults (v1 convenience)
    case "${cmd}" in
      status)
        header="git status --short --branch"
        body_cmd=(git status --short --branch)
        ;;
      diff)
        header="git diff --cached"
        body_cmd=(git diff --cached)
        ;;
      diff-all)
        header="git diff"
        body_cmd=(git diff)
        ;;
      diffstat)
        header="git diff --cached --stat"
        body_cmd=(git diff --cached --stat)
        ;;
      *)
        # Treat as a raw `git <cmd...>` (split on whitespace)
        # shellcheck disable=SC2206
        header="git ${cmd}"
        # shellcheck disable=SC2206
        body_cmd=(git ${cmd})
        ;;
    esac

    {
      printf '%s\n' "--- ${header} ---"
      "${body_cmd[@]}" 2>/dev/null || true
      printf '%s\n' "" 
    } | comment_prefix_lines

  done < <(parse_git_info "${GIT_INFO_RAW}")

} > "${FINAL_TMP}"

# 7) write message file atomically
mv -f -- "${FINAL_TMP}" "${MSG_FILE}"

# cleanup backup
rm -f -- "${ORIG_BAK}" 2>/dev/null || true

exit 0
