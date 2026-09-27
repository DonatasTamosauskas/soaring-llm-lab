# Not a mutation of the game: adds a harness (only in the private copy) that
# boots main.tscn, starts a run, flies 8 s, then quits through the game's own
# Quit path (GameMain.quit_game: audio shutdown, then get_tree().quit()).
src = '''extends Node
var main: GameMain
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = get_parent() as GameMain
	if not main.is_loaded:
		await main.loaded
	await get_tree().create_timer(1.0).timeout
	main.ui.bridge.start_run()
	await get_tree().create_timer(8.0).timeout
	print("[r3eng] quitting through GameMain.quit_game")
	main.quit_game()
'''
open('tests/shots/integration_r3quit.gd', 'w').write(src)
print("[r3eng-mut] added the quit harness (copy only)")
