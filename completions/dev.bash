# bash completion for ./dev  (sourced by the nix devShell; or: source completions/dev.bash)
_dev_complete() {
  local cur prev cmds tests
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  cmds="build run shot test check fmt lint compiledb doctor watch help"
  tests="font loopback ws_loopback engine_e2e obd2 smoke all"

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur")); return
  fi

  # targets = the shell apps + mcp + example basenames
  local examples targets
  examples="$(ls examples/*.lua 2>/dev/null | sed 's|examples/||; s|\.lua$||' | tr '\n' ' ')"
  targets="auto dash gcs rov mcp $examples"

  case "${COMP_WORDS[1]}" in
    run | shot | watch) COMPREPLY=($(compgen -W "$targets" -- "$cur")) ;;
    test) COMPREPLY=($(compgen -W "$tests" -- "$cur")) ;;
    build) COMPREPLY=($(compgen -W "dcf" -- "$cur")) ;;
    fmt | lint) COMPREPLY=($(compgen -W "--all" -- "$cur")) ;;
    check) COMPREPLY=($(compgen -W "--fast" -- "$cur")) ;;
  esac
}
complete -F _dev_complete dev ./dev
