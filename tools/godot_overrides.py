"""Set keys in a copied project's project.godot for a capture: python3 godot_overrides.py PROJECT.GODOT
[--user-dir NAME] [--autoload NAME=PATH].

Always pins the window to 1280x720: Godot's movie writer records at the project's window size, so a
--resolution that differs from it gives a zoomed crop. --user-dir gives the copy its own user://
folder: several builds are called "Soaring" and keep settings, best scores and tutorial progress
there, so without it a capture depends on, and writes into, the saves of whatever ran before.
Display and storage settings only; game logic is never touched.
"""
import re
import sys


def setting(text, section, key, value):
    line = f"{key}={value}"
    body = re.search(rf"^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[|\Z)", text, re.M | re.S)
    if not body:
        return text.rstrip("\n") + f"\n\n[{section}]\n\n{line}\n"
    start, end = body.span(1)
    if re.search(rf"^{re.escape(key)}=.*$", body.group(1), re.M):
        return text[:start] + re.sub(rf"^{re.escape(key)}=.*$", line, body.group(1), count=1, flags=re.M) + text[end:]
    return text[:start] + line + "\n" + text[start:]


def main(argv):
    path, args = argv[0], argv[1:]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = setting(text, "display", "window/size/window_width_override", "1280")
    text = setting(text, "display", "window/size/window_height_override", "720")
    while args:
        flag, value = args[0], args[1]
        args = args[2:]
        if flag == "--user-dir":
            text = setting(text, "application", "config/use_custom_user_dir", "true")
            text = setting(text, "application", "config/custom_user_dir_name", f'"{value}"')
        elif flag == "--autoload":
            name, script = value.split("=", 1)
            text = setting(text, "autoload", name, f'"*{script}"')
        else:
            raise SystemExit(f"unknown option {flag}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


if __name__ == "__main__":
    main(sys.argv[1:])
