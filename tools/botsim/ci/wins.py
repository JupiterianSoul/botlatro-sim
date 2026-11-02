import sys, math
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "train"))
import games as G
tot_a = tot_b = 0
for pair in sys.argv[1:]:
    b, n = pair.split(":")
    B, _ = G.load(b)
    N, _ = G.load(n)
    a = c = 0
    for k in N:
        if k in B:
            x, y = G.real_win(N[k]), G.real_win(B[k])
            a += x and not y
            c += y and not x
    tot_a += a; tot_b += c
    print(n.split("/")[-1], "new only", a, "base only", c)
d = tot_a + tot_b
print("all new only", tot_a, "base only", tot_b, "z", round((tot_a - tot_b) / math.sqrt(d), 2) if d else 0)
