# MacSwitcher generic interactive-zsh editor adapter. Loaded only by an
# explicitly installed, guarded source line. No command execution or key replay.
[[ -o interactive && -z ${_ms_bridge_loaded-} ]] || return 0
typeset -g _ms_bridge_loaded=1
typeset -g _ms_bridge_socket="${_ms_bridge_socket:-$HOME/Library/Caches/MacSwitcher/terminal-bridge/editor.sock}"
typeset -gi _ms_bridge_fd=-1 _ms_line_generation=0
typeset -g _ms_session_uuid="$(/usr/bin/uuidgen)"
typeset -g _ms_last_request_id='' _ms_last_response=''
typeset -g _ms_prepared_nonce='' _ms_prepared_buffer=''
typeset -gi _ms_prepared_cursor=0 _ms_prepared_mark=0 _ms_prepared_region=0
typeset -g _ms_wire_pending=''

_ms_b64_encode() {
  emulate -L zsh
  REPLY="$(print -rn -- "$1" | /usr/bin/base64 -b 0)" || return 1
  [[ ${#REPLY} -le 87384 ]]
}

_ms_b64_decode() {
  emulate -L zsh
  [[ ${#1} -le 87384 && $1 != *[^A-Za-z0-9+/=]* ]] || return 1
  local decoded
  decoded="$(print -rn -- "$1" | /usr/bin/base64 -D 2>/dev/null && print -rn -- '.')" || return 1
  REPLY="${decoded%.}"
  [[ ${#REPLY} -le 65536 && $REPLY != *$'\0'* ]]
}

_ms_bridge_nonce() { emulate -L zsh; REPLY="${_ms_session_uuid}.${_ms_line_generation}" }

_ms_bridge_disconnect() {
  emulate -L zsh
  (( _ms_bridge_fd >= 0 )) || return 0
  zle -F $_ms_bridge_fd 2>/dev/null || true
  exec {_ms_bridge_fd}>&-
  _ms_bridge_fd=-1
  _ms_wire_pending=''
  _ms_prepared_nonce=''
  _ms_prepared_buffer=''
  _ms_last_request_id=''
  _ms_last_response=''
}

_ms_bridge_connect() {
  emulate -L zsh
  (( _ms_bridge_fd < 0 )) || return 0
  local effectiveLocale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  [[ -o multibyte && ${(L)effectiveLocale} == *utf-8* ]] || return 1
  [[ -S $_ms_bridge_socket && -n $TTY ]] || return 1
  zmodload zsh/net/socket || return 1
  zsocket "$_ms_bridge_socket" || return 1
  _ms_bridge_fd=$REPLY
  local tty64
  _ms_b64_encode "$TTY" || { _ms_bridge_disconnect; return 1; }
  tty64=$REPLY
  print -r -- "H 1 $tty64" >&$_ms_bridge_fd || { _ms_bridge_disconnect; return 1; }
  zle -F -w $_ms_bridge_fd _ms_bridge_receive || { _ms_bridge_disconnect; return 1; }
}

_ms_bridge_line_init() {
  emulate -L zsh
  (( ++_ms_line_generation ))
  _ms_last_request_id=''
  _ms_last_response=''
  _ms_prepared_nonce=''
  _ms_prepared_buffer=''
}

_ms_bridge_line_finish() { emulate -L zsh; _ms_bridge_disconnect }

_ms_bridge_reply() {
  emulate -L zsh
  local id="$1" editStatus="$2" encoded
  _ms_b64_encode "$BUFFER" || { _ms_bridge_disconnect; return 1; }
  encoded=$REPLY
  _ms_bridge_nonce
  _ms_last_request_id=$id
  _ms_last_response="R $id $editStatus $REPLY $CURSOR $MARK $REGION_ACTIVE $encoded"
  print -r -- "$_ms_last_response" >&$_ms_bridge_fd
}

_ms_bridge_receive() {
  emulate -L zsh
  local fd=$1 chunk readStatus
  zmodload zsh/system || { _ms_bridge_disconnect; return 1; }
  sysread -i $fd -s 4096 -t 0 chunk
  readStatus=$?
  if (( readStatus == 5 || readStatus == 2 )); then
    _ms_bridge_disconnect
    return 1
  fi
  (( readStatus == 0 )) || return 0
  _ms_wire_pending+=$chunk
  if (( ${#_ms_wire_pending} > 175280 )); then
    _ms_bridge_disconnect
    return 1
  fi
  local line
  while [[ $_ms_wire_pending == *$'\n'* ]]; do
    line=${_ms_wire_pending%%$'\n'*}
    _ms_wire_pending=${_ms_wire_pending#*$'\n'}
    _ms_bridge_handle_line "$line" "$fd"
  done
}

_ms_bridge_handle_line() {
  emulate -L zsh
  local line=$1 fd=$2
  local -a fields
  fields=( ${(s: :)line} )
  [[ ${#fields} -ge 2 ]] || return 0
  local op=$fields[1] id=$fields[2]
  if [[ $op == P && ${#fields} -eq 2 ]]; then
    _ms_bridge_nonce
    _ms_prepared_nonce=$REPLY
    _ms_prepared_buffer=$BUFFER
    _ms_prepared_cursor=$CURSOR
    _ms_prepared_mark=$MARK
    _ms_prepared_region=$REGION_ACTIVE
    print -r -- "A $id $_ms_prepared_nonce" >&$fd
    return 0
  fi
  if [[ $op == Q && ( ${#fields} -eq 2 || ${#fields} -eq 3 ) ]]; then
    if (( ${#fields} == 3 )) && [[ $fields[3] != $_ms_prepared_nonce
          || $BUFFER != "$_ms_prepared_buffer" || $CURSOR != $_ms_prepared_cursor
          || $MARK != $_ms_prepared_mark || $REGION_ACTIVE != $_ms_prepared_region ]]; then
      print -r -- "F $id" >&$fd
      return 0
    fi
    local encoded
    _ms_b64_encode "$BUFFER" || { _ms_bridge_disconnect; return 1; }
    encoded=$REPLY
    _ms_bridge_nonce
    print -r -- "S $id $REPLY $CURSOR $MARK $REGION_ACTIVE $encoded" >&$fd
    return 0
  fi
  [[ $op == E && ${#fields} -eq 9 ]] || return 0
  if [[ -n $id && $id == $_ms_last_request_id ]]; then
    print -r -- "$_ms_last_response" >&$fd
    return 0
  fi
  local nonce=$fields[3] expectedCursor=$fields[4] expectedMark=$fields[5]
  local expectedRegion=$fields[6] expected64=$fields[7] proposed64=$fields[8]
  local newCursor=$fields[9] expected proposed
  if ! _ms_b64_decode "$expected64"; then _ms_bridge_reply "$id" refused; return 0; fi
  expected=$REPLY
  if ! _ms_b64_decode "$proposed64"; then _ms_bridge_reply "$id" refused; return 0; fi
  proposed=$REPLY
  _ms_bridge_nonce
  if [[ $nonce == $REPLY && $expected == "$BUFFER" && $proposed != "$BUFFER"
        && $expectedCursor == <-> && $expectedCursor -eq $CURSOR
        && $expectedMark == <-> && $expectedMark -eq $MARK
        && $expectedRegion == <-> && $expectedRegion -eq $REGION_ACTIVE
        && $newCursor == <-> && $newCursor -le ${#proposed} ]]; then
    BUFFER=$proposed
    CURSOR=$newCursor
    REGION_ACTIVE=0
    _ms_bridge_reply "$id" applied
    zle -R
  else
    _ms_bridge_reply "$id" refused
  fi
}

zle -N _ms_bridge_receive
autoload -Uz add-zle-hook-widget add-zsh-hook
add-zle-hook-widget line-init _ms_bridge_line_init
add-zle-hook-widget line-finish _ms_bridge_line_finish
add-zsh-hook precmd _ms_bridge_connect
add-zsh-hook preexec _ms_bridge_disconnect
_ms_bridge_connect
