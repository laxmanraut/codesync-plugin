#!/usr/bin/env bash
# load-env: env passthrough and .codesync/project.json marker walk-up.
. "$(dirname "$0")/lib.sh"
t_setup

# 1. Env vars win
OUT=$(cd "$T_TMP" && CODESYNC_PROJECT=testproj CODESYNC_ROLE=qa \
      bash -c "SCRIPT_DIR='$SCRIPTS'; . '$SCRIPTS/lib/load-env.sh'; echo \$CODESYNC_PROJECT/\$CODESYNC_ROLE")
t_eq "env vars pass through" "testproj/qa" "$OUT"

# 2. Marker walk-up from a nested dir, no env set
WORK="$T_TMP/work/deep/nested"
mkdir -p "$WORK"
mkdir -p "$T_TMP/work/.codesync"
printf '{"project": "testproj", "default_role": "backend"}\n' > "$T_TMP/work/.codesync/project.json"
OUT=$(cd "$WORK" && env -u CODESYNC_PROJECT -u CODESYNC_ROLE HOME="$HOME" \
      bash -c "SCRIPT_DIR='$SCRIPTS'; . '$SCRIPTS/lib/load-env.sh'; echo \$CODESYNC_PROJECT/\$CODESYNC_ROLE")
t_eq "marker walk-up resolves project+role" "testproj/backend" "$OUT"

# 3. No env, no marker → empty (silent)
OUT=$(cd "$T_TMP" && env -u CODESYNC_PROJECT -u CODESYNC_ROLE HOME="$HOME" \
      bash -c "SCRIPT_DIR='$SCRIPTS'; . '$SCRIPTS/lib/load-env.sh'; echo \"[\${CODESYNC_PROJECT:-}]\"")
t_eq "no marker leaves project unset" "[]" "$OUT"

t_done
