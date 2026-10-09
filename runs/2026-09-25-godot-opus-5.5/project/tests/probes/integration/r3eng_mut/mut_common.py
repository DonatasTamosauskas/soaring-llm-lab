import sys
def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    if n == 0 or (count == 1 and n != 1):
        print("[r3eng-mut] snippet found %d times in %s" % (n, path)); sys.exit(3)
    s = s.replace(old, new) if count != 1 else s.replace(old, new, 1)
    open(path, 'w').write(s)
