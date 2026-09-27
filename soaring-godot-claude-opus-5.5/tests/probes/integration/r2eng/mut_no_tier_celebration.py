import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
from mut_common import sub
# The tier-up celebration never shows.
sub('scripts/ui/ui_root.gd', "\thud.show_tier_up(old_tier, new_tier, p.mass if p else -1.0)\n", "\tpass\n")
print("[r2eng-mut] mutated: no tier-up celebration")
