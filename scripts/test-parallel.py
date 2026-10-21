#!/usr/bin/env python3
"""Runs the tests of the app in several copies of the test host at once.

Every test of OhMyMoneyTests runs inside the app, and the app keeps its settings, its files and its
logs in the container of its bundle id. Two hosts of one id would share all of that, and a test
of one would read what a test of the other just wrote. So each worker gets a copy of the host
with an id of its own (`<id>.shard<N>`, signed again with the same identity): its own container,
its own `UserDefaults`, its own files. The classes are spread over the workers by the time they
took last time (longest first, each to the least loaded worker).

The classes named in the serial list need what only one app at a time can have — the keyboard
of the active app, the menu bar — and run afterwards, one after another, in the host as built.

The run fails when any worker fails, and — on this Mac, not on CI — when any test was skipped:
a skipped test is a check that did not happen. All logs are joined into one, in the order of the
workers, so the checks that read the log of the tests read all of it.

Usage:
  test-parallel.py --products DIR --logs DIR --workers N --serial FILE --times FILE
                   --sign IDENTITY [--only Class ...] -- <arguments for xcodebuild>
"""

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import threading
import time

BUNDLE = "OhMyMoneyTests"
DESTINATION = "platform=macOS,arch=arm64"
LSREGISTER = (
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
    "/Support/lsregister"
)
SUITE_END = re.compile(
    r"^Test Suite '([A-Za-z0-9_]+)' (?:passed|failed) at .*\n\s+Executed \d+ tests?, .* in "
    r"([0-9.]+) \(",
    re.M,
)
CASE = re.compile(r"^Test Case '-\[\w+\.(\w+) (\w+)\]' (passed|failed|skipped)", re.M)
CASE_TIME = re.compile(
    r"^Test Case '-\[\w+\.(\w+) (\w+)\]' (?:passed|failed) \(([0-9.]+) seconds\)", re.M)


def say(text):
    print(f"test-parallel: {text}", flush=True)


def read_list(path):
    """Class names, one per line; `#` starts a comment."""
    if not path or not os.path.exists(path):
        return []
    names = []
    with open(path, encoding="utf-8") as file:
        for line in file:
            name = line.split("#", 1)[0].strip()
            if name:
                names.append(name)
    return names


def read_times(path):
    times = {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as file:
            for line in file:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    try:
                        times[parts[0]] = float(parts[1])
                    except ValueError:
                        pass
    return times


def write_times(path, times):
    if not path:
        return
    with open(path + ".new", "w", encoding="utf-8") as file:
        for name in sorted(times):
            file.write(f"{name}\t{times[name]:.3f}\n")
    os.replace(path + ".new", path)


def enumerate_classes(xctestrun, logs):
    """The classes of the bundle and the names of their tests, as the test host lists them."""
    out = os.path.join(logs, "test-enumeration.json")
    if os.path.exists(out):
        os.remove(out)
    command = [
        "xcodebuild", "test-without-building", "-xctestrun", xctestrun,
        "-destination", DESTINATION, f"-only-testing:{BUNDLE}", "-enumerate-tests",
        "-test-enumeration-format", "json", "-test-enumeration-output-path", out,
    ]
    with open(os.path.join(logs, "test-enumeration.log"), "w") as log:
        status = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
    if status != 0 or not os.path.exists(out):
        sys.exit("test-parallel: the tests could not be listed (test-enumeration.log)")
    with open(out, encoding="utf-8") as file:
        data = json.load(file)
    classes = {}

    def walk(node):
        if node.get("kind") == "class":
            classes[node["name"]] = [
                child["name"].rstrip("()") for child in node.get("children", [])
                if child.get("kind") == "test"]
            return
        for child in node.get("children", []):
            walk(child)

    for value in data.get("values", []):
        walk(value)
    if not classes:
        sys.exit("test-parallel: the host listed no test class")
    return classes


def spread(classes, workers, times):
    """Longest first, each to the least loaded worker. A class never timed counts its tests.

    A class that alone would take more than half a worker's share is split into its tests, so
    one long class does not hold the whole run up."""
    weight = {name: times.get(name, 0.05 * len(tests) + 0.5) for name, tests in classes.items()}
    share = sum(weight.values()) / max(1, workers)
    for name in [n for n in weight if weight[n] > share / 2 and len(classes[n]) > 1]:
        whole = weight.pop(name)
        tests = classes[name]
        for test in tests:
            weight[f"{name}/{test}"] = times.get(f"{name}/{test}", whole / len(tests))
    loads = [[0.0, i, []] for i in range(workers)]
    for name in sorted(weight, key=lambda n: (-weight[n], n)):
        load = min(loads)
        load[0] += weight[name]
        load[2].append(name)
    return [(load[1], load[0], sorted(load[2])) for load in sorted(loads, key=lambda l: l[1])]


def make_host(products, original, worker, sign):
    """A copy of the test host with an id of its own, signed again; its xctestrun beside it."""
    folder = os.path.join(products, f"Shard-{worker}")
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    app = os.path.join(folder, "OhMyMoney.app")
    subprocess.check_call(["cp", "-Rc", os.path.join(products, "Debug", "OhMyMoney.app"), app])
    info = os.path.join(app, "Contents", "Info.plist")
    with open(info, "rb") as file:
        plist = plistlib.load(file)
    identifier = f"{plist['CFBundleIdentifier']}.shard{worker}"
    plist["CFBundleIdentifier"] = identifier
    with open(info, "wb") as file:
        plistlib.dump(plist, file)
    subprocess.check_call(
        ["codesign", "--force", "--sign", sign,
         "--preserve-metadata=entitlements,flags,runtime", app],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(original, "rb") as file:
        run = plistlib.load(file)
    test = run[BUNDLE]
    test["TestHostPath"] = f"__TESTROOT__/Shard-{worker}/OhMyMoney.app"
    test["TestHostBundleIdentifier"] = identifier
    test["DependentProductPaths"] = [
        p for p in test.get("DependentProductPaths", []) if "UITests" not in p]
    keep = {k: v for k, v in run.items() if k in (BUNDLE, "__xctestrun_metadata__")}
    path = os.path.join(products, f"shard-{worker}.xctestrun")
    with open(path, "wb") as file:
        plistlib.dump(keep, file)
    return app, path


def start(xctestrun, names, log_path, result, scratch, extra):
    for path in (result, scratch):
        shutil.rmtree(path, ignore_errors=True)
    command = [
        "xcodebuild", "test-without-building", "-xctestrun", xctestrun,
        "-destination", DESTINATION, "-resultBundlePath", result, "-derivedDataPath", scratch,
    ] + [f"-only-testing:{BUNDLE}/{name}" for name in names] + extra
    log = open(log_path, "w")
    return subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log


def keep_in_front(executable, stop):
    """Brings the test host to the front, again and again, while the serial classes run.

    Since macOS 14 an app cannot take the activation for itself while another app holds it, and
    the one that holds it here is the terminal that runs the tests. System Events can still set
    a process frontmost (it needs «Accessibility» for that terminal, which the screenshots of
    the app need anyway). The process is found by its path, never by its name: the owner's copy
    of the app runs under the same name."""
    while not stop.is_set():
        found = subprocess.run(
            ["pgrep", "-f", executable], capture_output=True, text=True).stdout.split()
        for pid in found:
            subprocess.run(
                # Only when it is not in front already: activating an active app again moves
                # its key window, and with it the keyboard a test is waiting for.
                ["osascript", "-e",
                 'tell application "System Events" to tell '
                 f"(first process whose unix id is {pid}) to "
                 "if not frontmost then set frontmost to true"],
                capture_output=True)
        stop.wait(0.5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--products", required=True)
    parser.add_argument("--logs", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--serial")
    parser.add_argument("--times")
    parser.add_argument("--sign", default="-")
    parser.add_argument("--only", nargs="*", default=[])
    parser.add_argument("--prepend", help="a log to put first in test.log (the build)")
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    extra = [a for a in args.extra if a != "--"]
    on_ci = "OHMYMONEY_CI" in os.environ or "TEST_RUNNER_OHMYMONEY_CI" in os.environ

    products = os.path.realpath(args.products)
    runs = [f for f in os.listdir(products) if f.endswith(".xctestrun") and "shard" not in f]
    if len(runs) != 1:
        sys.exit(f"test-parallel: expected one .xctestrun in {products}, found {runs}")
    original = os.path.join(products, runs[0])
    os.makedirs(args.logs, exist_ok=True)
    scratch_root = os.path.join(os.path.dirname(products.rstrip("/")), "..", "TestRuns")
    scratch_root = os.path.realpath(scratch_root)

    began = time.time()
    classes = enumerate_classes(original, args.logs)
    if args.only:
        missing = [n for n in args.only if n not in classes]
        if missing:
            sys.exit(f"test-parallel: no such class: {' '.join(missing)}")
        classes = {n: classes[n] for n in args.only}
    serial_names = read_list(args.serial)
    unknown = [n for n in serial_names if n not in classes and not args.only]
    if unknown:
        sys.exit(f"test-parallel: the serial list names classes that do not exist: {unknown}")
    serial = [n for n in serial_names if n in classes]
    parallel = {n: c for n, c in classes.items() if n not in serial}
    times = read_times(args.times)
    workers = max(1, min(args.workers, len(parallel))) if parallel else 0
    plan = spread(parallel, workers, times) if workers else []
    say(f"{sum(map(len, classes.values()))} tests in {len(classes)} classes: "
        f"{len(parallel)} classes on {workers} workers, {len(serial)} after them one by one")

    hosts = []
    processes = []
    for worker, load, names in plan:
        app, xctestrun = make_host(products, original, worker + 1, args.sign)
        hosts.append(app)
        log_path = os.path.join(args.logs, f"test-worker-{worker + 1}.log")
        process, log = start(
            xctestrun, names, log_path,
            os.path.join(scratch_root, f"worker-{worker + 1}.xcresult"),
            os.path.join(scratch_root, f"worker-{worker + 1}"), extra)
        processes.append((worker + 1, process, log, log_path, load, len(names)))
        say(f"worker {worker + 1}: {len(names)} classes or tests, ≈ {load:.0f} s last time")

    failed = []
    for worker, process, log, log_path, load, count in processes:
        status = process.wait()
        log.close()
        if status != 0:
            failed.append(f"worker {worker} (test-worker-{worker}.log)")
        say(f"worker {worker} done: {'ok' if status == 0 else 'FAILED'}")
    parallel_end = time.time()

    logs = [p[3] for p in processes]
    if serial:
        log_path = os.path.join(args.logs, "test-serial.log")
        process, log = start(
            original, serial, log_path, os.path.join(scratch_root, "serial.xcresult"),
            os.path.join(scratch_root, "serial"),
            # These classes need the keyboard and the front of the screen, which the owner of the
            # Mac can take for a moment: a test that fails is tried again, up to three times in
            # all, and its last word counts. A test that is really broken fails all three.
            extra + ["-retry-tests-on-failure", "-test-iterations", "3"])
        stop = threading.Event()
        front = None
        if not on_ci:
            executable = os.path.join(products, "Debug", "OhMyMoney.app", "Contents", "MacOS", "OhMyMoney")
            front = threading.Thread(target=keep_in_front, args=(executable, stop), daemon=True)
            front.start()
        status = process.wait()
        stop.set()
        if front:
            front.join()
        log.close()
        logs.append(log_path)
        if status != 0:
            failed.append("the serial classes (test-serial.log)")
        say(f"serial classes done: {'ok' if status == 0 else 'FAILED'}")

    for app in hosts:
        subprocess.call([LSREGISTER, "-u", app], stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)

    joined = ""
    for path in ([args.prepend] if args.prepend else []) + logs:
        with open(path, encoding="utf-8", errors="replace") as file:
            joined += f"==== {os.path.basename(path)}\n" + file.read()
    with open(os.path.join(args.logs, "test.log"), "w", encoding="utf-8") as file:
        file.write(joined)

    for name, seconds in SUITE_END.findall(joined):
        if name in classes:
            times[name] = float(seconds)
    # A split class reports a suite per worker: its time is the sum of its tests.
    split = {}
    for name, test, seconds in CASE_TIME.findall(joined):
        times[f"{name}/{test}"] = float(seconds)
        split[name] = split.get(name, 0.0) + float(seconds)
    for name in {n.split("/")[0] for w in plan for n in w[2] if "/" in n}:
        times[name] = split.get(name, times.get(name, 0.0))
    write_times(args.times, times)

    # A test retried after a failure reports twice; its last word counts.
    outcome = {f"{c[0]}/{c[1]}": c[2] for c in CASE.findall(joined)}
    passed = sum(1 for v in outcome.values() if v == "passed")
    skipped = sorted(n for n, v in outcome.items() if v == "skipped")
    failures = sorted(n for n, v in outcome.items() if v == "failed")
    ran = set(outcome)
    expected = sum(map(len, classes.values()))
    say(f"{len(ran)} of {expected} tests ran: {passed} passed, {len(failures)} failed, "
        f"{len(skipped)} skipped; {parallel_end - began:.0f} s in parallel, "
        f"{time.time() - began:.0f} s in all")
    for name in failures:
        say(f"failed: {name}")
    if skipped and not on_ci:
        for name in skipped:
            say(f"skipped: {name}")
        failed.append(f"{len(skipped)} skipped on this Mac — every test must run here")
    if len(ran) < expected and not failed:
        failed.append(f"only {len(ran)} of {expected} tests reported a result")
    if failed:
        sys.exit("test-parallel: FAILED — " + "; ".join(failed))
    say("all tests passed")


if __name__ == "__main__":
    main()
