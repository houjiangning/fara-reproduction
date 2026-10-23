import numpy as np

rng = np.random.default_rng(1234)
lines = []
cases = []
for _ in range(200):
    cases.append((np.float32(rng.normal()), np.float32(rng.normal())))
for _ in range(200):
    cases.append((np.float32(rng.normal() * (10.0 ** rng.integers(-20, 20))),
                  np.float32(rng.normal() * (10.0 ** rng.integers(-20, 20)))))
for _ in range(200):
    a = np.float32(rng.normal())
    cases.append((a, np.float32(-a * np.float32(1.0 + rng.normal() * 1e-3))))

for a, b in cases:
    lines.append("M %08x %08x %08x" % (a.view(np.uint32), b.view(np.uint32), np.float32(a * b).view(np.uint32)))
    lines.append("A %08x %08x %08x" % (a.view(np.uint32), b.view(np.uint32), np.float32(a + b).view(np.uint32)))

open("vec.txt", "w").write("\n".join(lines) + "\n")
print("wrote", len(lines), "lines")
