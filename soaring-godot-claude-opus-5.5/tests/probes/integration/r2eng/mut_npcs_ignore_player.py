import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
from mut_common import sub
# NPC hunters never consider the player as prey.
sub('scripts/ai/npc_brain.gd', "if o.is_player() and not _player_open(o):", "if o.is_player():", count=0)
print("[r2eng-mut] mutated: NPCs never hunt the player")
