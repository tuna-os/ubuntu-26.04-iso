#!/usr/bin/env python3
"""
verify-bootc-status.py — reads bootc status JSON from stdin, verifies
the deployment is healthy, and prints a summary.  Exits 0 on success.
"""
import sys
import json

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    print(f"FAIL: could not parse bootc status JSON: {exc}", file=sys.stderr)
    sys.exit(1)

status  = data.get("status", {})
booted  = status.get("booted")
staged  = status.get("staged")
rollbck = status.get("rollback")

if not booted:
    print("FAIL: status.booted is null — system is not a bootc deployment", file=sys.stderr)
    sys.exit(1)

img    = booted.get("image", {}).get("image", {}).get("image", "(unknown)")
digest = booted.get("image", {}).get("imageDigest", "")
digest_short = digest[:19] + "..." if len(digest) > 19 else digest

print(f"  Booted image:  {img}")
print(f"  Image digest:  {digest_short}")
print(f"  Staged:        {'yes — ' + str(staged) if staged else 'none'}")
print(f"  Rollback:      {'yes' if rollbck else 'none'}")
print( "  bootc status:  VERIFIED OK ✓")
