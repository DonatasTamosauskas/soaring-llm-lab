import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else '.')
from mut_common import sub
# A small steady leak at every run start: 1 in-tree node and 3 RefCounted objects kept forever.
sub('scripts/main.gd', "\t\tEvents.game_state_changed.connect(_on_game_state_changed)\n" if False else "\tEvents.game_state_changed.connect(_on_game_state_changed)\n",
    "\tEvents.game_state_changed.connect(_on_game_state_changed)\n\tEvents.run_started.connect(_r2_leak)\n")
sub('scripts/main.gd', "func _exit_tree() -> void:\n",
    "static var _r2_kept: Array = []\nfunc _r2_leak() -> void:\n\tadd_child(Node.new())\n\tfor i in 3:\n\t\t_r2_kept.append(RefCounted.new())\n\n\nfunc _exit_tree() -> void:\n")
print("[r2eng-mut] mutated: 1 node + 3 objects leaked per run start")
