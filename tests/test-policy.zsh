#!/bin/zsh
set -eu
readonly repo_root=${0:A:h:h}
source "$repo_root/LogiOptions-Debloat.command"
readonly fixture_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/logi-debloat-tests.XXXXXX")
trap '/bin/rm -rf -- "$fixture_root"' EXIT
local_input="$fixture_root/before.json"
cat > "$local_input" <<'JSON'
{
 "analytics":{"value":true,"extra":"keep me"},
 "flow":{"value":false},
 "sso":{"value":true},
 "logivoice":{"value":true},
 "aipromptbuilder":{"value":false},
 "device_recommendation":{"value":true},
 "smartactions":{"value":true},
 "actions_ring":{"value":false},
 "update":{"value":false},
 "dfu":{"value":true},
 "backlight":{"value":false},
 "future_feature":{"value":true,"unicode":"保持","nested":[1,2,3]}
}
JSON
stage_policy apply "$local_input" '' "$fixture_root/applied.json"
stage_policy apply "$fixture_root/applied.json" '' "$fixture_root/applied-twice.json"
stage_policy restore "$fixture_root/applied.json" "$local_input" "$fixture_root/restored.json"

print '{"analytics":{"value":true},"future_feature":{"value":true}}' > "$fixture_root/partial.json"
stage_policy apply "$fixture_root/partial.json" '' "$fixture_root/partial-applied.json"

for invalid in '{"analytics":{"value":"true"}}' '{"analytics":true}' '{"analytics":{}}' '{"other":{"value":true}}' 'broken-json'; do
  print -r -- "$invalid" > "$fixture_root/invalid.json"
  if stage_policy apply "$fixture_root/invalid.json" '' "$fixture_root/rejected.json" >/dev/null 2>&1; then
    print -u2 'FAIL: invalid input was accepted'; exit 1
  fi
done
/bin/ln -sf "$local_input" "$fixture_root/symlink.json"
if validate_policy "$fixture_root/symlink.json" >/dev/null 2>&1; then
  print -u2 'FAIL: symlink accepted'; exit 1
fi

# Restoring must retain fields added since the original backup.
/bin/cp "$fixture_root/applied.json" "$fixture_root/with-new-field.json"
/usr/bin/plutil -insert new_since_backup -json '{"value":true}' "$fixture_root/with-new-field.json"
stage_policy restore "$fixture_root/with-new-field.json" "$local_input" "$fixture_root/restored-new-field.json"

verify_policy "$fixture_root/applied.json" "$fixture_root/applied-twice.json"
if verify_policy "$fixture_root/applied.json" "$local_input" >/dev/null 2>&1; then
  print -u2 'FAIL: incorrect final values accepted'; exit 1
fi
/bin/cp "$fixture_root/applied.json" "$fixture_root/missing-after-reload.json"
/usr/bin/plutil -remove smartactions "$fixture_root/missing-after-reload.json"
if verify_policy "$fixture_root/applied.json" "$fixture_root/missing-after-reload.json" >/dev/null 2>&1; then
  print -u2 'FAIL: missing final field accepted'; exit 1
fi
/bin/cp "$local_input" "$fixture_root/atomic-target.json"
/bin/chmod 640 "$fixture_root/atomic-target.json"
file_metadata_before=$(/usr/bin/stat -f '%Lp %u %g' "$fixture_root/atomic-target.json")
write_policy "$fixture_root/applied.json" "$fixture_root/atomic-target.json"
[[ "$(/usr/bin/stat -f '%Lp %u %g' "$fixture_root/atomic-target.json")" == "$file_metadata_before" ]]
verify_policy "$fixture_root/applied.json" "$fixture_root/atomic-target.json"

python3 - "$fixture_root" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])
read=lambda n: json.loads((p/n).read_text())
before=read('before.json');after=read('applied.json')
optional=['analytics','flow','sso','logivoice','aipromptbuilder','device_recommendation','smartactions','actions_ring']
assert all(after[k]['value'] is False for k in optional)
assert all(after[k]==v for k,v in before.items() if k not in optional)
assert after['analytics']['extra']=='keep me'
assert after==read('applied-twice.json')
assert before==read('restored.json')
assert set(read('partial-applied.json'))==set(read('partial.json'))
assert read('partial-applied.json')['analytics']['value'] is False
assert read('restored-new-field.json')==dict(before,new_since_backup={'value':True})
print('PASS: eight flags, preserved settings/metadata/Unicode, idempotence, restore roundtrip, missing flags, invalid schemas, symlinks, new fields after backup, failed verification, atomic replacement preserving owner/mode.')
PY
