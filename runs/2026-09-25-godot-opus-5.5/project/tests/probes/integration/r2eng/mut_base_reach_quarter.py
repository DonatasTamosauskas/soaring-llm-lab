import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
from mut_common import sub
# The player's BASE catch reach (no assist) shrinks to a quarter; assisted catches keep theirs.
sub('scripts/game/catch_rule.gd', "\t\treturn pred_span * player_reach_spans()\n",
    "\t\treturn pred_span * player_reach_spans() * (1.0 if player_assist > 0.0 else 0.25)\n")
print("[r2eng-mut] mutated: base (unassisted) player reach x0.25")
