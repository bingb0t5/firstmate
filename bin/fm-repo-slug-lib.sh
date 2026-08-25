# shellcheck shell=bash
# Shared GitHub owner/repo parser.
# Usage: . bin/fm-repo-slug-lib.sh; fm_repo_slug_parse "<origin-or-pr-url>"
#
# ONE OWNER for turning a GitHub remote or PR URL into its canonical owner/repo
# identity and for validating that identity before callers use it.

FM_REPO_SLUG_STATUS=
FM_REPO_SLUG=

fm_repo_slug_valid() {  # <owner/repo>
  local slug=$1 owner repo
  case "$slug" in
    */*/*|/*|*/|*[!a-z0-9._/-]*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  owner=${slug%%/*}
  repo=${slug#*/}
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  [ "$owner" != . ] && [ "$owner" != .. ] || return 1
  [ "$repo" != . ] && [ "$repo" != .. ] || return 1
}

fm_repo_slug_parse() {  # <origin-or-pr-url>
  local origin=${1-} transport= rest= authority= path= userinfo= hostport= host= port=
  local owner= repo= tail= number= has_userinfo=0
  FM_REPO_SLUG_STATUS=
  FM_REPO_SLUG=

  [ -n "$origin" ] || { FM_REPO_SLUG_STATUS=invalid-origin; return 1; }
  case "$origin" in
    *[[:cntrl:][:space:]]*|*\?*|*\#*) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;;
  esac

  case "$origin" in
    https://*) transport=https; rest=${origin#https://} ;;
    ssh://*) transport=ssh; rest=${origin#ssh://} ;;
    *://*) FM_REPO_SLUG_STATUS=unsupported-transport; return 1 ;;
    *) transport=scp; rest=$origin ;;
  esac

  if [ "$transport" = scp ]; then
    case "$rest" in *:*) ;; *) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
    authority=${rest%%:*}
    path=${rest#*:}
    case "$authority" in */*|*:*) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
  else
    case "$rest" in */*) ;; *) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
    authority=${rest%%/*}
    path=/${rest#*/}
  fi
  [ -n "$authority" ] && [ -n "$path" ] \
    || { FM_REPO_SLUG_STATUS=invalid-origin; return 1; }

  case "$authority" in
    *@*)
      userinfo=${authority%@*}
      hostport=${authority##*@}
      has_userinfo=1
      [ -n "$userinfo" ] && [ -n "$hostport" ] \
        || { FM_REPO_SLUG_STATUS=invalid-origin; return 1; }
      case "$userinfo" in *@*) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
      ;;
    *) hostport=$authority ;;
  esac

  if [ "$transport" = scp ]; then
    host=$hostport
  else
    case "$hostport" in
      *:*)
        host=${hostport%:*}
        port=${hostport##*:}
        [ -n "$host" ] && [ -n "$port" ] \
          || { FM_REPO_SLUG_STATUS=invalid-origin; return 1; }
        case "$host" in *:*) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
        case "$port" in *[!0-9]*) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
        ;;
      *) host=$hostport ;;
    esac
  fi
  host=$(printf '%s' "$host" | tr 'A-Z' 'a-z')
  [ "$host" = github.com ] \
    || { FM_REPO_SLUG_STATUS=unsupported-host; return 1; }

  case "$path" in */) path=${path%/} ;; esac
  [ -n "$path" ] || { FM_REPO_SLUG_STATUS=invalid-origin; return 1; }
  if [ "$transport" != scp ]; then
    case "$path" in /*) path=${path#/} ;; *) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
  fi
  case "$path" in /*|*/|*//* ) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac

  case "$path" in
    */pull/*)
      [ "$transport" = https ] && [ "$has_userinfo" -eq 0 ] && [ -z "$port" ] \
        || { FM_REPO_SLUG_STATUS=invalid-origin; return 1; }
      owner=${path%%/*}
      tail=${path#*/}
      repo=${tail%%/*}
      tail=${tail#*/}
      [ "${tail%%/*}" = pull ] && [ "$tail" != "${tail%%/*}" ] \
        || { FM_REPO_SLUG_STATUS=invalid-origin; return 1; }
      number=${tail#*/}
      case "$number" in ''|*[!0-9]*|*/*) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
      case "$number" in *[1-9]*) ;; *) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
      ;;
    *)
      case "$path" in */*/*|/*|*/) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
      case "$path" in */*) ;; *) FM_REPO_SLUG_STATUS=invalid-origin; return 1 ;; esac
      owner=${path%%/*}
      repo=${path#*/}
      ;;
  esac

  case "$repo" in *.git) repo=${repo%.git} ;; esac
  owner=$(printf '%s' "$owner" | tr 'A-Z' 'a-z')
  repo=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')
  FM_REPO_SLUG="$owner/$repo"
  if ! fm_repo_slug_valid "$FM_REPO_SLUG"; then
    FM_REPO_SLUG=
    FM_REPO_SLUG_STATUS=invalid-origin
    return 1
  fi
  FM_REPO_SLUG_STATUS=ok
  return 0
}
