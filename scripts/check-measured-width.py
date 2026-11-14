#!/usr/bin/env python3
"""Conservative source guard, not a Swift type checker. Keep height rules in the shell guard."""
import re
import sys
from pathlib import Path


def findings(source):
    # Preserve offsets and line numbers while ignoring comments and string contents.
    clean = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"',
                   lambda m: re.sub(r'[^\n]', ' ', m[0]), source, flags=re.S)
    lines = source.splitlines()

    def waived(offset):
        line = source.count('\n', 0, offset)
        return any(re.search(r'//\s*geometry:\s*\S', s)
                   for s in lines[max(0, line - 1):line + 1])

    def block(start):
        opening = clean.find('{', start)
        depth = 1
        end = opening + 1
        while end < len(clean) and depth:
            depth += (clean[end] == '{') - (clean[end] == '}')
            end += 1
        return opening, end

    results = set()
    for match in re.finditer(r'\b(onGeometryChange|onScrollGeometryChange|GeometryReader)\b', clean):
        start, end = block(match.end())
        if match[1] != 'GeometryReader':
            # Include the action closure (also the trailing-closure overload).
            tail = re.match(r'\s*(?:action:\s*)?\{', clean[end:])
            if tail:
                _, end = block(end)
        body = clean[start:end]
        if not re.search(r'\.(?:size|containerSize)\s*\.\s*width\b|\.frame\s*\(', body):
            continue
        # Whole frames used only for hit testing/anchors must explain their exception too.
        tainted = {'$0'} if match[1] != 'GeometryReader' else set()
        for line in re.finditer(r'[^\n]+', body):
            text = line[0]
            offset = start + line.start()
            width = bool(re.search(r'\.(?:size|containerSize)\s*\.\s*width\b|\.frame\s*\(', text))
            if match[1] != 'GeometryReader' and ' in' in text:
                params = re.search(r'\{\s*([\w, ]+)\s+in', text)
                if params:
                    tainted.update(p.strip() for p in params[1].split(',') if p.strip() != '_')
            assignment = re.search(r'\b([\w.]+)\s*=(?!=)\s*(.*)', text)
            if not assignment:
                continue
            target, rhs = assignment.groups()
            derived = width or any(re.search(r'(?<![\w])' + re.escape(n) + r'(?![\w])', rhs)
                                   for n in tainted)
            if not derived:
                continue
            if 'MeasuredWidth.resolve(' in rhs:
                continue
            if re.search(r'\b(?:let|var)\s+' + re.escape(target), text):
                tainted.add(target)
                continue
            if not waived(offset) and not waived(match.start()):
                results.add(source.count('\n', 0, offset) + 1)
    return sorted(results)


def self_test():
    bad = [
        'v.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }',
        'v.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in\n self.width = value\n}',
        'GeometryReader { proxy in\n let room = proxy.size.width\n v.onAppear { model.width = room }\n}',
        'v.onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, new in\n width = new\n}',
        'v.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.rect = $0 }',
    ]
    good = [
        'v.measuredWidth($width)',
        'GeometryReader { proxy in\n let width = proxy.size.width\n v.frame(width: width)\n}',
        'v.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in\n width = MeasuredWidth.resolve(value, previous: width)\n}',
        'v.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {\n // geometry: anchor only\n width = $0\n}',
    ]
    assert all(findings(s) for s in bad), [(s, findings(s)) for s in bad]
    assert not any(findings(s) for s in good), [(s, findings(s)) for s in good]
    print('check-measured-width self-test: ok')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    else:
        failed = False
        files = set()
        for arg in sys.argv[1:] or ['Apps']:
            path = Path(arg)
            files.update(path.rglob('*.swift') if path.is_dir() else [path])
        for path in sorted(files):
            for line in findings(path.read_text()):
                print(f'{path}:{line}: measured width/state requires measuredWidth or MeasuredWidth.resolve '
                      '(or // geometry: reason)')
                failed = True
        sys.exit(1 if failed else 0)
