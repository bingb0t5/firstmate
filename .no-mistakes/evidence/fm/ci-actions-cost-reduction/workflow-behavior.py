"""Local semantic event matrix plus execution of the actual PR gate commands.
GitHub scheduling and notification delivery remain owned by remote CI.
Run from the worktree with python3 <this-file>.
"""
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import yaml

BASE = '757f81d525d912ad27b4fe22f89bb8304376a9ab'
class Loader(yaml.SafeLoader):
    pass
Loader.yaml_implicit_resolvers = copy.deepcopy(Loader.yaml_implicit_resolvers)
for key, values in Loader.yaml_implicit_resolvers.items():
    Loader.yaml_implicit_resolvers[key] = [(tag, rx) for tag, rx in values if tag != 'tag:yaml.org,2002:bool']
Loader.add_implicit_resolver('tag:yaml.org,2002:bool', re.compile(r'^(true|false)$', re.I), list('tTfF'))
def unique_mapping(loader, node):
    pairs = loader.construct_pairs(node, deep=True)
    result = {}
    for k, v in pairs:
        assert k not in result, f'duplicate YAML key: {k}'
        result[k] = v
    return result
Loader.add_constructor('tag:yaml.org,2002:map', unique_mapping)
def load(path, revision=None):
    text = subprocess.check_output(['git', 'show', f'{revision}:{path}'], text=True) if revision else Path(path).read_text()
    return yaml.load(text, Loader=Loader)
def expr(expression, context):
    # These workflow expressions use the JS-compatible subset: property access,
    # string literals, ==, !=, && and ||. Execute the expressions, not text probes.
    expression = expression.strip().removeprefix('${{').removesuffix('}}').strip()
    js = 'const x=JSON.parse(process.argv[1]); console.log(JSON.stringify(require("node:vm").runInNewContext(x.expression,{github:x.context})))'
    return json.loads(subprocess.check_output(['node', '-e', js, json.dumps(dict(expression=expression, context=context))], text=True))
def group(w, context):
    return re.sub(r'\$\{\{(.*?)\}\}', lambda m: str(expr(m.group(1), context)), w['concurrency']['group'])
def event(name, action='', ref='refs/heads/main', number=37, author='contributor', run_id=1):
    return dict(event_name=name, ref=ref, run_id=run_id, event=dict(action=action, pull_request=dict(number=number, user=dict(login=author)) if name.startswith('pull_request') else {}))
def triggered(w, c):
    events = w['on']
    if c['event_name'] not in events:
        return False
    cfg = events[c['event_name']] or {}
    branch = c['ref'].removeprefix('refs/heads/') if c['event_name'] == 'push' else 'main'
    if cfg.get('branches') and branch not in cfg['branches']:
        return False
    if c['event_name'] in ('pull_request', 'pull_request_target'):
        return c['event']['action'] in cfg.get('types', ['opened', 'synchronize', 'reopened'])
    return True

def workflows(revision=None):
    names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', revision or 'HEAD', '.github/workflows'], text=True).splitlines()
    return {p: load(p, revision) for p in names if p.endswith(('.yml', '.yaml'))}
current, previous = workflows(), workflows(BASE)
ci = current['.github/workflows/ci.yml']
print('LOCAL SEMANTIC EVENT MATRIX (parsed workflow rules, not remote Actions execution)')
for name, c, want in [
    ('PR opened', event('pull_request', 'opened'), False),
    ('PR synchronize', event('pull_request', 'synchronize'), False),
    ('PR reopened', event('pull_request', 'reopened'), False),
    ('PR body edited', event('pull_request', 'edited'), False),
    ('main push', event('push'), True),
    ('feature push', event('push', ref='refs/heads/feature'), False),
    ('manual main', event('workflow_dispatch'), True),
    ('manual feature', event('workflow_dispatch', ref='refs/heads/feature'), True),
]:
    active = triggered(ci, c)
    mac = active and bool(expr(ci['jobs']['macos-stock-bash']['if'], c))
    assert mac == want, name
    print(f'{name}: CI={active}, macOS snapshot={mac}')

c = event('pull_request', 'synchronize')
old_count = sum(triggered(w, c) or triggered(w, event('pull_request_target', 'synchronize')) for w in previous.values())
new_count = sum(triggered(w, c) or triggered(w, event('pull_request_target', 'synchronize')) for w in current.values())
assert (old_count, new_count) == (4, 3)
assert '.github/workflows/pr-communication-sot.yml' not in current
print(f'PR synchronize workflow registrations: before={old_count}, after={new_count}')
for path, w in current.items():
    if not triggered(w, c):
        continue
    for action in ('opened', 'edited', 'synchronize', 'reopened'):
        if not triggered(w, event('pull_request', action)):
            continue
        a, b = event('pull_request', action, run_id=1), event('pull_request', 'synchronize', run_id=2)
        assert w['concurrency']['cancel-in-progress'] is True
        assert group(w, a) == group(w, b)
        assert group(w, a) != group(w, event('pull_request', action, number=38))
    print(f'{w["name"]}: PR37 group={group(w, c)}; cancel prior run={w["concurrency"]["cancel-in-progress"]}; PR38 isolated')
assert group(ci, event('push')) != group(ci, event('push', ref='refs/heads/other'))
req = current['.github/workflows/no-mistakes-required.yml']['jobs']['check']
assert req['timeout-minutes'] == 5
for author, want in [('contributor', True), ('github-actions[bot]', False), ('dependabot[bot]', False)]:
    got = bool(expr(req['if'], event('pull_request', 'opened', author=author)))
    assert got == want
    print(f'Attestation job: author={author}, selected={got}, timeout=5 minutes')
assert load('.no-mistakes.yaml')['agent'] == ['codex']
print('Strict unique-key configuration load: agent=[codex]')

print('\nACTUAL WORKFLOW SHELL EXECUTION WITH PR BODY FIXTURES')
marker = 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
steps = [dict(step=s, status='completed') for s in ('review', 'test', 'document')]
def body(items):
    return marker + '\n<!-- no-mistakes-pipeline-attestation:v1 ' + json.dumps(dict(head_sha='0'*40, steps=items)) + ' -->'
skipped = copy.deepcopy(steps)
skipped[1]['status'] = 'skipped'
for label, pr_body, expected in [('completed pipeline', body(steps), 0), ('missing signature', '', 1), ('missing attestation', marker, 1), ('malformed attestation', marker+'\n<!-- no-mistakes-pipeline-attestation:v1 {broken} -->', 1), ('skipped test', body(skipped), 1), ('missing document', body(steps[:2]), 1)]:
    proc = subprocess.run(['bash', '-e', '-c', req['steps'][0]['run']], env={**os.environ, 'PR_BODY': pr_body, 'PR_AUTHOR': 'test-author', 'PR_NUMBER': '37'}, text=True, capture_output=True)
    print(f'\n{label}: exit={proc.returncode}\n{proc.stdout}{proc.stderr}'.rstrip())
    assert proc.returncode == expected
print('\nACTUAL REMAINING COMMUNICATION WORKFLOW COMMANDS')
for label, pr_body, expected in [('complete overview', Path('tests/fixtures/pr-communication/bodies/14-ceo-overview.md').read_text(), 0), ('incomplete description', '## Summary\nA quick change.', 1)]:
    for step in current['.github/workflows/pr-communication.yml']['jobs']['pr-communication']['steps']:
        if 'run' not in step:
            continue
        proc = subprocess.run(['bash', '-e', '-c', step['run']], env={**os.environ, 'PR_BODY': pr_body, 'PR_TITLE': 'Improve request status visibility'}, text=True, capture_output=True)
        print(f'{label} / {step["name"]}: exit={proc.returncode}\n{proc.stdout}{proc.stderr}'.rstrip())
        assert proc.returncode == expected
