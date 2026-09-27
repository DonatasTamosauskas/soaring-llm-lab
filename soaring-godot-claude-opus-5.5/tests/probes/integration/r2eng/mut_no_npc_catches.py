import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
from mut_common import sub
# GameLoop never resolves an NPC-vs-NPC catch (the ecosystem stops eating itself).
sub('scripts/game/game_loop.gd', "\t\tvar ql := _s_flags[prey] & _F_PLAYER != 0\n",
    "\t\tvar ql := _s_flags[prey] & _F_PLAYER != 0\n\t\tif not pl and not ql:\n\t\t\tcontinue\n")
print("[r2eng-mut] mutated: no NPC-vs-NPC catches")
