#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

device=${CHECKCHECK_DEVICE:-}
if [[ -z $device ]]; then
  ids=() labels=()
  # devicectl also lists simulators, which can't run an iphoneos build.
  while IFS=$'\t' read -r id label; do
    ids+=("$id") labels+=("$label")
  done < <(xcrun devicectl list devices --quiet --json-output - | jq -r '
    .result.devices[]
    | select(.hardwareProperties.reality == "physical" and .hardwareProperties.platform == "iOS")
    | [.hardwareProperties.udid, "\(.deviceProperties.name) (\(.hardwareProperties.marketingName))"]
    | @tsv')

  case ${#ids[@]} in
    0)
      echo "No paired iPhone found. Connect it over USB once and trust this Mac." >&2
      exit 1
      ;;
    1)
      device=${ids[0]}
      echo "Installing on ${labels[0]}"
      ;;
    *)
      PS3="Install on which device? "
      select label in "${labels[@]}"; do
        if [[ -n $label ]]; then
          device=${ids[REPLY - 1]}
          break
        fi
      done
      [[ -n $device ]] || exit 1
      ;;
  esac
fi

flutter build ios --release
xcrun devicectl device install app --device "$device" build/ios/iphoneos/Runner.app
