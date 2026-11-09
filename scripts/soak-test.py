#!/usr/bin/env python3
"""Overnight soak test: uses a workspace mounted by the real Mountpoint app the way Media Composer would.

  python3 scripts/soak-test.py /Volumes/<workspace> [--hours 10] [--cap-gb 20] [--keep]

Setup: create an EMPTY folder (local SSD, RAID or NAS), add it in Mountpoint as a workspace, mount it, run this.
The script only works in an empty workspace (or one it used before, marker file `.mountpoint-soak`) and only
deletes files it created itself. Media Composer should not run (it would index the test media).

What runs in parallel, until the time is up or Ctrl-C:
  capture   writes clips (1 video + 2 audio MXF files, throttled) into Avid MediaFiles/MXF/<computer>.1
            ("1" on a local mount) and rewrites the media database files (msmMMOB.mdb, msmFMID.pmr) like MC
  playback  2 players read random clips with seeks; every 10th read checks the whole file's checksum
  bins      saves bins in "Soak Project" (write .tmp, rename over, keep 5 copies in "Avid Attic")
  cleanup   deletes the oldest clips when over --cap-gb, lists the MXF folder, verifies random clips
            through the volume AND in the source folder (the mirror must show the same bytes)
  monitor   every minute: mounted?, stat latency, RSS/CPU of Mountpoint and its helper, new log errors

Report: ~/Library/Logs/Mountpoint/soak-<time>/ (events.log, samples.csv, summary.txt).
The Mac is kept awake with caffeinate while it runs.
"""
import argparse, hashlib, json, os, random, re, shutil, subprocess, sys, threading, time
from datetime import datetime

MARKER = ".mountpoint-soak"
LIBRARY = os.path.expanduser("~/Library/Application Support/Mountpoint/library.json")
APPLOG = os.path.expanduser("~/Library/Logs/Mountpoint/Mountpoint.log")
MB = 1 << 20

p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
p.add_argument("volume", help="mount point of the test workspace, e.g. /Volumes/SoakTest")
p.add_argument("--hours", type=float, default=10)
p.add_argument("--cap-gb", type=float, default=20, help="max. test media on the volume (oldest clips are deleted)")
p.add_argument("--rate", type=float, default=60, help="capture write speed in MB/s")
p.add_argument("--keep", action="store_true", help="keep the test files at the end")
p.add_argument("--small", action="store_true", help=argparse.SUPPRESS)   # quick check of the script itself: tiny files, short pauses
args = p.parse_args()
vol = os.path.realpath(args.volume)
scale = 0.01 if args.small else 1


def sh(*cmd):
    # C locale: ps prints "0.0", not "0,0" on a German Mac
    return subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"}).stdout


def mount_line():
    for line in sh("/sbin/mount").splitlines():
        m = re.match(r"(\S+) on (.+) \((.*)\)$", line)
        if m and m.group(2) == vol:
            return m.group(1), m.group(3)
    return None


# --- safety: only a workspace Mountpoint mounted, only empty or our own ---
found = mount_line()
if os.environ.get("MP_SOAK_ANY_DIR") == "1":      # tests of this script without the app
    source, local = vol, True
elif not found or not found[0].startswith("mountpoint@"):
    sys.exit(f"{vol} is not a volume mounted by Mountpoint. Mount the test workspace first.")
else:
    uuid = found[0].split("@", 1)[1]
    ws = [w for w in json.load(open(LIBRARY))["workspaces"] if w["id"].upper() == uuid.upper()]
    if not ws:
        sys.exit(f"Workspace {uuid} not found in {LIBRARY}.")
    source, local = ws[0]["path"], "local" in found[1].split(", ")
entries = [e for e in os.listdir(vol) if not e.startswith(".")]
if entries and not os.path.exists(os.path.join(vol, MARKER)):
    sys.exit(f"{vol} is not empty ({', '.join(entries[:5])}). Use an empty folder as test workspace – nothing is touched.")
open(os.path.join(vol, MARKER), "a").close()

computer = sh("/usr/sbin/scutil", "--get", "ComputerName").strip() or "Mac"
mxf = os.path.join(vol, "Avid MediaFiles", "MXF", "1" if local else computer + ".1")
project = os.path.join(vol, "Soak Project")
os.makedirs(mxf, exist_ok=True)
os.makedirs(os.path.join(project, "Avid Attic"), exist_ok=True)

report = os.path.expanduser(f"~/Library/Logs/Mountpoint/soak-{datetime.now():%Y-%m-%d-%H%M}")
os.makedirs(report, exist_ok=True)
lock = threading.Lock()
stop = threading.Event()
end = time.time() + args.hours * 3600
stats = {k: 0 for k in ["clips", "files_written", "bytes_written", "reads", "bytes_read", "verified",
                        "bins_saved", "deleted", "listings", "errors", "mismatches", "slow_ops"]}
maxlat = {}
clips = []          # [(name, [(path, sha256, size)])], oldest first


def log(level, text):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {level:5} {text}"
    with lock:
        if level in ("ERROR", "MISMATCH"):
            stats["errors" if level == "ERROR" else "mismatches"] += 1
        with open(os.path.join(report, "events.log"), "a") as f:
            f.write(line + "\n")
    if level != "INFO" or args.small:
        print(line, flush=True)


def timed(kind, fn, *a):
    """runs fn, keeps the slowest time per kind, notes anything over 2 s"""
    t = time.time()
    result = fn(*a)
    d = time.time() - t
    with lock:
        maxlat[kind] = max(maxlat.get(kind, 0), d)
        if d > 2:
            stats["slow_ops"] += 1
    if d > 2:
        log("SLOW", f"{kind} took {d:.1f} s")
    return result


def guarded(name, fn):
    """worker loop: an error is logged and the worker goes on after a pause (like an editor clicking again)"""
    def run():
        while not stop.is_set() and time.time() < end:
            try:
                fn()
            except OSError as e:
                log("ERROR", f"{name}: {e}")
                stop.wait(10)
            except Exception as e:      # a bug in this script must not end the night silently
                log("ERROR", f"{name}: {type(e).__name__}: {e}")
                stop.wait(10)
    t = threading.Thread(target=run, name=name, daemon=True)
    t.start()
    return t


def write_file(path, size, throttle=True):
    h = hashlib.sha256()
    chunk = os.urandom(MB)
    t0 = time.time()
    with open(path, "wb") as f:
        done = 0
        while done < size:
            n = min(MB, size - done)
            block = chunk[:n] if done % (8 * MB) else os.urandom(n)   # not all blocks equal
            f.write(block)
            h.update(block)
            done += n
            if throttle:
                ahead = done / (args.rate * MB) - (time.time() - t0)
                if ahead > 0:
                    time.sleep(ahead)
        f.flush()
        os.fsync(f.fileno())
    with lock:
        stats["files_written"] += 1
        stats["bytes_written"] += size
    return h.hexdigest()


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while b := f.read(MB):
            h.update(b)
    return h.hexdigest()


def replace(path, size):
    """MC-style save: write next to it, then rename over the old one"""
    tmp = path + ".tmp"
    write_file(tmp, size, throttle=False)
    timed("rename", os.replace, tmp, path)


# --- workers ---
def capture():
    tape = f"A{random.randint(1, 99):03d}C{random.randint(1, 999):03d}"
    stamp = f"{int(time.time() * 1000) & 0xFFFFFFFF:08X}"
    files = []
    for suffix, lo, hi in [("V01", 50, 300), ("A01", 10, 30), ("A02", 10, 30)]:
        path = os.path.join(mxf, f"{tape}_{suffix}.{stamp}.mxf")
        size = int(random.randint(lo, hi) * MB * scale) + random.randint(0, 4095)
        files.append((path, timed("write clip file", write_file, path, size), size))
    with lock:
        clips.append((tape, files))
        stats["clips"] += 1
    replace(os.path.join(mxf, "msmMMOB.mdb"), int(random.randint(1, 4) * MB * scale) + 512)
    replace(os.path.join(mxf, "msmFMID.pmr"), int(256 * 1024 * scale) + 512)
    log("INFO", f"captured {tape} ({sum(f[2] for f in files) // MB} MB)")
    stop.wait(random.uniform(30, 120) * scale)


def playback():
    with lock:
        pool = [f for _, files in clips for f in files]
        reads = stats["reads"]
    if not pool:
        stop.wait(5)
        return
    path, digest, size = random.choice(pool)
    if reads % 10 == 9:
        if timed("verify read", sha, path) != digest:
            log("MISMATCH", f"{path}: content differs from what was written")
        with lock:
            stats["verified"] += 1
    else:
        with open(path, "rb") as f:
            for _ in range(random.randint(20, 200)):         # scrubbing: seek, read a few frames
                f.seek(random.randrange(0, max(1, size - 4 * MB)))
                data = timed("read 1 MB", f.read, MB)
                with lock:
                    stats["bytes_read"] += len(data)
                time.sleep(0.04)
    with lock:
        stats["reads"] += 1


def bins():
    n = random.randint(1, 20)
    path = os.path.join(project, f"Bin {n:02d}.avb")
    if os.path.exists(path):
        attic = os.path.join(project, "Avid Attic", f"Bin {n:02d}.avb.{int(time.time())}")
        shutil.copyfile(path, attic)
        old = sorted(e for e in os.listdir(os.path.join(project, "Avid Attic")) if e.startswith(f"Bin {n:02d}.avb."))
        for e in old[:-5]:
            os.remove(os.path.join(project, "Avid Attic", e))
    replace(path, int(random.randint(100, 2000) * 1024 * scale) + 100)
    if random.random() < 0.1:
        replace(os.path.join(project, "Soak Project.avp"), 20 * 1024)
    with lock:
        stats["bins_saved"] += 1
    stop.wait(random.uniform(5, 20) * scale)


def cleanup():
    total = lambda: sum(f[2] for _, files in clips for f in files)
    while True:
        with lock:
            if total() <= args.cap_gb * 1024 * MB * (scale if args.small else 1) or len(clips) < 2:
                break
            tape, files = clips.pop(0)
        for path, _, _ in files:
            timed("delete", os.remove, path)
            with lock:
                stats["deleted"] += 1
        log("INFO", f"deleted oldest clip {tape}")
    names = timed("list MXF folder", os.listdir, mxf)
    with lock:
        stats["listings"] += 1
        expected = {os.path.basename(f[0]) for _, files in clips for f in files}
    missing = expected - set(names)
    if missing:
        log("ERROR", f"listing misses {len(missing)} files, e.g. {sorted(missing)[0]}")
    with lock:
        pool = [f for _, files in clips for f in files]
    if pool:
        path, digest, _ = random.choice(pool)
        src = os.path.join(source, os.path.relpath(path, vol))
        if timed("verify in source folder", sha, src) != digest:
            log("MISMATCH", f"{src}: source folder differs from what was written through the volume")
        with lock:
            stats["verified"] += 1
    stop.wait(30 * scale)


def procs():
    """RSS (MB) and CPU of the app and of the helper serving this volume"""
    out = {}
    for line in sh("/bin/ps", "-axo", "pid=,rss=,%cpu=,args=").splitlines():
        pid, rss, cpu, cmd = line.split(None, 3)
        if cmd.endswith("/Contents/MacOS/Mountpoint"):
            out["app"] = (int(rss) // 1024, float(cpu))
        elif "/mirror " in cmd and f" {vol} " in cmd:
            out["helper"] = (int(rss) // 1024, float(cpu))
    return out


def monitor_loop():
    try:
        monitor()
    except Exception as e:                  # never end the watch silently
        log("ERROR", f"monitor stopped: {type(e).__name__}: {e}")


def monitor():
    applog_pos = os.path.getsize(APPLOG) if os.path.exists(APPLOG) else 0
    with open(os.path.join(report, "samples.csv"), "w") as f:
        f.write("time,mounted,stat_ms,app_rss_mb,app_cpu,helper_rss_mb,helper_cpu,clips,gb_written,errors\n")
    down_since = None
    while not stop.is_set() and time.time() < end:
        mounted = os.environ.get("MP_SOAK_ANY_DIR") == "1" or mount_line() is not None
        t = time.time()
        try:
            os.stat(os.path.join(mxf, "missing-" + str(random.random())))
        except FileNotFoundError:
            pass
        except OSError as e:
            log("ERROR", f"probe: {e}")
        stat_ms = (time.time() - t) * 1000
        pr = procs()
        app, helper = pr.get("app", ("", "")), pr.get("helper", ("", ""))
        with lock, open(os.path.join(report, "samples.csv"), "a") as f:
            f.write(f"{datetime.now():%H:%M:%S},{int(mounted)},{stat_ms:.0f},{app[0]},{app[1]},{helper[0]},{helper[1]},"
                    f"{stats['clips']},{stats['bytes_written'] / 1024 / MB:.2f},{stats['errors']}\n")
        if not mounted:
            down_since = down_since or time.time()
            log("ERROR", "volume is not mounted")
            if time.time() - down_since > 600:
                log("ERROR", "volume gone for 10 minutes – stopping")
                stop.set()
        else:
            down_since = None
        if "app" not in pr and os.environ.get("MP_SOAK_ANY_DIR") != "1":
            log("ERROR", "Mountpoint is not running")
        if os.path.exists(APPLOG):                     # the app's own errors during the night
            size = os.path.getsize(APPLOG)
            if size < applog_pos:
                applog_pos = 0                         # rotated
            with open(APPLOG, errors="replace") as f:
                f.seek(applog_pos)
                for line in f.read().splitlines():
                    if re.search(r"fail|error|not responding|helper stopped|dead|could not", line, re.I):
                        log("APP", line)
            applog_pos = size
        stop.wait(60 * (0.05 if args.small else 1))


def summary():
    rows = [l.split(",") for l in open(os.path.join(report, "samples.csv")).read().splitlines()[1:]]
    def col(i):
        return [float(r[i]) for r in rows if r[i]]
    hours = (time.time() - started) / 3600
    lines = [f"Mountpoint soak test {datetime.fromtimestamp(started):%Y-%m-%d %H:%M} – {hours:.1f} h on {vol}",
             f"source folder: {source}", f"MXF folder: {mxf}", ""]
    lines += [f"{k}: {v}" for k, v in stats.items()]
    lines += [f"written: {stats['bytes_written'] / 1024 / MB:.1f} GB, read: {stats['bytes_read'] / 1024 / MB:.1f} GB", ""]
    lines += [f"slowest {k}: {v:.2f} s" for k, v in sorted(maxlat.items())]
    for name, i in [("app", 3), ("helper", 5)]:
        v = col(i)
        if v:
            lines.append(f"{name} memory: start {v[0]:.0f} MB, end {v[-1]:.0f} MB, max {max(v):.0f} MB")
    lines.append(f"stat probe: max {max(col(2), default=0):.0f} ms; minutes not mounted: {sum(1 for r in rows if r[1] == '0')}")
    verdict = "PASSED" if stats["errors"] == 0 and stats["mismatches"] == 0 else "PROBLEMS – see events.log"
    lines += ["", verdict]
    text = "\n".join(lines)
    open(os.path.join(report, "summary.txt"), "w").write(text + "\n")
    print("\n" + text + f"\n\nReport: {report}")


started = time.time()
caff = subprocess.Popen(["/usr/bin/caffeinate", "-ims", "-w", str(os.getpid())])
log("START", f"{vol} (source {source}, {'local' if local else 'network'} mount), {args.hours} h, cap {args.cap_gb} GB")
workers = [guarded("capture", capture), guarded("player 1", playback), guarded("player 2", playback),
           guarded("bins", bins), guarded("cleanup", cleanup)]
mon = threading.Thread(target=monitor_loop, daemon=True)
mon.start()
try:
    while time.time() < end and not stop.is_set():
        time.sleep(1)
except KeyboardInterrupt:
    log("STOP", "stopped by hand")
stop.set()
for t in workers + [mon]:
    t.join(timeout=120)
if not args.keep:                                          # only what this script created
    for _, files in clips:
        for path, _, _ in files:
            try:
                os.remove(path)
            except OSError as e:
                log("ERROR", f"cleanup: {e}")
    shutil.rmtree(project, ignore_errors=True)            # the workspace was empty at the start: the project is ours
    for name in ("msmMMOB.mdb", "msmFMID.pmr"):
        try:
            os.remove(os.path.join(mxf, name))
        except OSError:
            pass
    for d in (mxf, os.path.dirname(mxf), os.path.dirname(os.path.dirname(mxf))):
        try:
            os.rmdir(d)                                   # only if empty
        except OSError:
            pass
log("END", "done")
summary()
caff.terminate()
