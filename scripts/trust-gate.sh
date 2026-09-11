#!/usr/bin/env sh
# gyeol trust gate — may the model on the other end of this session receive memory?
#
# Free and free-tier model APIs generally reserve the right to train on what
# they are sent. Memory is the one thing gyeol holds that is not recoverable
# once it has left: a repository can be cloned again, an identity cannot be
# un-sent. So the memory tree is gated on the provider, and the gate is what
# every hook script asks before it emits, reads, or demands anything.
#
# Where the answer comes from, and why it is the environment rather than the
# hook input: no harness hook carries the model. Measured on Claude Code
# 2.1.263 — the SessionStart payload is {session_id, transcript_path, cwd,
# hook_event_name, source} and UserPromptSubmit adds {prompt_id,
# permission_mode, prompt}; neither names a model, and the hook process
# environment carries no model or provider variable either. What *is* visible
# is the endpoint the harness was started against, and in Claude Code that is
# fixed for the life of the process, so reading it once per hook is sound.
#
# pi is the opposite case: its model changes mid-session, so its extension
# decides per turn and passes the answer down as GYEOL_TRUST.
#
# Resolution order:
#   1. GYEOL_TRUST, when set, wins. It is how pi (and any wrapper) speaks.
#   2. A first-party cloud relay (Bedrock / Vertex) is the user's own account.
#   3. An endpoint override is denied unless its host is allowlisted. Loopback
#      is NOT local here: in Claude Code a 127.0.0.1 endpoint is a router
#      forwarding to something unnamed, which is exactly the case to deny.
#   4. Otherwise: the harness's own first-party API. Allowed.
#
# Usage:
#   . "$GYEOL_HOME/scripts/trust-gate.sh"   # then call gyeol_trust_denied
#   sh "$GYEOL_HOME/scripts/trust-gate.sh"  # prints the verdict; exit 0 = allowed
#
# Extend the allowlist with GYEOL_TRUSTED_HOSTS="host1 host2" for a private
# gateway that is contractually not training on the traffic.

GYEOL_TRUST_STATE=""
GYEOL_TRUST_REASON=""

gyeol_trust_host_allowed() {  # gyeol_trust_host_allowed <url>
  host=$(printf '%s' "$1" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|/.*$||' -e 's|^.*@||' -e 's|:[0-9]*$||')
  for allowed in anthropic.com api.anthropic.com ${GYEOL_TRUSTED_HOSTS:-}; do
    case "$host" in
      "$allowed"|*".$allowed") return 0 ;;
    esac
  done
  return 1
}

gyeol_trust_decide() {
  case "${GYEOL_TRUST:-}" in
    0|off|no|deny|false|OFF|NO|DENY|FALSE)
      GYEOL_TRUST_STATE="deny"
      GYEOL_TRUST_REASON="GYEOL_TRUST=${GYEOL_TRUST}"
      return
      ;;
    1|on|yes|allow|true|ON|YES|ALLOW|TRUE)
      GYEOL_TRUST_STATE="allow"
      GYEOL_TRUST_REASON="GYEOL_TRUST=${GYEOL_TRUST}"
      return
      ;;
    "") ;;
    *)
      # An unrecognized value is a typo, and a typo must not read as consent.
      GYEOL_TRUST_STATE="deny"
      GYEOL_TRUST_REASON="GYEOL_TRUST=${GYEOL_TRUST} is not a recognized value"
      return
      ;;
  esac

  if [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ] || [ "${CLAUDE_CODE_USE_VERTEX:-}" = "1" ]; then
    GYEOL_TRUST_STATE="allow"
    GYEOL_TRUST_REASON="first-party cloud relay in the user's own account"
    return
  fi

  for var in ANTHROPIC_BASE_URL ANTHROPIC_API_URL; do
    eval "url=\${$var:-}"
    [ -n "$url" ] || continue
    if gyeol_trust_host_allowed "$url"; then
      GYEOL_TRUST_STATE="allow"
      GYEOL_TRUST_REASON="$var points at an allowlisted host"
    else
      GYEOL_TRUST_STATE="deny"
      GYEOL_TRUST_REASON="$var=$url is not an allowlisted host"
    fi
    return
  done

  GYEOL_TRUST_STATE="allow"
  GYEOL_TRUST_REASON="no endpoint override; the harness's own first-party API"
}

# True (exit 0) when memory must be withheld from this session.
gyeol_trust_denied() {
  [ -n "$GYEOL_TRUST_STATE" ] || gyeol_trust_decide
  [ "$GYEOL_TRUST_STATE" = "deny" ]
}

# The text a hook emits in place of memory. The agent is told, rather than left
# to wonder why it has no past: an agent that finds itself memoryless goes
# looking for the files, which is the leak the gate just prevented.
gyeol_trust_notice() {
  [ -n "$GYEOL_TRUST_STATE" ] || gyeol_trust_decide
  cat <<NOTICE
=== gyeol: memory is withheld from this session ===

The model serving this session is not trusted with memory ($GYEOL_TRUST_REASON).
Providers of free and free-tier APIs generally train on what they receive, and
memory cannot be un-sent.

For this session:
- There is no identity bootstrap. Do not reconstruct one.
- Do not read, quote, or summarize anything under the gyeol home directory,
  and do not ask the user to paste it.
- Nothing is recorded: no daily log is demanded and none should be written.
- Work normally on everything else. The user knows memory is off; say so once
  if it matters to the task, and do not work around it.

To turn memory back on, the user runs this session against a trusted provider.
NOTICE
}

# Executed rather than sourced: report and exit with the verdict.
case "$0" in
  *trust-gate.sh)
    gyeol_trust_decide
    printf '%s — %s\n' "$GYEOL_TRUST_STATE" "$GYEOL_TRUST_REASON"
    [ "$GYEOL_TRUST_STATE" = "allow" ]
    ;;
esac
