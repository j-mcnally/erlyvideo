#!/bin/sh

PLUGINS=$(ls plugins/ | grep -v rebar.config)
SUB_DIRS=$(echo $PLUGINS | sed -e 's/\([^ ]\+\)/"\1"/g' -e 's/ /, /g')

cat > plugins/rebar.config <<EOF
{sub_dirs, [
   $SUB_DIRS
]}.
EOF

